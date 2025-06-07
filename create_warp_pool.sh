#!/bin/bash
# 增强脚本健壮性：
# -e: 遇到错误立即退出
# -u: 使用未定义变量时报错
# -o pipefail: 管道中任一命令失败则整个管道失败
set -euo pipefail

# --- 配置参数 ---
POOL_SIZE=3                 # 代理池大小
BASE_PORT=10800             # SOCKS5代理的基础端口号
WARP_LICENSE_KEY=""         # WARP+ 许可证密钥 (可选)
WARP_ENDPOINT=""            # 自定义WARP端点IP和端口 (可选)
WARP_CONFIG_BASE_DIR="/var/lib/warp-configs"  # WARP配置目录
WARP_IPC_BASE_DIR="/run/warp-sockets"         # WARP IPC目录
LOCK_FILE="/tmp/warp_pool_$(id -u).lock"      # 用户隔离的锁文件
LOG_FILE="/var/log/warp-pool.log"             # 日志文件路径

# --- 日志功能 ---
log() {
    local level=$1
    local message=$2
    local timestamp=$(date "+%Y-%m-%d %H:%M:%S")
    # 输出到标准错误 (控制台)
    printf "[%s] [%s] %s\n" "$timestamp" "$level" "$message" >&2
    # 同时追加到日志文件
    printf "[%s] [%s] %s\n" "$timestamp" "$level" "$message" >> "$LOG_FILE"
}

# --- 前置检查 ---
# 检查必要命令是否存在
for cmd in warp-cli ip iptables sysctl socat mkdir tee flock; do
    if ! command -v "$cmd" &> /dev/null; then
        log "ERROR" "命令未找到: $cmd。请确保已安装必要的依赖。"
        exit 1
    fi
done
log "INFO" "✅ 所有必要命令检查通过。"

# 检查root权限或sudo权限
if [ "$EUID" -ne 0 ]; then
    # 检查无密码sudo权限
    if ! sudo -n true 2>/dev/null; then
        log "ERROR" "需要root权限或配置无密码sudo。"
        exit 1
    fi
    log "INFO" "⚠️ 使用sudo权限运行"
    SUDO="sudo"
else
    SUDO=""
    log "INFO" "✅ root权限检查通过。"
fi

# 启动sudo会话保持进程
if $SUDO -n true 2>/dev/null; then
    log "INFO" "✅ 无密码sudo权限检查通过，启动sudo会话保持进程。"
    # 在后台循环中运行 `sudo -v` 来刷新sudo时间戳
    while true; do $SUDO -n true; sleep 60; kill -0 "$$" || exit; done &>/dev/null &
    SUDO_KEEPALIVE_PID=$!
    # 设置一个陷阱，在脚本退出时杀死后台进程
    trap "$SUDO kill $SUDO_KEEPALIVE_PID &>/dev/null" EXIT
fi

# --- 函数定义 ---
# 清理函数
cleanup() {
    log "INFO" "🧹 开始进行彻底清理，确保环境干净..."
    
    # 1. 清理所有网络命名空间（而不仅限于当前POOL_SIZE范围）
    log "INFO" "   - 步骤1: 清理所有网络命名空间、挂载点、进程、veth设备和DNS配置..."
    for NS_NAME in $($SUDO ip netns list | awk '{print $1}'); do
        # 仅处理以 "ns" 开头的命名空间（脚本创建的）
        if [[ "$NS_NAME" =~ ^ns[0-9]+$ ]]; then
            log "INFO" "     - 正在清理命名空间 $NS_NAME..."
            
            # 获取索引号
            local idx=${NS_NAME#ns}
            
            # 卸载绑定挂载
            log "INFO" "       - 卸载绑定挂载..."
            $SUDO ip netns exec "$NS_NAME" sh -c '
                WARP_SYSTEM_CONFIG_DIR="/var/lib/cloudflare-warp"
                WARP_SYSTEM_IPC_DIR="/run/cloudflare-warp"
                
                if mount | grep -q "on $WARP_SYSTEM_CONFIG_DIR type"; then
                    umount "$WARP_SYSTEM_CONFIG_DIR" || true
                fi
                
                if mount | grep -q "on $WARP_SYSTEM_IPC_DIR type"; then
                    umount "$WARP_SYSTEM_IPC_DIR" || true
                fi
            '
            
            # 强制杀死命名空间内的所有进程
            log "INFO" "       - 停止 $NS_NAME 内的所有进程..."
            if pids=$($SUDO ip netns pids "$NS_NAME" 2>/dev/null); then
                [ -n "$pids" ] && $SUDO kill -9 $pids >/dev/null 2>&1 || true
            fi
            sleep 1
            
            # 删除命名空间
            log "INFO" "       - 删除命名空间 $NS_NAME..."
            $SUDO ip netns del "$NS_NAME" >/dev/null 2>&1 || true
            
            # 删除veth设备
            local VETH_HOST="veth$idx"
            if ip link show "$VETH_HOST" &> /dev/null; then
                log "INFO" "     - 删除 veth 设备 $VETH_HOST..."
                $SUDO ip link del "$VETH_HOST" >/dev/null 2>&1 || true
            fi
            
            # 清理DNS配置文件
            if [ -d "/etc/netns/$NS_NAME" ]; then
                log "INFO" "     - 删除DNS配置 /etc/netns/$NS_NAME..."
                $SUDO rm -rf "/etc/netns/$NS_NAME" >/dev/null 2>&1 || true
            fi
            
            # 清理独立的WARP配置目录
            local INSTANCE_CONFIG_DIR="${WARP_CONFIG_BASE_DIR}/${NS_NAME}"
            if [ -d "$INSTANCE_CONFIG_DIR" ]; then
                log "INFO" "     - 删除独立的WARP配置目录 $INSTANCE_CONFIG_DIR..."
                $SUDO rm -rf "$INSTANCE_CONFIG_DIR" >/dev/null 2>&1 || true
            fi
            
            # 清理独立的WARP IPC目录
            local INSTANCE_IPC_DIR="${WARP_IPC_BASE_DIR}/${NS_NAME}"
            if [ -d "$INSTANCE_IPC_DIR" ]; then
                log "INFO" "     - 删除独立的WARP IPC目录 $INSTANCE_IPC_DIR..."
                $SUDO rm -rf "$INSTANCE_IPC_DIR" >/dev/null 2>&1 || true
            fi
        fi
    done
    log "INFO" "   ✅ 网络命名空间、veth设备及相关配置已清理。"
    
    # 2. 清理 iptables 规则
    log "INFO" "   - 步骤2: 清理iptables规则..."
    
    # 清理所有与脚本相关的DNAT规则
    $SUDO iptables-save | grep -E -- '--dport (108[0-9]{2}|400[0-9]{2})' | while read rule; do
        # 解析规则并删除
        local table=$(echo "$rule" | awk '{print $1}')
        local chain=$(echo "$rule" | awk '{print $2}')
        local rule_content=$(echo "$rule" | sed -E 's/^-A //; s/-j DNAT.*//')
        
        if [ -n "$rule_content" ]; then
            log "INFO" "     - 删除DNAT规则: $table $chain $rule_content"
            $SUDO iptables -t "$table" -D "$chain" $rule_content -j DNAT >/dev/null 2>&1 || true
        fi
    done
    
    # 清理FORWARD规则
    $SUDO iptables-save | grep -E '10\.0\.[0-9]+\.[0-9]+' | while read rule; do
        local chain=$(echo "$rule" | awk '{print $2}')
        local rule_content=$(echo "$rule" | sed -E 's/^-A //; s/-j ACCEPT.*//')
        
        if [ -n "$rule_content" ]; then
            log "INFO" "     - 删除FORWARD规则: $chain $rule_content"
            $SUDO iptables -D "$chain" $rule_content -j ACCEPT >/dev/null 2>&1 || true
        fi
    done
    
    # 清理MASQUERADE规则
    $SUDO iptables -t nat -S POSTROUTING | grep '10.0.' | while read rule; do
        local rule_content=$(echo "$rule" | sed 's/-A POSTROUTING //')
        log "INFO" "     - 删除MASQUERADE规则: $rule_content"
        $SUDO iptables -t nat -D POSTROUTING $rule_content >/dev/null 2>&1 || true
    done
    
    log "INFO" "   ✅ 旧的iptables规则已清理。"
    
    # 3. 杀死所有残留的转发进程
    log "INFO" "   - 步骤3: 停止所有残留的转发进程..."
    
    # 精确匹配脚本启动的socat进程
    SOCAT_PATTERN="socat TCP4-LISTEN:[0-9]+,fork,reuseaddr TCP4:127.0.0.1:[0-9]+"
    if pgrep -f "$SOCAT_PATTERN" >/dev/null; then
        log "INFO" "     - 停止所有匹配的socat进程..."
        $SUDO pkill -f "$SOCAT_PATTERN" || true
        sleep 1
    fi
    log "INFO" "   ✅ 转发进程清理完成。"
    
    # 4. 清理锁文件
    log "INFO" "   - 步骤4: 清理锁文件..."
    rm -f "$LOCK_FILE" >/dev/null 2>&1 || true
    log "INFO" "   ✅ 锁文件已清理。"
    
    log "INFO" "✅ 彻底清理完成。"
}

# 计算MTU值
calculate_mtu() {
    # 获取默认接口
    local default_iface=$($SUDO ip route | awk '/default/ {print $5; exit}')
    [ -z "$default_iface" ] && { 
        log "WARNING" "无法确定默认网络接口，使用默认MTU 1420"; 
        echo 1420; 
        return; 
    }
    
    # 获取主机接口MTU
    local host_mtu=$($SUDO ip link show "$default_iface" | awk '/mtu/ {print $5; exit}')
    [ -z "$host_mtu" ] && { 
        log "WARNING" "无法获取接口MTU，使用默认MTU 1420"; 
        echo 1420; 
        return; 
    }
    
    # 计算WARP接口MTU (减去WARP封装开销)
    local warp_mtu=$((host_mtu - 80))
    [ "$warp_mtu" -lt 1280 ] && warp_mtu=1280  # 最小MTU
    
    log "INFO" "主机接口 $default_iface MTU: $host_mtu, WARP接口MTU: $warp_mtu"
    echo "$warp_mtu"
}

# 配置DNS
configure_dns() {
    local ns_name=$1
    
    # 创建DNS配置目录
    $SUDO mkdir -p "/etc/netns/$ns_name"
    
    # 复制主机的DNS配置
    if [ -f "/etc/resolv.conf" ]; then
        $SUDO cp "/etc/resolv.conf" "/etc/netns/$ns_name/resolv.conf"
        log "INFO" "   ✅ 已复制主机DNS配置到命名空间 $ns_name"
    else
        # 使用备用DNS
        printf "nameserver 1.1.1.1\nnameserver 8.8.8.8\n" | \
        $SUDO tee "/etc/netns/$ns_name/resolv.conf" > /dev/null
        log "WARNING" "   ⚠️ 使用备用DNS配置 (1.1.1.1, 8.8.8.8)"
    fi
}

# 初始化WARP实例
init_warp_instance() {
    local ns_name=$1
    local idx=$2
    local warp_internal_port=$3
    
    # 在执行命令前，确保挂载命名空间对当前shell可见
    $SUDO ip netns exec "$ns_name" bash -c '
        ns_name=$1
        idx=$2
        warp_internal_port=$3
        warp_license_key=$4
        warp_endpoint=$5
        
        log() {
            local level=$1
            local message=$2
            local timestamp=$(date "+%Y-%m-%d %H:%M:%S")
            printf "[%s] [%s] %s\n" "$timestamp" "$level" "$message" >&2
            printf "[%s] [%s] %s\n" "$timestamp" "$level" "$message" >> "'"$LOG_FILE"'"
        }
        
        # 检查外网连通性
        log "INFO" "     - 检查外网连通性..."
        if ! timeout 10s ping -c 1 api.cloudflareclient.com >/dev/null 2>&1; then
            sleep 2
            if ! timeout 10s ping -c 1 api.cloudflareclient.com >/dev/null 2>&1; then
                log "ERROR" "命名空间 $ns_name 无法 ping 通 api.cloudflareclient.com，请检查网络配置。"
                exit 1
            fi
        fi
        log "INFO" "     ✅ ping api.cloudflareclient.com 成功。"
        
        # 清理残留的socket文件
        log "INFO" "     - 清理残留的socket文件..."
        rm -f /run/cloudflare-warp/warp_service || true
        
        # 启动WARP服务守护进程
        log "INFO" "     - 启动WARP守护进程..."
        nohup warp-svc >/dev/null 2>&1 &
        sleep 8
        
        # 等待WARP服务IPC Socket就绪
        log "INFO" "     - 等待WARP服务IPC Socket就绪..."
        _MAX_SVC_WAIT_ATTEMPTS=20
        _SVC_WAIT_COUNT=0
        while ! test -S /run/cloudflare-warp/warp_service; do
            _SVC_WAIT_COUNT=$(($_SVC_WAIT_COUNT + 1))
            if [ $_SVC_WAIT_COUNT -gt $_MAX_SVC_WAIT_ATTEMPTS ]; then
                log "ERROR" "等待WARP服务 (warp-svc) 超时。"
                ps aux | grep warp || true
                exit 1
            fi
            log "INFO" "       等待中... 尝试 $_SVC_WAIT_COUNT / $_MAX_SVC_WAIT_ATTEMPTS"
            sleep 2
        done
        log "INFO" "     ✅ WARP服务IPC Socket已就绪。"
        
        # 尝试注册WARP
        log "INFO" "     - 注册WARP并接受服务条款..."
        for attempt in {1..5}; do
            if warp-cli --accept-tos registration new >/dev/null 2>&1; then
                log "INFO" "     ✅ WARP新注册成功 (尝试 $attempt)。"
                break
            elif warp-cli --accept-tos status | grep -q "Status: Registered"; then
                log "INFO" "     ℹ️  WARP已注册 (尝试 $attempt)。"
                break
            fi
            
            if [ $attempt -eq 5 ]; then
                log "ERROR" "注册WARP失败。请检查网络连接。"
                warp-cli --accept-tos status
                exit 1
            fi
            
            log "WARNING" "     ⚠️  注册失败，等待重试 (尝试 $attempt/5)..."
            sleep $((attempt * 2))
        done
        
        # 设置代理模式
        log "INFO" "     - 设置WARP为SOCKS5代理模式..."
        warp-cli --accept-tos mode proxy >/dev/null 2>&1 || \
            { log "ERROR" "设置WARP代理模式失败。"; exit 1; }
        
        log "INFO" "     - 设置WARP SOCKS5代理端口: $warp_internal_port..."
        warp-cli --accept-tos proxy port "$warp_internal_port" >/dev/null 2>&1 || \
            log "WARNING" "设置自定义代理端口失败，可能warp-cli版本不支持。"
        
        # 应用许可证密钥 (如果提供)
        if [ -n "$warp_license_key" ]; then
            log "INFO" "     - 应用WARP+许可证密钥..."
            warp-cli --accept-tos registration license "$warp_license_key" >/dev/null 2>&1 || \
                log "WARNING" "许可证密钥设置失败。"
        fi
        
        # 设置自定义端点 (如果提供)
        if [ -n "$warp_endpoint" ]; then
            log "INFO" "     - 设置自定义WARP端点: $warp_endpoint..."
            warp-cli --accept-tos tunnel endpoint reset >/dev/null 2>&1 || \
                log "WARNING" "重置端点失败。"
            warp-cli --accept-tos tunnel endpoint set "$warp_endpoint" >/dev/null 2>&1 || \
                log "WARNING" "设置自定义端点失败。"
        fi
        
        # 连接WARP
        log "INFO" "     - 连接WARP..."
        warp-cli --accept-tos connect >/dev/null 2>&1 || \
            { log "ERROR" "连接WARP失败。"; exit 1; }
        
        # 等待连接成功
        log "INFO" "     - 等待WARP连接成功..."
        MAX_CONNECT_WAIT_ATTEMPTS=30
        CONNECT_WAIT_COUNT=0
        while ! warp-cli --accept-tos status | grep -E -q "Status( update)?:[[:space:]]*Connected"; do
            CONNECT_WAIT_COUNT=$((CONNECT_WAIT_COUNT+1))
            if [ $CONNECT_WAIT_COUNT -gt $MAX_CONNECT_WAIT_ATTEMPTS ]; then
                log "ERROR" "连接WARP后状态检查失败 (超时)。"
                warp-cli --accept-tos status
                exit 1
            fi
            log "INFO" "       (尝试 $CONNECT_WAIT_COUNT/$MAX_CONNECT_WAIT_ATTEMPTS) 等待连接..."
            sleep 3
        done
        log "INFO" "   ✅ WARP在 $ns_name 中已成功初始化并连接。"
        
        # 刷新IP
        log "INFO" "     - 刷新IP地址..."
        warp-cli --accept-tos tunnel endpoint reset >/dev/null 2>&1 || \
            { log "ERROR" "使用endpoint reset刷新IP失败。"; exit 1; }
        sleep 3
        log "INFO" "   ✅ WARP在 $ns_name 中已成功刷新IP。"
        
    ' bash "$ns_name" "$idx" "$warp_internal_port" "$WARP_LICENSE_KEY" "$WARP_ENDPOINT" || \
        { log "ERROR" "在 $ns_name 中初始化WARP失败。"; exit 1; }
}

# 创建代理池
create_pool() {
    log "INFO" "🚀 开始创建 WARP 代理池 (大小: $POOL_SIZE)..."
    
    # 启用IP转发和相关内核参数
    $SUDO sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1 || \
        { log "ERROR" "启用IP转发失败。"; exit 1; }
    $SUDO sysctl -w net.ipv4.conf.all.route_localnet=1 >/dev/null 2>&1 || \
        log "WARNING" "设置route_localnet失败，直接访问127.0.0.1的端口可能不工作。"
    log "INFO" "✅ IP转发和本地网络路由已启用。"
    
    # 计算动态MTU值
    local DYNAMIC_MTU=$(calculate_mtu)
    log "INFO" "计算后的动态MTU值: $DYNAMIC_MTU"
    
    for i in $(seq 0 $(($POOL_SIZE-1))); do
        (
            # 使用锁确保实例创建过程串行化
            $SUDO flock -x -w 120 200 || { log "ERROR" "获取锁超时"; exit 1; }
            
            log "INFO" "-----------------------------------------------------"
            log "INFO" "✨ 正在创建 WARP 实例 $i (端口: $((BASE_PORT + $i)))"
            log "INFO" "-----------------------------------------------------"
            
            # 每个实例使用独立的子网，避免IP冲突
            SUBNET_THIRD_OCTET=$((i / 256))
            SUBNET_FOURTH_OCTET=$((i % 256))
            GATEWAY_IP="10.${SUBNET_THIRD_OCTET}.${SUBNET_FOURTH_OCTET}.1"
            NAMESPACE_IP="10.${SUBNET_THIRD_OCTET}.${SUBNET_FOURTH_OCTET}.2"
            SUBNET="${GATEWAY_IP%.*}.0/24"
            
            # 创建网络命名空间
            NS_NAME="ns$i"
            log "INFO" "   - 创建网络命名空间 $NS_NAME..."
            $SUDO ip netns add "$NS_NAME" || \
                { log "ERROR" "创建网络命名空间 $NS_NAME 失败。"; exit 1; }
            
            # 创建并绑定独立配置目录
            INSTANCE_CONFIG_DIR="${WARP_CONFIG_BASE_DIR}/${NS_NAME}"
            INSTANCE_IPC_DIR="${WARP_IPC_BASE_DIR}/${NS_NAME}"
            WARP_SYSTEM_CONFIG_DIR="/var/lib/cloudflare-warp"
            WARP_SYSTEM_IPC_DIR="/run/cloudflare-warp"
            
            $SUDO mkdir -p "$INSTANCE_CONFIG_DIR"
            $SUDO mkdir -p "$INSTANCE_IPC_DIR"
            $SUDO chmod 700 "$INSTANCE_CONFIG_DIR" "$INSTANCE_IPC_DIR"
            
            $SUDO ip netns exec "$NS_NAME" mkdir -p "$WARP_SYSTEM_CONFIG_DIR"
            $SUDO ip netns exec "$NS_NAME" mount --bind "$INSTANCE_CONFIG_DIR" "$WARP_SYSTEM_CONFIG_DIR"
            
            $SUDO ip netns exec "$NS_NAME" mkdir -p "$WARP_SYSTEM_IPC_DIR"
            $SUDO ip netns exec "$NS_NAME" mount --bind "$INSTANCE_IPC_DIR" "$WARP_SYSTEM_IPC_DIR"
            
            # 启动loopback接口
            $SUDO ip netns exec "$NS_NAME" ip link set lo up || \
                { log "ERROR" "启动 $NS_NAME 内的 loopback 接口失败。"; exit 1; }
            
            # 配置DNS
            configure_dns "$NS_NAME"
            
            # 创建虚拟以太网设备对
            VETH_HOST="veth$i"
            VETH_NS="veth${i}-ns"
            log "INFO" "   - 创建虚拟以太网设备 $VETH_HOST <--> $VETH_NS..."
            $SUDO ip link add "$VETH_HOST" type veth peer name "$VETH_NS" || \
                { log "ERROR" "创建虚拟以太网设备对失败。"; exit 1; }
            
            # 配置虚拟以太网设备
            $SUDO ip link set "$VETH_NS" netns "$NS_NAME" || \
                { log "ERROR" "将 $VETH_NS 移入 $NS_NAME 失败。"; exit 1; }
            
            $SUDO ip netns exec "$NS_NAME" ip addr add "$NAMESPACE_IP/24" dev "$VETH_NS" || \
                { log "ERROR" "为 $VETH_NS@$NS_NAME 分配IP地址失败。"; exit 1; }
            
            $SUDO ip addr add "$GATEWAY_IP/24" dev "$VETH_HOST" || \
                { log "ERROR" "为 $VETH_HOST 分配IP地址失败。"; exit 1; }
            
            # 启动设备并设置MTU
            $SUDO ip link set "$VETH_HOST" up || \
                { log "ERROR" "启动 $VETH_HOST 失败。"; exit 1; }
            
            $SUDO ip netns exec "$NS_NAME" ip link set "$VETH_NS" up || \
                { log "ERROR" "启动 $VETH_NS@$NS_NAME 失败。"; exit 1; }
            
            # 设置MTU值（确保只传递数字）
            $SUDO ip netns exec "$NS_NAME" ip link set dev "$VETH_NS" mtu "$DYNAMIC_MTU" || \
                log "WARNING" "为 $VETH_NS 设置MTU失败，可能会影响连接稳定性。"
            
            # 禁用反向路径过滤
            $SUDO sysctl -w "net.ipv4.conf.$VETH_HOST.rp_filter=0" >/dev/null || \
                log "WARNING" "禁用 $VETH_HOST 反向路径过滤失败。"
            
            # 设置命名空间内的默认路由
            $SUDO ip netns exec "$NS_NAME" ip route add default via "$GATEWAY_IP" || \
                { log "ERROR" "在 $NS_NAME 中设置默认路由失败。"; exit 1; }
            
            # 配置NAT和转发规则
            if ! $SUDO iptables -t nat -C POSTROUTING -s "$SUBNET" -j MASQUERADE &> /dev/null; then
                $SUDO iptables -t nat -I POSTROUTING -s "$SUBNET" -j MASQUERADE || \
                    { log "ERROR" "配置NAT规则失败。"; exit 1; }
            fi
            
            if ! $SUDO iptables -C FORWARD -s "$SUBNET" -j ACCEPT &> /dev/null; then
                $SUDO iptables -I FORWARD -s "$SUBNET" -j ACCEPT || \
                    { log "ERROR" "配置出向FORWARD规则失败。"; exit 1; }
            fi
            
            if ! $SUDO iptables -C FORWARD -d "$SUBNET" -j ACCEPT &> /dev/null; then
                $SUDO iptables -I FORWARD -d "$SUBNET" -j ACCEPT || \
                    { log "ERROR" "配置入向FORWARD规则失败。"; exit 1; }
            fi
            
            # 初始化WARP实例
            WARP_INTERNAL_PORT=$((40000 + i))
            SOCAT_LISTEN_PORT=$((40001 + i))
            
            init_warp_instance "$NS_NAME" "$i" "$WARP_INTERNAL_PORT"
            
            # 启动socat端口转发
            $SUDO ip netns exec "$NS_NAME" bash -c "
                nohup socat TCP4-LISTEN:$SOCAT_LISTEN_PORT,fork,reuseaddr TCP4:127.0.0.1:$WARP_INTERNAL_PORT >/dev/null 2>&1 &
                echo \$! > $INSTANCE_IPC_DIR/socat.pid
            " || { log "ERROR" "在 $NS_NAME 中启动socat失败。"; exit 1; }
            
            # 创建端口映射
            HOST_PORT=$((BASE_PORT + i))
            log "INFO" "   - 创建端口映射 主机端口 $HOST_PORT -> $NAMESPACE_IP:$SOCAT_LISTEN_PORT..."
            
            # 为外部流量创建DNAT规则
            if ! $SUDO iptables -t nat -C PREROUTING -p tcp --dport $HOST_PORT -j DNAT --to-destination $NAMESPACE_IP:$SOCAT_LISTEN_PORT &> /dev/null; then
                $SUDO iptables -t nat -I PREROUTING -p tcp --dport $HOST_PORT -j DNAT --to-destination $NAMESPACE_IP:$SOCAT_LISTEN_PORT || \
                    { log "ERROR" "创建PREROUTING DNAT规则失败。"; exit 1; }
            fi
            
            # 为本机流量创建DNAT规则
            if ! $SUDO iptables -t nat -C OUTPUT -p tcp -d 127.0.0.1 --dport $HOST_PORT -j DNAT --to-destination $NAMESPACE_IP:$SOCAT_LISTEN_PORT &> /dev/null; then
                $SUDO iptables -t nat -I OUTPUT -p tcp -d 127.0.0.1 --dport $HOST_PORT -j DNAT --to-destination $NAMESPACE_IP:$SOCAT_LISTEN_PORT || \
                    { log "ERROR" "创建OUTPUT DNAT规则失败。"; exit 1; }
            fi
            
            log "INFO" "🎉 WARP 实例 $i 创建成功，SOCKS5代理监听在主机端口: $HOST_PORT"
            
        ) 200>"$LOCK_FILE"
        
        # 在创建下一个实例前加入延迟，避免资源竞争
        if [ "$i" -lt "$(($POOL_SIZE-1))" ]; then
            log "INFO" "   ⏳ 等待3秒后继续..."
            sleep 3
        fi
    done
    
    log "INFO" "====================================================="
    log "INFO" "✅✅✅ WARP 代理池创建完成！共 $POOL_SIZE 个实例。"
    log "INFO" "每个实例的SOCKS5代理端口从 $BASE_PORT 开始递增。"
}

# --- 主逻辑 ---
main() {
    log "INFO" "🚀 开始执行 WARP 代理池创建脚本..."
    
    # 确保日志目录存在
    $SUDO mkdir -p "$(dirname "$LOG_FILE")"
    $SUDO touch "$LOG_FILE"
    $SUDO chmod 644 "$LOG_FILE"
    
    # 首先执行清理，确保环境干净
    cleanup
    
    # 然后创建新的代理池
    create_pool
    
    log "INFO" "🎉🎉🎉 脚本执行完毕！"
    log "INFO" "查看日志: $LOG_FILE"
}

# 执行主函数
main "$@"