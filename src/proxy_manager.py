import threading
import subprocess
import time
import os
import logging
import json
import sys
from queue import Queue
from flask import Flask, jsonify, request
from functools import wraps
import socket
import struct
import secrets
import socks  # 用于连接后端的SOCKS5 WARP服务 (pip install PySocks)

# --- 日志记录配置 ---
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(levelname)s - %(message)s',
    datefmt='%Y-%m-%d %H:%M:%S'
)

app = Flask(__name__)

# --- API 安全配置 ---
# 强烈建议通过环境变量设置此令牌
API_SECRET_TOKEN = os.environ.get('API_SECRET_TOKEN')
if not API_SECRET_TOKEN:
    API_SECRET_TOKEN = secrets.token_hex(16)
    logging.warning("!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!")
    logging.warning("!!! 警告: 环境变量 'API_SECRET_TOKEN' 未设置。               !!!")
    logging.warning("!!! 为安全起见，已生成一个临时的随机令牌。                  !!!")
    logging.warning(f"!!! 临时令牌: {API_SECRET_TOKEN}                      !!!")
    logging.warning("!!! 在生产环境中，请务必设置一个安全的、持久的令牌。        !!!")
    logging.warning("!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!")
app.config['API_SECRET_TOKEN'] = API_SECRET_TOKEN


# --- SOCKS5 服务器配置 ---
SOCKS_SERVER_HOST = os.environ.get('SOCKS_HOST', '0.0.0.0')
SOCKS_SERVER_PORT = int(os.environ.get('SOCKS_PORT', 10880))
SOCKS_VERSION = 5
# SOCKS5 命令
CMD_CONNECT = 0x01
# SOCKS5 地址类型
ATYP_IPV4 = 0x01
ATYP_DOMAINNAME = 0x03
ATYP_IPV6 = 0x04
# SOCKS5 回复状态码
REP_SUCCESS = 0x00
REP_GENERAL_FAILURE = 0x01
REP_CONNECTION_NOT_ALLOWED = 0x02
REP_NETWORK_UNREACHABLE = 0x03
REP_HOST_UNREACHABLE = 0x04
REP_CONNECTION_REFUSED = 0x05
REP_TTL_EXPIRED = 0x06
REP_COMMAND_NOT_SUPPORTED = 0x07
REP_ADDRESS_TYPE_NOT_SUPPORTED = 0x08


# --- 后端 WARP 代理池配置 ---
WARP_POOL_CONFIG_FILE = 'src/warp_pool_config.json'
WARP_POOL_CONFIG = {} # 将以端口为键，存储 { "id": ..., "namespace": ... }
WARP_INSTANCE_IP = '127.0.0.1' # 后端WARP实例监听本地地址，供管理器连接
IP_REFRESH_WAIT = 5  # IP刷新后的等待时间(秒)

# --- 代理验证配置 ---
PROXY_VALIDATION_TARGET_HOST = os.environ.get('PROXY_VALIDATION_TARGET_HOST', '1.1.1.1')
PROXY_VALIDATION_TARGET_PORT = int(os.environ.get('PROXY_VALIDATION_TARGET_PORT', 443))
PROXY_VALIDATION_TIMEOUT = 10 # 验证连接的超时时间(秒)

# --- 代理状态管理 ---
available_proxies = Queue() # 存储可用的后端WARP端口 (例如: 10800, 10801)
in_use_proxies = {} # 存储正在被使用的后端WARP端口信息 (被SOCKS或API占用)
proxy_lock = threading.Lock() # 用于保护 available_proxies 和 in_use_proxies 的线程锁

def validate_proxy(backend_warp_port):
    """
    通过尝试连接到一个已知目标来验证一个后端WARP代理是否真的可用。
    返回 True 表示验证成功，False 表示失败。
    """
    logging.info(f"验证中: 正在测试后端端口 {backend_warp_port} 的连通性...")
    try:
        # 使用 PySocks 创建一个通过指定后端代理的连接
        conn = socks.create_connection(
            (PROXY_VALIDATION_TARGET_HOST, PROXY_VALIDATION_TARGET_PORT),
            proxy_type=socks.SOCKS5,
            proxy_addr=WARP_INSTANCE_IP,
            proxy_port=backend_warp_port,
            timeout=PROXY_VALIDATION_TIMEOUT
        )
        conn.close()
        logging.info(f"验证成功: 后端端口 {backend_warp_port} 可以成功连接到 {PROXY_VALIDATION_TARGET_HOST}:{PROXY_VALIDATION_TARGET_PORT}。")
        return True
    except (socks.ProxyConnectionError, socket.timeout, OSError) as e:
        logging.warning(f"验证失败: 后端端口 {backend_warp_port} 无法连接到验证目标。错误: {e}")
        return False
    except Exception as e:
        logging.error(f"验证中发生未知错误 (端口 {backend_warp_port}): {e}")
        return False

# --- 初始化代理池 (将在 main 函数中调用) ---
def initialize_proxy_pool_from_config(config_data):
    """根据加载的配置数据初始化代理池。"""
    logging.info(f"根据配置文件初始化后端代理池... 代理数量: {len(config_data)}")
    for instance in config_data:
        port = instance.get('port')
        if port is not None:
            WARP_POOL_CONFIG[port] = {
                "id": instance.get('id'),
                "namespace": instance.get('namespace')
            }
            available_proxies.put(port)
            logging.info(f"已添加后端端口 {port} (命名空间: {instance.get('namespace')}) 到可用代理池。")
        else:
            logging.warning(f"在配置中发现一个缺少 'port' 字段的实例: {instance}")
    return len(WARP_POOL_CONFIG) > 0

def refresh_proxy_ip(backend_warp_port):
    """
    刷新指定后端WARP代理实例的IP地址。
    'backend_warp_port' 是像 10800, 10801 这样的端口。
    """
    instance_config = WARP_POOL_CONFIG.get(backend_warp_port)
    if not instance_config:
        logging.error(f"无法刷新IP: 在配置中未找到端口 {backend_warp_port} 的信息。")
        return False
    
    ns_name = instance_config['namespace']
    idx = instance_config['id']
    
    logging.info(f"为端口 {backend_warp_port} (命名空间 {ns_name}) 请求IP刷新。")
    
    # 调用外部脚本刷新IP
    try:
        # 获取脚本目录
        script_dir = os.path.dirname(os.path.abspath(__file__))
        manage_pool_script = os.path.join(script_dir, '..', 'manage_pool.sh')
        # 转换为绝对路径
        manage_pool_script = os.path.abspath(manage_pool_script)
        
        # 检查脚本是否存在
        if not os.path.exists(manage_pool_script):
            logging.error(f"管理脚本 {manage_pool_script} 不存在。")
            return False
        
        # 构造命令
        cmd = ['sudo', manage_pool_script, 'refresh-ip', ns_name, str(idx)]
        logging.info(f"执行IP刷新命令: {' '.join(cmd)}")
        
        # 执行命令
        result = subprocess.run(cmd, capture_output=True, text=True, timeout=60)
        if result.returncode == 0:
            logging.info(f"端口 {backend_warp_port} ({ns_name}) 的IP刷新成功。")
            return True
        else:
            logging.error(f"端口 {backend_warp_port} ({ns_name}) 的IP刷新失败。返回码: {result.returncode}, 错误: {result.stderr}")
            return False
    except subprocess.TimeoutExpired:
        logging.error(f"端口 {backend_warp_port} ({ns_name}) 的IP刷新超时。")
        return False
    except Exception as e:
        logging.error(f"端口 {backend_warp_port} ({ns_name}) 的IP刷新过程中发生错误: {e}")
        return False

def _refresh_and_return_task(port_to_refresh):
    """
    在后台线程中刷新一个后端WARP代理的IP，验证其可用性，然后将其返回到可用代理池。
    'port_to_refresh' 是一个后端WARP端口 (例如: 10800)。
    """
    logging.info(f"后台任务: 开始为后端端口 {port_to_refresh} 刷新IP...")
    refreshed_successfully = refresh_proxy_ip(port_to_refresh)
    
    if not refreshed_successfully:
        logging.warning(f"后台任务: IP刷新失败，将端口 {port_to_refresh} 直接返回代理池以供后续重试。")
        with proxy_lock:
            available_proxies.put(port_to_refresh)
        return

    # IP刷新成功后，进行验证
    logging.info(f"后台任务: IP刷新成功，现在开始验证端口 {port_to_refresh} 的可用性。")
    is_valid = validate_proxy(port_to_refresh)
    
    if is_valid:
        with proxy_lock:
            available_proxies.put(port_to_refresh)
        logging.info(f"后台任务: 后端端口 {port_to_refresh} 验证成功，已返回可用代理池。")
    else:
        # 如果验证失败，将代理端口重新放回队列的末尾，并记录错误。
        # 这可以防止代理池因暂时的网络问题而耗尽。
        logging.warning(f"后台任务: 后端端口 {port_to_refresh} 在IP刷新后未能通过验证。将端口放回队列末尾以供后续重试。")
        with proxy_lock:
            available_proxies.put(port_to_refresh)

# --- API 认证装饰器 ---
def require_token(f):
    @wraps(f)
    def decorated_function(*args, **kwargs):
        token = None
        if 'Authorization' in request.headers:
            auth_header = request.headers['Authorization']
            try:
                token_type, token = auth_header.split()
                if token_type.lower() != 'bearer':
                    token = None # 不是 Bearer 令牌
            except ValueError:
                # Authorization 头格式不正确
                pass
        
        if not token or token != app.config['API_SECRET_TOKEN']:
            logging.warning(f"API 认证失败: 来自 {request.remote_addr} 的请求缺少或令牌不正确。")
            return jsonify({"error": "需要有效的 Bearer 令牌"}), 401
        
        return f(*args, **kwargs)
    return decorated_function

@app.route('/acquire', methods=['GET'])
@require_token
def acquire_proxy():
    """
    获取一个后端WARP端口。客户端应使用返回的中央SOCKS5服务器地址。
    返回中央SOCKS5服务器地址和作为释放凭证的后端端口号。
    """
    with proxy_lock:
        if available_proxies.empty():
            logging.warning(f"API /acquire: 没有可用的后端代理给 {request.remote_addr}")
            return jsonify({"error": "没有可用的后端代理"}), 503
        
        backend_port_acquired = available_proxies.get()
        
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
        logging.info(f"API /acquire: 后端WARP端口 {backend_port_acquired} 已被 {request.remote_addr} 获取。 "
                    f"客户端应使用中央SOCKS服务: {client_facing_socks_host}:{SOCKS_SERVER_PORT}")
        
        return jsonify({
            "proxy_to_use": f"socks5://{client_facing_socks_host}:{SOCKS_SERVER_PORT}",
            "backend_port_token_for_release": backend_port_acquired,
            "message": f"请连接到中央SOCKS5服务器 '{client_facing_socks_host}:{SOCKS_SERVER_PORT}'。 "
                       f"调用 /release 接口时请使用 'backend_port_token_for_release' ({backend_port_acquired})。"
        })

@app.route('/release/<int:backend_port_token>', methods=['POST'])
@require_token
def release_proxy(backend_port_token):
    """
    释放一个先前通过API获取的后端WARP代理 (由 backend_port_token 指定)
    并在后台线程中启动IP刷新。
    """
    logging.info(f"API /release: 来自 {request.remote_addr} 的请求，释放后端端口凭证 {backend_port_token}。")
    with proxy_lock:
        if backend_port_token not in in_use_proxies:
            logging.warning(f"API /release: 在 'in_use_proxies' 中未找到后端端口凭证 {backend_port_token} (请求来源: {request.remote_addr})。")
            return jsonify({"error": f"后端端口凭证 {backend_port_token} 未在使用或无效"}), 400
        
        proxy_info = in_use_proxies.pop(backend_port_token)
        usage_duration = time.time() - proxy_info.get("acquired_at", time.time())
        logging.info(f"API /release: 后端端口 {backend_port_token} 已被 {request.remote_addr} 释放。占用时长: {usage_duration:.2f} 秒。")

    threading.Thread(target=_refresh_and_return_task, args=(backend_port_token,)).start()
    logging.info(f"API /release: 已为后端端口 {backend_port_token} 启动后台IP刷新任务。")
    
    return jsonify({"status": f"已为后端端口 {backend_port_token} 发起释放和IP刷新流程"})

@app.route('/status', methods=['GET'])
def pool_status():
    """获取后端WARP代理池状态以及中央SOCKS服务器信息"""
    with proxy_lock:
        current_in_use_details = {}
        for port, info in in_use_proxies.items():
            info_copy = info.copy()
            if "client_address_on_socks_server" in info_copy and isinstance(info_copy["client_address_on_socks_server"], tuple):
                 info_copy["client_address_on_socks_server"] = f"{info_copy['client_address_on_socks_server'][0]}:{info_copy['client_address_on_socks_server'][1]}"
            current_in_use_details[port] = info_copy

        return jsonify({
            "central_socks5_server_listening_on": f"中央SOCKS5服务器监听地址: {SOCKS_SERVER_HOST}:{SOCKS_SERVER_PORT}",
            "backend_warp_pool_size": f"后端WARP代理池大小: {len(WARP_POOL_CONFIG)}",
            "available_backend_ports_count": f"可用后端代理数量: {available_proxies.qsize()}",
            "available_backend_ports_list": f"可用后端代理端口列表: {list(available_proxies.queue)}",
            "in_use_backend_ports_count": f"正在使用的后端代理数量: {len(in_use_proxies)}",
            "in_use_backend_ports_details": f"正在使用的后端代理详情: {current_in_use_details}"
        })

# --- SOCKS5 服务器实现 ---

def _forward_data(source_sock, dest_sock, stop_event, direction_log):
    """在两个套接字之间转发数据，直到发生错误或 stop_event 被设置。"""
    try:
        source_sock.settimeout(1.0)
        while not stop_event.is_set():
            try:
                data = source_sock.recv(4096)
            except socket.timeout:
                if stop_event.is_set(): break
                continue
            except ConnectionResetError:
                logging.warning(f"转发器 {direction_log}: 连接被对方重置。")
                break
            except Exception as e:
                if stop_event.is_set(): break
                logging.error(f"转发器 {direction_log}: 接收数据时出错: {e}")
                break
            
            if not data:
                logging.info(f"转发器 {direction_log}: 源连接已关闭 (收到空数据)。")
                break
            
            try:
                dest_sock.sendall(data)
            except socket.error as e:
                if stop_event.is_set(): break
                logging.error(f"转发器 {direction_log}: 发送数据时套接字出错: {e}")
                break
            except Exception as e:
                if stop_event.is_set(): break
                logging.error(f"转发器 {direction_log}: 发送数据时发生未知错误: {e}")
                break
    except Exception as e:
        if not stop_event.is_set():
             logging.error(f"转发器 {direction_log}: 转发循环中发生未处理的异常: {e}")
    finally:
        logging.info(f"转发器 {direction_log}: 正在停止。")
        stop_event.set()

def _release_backend_port_after_socks_usage(backend_port_to_release, refresh_ip_flag=True):
    """
    管理SOCKS使用后后端端口的释放。
    从 in_use_proxies 中移除，并可选择性地安排IP刷新。
    """
    logging.info(f"SOCKS清理: 正在释放后端端口 {backend_port_to_release}。刷新IP: {refresh_ip_flag}")
    with proxy_lock:
        if backend_port_to_release in in_use_proxies:
            proxy_info = in_use_proxies.pop(backend_port_to_release)
            usage_duration = time.time() - proxy_info.get("acquired_at", time.time())
            logging.info(f"SOCKS清理: 端口 {backend_port_to_release} 已被使用 {usage_duration:.2f} 秒。")
        else:
            logging.warning(f"SOCKS清理警告: 在SOCKS释放期间，未在 'in_use_proxies' 中找到后端端口 {backend_port_to_release}。")
            # 如果端口不在使用中，直接验证并返回到代理池
            logging.info(f"SOCKS清理: 正在验证端口 {backend_port_to_release} 的可用性...")
            is_valid = validate_proxy(backend_port_to_release)
            with proxy_lock:
                if is_valid:
                    available_proxies.put(backend_port_to_release)
                    logging.info(f"SOCKS清理: 后端端口 {backend_port_to_release} 验证成功，已返回代理池。")
                else:
                    # 如果验证失败，将代理端口重新放回队列的末尾，并记录错误
                    logging.warning(f"SOCKS清理: 后端端口 {backend_port_to_release} 未能通过验证。将端口放回队列末尾以供后续重试。")
                    available_proxies.put(backend_port_to_release)
            return

    if refresh_ip_flag:
        threading.Thread(target=_refresh_and_return_task, args=(backend_port_to_release,)).start()
        logging.info(f"SOCKS清理: 已为 {backend_port_to_release} 启动后台IP刷新任务。")
    else:
        # 即使跳过IP刷新，也要验证代理的可用性
        logging.info(f"SOCKS清理: 正在验证端口 {backend_port_to_release} 的可用性 (IP刷新被跳过)...")
        is_valid = validate_proxy(backend_port_to_release)
        with proxy_lock:
            if is_valid:
                available_proxies.put(backend_port_to_release)
                logging.info(f"SOCKS清理: 后端端口 {backend_port_to_release} 验证成功，已返回代理池 (IP刷新被跳过)。")
            else:
                # 如果验证失败，将代理端口重新放回队列的末尾，并记录错误
                logging.warning(f"SOCKS清理: 后端端口 {backend_port_to_release} 未能通过验证。将端口放回队列末尾以供后续重试。")
                available_proxies.put(backend_port_to_release)

def handle_socks_client_connection(client_socket, client_address_tuple):
    """处理单个SOCKS5客户端连接。"""
    client_ip_str = client_address_tuple[0]
    logging.info(f"SOCKS处理器: 来自 {client_ip_str}:{client_address_tuple[1]} 的新客户端连接")
    
    acquired_backend_port = None
    remote_connection_to_target = None
    
    try:
        client_socket.settimeout(10.0)
        ver_nmethods = client_socket.recv(2)
        if not ver_nmethods or ver_nmethods[0] != SOCKS_VERSION:
            logging.warning(f"SOCKS处理器 {client_ip_str}: 无效的SOCKS版本。应为 {SOCKS_VERSION}, 收到 {ver_nmethods[0] if ver_nmethods else 'None'}。")
            return
        
        num_auth_methods = ver_nmethods[1]
        auth_methods_offered = client_socket.recv(num_auth_methods)
        if b'\x00' not in auth_methods_offered:
            logging.warning(f"SOCKS处理器 {client_ip_str}: 不支持的认证方法。客户端提供: {auth_methods_offered.hex()}。我们需要 0x00 (无认证)。")
            client_socket.sendall(struct.pack("!BB", SOCKS_VERSION, 0xFF))
            return
        
        client_socket.sendall(struct.pack("!BB", SOCKS_VERSION, 0x00))
        logging.info(f"SOCKS处理器 {client_ip_str}: 握手成功 (无认证)。")

        request_header = client_socket.recv(4)
        if not request_header or request_header[0] != SOCKS_VERSION:
            logging.warning(f"SOCKS处理器 {client_ip_str}: 请求中的SOCKS版本无效。")
            return
        
        req_ver, req_cmd, req_rsv, req_atyp = request_header
        
        if req_cmd != CMD_CONNECT:
            logging.warning(f"SOCKS处理器 {client_ip_str}: 不支持的命令 {req_cmd}。仅支持 CONNECT ({CMD_CONNECT})。")
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
            logging.warning(f"SOCKS处理器 {client_ip_str}: 不支持的地址类型 {req_atyp}。")
            reply = struct.pack("!BBBB", SOCKS_VERSION, REP_ADDRESS_TYPE_NOT_SUPPORTED, 0x00, ATYP_IPV4) + socket.inet_aton("0.0.0.0") + struct.pack("!H", 0)
            client_socket.sendall(reply)
            return
            
        target_port_bytes = client_socket.recv(2)
        target_port_int = struct.unpack("!H", target_port_bytes)[0]
        logging.info(f"SOCKS处理器 {client_ip_str}: 请求连接到 {target_host_str}:{target_port_int}")

        with proxy_lock:
            if available_proxies.empty():
                logging.warning(f"SOCKS处理器 {client_ip_str}: 没有可用的后端WARP代理来连接 -> {target_host_str}:{target_port_int}")
                reply = struct.pack("!BBBB", SOCKS_VERSION, REP_GENERAL_FAILURE, 0x00, ATYP_IPV4) + socket.inet_aton("0.0.0.0") + struct.pack("!H", 0)
                client_socket.sendall(reply)
                return
            acquired_backend_port = available_proxies.get()
            in_use_proxies[acquired_backend_port] = {
                "type": "socks_direct",
                "client_address_on_socks_server": client_address_tuple,
                "requested_target_host": target_host_str,
                "requested_target_port": target_port_int,
                "backend_warp_port_used": acquired_backend_port,
                "acquired_at": time.time()
            }
        logging.info(f"SOCKS处理器 {client_ip_str}: 已获取后端WARP {WARP_INSTANCE_IP}:{acquired_backend_port} 用于连接 -> {target_host_str}:{target_port_int}")

        try:
            logging.info(f"SOCKS处理器 {client_ip_str}: 正在通过后端SOCKS5 {WARP_INSTANCE_IP}:{acquired_backend_port} 连接到 ({target_host_str}, {target_port_int})...")
            remote_connection_to_target = socks.create_connection(
                (target_host_str, target_port_int),
                proxy_type=socks.SOCKS5,
                proxy_addr=WARP_INSTANCE_IP,
                proxy_port=acquired_backend_port,
                timeout=20
            )
            logging.info(f"SOCKS处理器 {client_ip_str}: 已通过后端WARP {WARP_INSTANCE_IP}:{acquired_backend_port} 成功连接到 {target_host_str}:{target_port_int}")
            
            bound_addr_bytes = socket.inet_aton("0.0.0.0")
            bound_port_bytes = struct.pack("!H", 0)
            reply = struct.pack("!BBBB", SOCKS_VERSION, REP_SUCCESS, 0x00, ATYP_IPV4) + bound_addr_bytes + bound_port_bytes
            client_socket.sendall(reply)

        except socks.ProxyConnectionError as e_pysocks:
            logging.error(f"SOCKS处理器 {client_ip_str}: 后端WARP {WARP_INSTANCE_IP}:{acquired_backend_port} 无法连接到目标 {target_host_str}:{target_port_int}。PySocks错误: {e_pysocks}")
            socks_reply_code = REP_HOST_UNREACHABLE
            if "Connection refused" in str(e_pysocks): socks_reply_code = REP_CONNECTION_REFUSED
            elif "Host unreachable" in str(e_pysocks): socks_reply_code = REP_HOST_UNREACHABLE
            elif "Network is unreachable" in str(e_pysocks): socks_reply_code = REP_NETWORK_UNREACHABLE
            reply = struct.pack("!BBBB", SOCKS_VERSION, socks_reply_code, 0x00, ATYP_IPV4) + socket.inet_aton("0.0.0.0") + struct.pack("!H", 0)
            try:
                client_socket.sendall(reply)
            except Exception as e_send:
                logging.warning(f"SOCKS处理器 {client_ip_str}: 发送错误回复时失败: {e_send}")
            _release_backend_port_after_socks_usage(acquired_backend_port, refresh_ip_flag=False)
            acquired_backend_port = None
            return
        except socket.timeout:
            logging.warning(f"SOCKS处理器 {client_ip_str}: 通过后端WARP {WARP_INSTANCE_IP}:{acquired_backend_port} 连接到 {target_host_str}:{target_port_int} 超时")
            reply = struct.pack("!BBBB", SOCKS_VERSION, REP_TTL_EXPIRED, 0x00, ATYP_IPV4) + socket.inet_aton("0.0.0.0") + struct.pack("!H", 0)
            try:
                client_socket.sendall(reply)
            except Exception as e_send:
                logging.warning(f"SOCKS处理器 {client_ip_str}: 发送超时回复时失败: {e_send}")
            _release_backend_port_after_socks_usage(acquired_backend_port, refresh_ip_flag=False)
            acquired_backend_port = None
            return
        except socket.gaierror as e_dns:
            logging.warning(f"SOCKS处理器 {client_ip_str}: 目标 {target_host_str} 的DNS解析失败。错误: {e_dns}")
            reply = struct.pack("!BBBB", SOCKS_VERSION, REP_HOST_UNREACHABLE, 0x00, ATYP_IPV4) + socket.inet_aton("0.0.0.0") + struct.pack("!H", 0)
            try:
                client_socket.sendall(reply)
            except Exception as e_send:
                logging.warning(f"SOCKS处理器 {client_ip_str}: 发送DNS错误回复时失败: {e_send}")
            _release_backend_port_after_socks_usage(acquired_backend_port, refresh_ip_flag=False)
            acquired_backend_port = None
            return
        except Exception as e_conn_target:
            logging.error(f"SOCKS处理器 {client_ip_str}: 通过后端WARP {WARP_INSTANCE_IP}:{acquired_backend_port} 连接到 {target_host_str}:{target_port_int} 时发生未知错误。错误: {e_conn_target}")
            reply = struct.pack("!BBBB", SOCKS_VERSION, REP_GENERAL_FAILURE, 0x00, ATYP_IPV4) + socket.inet_aton("0.0.0.0") + struct.pack("!H", 0)
            try:
                client_socket.sendall(reply)
            except Exception as e_send:
                logging.warning(f"SOCKS处理器 {client_ip_str}: 发送通用错误回复时失败: {e_send}")
            _release_backend_port_after_socks_usage(acquired_backend_port, refresh_ip_flag=False)
            acquired_backend_port = None
            return

        logging.info(f"SOCKS处理器 {client_ip_str}: 正在客户端和 {target_host_str}:{target_port_int} (通过后端 {acquired_backend_port}) 之间中继数据")
        client_socket.settimeout(None)
        remote_connection_to_target.settimeout(None)

        stop_event = threading.Event()
        
        thread_client_to_target = threading.Thread(target=_forward_data, args=(client_socket, remote_connection_to_target, stop_event, f"客户端({client_ip_str})->目标({target_host_str})"))
        thread_target_to_client = threading.Thread(target=_forward_data, args=(remote_connection_to_target, client_socket, stop_event, f"目标({target_host_str})->客户端({client_ip_str})"))
        
        thread_client_to_target.daemon = True
        thread_target_to_client.daemon = True
        thread_client_to_target.start()
        thread_target_to_client.start()
        
        stop_event.wait()

        logging.info(f"SOCKS处理器 {client_ip_str}: 与 {target_host_str}:{target_port_int} (后端 {acquired_backend_port}) 的数据中继已完成。")

    except ConnectionResetError:
        logging.warning(f"SOCKS处理器 {client_ip_str}: 客户端在操作期间重置了连接。")
    except BrokenPipeError:
        logging.warning(f"SOCKS处理器 {client_ip_str}: 管道破裂 (客户端可能已关闭连接)。")
    except socket.timeout:
        logging.warning(f"SOCKS处理器 {client_ip_str}: 在初始握手/请求阶段套接字超时。")
    except Exception as e_handler:
        logging.error(f"SOCKS处理器 {client_ip_str}: 客户端处理器中发生未处理的错误: {e_handler}")
        import traceback
        logging.error(traceback.format_exc())
    finally:
        logging.info(f"SOCKS处理器 {client_ip_str}: 正在清理SOCKS连接。")
        if remote_connection_to_target:
            try:
                remote_connection_to_target.close()
            except Exception as e_close_remote:
                logging.warning(f"SOCKS处理器 {client_ip_str}: 关闭到目标的连接时出错: {e_close_remote}")
        try:
            client_socket.close()
        except Exception as e_close_client:
            logging.warning(f"SOCKS处理器 {client_ip_str}: 关闭客户端连接时出错: {e_close_client}")
        
        if acquired_backend_port is not None:
            _release_backend_port_after_socks_usage(acquired_backend_port, refresh_ip_flag=True)
        
        logging.info(f"SOCKS处理器 {client_ip_str}: 连接已完全关闭，资源已处理。")

def start_central_socks5_server():
    """初始化并启动SOCKS5代理服务器，监听客户端连接。"""
    listener_socket = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    listener_socket.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    try:
        listener_socket.bind((SOCKS_SERVER_HOST, SOCKS_SERVER_PORT))
        listener_socket.listen(128)
        logging.info(f"中央SOCKS5服务器已成功启动，监听地址 {SOCKS_SERVER_HOST}:{SOCKS_SERVER_PORT}")
    except Exception as e_bind:
        logging.critical(f"严重错误: 无法在 {SOCKS_SERVER_HOST}:{SOCKS_SERVER_PORT} 上绑定或启动SOCKS5服务器。错误: {e_bind}")
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
            logging.error(f"SOCKS服务器主循环: 接受新客户端连接时出错: {e_accept}")
            time.sleep(0.01)
# --- 主程序执行 ---
if __name__ == '__main__':
    logging.info("代理管理器服务正在启动...")
    
    # --- 从 JSON 文件加载代理池配置 ---
    logging.info(f"正在从 '{WARP_POOL_CONFIG_FILE}' 加载代理池配置...")
    try:
        with open(WARP_POOL_CONFIG_FILE, 'r') as f:
            config_list = json.load(f)
        if not isinstance(config_list, list) or not config_list:
            raise ValueError("配置文件内容不是一个有效的非空列表。")
    except FileNotFoundError:
        logging.critical(f"严重错误: 配置文件 '{WARP_POOL_CONFIG_FILE}' 未找到。脚本无法启动。")
        sys.exit(1)
    except json.JSONDecodeError:
        logging.critical(f"严重错误: 无法解析配置文件 '{WARP_POOL_CONFIG_FILE}'。请检查其JSON格式。")
        sys.exit(1)
    except Exception as e:
        logging.critical(f"严重错误: 加载或解析配置文件 '{WARP_POOL_CONFIG_FILE}' 时发生未知错误: {e}")
        sys.exit(1)

    # --- 初始化代理池 ---
    if not initialize_proxy_pool_from_config(config_list):
        logging.critical("严重错误: 从配置文件初始化代理池失败，没有可用的代理。脚本将退出。")
        sys.exit(1)

    logging.info("✅ 代理池已成功从配置文件初始化。")
    logging.info(f"当前后端WARP代理池大小: {len(WARP_POOL_CONFIG)}")
    logging.info(f"队列中初始可用的后端端口: {list(available_proxies.queue)}")
    logging.info("重要提示: 本脚本在刷新IP时可能会使用 'sudo' 执行 'ip netns exec warp-cli' 命令。")
    logging.info("请确保已安装 PySocks: 'pip install PySocks'")

    # 在独立的守护线程中启动中央SOCKS5服务器
    logging.info(f"正在启动中央SOCKS5服务器线程，监听地址 {SOCKS_SERVER_HOST}:{SOCKS_SERVER_PORT}...")
    socks_server_daemon_thread = threading.Thread(target=start_central_socks5_server, daemon=True)
    socks_server_daemon_thread.start()
    
    if socks_server_daemon_thread.is_alive():
        logging.info("中央SOCKS5服务器线程已启动。")
    else:
        logging.warning("警告: 中央SOCKS5服务器线程已初始化，但可能未在运行 (请检查日志中的绑定错误)。")

    # 启动 Flask HTTP API 服务器
    api_port = int(os.environ.get('API_PORT', 5000))
    logging.info(f"正在启动 Flask HTTP API 服务器，监听地址 0.0.0.0, 端口 {api_port}。")
    try:
        app.run(host='0.0.0.0', port=api_port, threaded=True)
    except Exception as e_flask:
        logging.critical(f"严重错误: Flask API 服务器启动失败: {e_flask}")
    
    logging.info("代理管理器服务正在关闭或 Flask 服务器已退出。")