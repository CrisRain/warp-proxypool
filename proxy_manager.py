import threading
import subprocess
import time
from queue import Queue
from flask import Flask, jsonify, request
import socket
import struct
import socks  # For connecting to backend SOCKS5 WARP (pip install PySocks)

app = Flask(__name__)

# --- Logging ---
def log_message(message):
    """Helper function for logging with a timestamp."""
    print(f"[{time.strftime('%Y-%m-%d %H:%M:%S')}] {message}")

# --- SOCKS5 Server Configuration ---
SOCKS_SERVER_HOST = '0.0.0.0'
SOCKS_SERVER_PORT = 10880
SOCKS_VERSION = 5
# SOCKS5 CMD
CMD_CONNECT = 0x01
# SOCKS5 ATYP
ATYP_IPV4 = 0x01
ATYP_DOMAINNAME = 0x03
ATYP_IPV6 = 0x04
# SOCKS5 Reply Codes (status)
REP_SUCCESS = 0x00
REP_GENERAL_FAILURE = 0x01
REP_CONNECTION_NOT_ALLOWED = 0x02 # ruleset
REP_NETWORK_UNREACHABLE = 0x03
REP_HOST_UNREACHABLE = 0x04
REP_CONNECTION_REFUSED = 0x05
REP_TTL_EXPIRED = 0x06
REP_COMMAND_NOT_SUPPORTED = 0x07
REP_ADDRESS_TYPE_NOT_SUPPORTED = 0x08


# --- Backend WARP Proxy Pool Configuration ---
# Note: These should align with your create_warp_pool.sh script
POOL_SIZE = 5  # Number of WARP instances, should match NUM_INSTANCES in create_warp_pool.sh
BACKEND_BASE_PORT = 40000 # Starting port for backend WARP SOCKS5 instances (e.g., 40000, 40001, ...)
WARP_INSTANCE_IP = '127.0.0.1' # Backend WARP instances listen on localhost for the manager
IP_REFRESH_WAIT = 5  # IP刷新等待时间(秒)

# 代理状态管理
available_proxies = Queue() # Stores backend WARP ports (e.g., 40000, 40001)
in_use_proxies = {} # Stores info about backend WARP ports in use (by SOCKS or API)
proxy_lock = threading.Lock() # Lock for available_proxies and in_use_proxies

# 初始化代理池 (stores backend WARP ports)
log_message(f"Initializing backend proxy pool. Size: {POOL_SIZE}, Start Port: {BACKEND_BASE_PORT}")
for i in range(POOL_SIZE):
    port_to_add = BACKEND_BASE_PORT + i
    available_proxies.put(port_to_add)
    log_message(f"Added backend port {port_to_add} to available pool.")

def refresh_proxy_ip(backend_warp_port):
    """
    Refreshes the IP address of the specified backend WARP proxy instance.
    'backend_warp_port' is the port like 40000, 40001, etc.
    """
    # Calculate the index based on the BACKEND_BASE_PORT
    proxy_index = backend_warp_port - BACKEND_BASE_PORT
    ns_name = f"ns{proxy_index}" # Assumes ns0, ns1, ... correspond to 40000, 40001, ...
    
    log_message(f"Attempting to refresh IP for backend WARP on port {backend_warp_port} (namespace {ns_name})...")
    try:
        # 断开WARP连接
        log_message(f"Disconnecting WARP in {ns_name}...")
        subprocess.run(
            f"sudo ip netns exec {ns_name} warp-cli disconnect",
            shell=True, check=True, timeout=15 # Increased timeout slightly
        )
        log_message(f"WARP disconnected in {ns_name}.")
        
        # 重新连接WARP
        log_message(f"Connecting WARP in {ns_name}...")
        subprocess.run(
            f"sudo ip netns exec {ns_name} warp-cli connect",
            shell=True, check=True, timeout=15 # Increased timeout slightly
        )
        log_message(f"WARP connected in {ns_name}.")
        
        # 等待连接稳定
        log_message(f"Waiting {IP_REFRESH_WAIT}s for WARP on port {backend_warp_port} ({ns_name}) to stabilize IP...")
        time.sleep(IP_REFRESH_WAIT)
        log_message(f"IP for backend WARP on port {backend_warp_port} ({ns_name}) assumed refreshed.")
        return True
    except subprocess.TimeoutExpired as e_timeout:
        log_message(f"Timeout during IP refresh for backend WARP on port {backend_warp_port} ({ns_name}): {e_timeout}")
        return False
    except subprocess.CalledProcessError as e_called:
        log_message(f"CalledProcessError during IP refresh for backend WARP on port {backend_warp_port} ({ns_name}): {e_called}")
        return False
    except Exception as e:
        log_message(f"Generic failure during IP refresh for backend WARP on port {backend_warp_port} ({ns_name}): {str(e)}")
        return False

def _refresh_and_return_task(port_to_refresh):
    """
    Refreshes the IP of a backend WARP proxy and returns it to the available pool.
    This runs in a separate thread.
    'port_to_refresh' is a backend WARP port (e.g., 40000).
    """
    log_message(f"BG TASK: Initiating IP refresh for backend port {port_to_refresh}...")
    refreshed_successfully = refresh_proxy_ip(port_to_refresh)
    
    # Always return the port to the pool, regardless of refresh success,
    # so it doesn't get lost. The SOCKS server or API can decide what to do.
    with proxy_lock:
        available_proxies.put(port_to_refresh)
    
    if refreshed_successfully:
        log_message(f"BG TASK: Backend port {port_to_refresh} returned to pool after successful IP refresh.")
    else:
        log_message(f"BG TASK: Backend port {port_to_refresh} returned to pool (IP refresh FAILED or was skipped).")

@app.route('/acquire', methods=['GET'])
def acquire_proxy():
    """
    Acquires a backend WARP port. The client should then use the central SOCKS5 server.
    Returns the central SOCKS5 server address and the acquired backend port (as a token for release).
    """
    with proxy_lock:
        if available_proxies.empty():
            log_message(f"API /acquire: No available backend proxies for {request.remote_addr}")
            return jsonify({"error": "No available backend proxies"}), 503
        
        backend_port_acquired = available_proxies.get() # This is a backend WARP port, e.g., 40000
        
        # Determine the IP address the client should use to connect to the central SOCKS server.
        client_facing_socks_host = request.host.split(':')[0]
        if SOCKS_SERVER_HOST != '0.0.0.0':
            client_facing_socks_host = SOCKS_SERVER_HOST

        in_use_proxies[backend_port_acquired] = {
            "type": "api_acquired",
            "acquired_at": time.time(),
            "api_client_ip": request.remote_addr,
            "central_socks_server_advertised": f"{client_facing_socks_host}:{SOCKS_SERVER_PORT}",
            "backend_port_in_use": backend_port_acquired
        }
        log_message(f"API /acquire: Backend WARP port {backend_port_acquired} acquired by {request.remote_addr}. "
                    f"Client should use central SOCKS: {client_facing_socks_host}:{SOCKS_SERVER_PORT}")
        
        return jsonify({
            "proxy_to_use": f"socks5://{client_facing_socks_host}:{SOCKS_SERVER_PORT}",
            "backend_port_token_for_release": backend_port_acquired,
            "message": f"Connect to the central SOCKS5 server at '{client_facing_socks_host}:{SOCKS_SERVER_PORT}'. "
                       f"Use 'backend_port_token_for_release' ({backend_port_acquired}) when calling /release."
        })

@app.route('/release/<int:backend_port_token>', methods=['POST'])
def release_proxy(backend_port_token):
    """
    Releases a previously API-acquired backend WARP proxy (specified by backend_port_token)
    and initiates IP refresh in a background thread.
    """
    log_message(f"API /release: Request from {request.remote_addr} to release backend port token {backend_port_token}.")
    with proxy_lock:
        if backend_port_token not in in_use_proxies:
            log_message(f"API /release: Backend port token {backend_port_token} not found in in_use_proxies for {request.remote_addr}.")
            return jsonify({"error": f"Backend port token {backend_port_token} not in use or invalid"}), 400
        
        proxy_info = in_use_proxies.get(backend_port_token)
        if not proxy_info or proxy_info.get("type") != "api_acquired":
            log_message(f"API /release WARNING: Releasing port {backend_port_token} which might not be 'api_acquired'. Current type: {proxy_info.get('type') if proxy_info else 'N/A'}")

        del in_use_proxies[backend_port_token]
        log_message(f"API /release: Backend port {backend_port_token} removed from in_use_proxies by {request.remote_addr}.")

    threading.Thread(target=_refresh_and_return_task, args=(backend_port_token,)).start()
    log_message(f"API /release: Background IP refresh task started for backend port {backend_port_token}.")
    
    return jsonify({"status": f"Release and IP refresh initiated for backend port {backend_port_token}"})

@app.route('/status', methods=['GET'])
def pool_status():
    """获取后端WARP代理池状态以及中央SOCKS服务器信息"""
    with proxy_lock:
        current_in_use_details = {}
        for port, info in in_use_proxies.items():
            info_copy = info.copy()
            # Ensure client_address_on_socks_server is serializable if it exists
            if "client_address_on_socks_server" in info_copy and isinstance(info_copy["client_address_on_socks_server"], tuple):
                 info_copy["client_address_on_socks_server"] = f"{info_copy['client_address_on_socks_server'][0]}:{info_copy['client_address_on_socks_server'][1]}"
            current_in_use_details[port] = info_copy

        return jsonify({
            "central_socks5_server_listening_on": f"{SOCKS_SERVER_HOST}:{SOCKS_SERVER_PORT}",
            "backend_warp_pool_size": POOL_SIZE,
            "available_backend_ports_count": available_proxies.qsize(),
            "available_backend_ports_list": list(available_proxies.queue),
            "in_use_backend_ports_count": len(in_use_proxies),
            "in_use_backend_ports_details": current_in_use_details
        })

# --- SOCKS5 Server Implementation ---

def _forward_data(source_sock, dest_sock, stop_event, direction_log):
    """Forwards data between two sockets until an error or stop_event."""
    try:
        source_sock.settimeout(1.0) 
        while not stop_event.is_set():
            try:
                data = source_sock.recv(4096) 
            except socket.timeout:
                if stop_event.is_set(): break 
                continue 
            except ConnectionResetError:
                log_message(f"FORWARDER {direction_log}: Connection reset by peer.")
                break
            except Exception as e:
                if stop_event.is_set(): break 
                log_message(f"FORWARDER {direction_log}: Error receiving data: {e}")
                break
            
            if not data:
                log_message(f"FORWARDER {direction_log}: Connection closed by source (received empty data).")
                break
            
            try:
                dest_sock.sendall(data)
            except socket.error as e: 
                if stop_event.is_set(): break
                log_message(f"FORWARDER {direction_log}: Socket error sending data: {e}")
                break
            except Exception as e:
                if stop_event.is_set(): break
                log_message(f"FORWARDER {direction_log}: Generic error sending data: {e}")
                break
    except Exception as e:
        if not stop_event.is_set(): 
             log_message(f"FORWARDER {direction_log}: Unhandled exception in forwarding loop: {e}")
    finally:
        log_message(f"FORWARDER {direction_log}: Stopping.")
        stop_event.set()

def _release_backend_port_after_socks_usage(backend_port_to_release, refresh_ip_flag=True):
    """
    Manages releasing a backend port after SOCKS usage.
    Removes from in_use_proxies and optionally schedules IP refresh.
    """
    log_message(f"SOCKS_CLEANUP: Releasing backend port {backend_port_to_release}. Refresh IP: {refresh_ip_flag}")
    with proxy_lock:
        if backend_port_to_release in in_use_proxies:
            usage_type = in_use_proxies[backend_port_to_release].get("type", "unknown")
            if usage_type != "socks_direct":
                log_message(f"SOCKS_CLEANUP WARNING: Port {backend_port_to_release} type is '{usage_type}', not 'socks_direct'. Still releasing.")
            del in_use_proxies[backend_port_to_release]
        else:
            log_message(f"SOCKS_CLEANUP WARNING: Backend port {backend_port_to_release} not found in in_use_proxies during SOCKS release.")

    if refresh_ip_flag:
        threading.Thread(target=_refresh_and_return_task, args=(backend_port_to_release,)).start()
        log_message(f"SOCKS_CLEANUP: Background IP refresh task started for {backend_port_to_release}.")
    else:
        with proxy_lock:
            available_proxies.put(backend_port_to_release)
        log_message(f"SOCKS_CLEANUP: Backend port {backend_port_to_release} returned to pool (IP refresh skipped).")

def handle_socks_client_connection(client_socket, client_address_tuple):
    """Handles a single SOCKS5 client connection."""
    client_ip_str = client_address_tuple[0]
    log_message(f"SOCKS_HANDLER: New client connection from {client_ip_str}:{client_address_tuple[1]}")
    
    acquired_backend_port = None 
    remote_connection_to_target = None 

    try:
        client_socket.settimeout(10.0) 
        ver_nmethods = client_socket.recv(2)
        if not ver_nmethods or ver_nmethods[0] != SOCKS_VERSION:
            log_message(f"SOCKS_HANDLER {client_ip_str}: Invalid SOCKS version. Expected {SOCKS_VERSION}, got {ver_nmethods[0] if ver_nmethods else 'None'}.")
            return 
        
        num_auth_methods = ver_nmethods[1]
        auth_methods_offered = client_socket.recv(num_auth_methods)
        if b'\x00' not in auth_methods_offered: 
            log_message(f"SOCKS_HANDLER {client_ip_str}: No supported authentication method. Offered: {auth_methods_offered.hex()}. We need 0x00.")
            client_socket.sendall(struct.pack("!BB", SOCKS_VERSION, 0xFF)) 
            return
        
        client_socket.sendall(struct.pack("!BB", SOCKS_VERSION, 0x00)) 
        log_message(f"SOCKS_HANDLER {client_ip_str}: Handshake successful (No Auth).")

        request_header = client_socket.recv(4) 
        if not request_header or request_header[0] != SOCKS_VERSION:
            log_message(f"SOCKS_HANDLER {client_ip_str}: Invalid SOCKS version in request.")
            return
        
        req_ver, req_cmd, req_rsv, req_atyp = request_header
        
        if req_cmd != CMD_CONNECT:
            log_message(f"SOCKS_HANDLER {client_ip_str}: Unsupported command {req_cmd}. Only CONNECT ({CMD_CONNECT}) is supported.")
            reply = struct.pack("!BBBB", SOCKS_VERSION, REP_COMMAND_NOT_SUPPORTED, 0x00, ATYP_IPV4) + socket.inet_aton("0.0.0.0") + struct.pack("!H", 0)
            client_socket.sendall(reply)
            return

        target_host_str = ""
        if req_atyp == ATYP_IPV4:
            addr_bytes = client_socket.recv(4)
            target_host_str = socket.inet_ntoa(addr_bytes)
        elif req_atyp == ATYP_DOMAINNAME:
            domain_len = client_socket.recv(1)[0]
            addr_bytes = client_socket.recv(domain_len)
            target_host_str = addr_bytes.decode("utf-8", errors="ignore")
        elif req_atyp == ATYP_IPV6:
            addr_bytes = client_socket.recv(16)
            target_host_str = socket.inet_ntop(socket.AF_INET6, addr_bytes)
        else:
            log_message(f"SOCKS_HANDLER {client_ip_str}: Unsupported address type {req_atyp}.")
            reply = struct.pack("!BBBB", SOCKS_VERSION, REP_ADDRESS_TYPE_NOT_SUPPORTED, 0x00, ATYP_IPV4) + socket.inet_aton("0.0.0.0") + struct.pack("!H", 0)
            client_socket.sendall(reply)
            return
            
        target_port_bytes = client_socket.recv(2)
        target_port_int = struct.unpack("!H", target_port_bytes)[0]
        log_message(f"SOCKS_HANDLER {client_ip_str}: Request CONNECT to {target_host_str}:{target_port_int}")

        with proxy_lock:
            if available_proxies.empty():
                log_message(f"SOCKS_HANDLER {client_ip_str}: No backend WARP proxies available for -> {target_host_str}:{target_port_int}")
                reply = struct.pack("!BBBB", SOCKS_VERSION, REP_GENERAL_FAILURE, 0x00, ATYP_IPV4) + socket.inet_aton("0.0.0.0") + struct.pack("!H", 0) 
                client_socket.sendall(reply)
                return
            acquired_backend_port = available_proxies.get() 
            in_use_proxies[acquired_backend_port] = {
                "type": "socks_direct",
                "client_address_on_socks_server": client_address_tuple, # Store the tuple directly
                "requested_target_host": target_host_str,
                "requested_target_port": target_port_int,
                "backend_warp_port_used": acquired_backend_port,
                "acquired_at": time.time()
            }
        log_message(f"SOCKS_HANDLER {client_ip_str}: Acquired backend WARP {WARP_INSTANCE_IP}:{acquired_backend_port} for -> {target_host_str}:{target_port_int}")

        try:
            log_message(f"SOCKS_HANDLER {client_ip_str}: Connecting to ({target_host_str}, {target_port_int}) via backend SOCKS5 {WARP_INSTANCE_IP}:{acquired_backend_port}...")
            remote_connection_to_target = socks.create_connection(
                (target_host_str, target_port_int), 
                proxy_type=socks.SOCKS5,
                proxy_addr=WARP_INSTANCE_IP,    
                proxy_port=acquired_backend_port, 
                timeout=20 
            )
            log_message(f"SOCKS_HANDLER {client_ip_str}: Successfully connected to {target_host_str}:{target_port_int} via backend WARP {WARP_INSTANCE_IP}:{acquired_backend_port}")
            
            bound_addr_bytes = socket.inet_aton("0.0.0.0") 
            bound_port_bytes = struct.pack("!H", 0) 
            reply = struct.pack("!BBBB", SOCKS_VERSION, REP_SUCCESS, 0x00, ATYP_IPV4) + bound_addr_bytes + bound_port_bytes
            client_socket.sendall(reply)

        except socks.ProxyConnectionError as e_pysocks: 
            log_message(f"SOCKS_HANDLER {client_ip_str}: Backend WARP {WARP_INSTANCE_IP}:{acquired_backend_port} could not connect to target {target_host_str}:{target_port_int}. PySocks Error: {e_pysocks}")
            socks_reply_code = REP_HOST_UNREACHABLE 
            if "Connection refused" in str(e_pysocks): socks_reply_code = REP_CONNECTION_REFUSED
            elif "Host unreachable" in str(e_pysocks): socks_reply_code = REP_HOST_UNREACHABLE
            elif "Network is unreachable" in str(e_pysocks): socks_reply_code = REP_NETWORK_UNREACHABLE
            reply = struct.pack("!BBBB", SOCKS_VERSION, socks_reply_code, 0x00, ATYP_IPV4) + socket.inet_aton("0.0.0.0") + struct.pack("!H", 0)
            client_socket.sendall(reply)
            _release_backend_port_after_socks_usage(acquired_backend_port, refresh_ip_flag=False) 
            acquired_backend_port = None 
            return
        except socket.timeout: 
            log_message(f"SOCKS_HANDLER {client_ip_str}: Timeout connecting to {target_host_str}:{target_port_int} via backend WARP {WARP_INSTANCE_IP}:{acquired_backend_port}")
            reply = struct.pack("!BBBB", SOCKS_VERSION, REP_TTL_EXPIRED, 0x00, ATYP_IPV4) + socket.inet_aton("0.0.0.0") + struct.pack("!H", 0)
            client_socket.sendall(reply)
            _release_backend_port_after_socks_usage(acquired_backend_port, refresh_ip_flag=False)
            acquired_backend_port = None
            return
        except socket.gaierror as e_dns: 
            log_message(f"SOCKS_HANDLER {client_ip_str}: DNS resolution failed for target {target_host_str}. Error: {e_dns}")
            reply = struct.pack("!BBBB", SOCKS_VERSION, REP_HOST_UNREACHABLE, 0x00, ATYP_IPV4) + socket.inet_aton("0.0.0.0") + struct.pack("!H", 0)
            client_socket.sendall(reply)
            _release_backend_port_after_socks_usage(acquired_backend_port, refresh_ip_flag=False)
            acquired_backend_port = None
            return
        except Exception as e_conn_target: 
            log_message(f"SOCKS_HANDLER {client_ip_str}: Generic error connecting to {target_host_str}:{target_port_int} via backend WARP {WARP_INSTANCE_IP}:{acquired_backend_port}. Error: {e_conn_target}")
            reply = struct.pack("!BBBB", SOCKS_VERSION, REP_GENERAL_FAILURE, 0x00, ATYP_IPV4) + socket.inet_aton("0.0.0.0") + struct.pack("!H", 0)
            client_socket.sendall(reply)
            _release_backend_port_after_socks_usage(acquired_backend_port, refresh_ip_flag=False)
            acquired_backend_port = None
            return

        log_message(f"SOCKS_HANDLER {client_ip_str}: Relaying data between client and {target_host_str}:{target_port_int} (via backend {acquired_backend_port})")
        client_socket.settimeout(None) 
        remote_connection_to_target.settimeout(None)

        stop_event = threading.Event()
        
        thread_client_to_target = threading.Thread(target=_forward_data, args=(client_socket, remote_connection_to_target, stop_event, f"Client({client_ip_str})->Target({target_host_str})"))
        thread_target_to_client = threading.Thread(target=_forward_data, args=(remote_connection_to_target, client_socket, stop_event, f"Target({target_host_str})->Client({client_ip_str})"))
        
        thread_client_to_target.daemon = True 
        thread_target_to_client.daemon = True
        thread_client_to_target.start()
        thread_target_to_client.start()
        
        stop_event.wait() 

        log_message(f"SOCKS_HANDLER {client_ip_str}: Data relay finished for <-> {target_host_str}:{target_port_int} (Backend {acquired_backend_port}).")

    except ConnectionResetError:
        log_message(f"SOCKS_HANDLER {client_ip_str}: Client reset connection during operation.")
    except BrokenPipeError: 
        log_message(f"SOCKS_HANDLER {client_ip_str}: Broken pipe (client likely closed connection).")
    except socket.timeout: 
        log_message(f"SOCKS_HANDLER {client_ip_str}: Socket timeout during initial handshake/request phase.")
    except Exception as e_handler:
        log_message(f"SOCKS_HANDLER {client_ip_str}: Unhandled error in client handler: {e_handler}")
        import traceback
        log_message(traceback.format_exc())
    finally:
        log_message(f"SOCKS_HANDLER {client_ip_str}: Cleaning up SOCKS connection.")
        if remote_connection_to_target:
            try:
                remote_connection_to_target.close()
            except Exception as e_close_remote:
                log_message(f"SOCKS_HANDLER {client_ip_str}: Error closing remote_connection_to_target: {e_close_remote}")
        try:
            client_socket.close()
        except Exception as e_close_client:
            log_message(f"SOCKS_HANDLER {client_ip_str}: Error closing client_socket: {e_close_client}")
        
        if acquired_backend_port is not None: 
            _release_backend_port_after_socks_usage(acquired_backend_port, refresh_ip_flag=True)
        
        log_message(f"SOCKS_HANDLER {client_ip_str}: Connection fully closed and resources handled.")

def start_central_socks5_server():
    """Initializes and starts the SOCKS5 proxy server, listening for client connections."""
    listener_socket = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    listener_socket.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1) 
    try:
        listener_socket.bind((SOCKS_SERVER_HOST, SOCKS_SERVER_PORT))
        listener_socket.listen(128) 
        log_message(f"Central SOCKS5 server successfully started, listening on {SOCKS_SERVER_HOST}:{SOCKS_SERVER_PORT}")
    except Exception as e_bind:
        log_message(f"CRITICAL_ERROR: Could not bind or start SOCKS5 server on {SOCKS_SERVER_HOST}:{SOCKS_SERVER_PORT}. Error: {e_bind}")
        return 

    while True: 
        try:
            client_conn_socket, client_address_info = listener_socket.accept()
            client_handler_thread = threading.Thread(
                target=handle_socks_client_connection, 
                args=(client_conn_socket, client_address_info)
            )
            client_handler_thread.daemon = True 
            client_handler_thread.start()
        except Exception as e_accept:
            log_message(f"SOCKS_SERVER_LOOP: Error accepting new client connection: {e_accept}")
            time.sleep(0.01) # Avoid busy-looping on persistent accept errors
# --- Main Application Execution ---
if __name__ == '__main__':
    log_message("Proxy Manager Service is starting...")
    log_message("Important: This script may use 'sudo' for 'ip netns exec warp-cli' commands during IP refresh.")
    log_message("Please ensure that PySocks is installed: 'pip install PySocks'")
    log_message(f"Current backend WARP pool size: {POOL_SIZE}, Base Port for backends: {BACKEND_BASE_PORT}")
    log_message(f"Initial available backend ports in queue: {list(available_proxies.queue)}")

    # Start the Central SOCKS5 Server in a separate daemon thread
    log_message(f"Initiating Central SOCKS5 server thread to listen on {SOCKS_SERVER_HOST}:{SOCKS_SERVER_PORT}...")
    socks_server_daemon_thread = threading.Thread(target=start_central_socks5_server, daemon=True)
    socks_server_daemon_thread.start()
    
    # Basic check if thread started (doesn't guarantee server is bound and listening)
    if socks_server_daemon_thread.is_alive():
        log_message("Central SOCKS5 server thread has been started.")
    else:
        log_message("Warning: Central SOCKS5 server thread was initiated but may not be running (check logs for bind errors).")

    # Start the Flask HTTP API server
    log_message(f"Starting Flask HTTP API server on host 0.0.0.0, port 5000.")
    try:
        app.run(host='0.0.0.0', port=5000, threaded=True)
    except Exception as e_flask:
        log_message(f"CRITICAL_ERROR: Flask API server failed to start: {e_flask}")
    
    log_message("Proxy Manager Service is shutting down or Flask server exited.")