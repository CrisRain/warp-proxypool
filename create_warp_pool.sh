#!/bin/bash
# 增强脚本健壮性：
# -e: 遇到错误立即退出
# -u: 使用未定义变量时报错
# -o pipefail: 管道中任一命令失败则整个管道失败
set -euo pipefail
# --- 权限检查和SUDO变量定义 ---
# 必须在脚本早期定义SUDO，因为 set -u 会在未定义变量被使用时报错
if [ "$(id -u)" -ne 0 ]; then
    SUDO="sudo"
else
    SUDO=""
fi

# 强制加载 nat 模块，防止 iptables 操作静默失败
$SUDO modprobe iptable_nat || log "WARNING" "加载 iptable_nat 模块失败，nat 表可能无法正常工作。"

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
    local timestamp
    timestamp=$(date "+%Y-%m-%d %H:%M:%S")

    # 输出到标准错误 (控制台) - 使用 printf 直接格式化输出
    printf "[%s] [%s] %s\n" "$timestamp" "$level" "$message" >&2

    # 同时追加到日志文件
    if [ -z "${SUDO+x}" ] || [ -z "$SUDO" ]; then # 如果 SUDO 未定义或为空 (例如以root运行)
        # 直接使用 printf 写入日志文件
        printf "[%s] [%s] %s\n" "$timestamp" "$level" "$message" >> "$LOG_FILE" 2>/dev/null || true
    else
        # SUDO 已定义且非空，使用 printf 将格式化后的字符串通过管道传递给 sudo tee
        # tee 的标准输出和标准错误都重定向到 /dev/null，防止重复打印到屏幕
        printf "[%s] [%s] %s\n" "$timestamp" "$level" "$message" | $SUDO tee -a "$LOG_FILE" >/dev/null 2>&1
    fi
}

# --- 前置检查 ---
# 检查必要命令是否存在
for cmd in warp-cli ip iptables sysctl mkdir tee flock; do
    if ! command -v "$cmd" &> /dev/null; then
        log "ERROR" "命令未找到: $cmd。请确保已安装必要的依赖。"
        exit 1
    fi
done
log "INFO" "✅ 所有必要命令检查通过。"

# 检查root权限或sudo权限
if [ "$EUID" -ne 0 ]; then
    # 检查无密码sudo权限
    if ! $SUDO -n true 2>/dev/null; then
        log "ERROR" "需要root权限或配置无密码sudo。"
        exit 1
    fi
    log "INFO" "⚠️ 使用sudo权限运行"
else
    log "INFO" "✅ root权限检查通过。"
fi

# 启动sudo会话保持进程
if [ -n "$SUDO" ]; then # 仅当SUDO变量非空时 (即需要sudo时)
    if $SUDO -n true 2>/dev/null; then
        log "INFO" "✅ 无密码sudo权限检查通过，启动sudo会话保持进程。"
        # 在后台循环中运行 `sudo -v` 来刷新sudo时间戳
        while true; do $SUDO -n true; sleep 60; kill -0 "$$" || exit; done &>/dev/null &
        SUDO_KEEPALIVE_PID=$!
        # 设置一个陷阱，在脚本退出时杀死后台进程
        # 确保SUDO_KEEPALIVE_PID已设置
        trap '[ -n "${SUDO_KEEPALIVE_PID-}" ] && '"$SUDO"' kill "$SUDO_KEEPALIVE_PID" &>/dev/null' EXIT
    else
        log "WARNING" "⚠️  无密码sudo权限似乎不可用或已过期，无法启动sudo会话保持。后续操作可能频繁请求密码。"
    fi
else
    log "INFO" "ℹ️  以root身份运行，无需sudo会话保持。"
fi

# --- 函数定义 ---
# 清理函数
cleanup() {
    log "INFO" "🧹 开始进行彻底清理，确保环境干净..."

    # 1. 预先收集所有需要清理的iptables规则信息
    # 必须在删除命名空间之前进行，否则无法获取到相关信息
    log "INFO" "   - 步骤1: 预扫描现有命名空间以准备清理iptables规则..."
    declare -A script_subnets
    declare -A script_host_ports
    declare -A script_namespace_ips
    declare -a existing_ns_names

    for NS_NAME_CLEANUP in $($SUDO ip netns list 2>/dev/null | awk '{print $1}'); do
        if [[ "$NS_NAME_CLEANUP" =~ ^ns([0-9]+)$ ]]; then
            existing_ns_names+=("$NS_NAME_CLEANUP") # 保存命名空间名称以供后续清理
            local idx_cleanup=${BASH_REMATCH[1]}
            script_host_ports[$((BASE_PORT + idx_cleanup))]=1

            local subnet_third_octet_cleanup=$((idx_cleanup / 256))
            local subnet_fourth_octet_cleanup=$((idx_cleanup % 256))
            script_namespace_ips["10.${subnet_third_octet_cleanup}.${subnet_fourth_octet_cleanup}.2"]=1
            script_subnets["10.${subnet_third_octet_cleanup}.${subnet_fourth_octet_cleanup}.0/24"]=1
        fi
    done
    log "INFO" "   ✅ 完成预扫描，已识别 ${#existing_ns_names[@]} 个由脚本管理的命名空间。"

    # 2. 清理 iptables 规则
    log "INFO" "   - 步骤2: 清理iptables规则..."
    if [ ${#existing_ns_names[@]} -gt 0 ]; then
        current_table=""
        # 使用进程替换来读取 iptables-save 的输出
        while IFS= read -r rule_line; do
            if [[ "$rule_line" == \** ]]; then # 表名行, 例如 *nat
                current_table="${rule_line#\*}"
                continue
            fi

            if [[ "$rule_line" == -A* ]]; then # 规则行, 例如 -A PREROUTING ...
                local chain_name=$(echo "$rule_line" | awk '{print $2}')
                # 获取 "-A CHAIN" 之后的规则部分
                local rule_spec=$(echo "$rule_line" | sed 's/^-A [^ ]* //')
                local should_delete=0

                # 检查 DNAT 规则 (在 nat 表中)
                if [ "$current_table" == "nat" ] && [[ "$rule_spec" == *"-j DNAT"* ]]; then
                    local dport_val=""
                    local to_dest_ip_val=""
                    local to_dest_port_val=""

                    if [[ "$rule_spec" =~ --dport[[:space:]]+([0-9]+) ]]; then
                        dport_val="${BASH_REMATCH[1]}"
                    fi
                    if [[ "$rule_spec" =~ --to-destination[[:space:]]+([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+):([0-9]+) ]]; then
                        to_dest_ip_val="${BASH_REMATCH[1]}"
                        to_dest_port_val="${BASH_REMATCH[2]}"
                    fi

                    if [ -n "$dport_val" ] && [ -n "$to_dest_ip_val" ] && [ -n "$to_dest_port_val" ]; then
                        if [[ -n "${script_host_ports[$dport_val]}" && \
                              -n "${script_namespace_ips[$to_dest_ip_val]}" ]]; then
                            if [[ "$chain_name" == "PREROUTING" || \
                                  ( "$chain_name" == "OUTPUT" && "$rule_spec" =~ -d[[:space:]]+127\.0\.0\.1 ) ]]; then
                                should_delete=1
                            fi
                        fi
                    fi
                fi

                # 检查 FORWARD 规则 (在 filter 表中)
                if [ "$current_table" == "filter" ] && [[ "$rule_spec" == *"-j ACCEPT"* && "$chain_name" == "FORWARD" ]]; then
                    local s_subnet_val=""
                    local d_subnet_val=""
                    if [[ "$rule_spec" =~ -s[[:space:]]+([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+) ]]; then
                        s_subnet_val="${BASH_REMATCH[1]}"
                    fi
                    if [[ "$rule_spec" =~ -d[[:space:]]+([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+) ]]; then
                        d_subnet_val="${BASH_REMATCH[1]}"
                    fi

                    local s_subnet_exists=0
                    local d_subnet_exists=0
                    if [ -n "$s_subnet_val" ] && [[ ${script_subnets[$s_subnet_val]+_} ]]; then
                        s_subnet_exists=1
                    fi
                    if [ -n "$d_subnet_val" ] && [[ ${script_subnets[$d_subnet_val]+_} ]]; then
                        d_subnet_exists=1
                    fi

                    if [ "$s_subnet_exists" -eq 1 ] || [ "$d_subnet_exists" -eq 1 ]; then
                        should_delete=1
                    fi
                fi

                # 检查 MASQUERADE 规则 (在 nat 表中)
                if [ "$current_table" == "nat" ] && [[ "$rule_spec" == *"-j MASQUERADE"* && "$chain_name" == "POSTROUTING" ]]; then
                    local s_subnet_val=""
                    if [[ "$rule_spec" =~ -s[[:space:]]+([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+) ]]; then
                        s_subnet_val="${BASH_REMATCH[1]}"
                    fi
                    if [ -n "$s_subnet_val" ] && [ -n "${script_subnets[$s_subnet_val]}" ]; then
                        should_delete=1
                    fi
                fi

                if [ "$should_delete" -eq 1 ]; then
                    log "INFO" "     - 删除规则 from $current_table/$chain_name: $rule_spec"
                    if ! $SUDO iptables -t "$current_table" -D "$chain_name" $rule_spec >/dev/null 2>&1; then
                        log "WARNING" "       - 删除规则失败 (可能已不存在或规则稍有不同): $SUDO iptables -t $current_table -D $chain_name $rule_spec"
                    fi
                fi
            fi
        done < <($SUDO iptables-save)
        log "INFO" "   ✅ 旧的iptables规则已清理。"
    else
        log "INFO" "   - 未发现由脚本管理的命名空间，跳过iptables规则清理。"
    fi

    # 3. 清理所有网络命名空间、挂载点、进程、veth设备和DNS配置
    log "INFO" "   - 步骤3: 清理网络命名空间及相关资源..."
    if [ ${#existing_ns_names[@]} -gt 0 ]; then
        for NS_NAME in "${existing_ns_names[@]}"; do
            log "INFO" "     - 正在清理命名空间 $NS_NAME..."
            local idx=${NS_NAME#ns}
            
            log "INFO" "       - 卸载绑定挂载..."
            $SUDO ip netns exec "$NS_NAME" sh -c '
                WARP_SYSTEM_CONFIG_DIR="/var/lib/cloudflare-warp"
                WARP_SYSTEM_IPC_DIR="/run/cloudflare-warp"
                if mount | grep -q "on $WARP_SYSTEM_CONFIG_DIR type"; then umount "$WARP_SYSTEM_CONFIG_DIR" || true; fi
                if mount | grep -q "on $WARP_SYSTEM_IPC_DIR type"; then umount "$WARP_SYSTEM_IPC_DIR" || true; fi
            '
            
            log "INFO" "       - 停止 $NS_NAME 内的所有进程..."
            if pids=$($SUDO ip netns pids "$NS_NAME" 2>/dev/null); then
                [ -n "$pids" ] && $SUDO kill -9 $pids >/dev/null 2>&1 || true
            fi
            sleep 1
            
            log "INFO" "       - 删除命名空间 $NS_NAME..."
            $SUDO ip netns del "$NS_NAME" >/dev/null 2>&1 || true
            
            local VETH_HOST="veth$idx"
            if ip link show "$VETH_HOST" &> /dev/null; then
                log "INFO" "     - 删除 veth 设备 $VETH_HOST..."
                $SUDO ip link del "$VETH_HOST" >/dev/null 2>&1 || true
            fi
            
            if [ -d "/etc/netns/$NS_NAME" ]; then
                log "INFO" "     - 删除DNS配置 /etc/netns/$NS_NAME..."
                $SUDO rm -rf "/etc/netns/$NS_NAME" >/dev/null 2>&1 || true
            fi
            
            local INSTANCE_CONFIG_DIR="${WARP_CONFIG_BASE_DIR}/${NS_NAME}"
            if [ -d "$INSTANCE_CONFIG_DIR" ]; then
                log "INFO" "     - 删除独立的WARP配置目录 $INSTANCE_CONFIG_DIR..."
                $SUDO rm -rf "$INSTANCE_CONFIG_DIR" >/dev/null 2>&1 || true
            fi
            
            local INSTANCE_IPC_DIR="${WARP_IPC_BASE_DIR}/${NS_NAME}"
            if [ -d "$INSTANCE_IPC_DIR" ]; then
                log "INFO" "     - 删除独立的WARP IPC目录 $INSTANCE_IPC_DIR..."
                $SUDO rm -rf "$INSTANCE_IPC_DIR" >/dev/null 2>&1 || true
            fi
        done
        log "INFO" "   ✅ 网络命名空间、veth设备及相关配置已清理。"
    else
        log "INFO" "   - 未发现需要清理的命名空间。"
    fi

    # 4. 杀死所有残留的转发进程
    log "INFO" "   - 步骤4: 停止所有残留的转发进程..."
    log "INFO" "   ✅ 转发进程清理完成 (socat已移除)。"
    
    # 5. 清理锁文件
    log "INFO" "   - 步骤5: 清理锁文件..."
    rm -f "$LOCK_FILE" >/dev/null 2>&1 || true
    log "INFO" "   ✅ 锁文件已清理。"
    
    log "INFO" "✅ 彻底清理完成。"
}

# 在全局命名空间中注册WARP (如果尚未注册)
register_warp_globally() {
    log "INFO" "🌐 检查全局WARP注册状态..."
    # WARP的注册文件路径
    local reg_file="/var/lib/cloudflare-warp/reg.json"

    # 检查注册文件是否存在且内容不为空
    if [ -s "$reg_file" ]; then
        log "INFO" "   ✅ 全局WARP注册文件已存在 ($reg_file)，跳过注册。"
        return 0
    fi

    log "INFO" "   - 全局WARP未注册，开始注册流程..."
    # 确保cloudflare-warp目录存在且权限正确
    $SUDO mkdir -p /var/lib/cloudflare-warp
    $SUDO chmod 700 /var/lib/cloudflare-warp

    # 循环尝试注册，因为网络问题可能导致失败
    for attempt in {1..5}; do
        log "INFO" "     - 尝试注册 (第 $attempt 次)..."
        # 执行注册命令，接受服务条款
        if $SUDO warp-cli --accept-tos register; then
            log "INFO" "   ✅ 全局WARP注册成功！"
            # 成功后，设置模式为warp，然后断开连接，以防影响主机网络
            log "INFO" "   - 设置模式为 WARP 并断开连接..."
            $SUDO warp-cli set-mode warp >/dev/null 2>&1 || log "WARNING" "设置模式失败"
            $SUDO warp-cli disconnect >/dev/null 2>&1 || log "WARNING" "断开连接失败"
            return 0
        fi
        log "WARNING" "     - 注册失败，等待5秒后重试..."
        sleep 5
    done

    log "ERROR" "   ❌ 经过多次尝试后，全局WARP注册失败。请检查主机网络环境和Cloudflare服务状态。"
    exit 1
}

# 计算MTU值
calculate_mtu() {
    # 获取默认接口
    local default_iface=$($SUDO ip -o route get 8.8.8.8 2>/dev/null | awk '{print $5}')
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
        
        # 由于已在全局注册，此处不再需要注册逻辑
        # 检查状态以确认服务是否正常
        if ! warp-cli --accept-tos status | grep -q "Status: Disconnected"; then
             log "WARNING" "     - WARP 初始状态不是 Disconnected，可能存在问题。尝试继续..."
             warp-cli --accept-tos status
        else
             log "INFO" "     ✅ WARP 初始状态为 Disconnected，符合预期。"
        fi
        
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
    # 使用更可靠的方式确保 route_localnet 生效
    $SUDO sh -c "echo 1 > /proc/sys/net/ipv4/conf/all/route_localnet" || \
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
            
            init_warp_instance "$NS_NAME" "$i" "$WARP_INTERNAL_PORT"
            
            # socat 已被移除，直接使用 iptables 转发到 WARP 的内部端口
            
            # 创建端口映射
            HOST_PORT=$((BASE_PORT + i))
            log "INFO" "   - 创建端口映射 主机端口 $HOST_PORT -> $NAMESPACE_IP:$WARP_INTERNAL_PORT..."
            
            # 为外部流量创建DNAT规则
            if ! $SUDO iptables -t nat -C PREROUTING -p tcp --dport $HOST_PORT -j DNAT --to-destination $NAMESPACE_IP:$WARP_INTERNAL_PORT &> /dev/null; then
                $SUDO iptables -t nat -I PREROUTING -p tcp --dport $HOST_PORT -j DNAT --to-destination $NAMESPACE_IP:$WARP_INTERNAL_PORT || \
                    { log "ERROR" "创建PREROUTING DNAT规则失败。"; exit 1; }
            fi
            
            # 为本机流量创建DNAT规则 (先清空以确保幂等性)
            log "INFO" "   - 为本机流量 (127.0.0.1) 创建 OUTPUT 规则..."
            if ! $SUDO iptables -t nat -C OUTPUT -p tcp -d 127.0.0.1 --dport $HOST_PORT -j DNAT --to-destination $NAMESPACE_IP:$WARP_INTERNAL_PORT &> /dev/null; then
                $SUDO iptables -t nat -I OUTPUT -p tcp -d 127.0.0.1 --dport $HOST_PORT -j DNAT --to-destination $NAMESPACE_IP:$WARP_INTERNAL_PORT || \
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

# 生成JSON配置文件
generate_config_json() {
    log "INFO" "📄 开始生成 warp_pool_config.json 配置文件..."
    local json_file="warp_pool_config.json"
    local json_content="["

    for i in $(seq 0 $(($POOL_SIZE-1))); do
        local id=$i
        local namespace="ns$i"
        local port=$((BASE_PORT + i))

        # 构建JSON对象
        local instance_json
        instance_json=$(printf '{"id": %d, "namespace": "%s", "port": %d}' "$id" "$namespace" "$port")

        # 追加到JSON内容
        if [ "$i" -gt 0 ]; then
            json_content="$json_content,"
        fi
        json_content="$json_content$instance_json"
    done

    json_content="$json_content]"

    # 写入文件
    # 不需要sudo，因为是在当前用户目录下创建文件
    echo "$json_content" > "$json_file"
    log "INFO" "✅ 配置文件已成功生成: $json_file"
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

    # 全局注册WARP
    register_warp_globally
    
    # 然后创建新的代理池
    create_pool
    
    # 生成配置文件
    generate_config_json
    
    log "INFO" "🎉🎉🎉 脚本执行完毕！"
    log "INFO" "查看日志: $LOG_FILE"
}

# 执行主函数
main "$@"