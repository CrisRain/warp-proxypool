#!/bin/bash
# =================================================================
# WARP 代理池统一管理脚本 (manage_pool.sh)
#
# 功能:
#   - 启动、停止、重启和清理整个代理池服务。
#   - 集中管理配置，消除冗余。
#   - 使用健壮的iptables规则管理。
#   - 统一的日志记录。
# =================================================================

# --- 脚本健壮性设置 ---
# -e: 遇到错误立即退出
# -u: 使用未定义变量时报错
# -o pipefail: 管道中任一命令失败则整个管道失败
set -euo pipefail

# --- 全局配置 ---
# WARP池配置
POOL_SIZE=3                 # 代理池大小
BASE_PORT=10800             # SOCKS5代理的基础端口号
WARP_LICENSE_KEY=""         # WARP+ 许可证密钥 (可选)
WARP_ENDPOINT=""            # 自定义WARP端点IP和端口 (可选)

# 路径配置
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
CONFIG_BASE_DIR="/var/lib/warp-configs"  # WARP配置目录
IPC_BASE_DIR="/run/warp-sockets"         # WARP IPC目录
LOG_FILE="/var/log/warp-pool.log"        # 日志文件路径
LOCK_FILE="/tmp/warp_pool_$(id -u).lock" # 用户隔离的锁文件
PID_FILE="/tmp/proxy_manager.pid"        # API服务进程ID文件

# Python应用配置
VENV_DIR="${SCRIPT_DIR}/.venv"
REQUIREMENTS_FILE="${SCRIPT_DIR}/requirements.txt"
PROXY_MANAGER_SCRIPT="${SCRIPT_DIR}/src/proxy_manager.py"
PYTHON_CMD="python3"

# iptables配置
IPTABLES_CHAIN_PREFIX="WARP_POOL"
IPTABLES_COMMENT_PREFIX="WARP-POOL"

# --- SUDO权限处理 ---
# 在脚本早期定义SUDO变量
if [ "$(id -u)" -ne 0 ]; then
    SUDO="sudo"
else
    SUDO=""
fi

# --- 日志功能 ---
log() {
    local level=$1
    local message=$2
    local timestamp
    timestamp=$(date "+%Y-%m-%d %H:%M:%S")
    
    # 格式化消息
    local log_message
    log_message=$(printf "[%s] [%s] %s" "$timestamp" "$level" "$message")

    # 输出到控制台 (stderr)
    echo "$log_message" >&2

    # 追加到日志文件 (如果路径可写)
    if [ -n "$SUDO" ]; then
        echo "$log_message" | $SUDO tee -a "$LOG_FILE" >/dev/null
    else
        echo "$log_message" >> "$LOG_FILE" 2>/dev/null || true
    fi
}

# --- 帮助信息 ---
show_help() {
    echo "WARP 代理池统一管理脚本"
    echo ""
    echo "用法: $0 <命令> [选项]"
    echo ""
    echo "命令:"
    echo "  start       启动整个代理池服务 (创建网络资源并启动API)。"
    echo "              选项: --foreground  在前台运行API服务，用于Docker。"
    echo "  stop        停止API服务并清理所有网络资源。"
    echo "  restart     重启服务 (相当于 stop 后再 start)。"
    echo "  status      检查服务和网络资源的状态。"
    echo "  cleanup     仅清理所有网络资源，不影响正在运行的API服务。"
    echo "  start-api   仅启动API服务 (假设网络资源已存在)。"
    echo "  stop-api    仅停止API服务。"
    echo "  help        显示此帮助信息。"
    echo ""
    echo "示例:"
    echo "  sudo ./manage_pool.sh start"
    echo "  sudo ./manage_pool.sh stop"
    echo "  ./manage_pool.sh status"
}

# --- iptables 管理 ---
setup_iptables_chains() {
    log "INFO" "创建或验证iptables自定义链..."
    $SUDO iptables -t nat -N "${IPTABLES_CHAIN_PREFIX}_PREROUTING" 2>/dev/null || true
    $SUDO iptables -t nat -N "${IPTABLES_CHAIN_PREFIX}_OUTPUT" 2>/dev/null || true
    $SUDO iptables -t nat -N "${IPTABLES_CHAIN_PREFIX}_POSTROUTING" 2>/dev/null || true
    $SUDO iptables -N "${IPTABLES_CHAIN_PREFIX}_FORWARD" 2>/dev/null || true

    if ! $SUDO iptables -t nat -C PREROUTING -j "${IPTABLES_CHAIN_PREFIX}_PREROUTING" 2>/dev/null; then
        $SUDO iptables -t nat -I PREROUTING 1 -j "${IPTABLES_CHAIN_PREFIX}_PREROUTING"
    fi
    if ! $SUDO iptables -t nat -C OUTPUT -j "${IPTABLES_CHAIN_PREFIX}_OUTPUT" 2>/dev/null; then
        $SUDO iptables -t nat -I OUTPUT 1 -j "${IPTABLES_CHAIN_PREFIX}_OUTPUT"
    fi
    if ! $SUDO iptables -t nat -C POSTROUTING -j "${IPTABLES_CHAIN_PREFIX}_POSTROUTING" 2>/dev/null; then
        $SUDO iptables -t nat -I POSTROUTING 1 -j "${IPTABLES_CHAIN_PREFIX}_POSTROUTING"
    fi
    if ! $SUDO iptables -C FORWARD -j "${IPTABLES_CHAIN_PREFIX}_FORWARD" 2>/dev/null; then
        $SUDO iptables -I FORWARD 1 -j "${IPTABLES_CHAIN_PREFIX}_FORWARD"
    fi
    log "INFO" "✅ iptables自定义链已设置。"
}

cleanup_iptables() {
    log "INFO" "🧹 清理iptables规则..."
    
    # 从主链中移除自定义链的引用
    $SUDO iptables -t nat -D PREROUTING -j "${IPTABLES_CHAIN_PREFIX}_PREROUTING" 2>/dev/null || true
    $SUDO iptables -t nat -D OUTPUT -j "${IPTABLES_CHAIN_PREFIX}_OUTPUT" 2>/dev/null || true
    $SUDO iptables -t nat -D POSTROUTING -j "${IPTABLES_CHAIN_PREFIX}_POSTROUTING" 2>/dev/null || true
    $SUDO iptables -D FORWARD -j "${IPTABLES_CHAIN_PREFIX}_FORWARD" 2>/dev/null || true
    
    # 清空并删除自定义链
    $SUDO iptables -t nat -F "${IPTABLES_CHAIN_PREFIX}_PREROUTING" 2>/dev/null || true
    $SUDO iptables -t nat -X "${IPTABLES_CHAIN_PREFIX}_PREROUTING" 2>/dev/null || true
    $SUDO iptables -t nat -F "${IPTABLES_CHAIN_PREFIX}_OUTPUT" 2>/dev/null || true
    $SUDO iptables -t nat -X "${IPTABLES_CHAIN_PREFIX}_OUTPUT" 2>/dev/null || true
    $SUDO iptables -t nat -F "${IPTABLES_CHAIN_PREFIX}_POSTROUTING" 2>/dev/null || true
    $SUDO iptables -t nat -X "${IPTABLES_CHAIN_PREFIX}_POSTROUTING" 2>/dev/null || true
    $SUDO iptables -F "${IPTABLES_CHAIN_PREFIX}_FORWARD" 2>/dev/null || true
    $SUDO iptables -X "${IPTABLES_CHAIN_PREFIX}_FORWARD" 2>/dev/null || true
    
    log "INFO" "✅ iptables规则清理完成。"
}

# --- 资源清理 ---
cleanup_resources() {
    log "INFO" "🧹 开始全面清理网络资源..."

    # 1. 清理iptables
    cleanup_iptables

    # 2. 清理网络命名空间及相关资源
    log "INFO" "   - 清理网络命名空间、veth设备和配置文件..."
    local existing_ns
    existing_ns=$($SUDO ip netns list | awk '{print $1}' | grep '^ns[0-9]\+') || true
    
    if [ -z "$existing_ns" ]; then
        log "INFO" "   - 未发现需要清理的网络命名空间。"
    else
        for ns_name in $existing_ns; do
            log "INFO" "     - 正在清理命名空间 $ns_name..."
            local idx=${ns_name#ns}
            
            # 卸载绑定挂载
            $SUDO ip netns exec "$ns_name" sh -c '
                umount /var/lib/cloudflare-warp &>/dev/null || true
                umount /run/cloudflare-warp &>/dev/null || true
            ' 2>/dev/null || true

            # 强制杀死命名空间内的所有进程
            if pids=$($SUDO ip netns pids "$ns_name" 2>/dev/null); then
                [ -n "$pids" ] && $SUDO kill -9 $pids >/dev/null 2>&1 || true
            fi
            sleep 0.5
            
            # 删除命名空间
            $SUDO ip netns del "$ns_name" >/dev/null 2>&1 || true
            
            # 删除veth设备
            local veth_host="veth$idx"
            if $SUDO ip link show "$veth_host" &> /dev/null; then
                $SUDO ip link del "$veth_host" >/dev/null 2>&1 || true
            fi
            
            # 删除相关目录
            $SUDO rm -rf "/etc/netns/$ns_name" "${CONFIG_BASE_DIR}/${ns_name}" "${IPC_BASE_DIR}/${ns_name}"
        done
        log "INFO" "   ✅ 网络命名空间清理完成。"
    fi

    # 3. 杀死残留进程
    log "INFO"   "- 停止所有残留的WARP进程..."
    $SUDO pkill -f warp-svc >/dev/null 2>&1 || true
    $SUDO pkill -f warp-cli >/dev/null 2>&1 || true
    log "INFO"   "✅ WARP进程已清理。"

    # 4. 清理锁文件
    log "INFO" "   - 清理锁文件..."
    rm -f "$LOCK_FILE"
    log "INFO" "   ✅ 锁文件已清理。"

    log "INFO" "✅ 全面清理完成。"
}


# --- API 服务管理 ---
start_api() {
    log "INFO" "🐍 启动代理管理API服务..."

    # 1. 检查Python虚拟环境
    if [ ! -d "$VENV_DIR" ]; then
        log "INFO" "   - 创建Python虚拟环境到 ${VENV_DIR}..."
        $PYTHON_CMD -m venv "$VENV_DIR" || { log "ERROR" "创建Python虚拟环境失败。"; return 1; }
    fi
    
    # 2. 安装依赖
    local venv_pip="${VENV_DIR}/bin/pip"
    if [ -f "$REQUIREMENTS_FILE" ]; then
        log "INFO" "   - 从 ${REQUIREMENTS_FILE} 安装依赖..."
        "$venv_pip" install -r "$REQUIREMENTS_FILE" || { log "ERROR" "安装依赖失败。"; return 1; }
    else
        log "WARNING" "   - 未找到 ${REQUIREMENTS_FILE}，请确保依赖已安装。"
    fi

    # 3. 检查API是否已在运行
    if [ -f "$PID_FILE" ] && ps -p "$(cat "$PID_FILE")" > /dev/null; then
        log "WARNING" "API服务已在运行 (PID: $(cat "$PID_FILE"))。"
        return 0
    fi

    # 4. 启动API
    local venv_python="${VENV_DIR}/bin/python"
    export POOL_SIZE # 导出环境变量供Python脚本使用
    export BASE_PORT
    
    if [ "$1" = true ]; then # 前台运行
        log "INFO" "   - 在前台启动API服务..."
        exec "$venv_python" "$PROXY_MANAGER_SCRIPT"
    else # 后台运行
        log "INFO" "   - 在后台启动API服务..."
        nohup "$venv_python" "$PROXY_MANAGER_SCRIPT" > "$LOG_FILE" 2>&1 &
        local pid=$!
        echo "$pid" > "$PID_FILE"
        log "INFO" "   ✅ API服务已启动 (PID: $pid)。日志: $LOG_FILE"
    fi
}

stop_api() {
    log "INFO" "🛑 停止代理管理API服务..."
    if [ ! -f "$PID_FILE" ]; then
        log "INFO" "   - 未找到PID文件，可能服务未在运行。"
        # 作为后备，尝试用pkill杀死
        $SUDO pkill -f "$PROXY_MANAGER_SCRIPT" >/dev/null 2>&1 || true
        return 0
    fi

    local pid
    pid=$(cat "$PID_FILE")
    if ps -p "$pid" > /dev/null; then
        log "INFO" "   - 正在停止进程 (PID: $pid)..."
        kill "$pid" || true
        sleep 2
        if ps -p "$pid" > /dev/null; then
            log "WARNING" "   - 进程无法正常停止，强制杀死..."
            kill -9 "$pid" || true
        fi
        log "INFO" "   ✅ API服务已停止。"
    else
        log "INFO" "   - PID文件中的进程 ($pid) 未在运行。"
    fi
    rm -f "$PID_FILE"
}

# --- 核心创建逻辑 ---
check_dependencies() {
    log "INFO" "🔍 检查系统依赖..."
    for cmd in warp-cli ip iptables sysctl mkdir tee flock; do
        if ! command -v "$cmd" &> /dev/null; then
            log "ERROR" "命令未找到: $cmd。请运行安装脚本或手动安装。"
            return 1
        fi
    done
    log "INFO" "✅ 所有必要命令检查通过。"
}

register_warp_globally() {
    log "INFO" "🌐 检查全局WARP注册状态..."
    if [ -s "/var/lib/cloudflare-warp/reg.json" ]; then
        log "INFO" "   ✅ 全局WARP已注册。"
        return 0
    fi

    log "INFO" "   - 全局WARP未注册，开始注册..."
    $SUDO mkdir -p /var/lib/cloudflare-warp && $SUDO chmod 700 /var/lib/cloudflare-warp
    for attempt in {1..3}; do
        if $SUDO warp-cli --accept-tos register; then
            log "INFO" "   ✅ 全局WARP注册成功！"
            $SUDO warp-cli set-mode warp >/dev/null 2>&1
            $SUDO warp-cli disconnect >/dev/null 2>&1
            return 0
        fi
        log "WARNING" "     - 注册失败 (第 $attempt 次)，等待3秒后重试..."
        sleep 3
    done
    log "ERROR" "   ❌ 全局WARP注册失败。"
    return 1
}

init_warp_instance() {
    local ns_name=$1
    local idx=$2
    local warp_internal_port=$3
    
    log "INFO" "     - 在 $ns_name 中初始化WARP..."
    $SUDO ip netns exec "$ns_name" bash -c '
        set -euo pipefail
        # 从父脚本继承变量
        ns_name=$1; idx=$2; warp_internal_port=$3;
        warp_license_key=$4; warp_endpoint=$5; log_file=$6

        log_ns() {
            printf "[%s] [%s] [%s] %s\n" "$(date "+%Y-%m-%d %H:%M:%S")" "$1" "$ns_name" "$2" >> "$log_file"
        }

        log_ns "INFO" "启动WARP守护进程..."
        nohup warp-svc >/dev/null 2>&1 &
        sleep 5

        for i in {1..10}; do
            if test -S /run/cloudflare-warp/warp_service; then break; fi
            log_ns "INFO" "等待WARP服务就绪... ($i/10)"
            sleep 2
        done
        if ! test -S /run/cloudflare-warp/warp_service; then
            log_ns "ERROR" "等待WARP服务超时。"
            exit 1
        fi
        
        log_ns "INFO" "设置代理模式并连接..."
        warp-cli --accept-tos set-mode proxy
        warp-cli --accept-tos proxy port "$warp_internal_port"
        [ -n "$warp_license_key" ] && warp-cli --accept-tos registration license "$warp_license_key"
        [ -n "$warp_endpoint" ] && warp-cli --accept-tos tunnel endpoint set "$warp_endpoint"
        warp-cli --accept-tos connect

        for i in {1..15}; do
            if warp-cli --accept-tos status | grep -q "Status: Connected"; then
                log_ns "INFO" "WARP连接成功！"
                exit 0
            fi
            log_ns "INFO" "等待WARP连接... ($i/15)"
            sleep 2
        done
        
        log_ns "ERROR" "连接WARP超时。"
        warp-cli --accept-tos status
        exit 1
    ' bash "$ns_name" "$idx" "$warp_internal_port" "$WARP_LICENSE_KEY" "$WARP_ENDPOINT" "$LOG_FILE"
}

create_pool() {
    log "INFO" "🚀 开始创建 WARP 代理池 (大小: $POOL_SIZE)..."
    
    check_dependencies
    register_warp_globally

    $SUDO sysctl -w net.ipv4.ip_forward=1 >/dev/null
    $SUDO sh -c "echo 1 > /proc/sys/net/ipv4/conf/all/route_localnet"

    setup_iptables_chains

    for i in $(seq 0 $(($POOL_SIZE-1))); do
        (
            $SUDO flock -x 200 # 使用文件描述符200进行锁定
            
            local ns_name="ns$i"
            log "INFO" "✨ 正在创建 WARP 实例 $i (命名空间: $ns_name)..."
            
            # 网络配置 (使用 /256 和 %256 来确保每个实例都有唯一的 /24 子网)
            local subnet_third=$((i / 256))
            local subnet_fourth=$((i % 256))
            local gateway_ip="10.${subnet_third}.${subnet_fourth}.1"
            local namespace_ip="10.${subnet_third}.${subnet_fourth}.2"
            local subnet="${gateway_ip%.*}.0/24"
            local veth_host="veth$i"
            local veth_ns="veth${i}-ns"
            
            # 创建命名空间和veth
            $SUDO ip netns add "$ns_name"
            $SUDO ip link add "$veth_host" type veth peer name "$veth_ns"
            $SUDO ip link set "$veth_ns" netns "$ns_name"
            $SUDO ip addr add "$gateway_ip/24" dev "$veth_host"
            $SUDO ip link set "$veth_host" up
            
            # 配置命名空间内部网络
            $SUDO ip netns exec "$ns_name" ip addr add "$namespace_ip/24" dev "$veth_ns"
            $SUDO ip netns exec "$ns_name" ip link set lo up
            $SUDO ip netns exec "$ns_name" ip link set "$veth_ns" up
            $SUDO ip netns exec "$ns_name" ip route add default via "$gateway_ip"

            # 绑定配置目录
            $SUDO mkdir -p "${CONFIG_BASE_DIR}/${ns_name}" "${IPC_BASE_DIR}/${ns_name}"
            $SUDO ip netns exec "$ns_name" mkdir -p /var/lib/cloudflare-warp /run/cloudflare-warp
            $SUDO ip netns exec "$ns_name" mount --bind "${CONFIG_BASE_DIR}/${ns_name}" /var/lib/cloudflare-warp
            $SUDO ip netns exec "$ns_name" mount --bind "${IPC_BASE_DIR}/${ns_name}" /run/cloudflare-warp

            # 初始化WARP
            local warp_internal_port=$((40000 + i))
            init_warp_instance "$ns_name" "$i" "$warp_internal_port"

            # 配置iptables规则
            local host_port=$((BASE_PORT + i))
            local comment_args="-m comment --comment \"${IPTABLES_COMMENT_PREFIX}-DNAT-$host_port\""
            $SUDO iptables -t nat -A "${IPTABLES_CHAIN_PREFIX}_PREROUTING" -p tcp --dport "$host_port" -j DNAT --to-destination "$namespace_ip:$warp_internal_port" $comment_args
            $SUDO iptables -t nat -A "${IPTABLES_CHAIN_PREFIX}_OUTPUT" -p tcp -d 127.0.0.1 --dport "$host_port" -j DNAT --to-destination "$namespace_ip:$warp_internal_port" $comment_args
            
            comment_args="-m comment --comment \"${IPTABLES_COMMENT_PREFIX}-FWD-$subnet\""
            $SUDO iptables -A "${IPTABLES_CHAIN_PREFIX}_FORWARD" -s "$subnet" -j ACCEPT $comment_args
            $SUDO iptables -A "${IPTABLES_CHAIN_PREFIX}_FORWARD" -d "$subnet" -j ACCEPT $comment_args
            
            comment_args="-m comment --comment \"${IPTABLES_COMMENT_PREFIX}-MASQ-$subnet\""
            $SUDO iptables -t nat -A "${IPTABLES_CHAIN_PREFIX}_POSTROUTING" -s "$subnet" -j MASQUERADE $comment_args

            log "INFO" "✅ 实例 $i 创建成功，代理监听在 127.0.0.1:$host_port"
        ) 200>"$LOCK_FILE"
    done
    log "INFO" "✅✅✅ WARP 代理池创建完成！"
}

# --- 状态检查 ---
show_status() {
    log "INFO" "📊 服务状态检查..."
    
    # 1. API 进程状态
    if [ -f "$PID_FILE" ] && ps -p "$(cat "$PID_FILE")" > /dev/null; then
        log "INFO" "   - API 服务: ✅ 运行中 (PID: $(cat "$PID_FILE"))"
    else
        log "INFO" "   - API 服务: ❌ 已停止"
    fi

    # 2. 网络命名空间状态
    log "INFO" "   - 网络命名空间:"
    local ns_list
    ns_list=$($SUDO ip netns list | awk '{print $1}' | grep '^ns[0-9]\+') || true
    if [ -z "$ns_list" ]; then
        log "INFO" "     - 未发现活动的命名空间。"
    else
        for ns in $ns_list; do
            log "INFO" "     - ✅ $ns"
        done
    fi

    # 3. iptables 规则状态
    log "INFO" "   - iptables 规则:"
    $SUDO iptables -t nat -L "${IPTABLES_CHAIN_PREFIX}_PREROUTING" -n -v | head -n 2
    $SUDO iptables -L "${IPTABLES_CHAIN_PREFIX}_FORWARD" -n -v | head -n 2
}


# --- 主逻辑 ---
main() {
    # 确保日志文件和目录存在且权限正确
    $SUDO mkdir -p "$(dirname "$LOG_FILE")"
    $SUDO touch "$LOG_FILE"
    $SUDO chmod 644 "$LOG_FILE"

    # 启动sudo会话保持
    if [ -n "$SUDO" ] && $SUDO -n true 2>/dev/null; then
        log "INFO" "启动sudo会话保持进程..."
        while true; do $SUDO -n true; sleep 60; kill -0 "$$" || exit; done &>/dev/null &
        SUDO_KEEPALIVE_PID=$!
        trap '$SUDO kill "$SUDO_KEEPALIVE_PID" &>/dev/null' EXIT
    fi

    local action=${1:-"help"}
    local foreground=false
    if [ "${2:-}" == "--foreground" ]; then
        foreground=true
    fi

    # 检查root权限，但允许status和help命令
    if [[ "$action" != "status" && "$action" != "help" && "$EUID" -ne 0 ]]; then
        log "ERROR" "此命令需要root权限。请使用 'sudo' 运行。"
        exit 1
    fi

    case "$action" in
        start)
            log "INFO" "命令: start"
            cleanup_resources
            create_pool
            start_api "$foreground"
            log "INFO" "🎉 服务启动完成。"
            ;;
        stop)
            log "INFO" "命令: stop"
            stop_api
            cleanup_resources
            log "INFO" "🎉 服务已停止并清理。"
            ;;
        restart)
            log "INFO" "命令: restart"
            stop_api
            cleanup_resources
            create_pool
            start_api "$foreground"
            log "INFO" "🎉 服务重启完成。"
            ;;
        status)
            show_status
            ;;
        cleanup)
            log "INFO" "命令: cleanup"
            cleanup_resources
            ;;
        start-api)
            log "INFO" "命令: start-api"
            start_api "$foreground"
            ;;
        stop-api)
            log "INFO" "命令: stop-api"
            stop_api
            ;;
        help|*)
            show_help
            ;;
    esac
}

# --- 脚本执行入口 ---
# 将所有参数传递给主函数
main "$@"