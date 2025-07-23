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
init_global_config() {
    # WARP池配置
    POOL_SIZE="${POOL_SIZE:-3}"                 # 代理池大小 (可被环境变量覆盖)
    BASE_PORT="${BASE_PORT:-10800}"             # SOCKS5代理的基础端口号 (可被环境变量覆盖)
    WARP_LICENSE_KEY="${WARP_LICENSE_KEY:-}"    # WARP+ 许可证密钥 (可被环境变量覆盖，可选)
    WARP_ENDPOINT="${WARP_ENDPOINT:-}"          # 自定义WARP端点IP和端口 (可被环境变量覆盖，可选)

    # 路径配置 (均可被环境变量覆盖)
    CONFIG_BASE_DIR="${WARP_CONFIG_BASE_DIR:-/var/lib/warp-configs}"  # WARP配置目录
    IPC_BASE_DIR="${WARP_IPC_BASE_DIR:-/run/warp-sockets}"            # WARP IPC目录
    LOG_FILE="${WARP_LOG_FILE:-/var/log/warp-pool.log}"               # 日志文件路径

    # 路径配置
    SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
    CONFIG_BASE_DIR="/var/lib/warp-configs"  # WARP配置目录
    IPC_BASE_DIR="/run/warp-sockets"         # WARP IPC目录
    LOG_FILE="/var/log/warp-pool.log"        # 日志文件路径
    LOCK_FILE="/tmp/warp_pool_$(id -u).lock" # 用户隔离的锁文件
    PID_FILE="/tmp/proxy_manager_$(id -u).pid" # 用户隔离的API服务进程ID文件
    WARP_POOL_CONFIG_FILE="${SCRIPT_DIR}/src/warp_pool_config.json" # WARP池配置文件

    # Python应用配置
    VENV_DIR="${SCRIPT_DIR}/.venv"
    REQUIREMENTS_FILE="${SCRIPT_DIR}/requirements.txt"
    PROXY_MANAGER_SCRIPT="${SCRIPT_DIR}/src/proxy_manager.py"
    PYTHON_CMD="python3"

    # iptables配置
    IPTABLES_CHAIN_PREFIX="WARP_POOL"
    IPTABLES_COMMENT_PREFIX="WARP-POOL"
    IPTABLES_CMD="iptables" # 默认为iptables，可在依赖检查中被覆盖
}

# --- SUDO权限处理 ---
init_sudo_config() {
    # 使用数组来安全地处理sudo命令和参数
    SUDO_CMD=()
    if [[ "$(id -u)" -ne 0 ]]; then
        SUDO_CMD=(sudo)
    fi
    # 为了兼容旧的日志函数等少量不需要数组的地方，保留SUDO变量
    if [[ "$(id -u)" -ne 0 ]]; then
        SUDO="sudo"
    else
        SUDO=""
    fi
}

# 初始化全局配置
init_global_config
init_sudo_config

# --- 日志功能 ---
log() {
    local level="$1"
    local message="$2"
    local timestamp
    timestamp=$(date "+%Y-%m-%d %H:%M:%S")
    
    # 格式化消息
    local log_message
    log_message=$(printf "[%s] [%s] %s" "$timestamp" "$level" "$message")

    # 输出到控制台 (stderr)
    echo "$log_message" >&2

    # 追加到日志文件 (如果路径可写)
    if [[ -n "$SUDO" ]]; then
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
    echo "              选项: --foreground  在前台运行API服务，用于Docker或调试。"
    echo "  stop        停止API服务并清理所有网络资源。"
    echo "  restart     重启服务 (相当于 stop 后再 start)。"
    echo "  status      检查服务和网络资源的状态。"
    echo "  cleanup     仅清理所有网络资源，不影响正在运行的API服务。"
    echo "  refresh-ip  刷新指定命名空间的WARP IP地址。"
    echo "              用法: refresh-ip <namespace> <index>"
    echo "  start-api   仅启动API服务 (假设网络资源已存在)。"
    echo "              选项: --foreground  在前台运行API服务。"
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
    
    # 检查是否在nftables模式下运行，如果是则使用兼容模式
    local iptables_compat_flag=""
    if [[ "$IPTABLES_CMD" == "iptables-nft" ]] || [[ "$IPTABLES_CMD" == "iptables" && -n "$(iptables -V | grep -i nft)" ]]; then
        log "INFO" "检测到nftables兼容模式，将使用兼容性规则。"
        iptables_compat_flag="--compat"
    fi
    
    # 创建自定义链，如果已存在则忽略错误
    "${SUDO_CMD[@]}" "$IPTABLES_CMD" $iptables_compat_flag -t nat -N "${IPTABLES_CHAIN_PREFIX}_PREROUTING" 2>/dev/null || true
    "${SUDO_CMD[@]}" "$IPTABLES_CMD" $iptables_compat_flag -t nat -N "${IPTABLES_CHAIN_PREFIX}_OUTPUT" 2>/dev/null || true
    "${SUDO_CMD[@]}" "$IPTABLES_CMD" $iptables_compat_flag -t nat -N "${IPTABLES_CHAIN_PREFIX}_POSTROUTING" 2>/dev/null || true
    "${SUDO_CMD[@]}" "$IPTABLES_CMD" $iptables_compat_flag -N "${IPTABLES_CHAIN_PREFIX}_FORWARD" 2>/dev/null || true

    # 添加自定义链到主链，如果已存在则忽略错误
    # 使用 -C (check) 命令检查规则是否存在，如果不存在则添加
    if ! "${SUDO_CMD[@]}" "$IPTABLES_CMD" $iptables_compat_flag -t nat -C PREROUTING -j "${IPTABLES_CHAIN_PREFIX}_PREROUTING" 2>/dev/null; then
        if ! "${SUDO_CMD[@]}" "$IPTABLES_CMD" $iptables_compat_flag -t nat -I PREROUTING 1 -j "${IPTABLES_CHAIN_PREFIX}_PREROUTING" 2>/dev/null; then
            log "ERROR" "无法将 ${IPTABLES_CHAIN_PREFIX}_PREROUTING 链添加到 PREROUTING 链。"
            return 1
        fi
    fi
    
    if ! "${SUDO_CMD[@]}" "$IPTABLES_CMD" $iptables_compat_flag -t nat -C OUTPUT -j "${IPTABLES_CHAIN_PREFIX}_OUTPUT" 2>/dev/null; then
        if ! "${SUDO_CMD[@]}" "$IPTABLES_CMD" $iptables_compat_flag -t nat -I OUTPUT 1 -j "${IPTABLES_CHAIN_PREFIX}_OUTPUT" 2>/dev/null; then
            log "ERROR" "无法将 ${IPTABLES_CHAIN_PREFIX}_OUTPUT 链添加到 OUTPUT 链。"
            return 1
        fi
    fi
    
    if ! "${SUDO_CMD[@]}" "$IPTABLES_CMD" $iptables_compat_flag -t nat -C POSTROUTING -j "${IPTABLES_CHAIN_PREFIX}_POSTROUTING" 2>/dev/null; then
        if ! "${SUDO_CMD[@]}" "$IPTABLES_CMD" $iptables_compat_flag -t nat -I POSTROUTING 1 -j "${IPTABLES_CHAIN_PREFIX}_POSTROUTING" 2>/dev/null; then
            log "ERROR" "无法将 ${IPTABLES_CHAIN_PREFIX}_POSTROUTING 链添加到 POSTROUTING 链。"
            return 1
        fi
    fi
    
    if ! "${SUDO_CMD[@]}" "$IPTABLES_CMD" $iptables_compat_flag -C FORWARD -j "${IPTABLES_CHAIN_PREFIX}_FORWARD" 2>/dev/null; then
        if ! "${SUDO_CMD[@]}" "$IPTABLES_CMD" $iptables_compat_flag -I FORWARD 1 -j "${IPTABLES_CHAIN_PREFIX}_FORWARD" 2>/dev/null; then
            log "ERROR" "无法将 ${IPTABLES_CHAIN_PREFIX}_FORWARD 链添加到 FORWARD 链。"
            return 1
        fi
    fi
    
    # 检查是否使用ufw，如果是则添加ufw兼容性规则
    if command -v ufw &> /dev/null && ufw status | grep -q "Status: active"; then
        log "INFO" "检测到ufw防火墙，添加ufw兼容性规则..."
        # 允许转发流量通过ufw
        # 注意：这需要root权限，并且可能需要用户确认
        echo "ufw allow 10800:10900/tcp comment 'WARP Proxy Pool'" | "${SUDO_CMD[@]}" bash || true
    fi
    
    log "INFO" "✅ iptables自定义链已设置。"
}

cleanup_iptables() {
    log "INFO" "🧹 清理iptables规则..."
    
    # 检查是否在nftables模式下运行，如果是则使用兼容模式
    local iptables_compat_flag=""
    if [[ "$IPTABLES_CMD" == "iptables-nft" ]] || [[ "$IPTABLES_CMD" == "iptables" && -n "$(iptables -V | grep -i nft)" ]]; then
        log "INFO" "检测到nftables兼容模式，将使用兼容性规则进行清理。"
        iptables_compat_flag="--compat"
    fi
    
    # 从主链中移除自定义链的引用
    "${SUDO_CMD[@]}" "$IPTABLES_CMD" $iptables_compat_flag -t nat -D PREROUTING -j "${IPTABLES_CHAIN_PREFIX}_PREROUTING" 2>/dev/null || true
    "${SUDO_CMD[@]}" "$IPTABLES_CMD" $iptables_compat_flag -t nat -D OUTPUT -j "${IPTABLES_CHAIN_PREFIX}_OUTPUT" 2>/dev/null || true
    "${SUDO_CMD[@]}" "$IPTABLES_CMD" $iptables_compat_flag -t nat -D POSTROUTING -j "${IPTABLES_CHAIN_PREFIX}_POSTROUTING" 2>/dev/null || true
    "${SUDO_CMD[@]}" "$IPTABLES_CMD" $iptables_compat_flag -D FORWARD -j "${IPTABLES_CHAIN_PREFIX}_FORWARD" 2>/dev/null || true
    
    # 清空并删除自定义链
    "${SUDO_CMD[@]}" "$IPTABLES_CMD" $iptables_compat_flag -t nat -F "${IPTABLES_CHAIN_PREFIX}_PREROUTING" 2>/dev/null || true
    "${SUDO_CMD[@]}" "$IPTABLES_CMD" $iptables_compat_flag -t nat -X "${IPTABLES_CHAIN_PREFIX}_PREROUTING" 2>/dev/null || true
    "${SUDO_CMD[@]}" "$IPTABLES_CMD" $iptables_compat_flag -t nat -F "${IPTABLES_CHAIN_PREFIX}_OUTPUT" 2>/dev/null || true
    "${SUDO_CMD[@]}" "$IPTABLES_CMD" $iptables_compat_flag -t nat -X "${IPTABLES_CHAIN_PREFIX}_OUTPUT" 2>/dev/null || true
    "${SUDO_CMD[@]}" "$IPTABLES_CMD" $iptables_compat_flag -t nat -F "${IPTABLES_CHAIN_PREFIX}_POSTROUTING" 2>/dev/null || true
    "${SUDO_CMD[@]}" "$IPTABLES_CMD" $iptables_compat_flag -t nat -X "${IPTABLES_CHAIN_PREFIX}_POSTROUTING" 2>/dev/null || true
    "${SUDO_CMD[@]}" "$IPTABLES_CMD" $iptables_compat_flag -F "${IPTABLES_CHAIN_PREFIX}_FORWARD" 2>/dev/null || true
    "${SUDO_CMD[@]}" "$IPTABLES_CMD" $iptables_compat_flag -X "${IPTABLES_CHAIN_PREFIX}_FORWARD" 2>/dev/null || true
    
    # 检查是否使用ufw，如果是则清理ufw规则
    if command -v ufw &> /dev/null && ufw status | grep -q "Status: active"; then
        log "INFO" "检测到ufw防火墙，清理ufw规则..."
        # 删除之前添加的ufw规则
        # 注意：这需要root权限，并且可能需要用户确认
        echo "ufw delete allow 10800:10900/tcp comment 'WARP Proxy Pool'" | "${SUDO_CMD[@]}" bash || true
    fi
    
    log "INFO" "✅ iptables规则清理完成。"
}

# --- 资源清理 ---
cleanup_resources() {
    log "INFO" "🧹 开始全面清理网络资源..."

    # 1. 清理配置文件
    log "INFO" "   - 清理 ${WARP_POOL_CONFIG_FILE}..."
    "${SUDO_CMD[@]}" rm -f "$WARP_POOL_CONFIG_FILE" 2>/dev/null || true
    log "INFO" "   ✅ 配置文件已清理。"

    # 2. 清理iptables
    cleanup_iptables

    # 3. 清理网络命名空间及相关资源
    log "INFO" "   - 清理网络命名空间、veth设备和配置文件..."
    local existing_ns
    existing_ns=$("${SUDO_CMD[@]}" ip netns list | awk '{print $1}' | grep -E '^ns[0-9]+$') || true
    
    if [[ -z "$existing_ns" ]]; then
        log "INFO" "   - 未发现需要清理的网络命名空间。"
    else
        for ns_name in $existing_ns; do
            log "INFO" "     - 正在清理命名空间 $ns_name..."
            local idx="${ns_name#ns}"
            
            # 停止并清理WARP进程PID文件
            local warp_pid_file="${CONFIG_BASE_DIR}/${ns_name}/warp.pid"
            if "${SUDO_CMD[@]}" test -f "$warp_pid_file"; then
                local warp_pid
                warp_pid=$("${SUDO_CMD[@]}" cat "$warp_pid_file")
                log "INFO" "     - 停止命名空间 $ns_name 中的WARP进程 (PID: $warp_pid)..."
                "${SUDO_CMD[@]}" kill -9 "$warp_pid" >/dev/null 2>&1 || true
                "${SUDO_CMD[@]}" rm -f "$warp_pid_file" 2>/dev/null || true
            fi

            # 卸载绑定挂载
            "${SUDO_CMD[@]}" ip netns exec "$ns_name" sh -c '
                umount /var/lib/cloudflare-warp &>/dev/null || true
                umount /run/cloudflare-warp &>/dev/null || true
            ' 2>/dev/null || true

            # 强制杀死命名空间内的所有进程
            if pids=$("${SUDO_CMD[@]}" ip netns pids "$ns_name" 2>/dev/null); then
                [[ -n "$pids" ]] && "${SUDO_CMD[@]}" kill -9 $pids >/dev/null 2>&1 || true
            fi
            sleep 0.5
            
            # 删除命名空间
            "${SUDO_CMD[@]}" ip netns del "$ns_name" >/dev/null 2>&1 || true
            
            # 删除veth设备
            local veth_host="veth$idx"
            if "${SUDO_CMD[@]}" ip link show "$veth_host" &> /dev/null; then
                "${SUDO_CMD[@]}" ip link del "$veth_host" >/dev/null 2>&1 || true
            fi
            
            # 删除相关目录
            "${SUDO_CMD[@]}" rm -rf "/etc/netns/$ns_name" "${CONFIG_BASE_DIR}/${ns_name}" "${IPC_BASE_DIR}/${ns_name}" 2>/dev/null || true
        done
        log "INFO" "   ✅ 网络命名空间清理完成。"
    fi

    # 4. 杀死残留进程
    log "INFO"   "- 停止所有残留的WARP进程..."
    "${SUDO_CMD[@]}" pkill -f warp-svc >/dev/null 2>&1 || true
    "${SUDO_CMD[@]}" pkill -f warp-cli >/dev/null 2>&1 || true
    log "INFO"   "✅ WARP进程已清理。"

    # 5. 清理锁文件
    log "INFO" "   - 清理锁文件..."
    rm -f "$LOCK_FILE" 2>/dev/null || true
    log "INFO" "   ✅ 锁文件已清理。"

    log "INFO" "✅ 全面清理完成。"
    log "INFO" "💡 提示: 为了管理日志文件大小，建议配置logrotate。"
}


# --- API 服务管理 ---
start_api() {
    log "INFO" "🐍 启动代理管理API服务..."

    # 1. 检查Python虚拟环境
    if [[ ! -d "$VENV_DIR" ]]; then
        log "INFO" "   - 创建Python虚拟环境到 ${VENV_DIR}..."
        "$PYTHON_CMD" -m venv "$VENV_DIR" || { log "ERROR" "创建Python虚拟环境失败。"; return 1; }
    fi
    
    # 2. 安装依赖
    local venv_pip="${VENV_DIR}/bin/pip"
    if [[ -f "$REQUIREMENTS_FILE" ]]; then
        log "INFO" "   - 从 ${REQUIREMENTS_FILE} 安装依赖..."
        "$venv_pip" install -r "$REQUIREMENTS_FILE" || { log "ERROR" "安装依赖失败。"; return 1; }
    else
        log "WARNING" "   - 未找到 ${REQUIREMENTS_FILE}，请确保依赖已安装。"
    fi

    # 3. 检查API是否已在运行
    if [[ -f "$PID_FILE" ]] && ps -p "$(cat "$PID_FILE")" > /dev/null; then
        log "WARNING" "API服务已在运行 (PID: $(cat "$PID_FILE"))。"
        return 0
    fi

    # 4. 启动API
    local venv_python="${VENV_DIR}/bin/python"
    export POOL_SIZE # 导出环境变量供Python脚本使用
    export BASE_PORT
    
    if [[ "$1" == true ]]; then # 前台运行
        log "INFO" "   - 在前台启动API服务..."
        # 不使用exec，以便trap可以捕获信号
        # 直接执行，使脚本在前台运行，允许trap捕获Ctrl+C
        "$venv_python" "$PROXY_MANAGER_SCRIPT"
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
    local pid
    if [[ -f "$PID_FILE" ]]; then
        pid=$(cat "$PID_FILE")
        if ps -p "$pid" > /dev/null; then
            log "INFO" "   - 正在停止主进程 (PID: $pid)..."
            kill "$pid" || true
            sleep 2
            if ps -p "$pid" > /dev/null; then
                log "WARNING" "   - 进程无法正常停止，强制杀死..."
                kill -9 "$pid" || true
            fi
        else
            log "INFO" "   - PID文件中的进程 ($pid) 未在运行。"
        fi
        rm -f "$PID_FILE"
    else
        log "INFO" "   - 未找到PID文件，将尝试通过进程名查找。"
    fi

    # 使用pkill确保所有相关子进程都被杀死
    log "INFO" "   - 确保所有API相关的Python进程都已停止..."
    pkill -f "$PROXY_MANAGER_SCRIPT" >/dev/null 2>&1 || true
    log "INFO" "   ✅ API服务已停止。"
}

# --- 核心创建逻辑 ---
check_dependencies() {
    log "INFO" "🔍 检查系统依赖..."
    local missing_deps=0
    local commands_to_check=("warp-cli" "ip" "iptables" "sysctl" "mkdir" "tee" "flock" "python3")

    for cmd in "${commands_to_check[@]}"; do
        if ! command -v "$cmd" &> /dev/null; then
            log "ERROR" "命令未找到: $cmd。请确保已安装。"
            missing_deps=1
        fi
    done

    # 检查 ip netns 支持
    if ! "${SUDO_CMD[@]}" ip netns list &>/dev/null; then
        log "ERROR" "命令 'ip netns' 不可用或执行失败。请确保您的内核支持网络命名空间。"
        missing_deps=1
    fi

    # 检查 iptables-legacy 或 nftables 兼容性
    if command -v iptables-legacy &> /dev/null; then
        log "INFO" "检测到 'iptables-legacy'，将优先使用。"
        IPTABLES_CMD="iptables-legacy"
    elif command -v iptables-nft &> /dev/null; then
        log "INFO" "检测到 'iptables-nft'，将优先使用。"
        IPTABLES_CMD="iptables-nft"
    else
        # 默认使用iptables，但在nftables系统上可能需要特殊处理
        log "INFO" "使用默认iptables命令。"
        IPTABLES_CMD="iptables"
    fi

    if [[ $missing_deps -ne 0 ]]; then
        log "ERROR" "依赖检查失败，请安装缺失的工具后重试。"
        exit 1
    fi

    log "INFO" "✅ 所有必要命令检查通过。"
}

register_warp_globally() {
    log "INFO" "🌐 检查全局WARP注册状态..."
    if "${SUDO_CMD[@]}" test -s "/var/lib/cloudflare-warp/reg.json"; then
        log "INFO" "   ✅ 全局WARP已注册。"
        return 0
    fi

    log "INFO" "   - 全局WARP未注册，开始注册..."
    "${SUDO_CMD[@]}" mkdir -p /var/lib/cloudflare-warp && "${SUDO_CMD[@]}" chmod 700 /var/lib/cloudflare-warp
    
    # 检查是否有旧的注册，如果有则删除
    if "${SUDO_CMD[@]}" test -f "/var/lib/cloudflare-warp/reg.json"; then
        log "INFO" "   - 检测到旧的注册，正在删除..."
        "${SUDO_CMD[@]}" warp-cli --accept-tos registration delete >/dev/null 2>&1 || true
        sleep 2
    fi
    
    for attempt in {1..3}; do
        if "${SUDO_CMD[@]}" warp-cli --accept-tos registration new; then
            log "INFO" "   ✅ 全局WARP注册成功！"
            "${SUDO_CMD[@]}" warp-cli --accept-tos mode warp >/dev/null 2>&1
            "${SUDO_CMD[@]}" warp-cli --accept-tos disconnect >/dev/null 2>&1
            return 0
        fi
        log "WARNING" "     - 注册失败 (第 $attempt 次)，等待3秒后重试..."
        sleep 3
    done
    log "ERROR" "   ❌ 全局WARP注册失败。"
    return 1
}

init_warp_instance() {
    local ns_name="$1"
    local idx="$2"
    local warp_internal_port="$3"
    local warp_license_key="$4"
    local warp_endpoint="$5"

    log "INFO" "     - 在 $ns_name 中初始化WARP..."
    # 将日志重定向到特定于命名空间的文件以避免交错
    local ns_log_file="${LOG_FILE}.${ns_name}"
    "${SUDO_CMD[@]}" touch "$ns_log_file"
    "${SUDO_CMD[@]}" chmod 640 "$ns_log_file"

    "${SUDO_CMD[@]}" ip netns exec "$ns_name" bash -c '
        set -euo pipefail
        # 将所有输出重定向到命名空间日志文件
        exec &> >(tee -a "$6")

        # 从父脚本继承变量
        ns_name=$1; idx=$2; warp_internal_port=$3;
        warp_license_key=$4; warp_endpoint=$5;

        echo "--- WARP 初始化开始于 $(date) ---"

        echo "INFO: 启动WARP守护进程..."
        nohup warp-svc >/dev/null 2>&1 &
        # 使用pgrep获取更可靠的PID
        warp_pid=""
        for i in {1..10}; do
            warp_pid=$(pgrep -n warp-svc)
            if [[ -n "$warp_pid" ]]; then break; fi
            echo "INFO: 等待WARP守护进程启动... ($i/10)"
            sleep 2
        done
        if [[ -z "$warp_pid" ]]; then
            echo "ERROR: 无法获取WARP守护进程的PID。"
            exit 1
        fi
        echo "$warp_pid" > /var/lib/cloudflare-warp/warp.pid
        echo "INFO: WARP守护进程已启动 (PID: $warp_pid)"
        sleep 10

        for i in {1..10}; do
            if test -S /run/cloudflare-warp/warp_service; then break; fi
            echo "INFO: 等待WARP服务就绪... ($i/10)"
            sleep 2
        done
        if ! test -S /run/cloudflare-warp/warp_service; then
            echo "ERROR: 等待WARP服务超时。"
            exit 1
        fi
        
        echo "INFO: 设置代理模式并连接..."
        # 增加重试机制
        for mode_attempt in {1..3}; do
            if warp-cli --accept-tos mode proxy; then
                echo "INFO: 成功设置代理模式 (第 $mode_attempt 次尝试)。"
                break
            else
                echo "WARNING: 设置代理模式失败 (第 $mode_attempt 次尝试)。"
                if [[ $mode_attempt -lt 3 ]]; then
                    echo "INFO: 等待3秒后重试..."
                    sleep 3
                else
                    echo "ERROR: 设置代理模式失败，已重试3次。"
                    exit 1
                fi
            fi
        done
        
        # 设置代理端口
        for port_attempt in {1..3}; do
            if warp-cli --accept-tos proxy port "$warp_internal_port"; then
                echo "INFO: 成功设置代理端口 $warp_internal_port (第 $port_attempt 次尝试)。"
                break
            else
                echo "WARNING: 设置代理端口 $warp_internal_port 失败 (第 $port_attempt 次尝试)。"
                if [[ $port_attempt -lt 3 ]]; then
                    echo "INFO: 等待3秒后重试..."
                    sleep 3
                else
                    echo "ERROR: 设置代理端口 $warp_internal_port 失败，已重试3次。"
                    exit 1
                fi
            fi
        done
        
        # 设置许可证密钥（如果提供）
        if [[ -n "$warp_license_key" ]]; then
            for license_attempt in {1..3}; do
                if warp-cli --accept-tos registration license "$warp_license_key"; then
                    echo "INFO: 成功设置许可证密钥 (第 $license_attempt 次尝试)。"
                    break
                else
                    echo "WARNING: 设置许可证密钥失败 (第 $license_attempt 次尝试)。"
                    if [[ $license_attempt -lt 3 ]]; then
                        echo "INFO: 等待3秒后重试..."
                        sleep 3
                    else
                        echo "ERROR: 设置许可证密钥失败，已重试3次。"
                        exit 1
                    fi
                fi
            done
        fi
        
        # 设置端点（如果提供）
        if [[ -n "$warp_endpoint" ]]; then
            for endpoint_attempt in {1..3}; do
                if warp-cli --accept-tos tunnel endpoint set "$warp_endpoint"; then
                    echo "INFO: 成功设置端点 $warp_endpoint (第 $endpoint_attempt 次尝试)。"
                    break
                else
                    echo "WARNING: 设置端点 $warp_endpoint 失败 (第 $endpoint_attempt 次尝试)。"
                    if [[ $endpoint_attempt -lt 3 ]]; then
                        echo "INFO: 等待3秒后重试..."
                        sleep 3
                    else
                        echo "ERROR: 设置端点 $warp_endpoint 失败，已重试3次。"
                        exit 1
                    fi
                fi
            done
        fi
        
        echo "INFO: 尝试连接WARP..."
        # 增加重试机制
        connect_success=false
        for connect_attempt in {1..3}; do
            if timeout 30s warp-cli --accept-tos connect; then
                echo "INFO: WARP连接命令执行成功 (第 $connect_attempt 次尝试)。"
                connect_success=true
                break
            else
                echo "WARNING: WARP连接命令执行失败 (第 $connect_attempt 次尝试)。"
                if [[ $connect_attempt -lt 3 ]]; then
                    echo "INFO: 等待5秒后重试..."
                    sleep 5
                fi
            fi
        done
        
        if [[ "$connect_success" != true ]]; then
            echo "ERROR: warp-cli connect 命令执行超时或失败，已重试3次。"
            exit 1
        fi

        # 增加更多的连接状态检查重试
        for i in {1..30}; do
            status_output=$(warp-cli --accept-tos status 2>/dev/null || true)
            if echo "$status_output" | grep -qE "Status: Connected|Status update: Connected"; then
                echo "INFO: WARP连接成功！"
                echo "$status_output"
                # 额外等待以确保连接稳定
                sleep 3
                exit 0
            fi
            echo "INFO: 等待WARP连接... ($i/30)"
            sleep 3
        done
        
        echo "ERROR: 连接WARP超时。"
        warp-cli --accept-tos status
        exit 1
    ' bash "$ns_name" "$idx" "$warp_internal_port" "$warp_license_key" "$warp_endpoint" "$ns_log_file" || {
        log "ERROR" "WARP实例 $ns_name 初始化失败。中止代理池创建。"
        return 1
    }
}

refresh_warp_ip() {
    local ns_name="$1"
    local idx="$2"
    
    log "INFO" "🔄 正在为命名空间 $ns_name 刷新WARP IP..."
    
    # 在指定的网络命名空间中执行WARP CLI命令来刷新IP
    if "${SUDO_CMD[@]}" ip netns exec "$ns_name" warp-cli --accept-tos disconnect >/dev/null 2>&1; then
        log "INFO" "   - 已断开 $ns_name 中的WARP连接"
    else
        log "WARNING" "   - 断开 $ns_name 中的WARP连接失败"
    fi
    
    # 等待一小段时间确保断开连接
    sleep 2
    
    # 重新连接WARP
    if "${SUDO_CMD[@]}" ip netns exec "$ns_name" warp-cli --accept-tos connect >/dev/null 2>&1; then
        log "INFO" "   - 已在 $ns_name 中重新连接WARP"
    else
        log "WARNING" "   - 在 $ns_name 中重新连接WARP失败"
        return 1
    fi
    
    # 等待连接建立
    for i in {1..15}; do
        local status_output
        status_output=$("${SUDO_CMD[@]}" ip netns exec "$ns_name" warp-cli --accept-tos status 2>/dev/null || true)
        if echo "$status_output" | grep -q "Status: Connected"; then
            log "INFO" "   ✅ $ns_name 中的WARP IP刷新成功"
            return 0
        fi
        log "INFO" "   - 等待 $ns_name 中的WARP连接... ($i/15)"
        sleep 2
    done
    
    log "ERROR" "   ❌ $ns_name 中的WARP IP刷新超时"
    return 1
}

create_pool() {
    log "INFO" "🚀 开始创建 WARP 代理池 (大小: $POOL_SIZE)..."
    
    check_dependencies
    register_warp_globally || { log "ERROR" "WARP全局注册失败，中止操作。"; return 1; }

    "${SUDO_CMD[@]}" sysctl -w net.ipv4.ip_forward=1 >/dev/null
    "${SUDO_CMD[@]}" sh -c "echo 1 > /proc/sys/net/ipv4/conf/all/route_localnet"

    setup_iptables_chains

    for i in $(seq 0 $(($POOL_SIZE-1))); do
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
        "${SUDO_CMD[@]}" ip netns add "$ns_name"
        "${SUDO_CMD[@]}" ip link add "$veth_host" type veth peer name "$veth_ns"
        "${SUDO_CMD[@]}" ip link set "$veth_ns" netns "$ns_name"
        "${SUDO_CMD[@]}" ip addr add "$gateway_ip/24" dev "$veth_host"
        "${SUDO_CMD[@]}" ip link set "$veth_host" up
        
        # 配置命名空间内部网络
        "${SUDO_CMD[@]}" ip netns exec "$ns_name" ip addr add "$namespace_ip/24" dev "$veth_ns"
        "${SUDO_CMD[@]}" ip netns exec "$ns_name" ip link set lo up
        "${SUDO_CMD[@]}" ip netns exec "$ns_name" ip link set "$veth_ns" up
        "${SUDO_CMD[@]}" ip netns exec "$ns_name" ip route add default via "$gateway_ip"

        # 绑定配置目录
        "${SUDO_CMD[@]}" mkdir -p "${CONFIG_BASE_DIR}/${ns_name}" "${IPC_BASE_DIR}/${ns_name}"
        "${SUDO_CMD[@]}" ip netns exec "$ns_name" mkdir -p /var/lib/cloudflare-warp /run/cloudflare-warp
        "${SUDO_CMD[@]}" ip netns exec "$ns_name" mount --bind "${CONFIG_BASE_DIR}/${ns_name}" /var/lib/cloudflare-warp
        "${SUDO_CMD[@]}" ip netns exec "$ns_name" mount --bind "${IPC_BASE_DIR}/${ns_name}" /run/cloudflare-warp

        # 初始化WARP
        local warp_internal_port=$((40000 + i))
        if ! init_warp_instance "$ns_name" "$i" "$warp_internal_port" "$WARP_LICENSE_KEY" "$WARP_ENDPOINT"; then
            log "ERROR" "WARP实例 $ns_name 初始化失败。中止代理池创建。"
            return 1
        fi

        # 配置iptables规则
        local host_port=$((BASE_PORT + i))
        local comment_args="-m comment --comment \"${IPTABLES_COMMENT_PREFIX}-DNAT-$host_port\""
        
        # 检查是否在nftables模式下运行，如果是则使用兼容模式
        local iptables_compat_flag=""
        if [[ "$IPTABLES_CMD" == "iptables-nft" ]] || [[ "$IPTABLES_CMD" == "iptables" && -n "$(iptables -V | grep -i nft)" ]]; then
            iptables_compat_flag="--compat"
        fi
        
        # 添加PREROUTING DNAT规则
        # 先尝试删除可能存在的旧规则，避免重复
        "${SUDO_CMD[@]}" "$IPTABLES_CMD" $iptables_compat_flag -t nat -D "${IPTABLES_CHAIN_PREFIX}_PREROUTING" -p tcp --dport "$host_port" -j DNAT --to-destination "$namespace_ip:$warp_internal_port" $comment_args 2>/dev/null || true
        # 添加新规则
        if ! "${SUDO_CMD[@]}" "$IPTABLES_CMD" $iptables_compat_flag -t nat -A "${IPTABLES_CHAIN_PREFIX}_PREROUTING" -p tcp --dport "$host_port" -j DNAT --to-destination "$namespace_ip:$warp_internal_port" $comment_args 2>/dev/null; then
            log "ERROR" "无法为实例 $i (命名空间: $ns_name) 添加PREROUTING DNAT规则。"
            return 1
        fi
        
        # 添加OUTPUT DNAT规则
        "${SUDO_CMD[@]}" "$IPTABLES_CMD" $iptables_compat_flag -t nat -D "${IPTABLES_CHAIN_PREFIX}_OUTPUT" -p tcp -d 127.0.0.1 --dport "$host_port" -j DNAT --to-destination "$namespace_ip:$warp_internal_port" $comment_args 2>/dev/null || true
        if ! "${SUDO_CMD[@]}" "$IPTABLES_CMD" $iptables_compat_flag -t nat -A "${IPTABLES_CHAIN_PREFIX}_OUTPUT" -p tcp -d 127.0.0.1 --dport "$host_port" -j DNAT --to-destination "$namespace_ip:$warp_internal_port" $comment_args 2>/dev/null; then
            log "ERROR" "无法为实例 $i (命名空间: $ns_name) 添加OUTPUT DNAT规则。"
            return 1
        fi
        
        # 添加FORWARD规则
        comment_args="-m comment --comment \"${IPTABLES_COMMENT_PREFIX}-FWD-$subnet\""
        # 允许从命名空间到外部的流量
        "${SUDO_CMD[@]}" "$IPTABLES_CMD" $iptables_compat_flag -D "${IPTABLES_CHAIN_PREFIX}_FORWARD" -s "$subnet" -j ACCEPT $comment_args 2>/dev/null || true
        if ! "${SUDO_CMD[@]}" "$IPTABLES_CMD" $iptables_compat_flag -A "${IPTABLES_CHAIN_PREFIX}_FORWARD" -s "$subnet" -j ACCEPT $comment_args 2>/dev/null; then
            log "ERROR" "无法为实例 $i (命名空间: $ns_name) 添加FORWARD (outbound) 规则。"
            return 1
        fi
        
        # 允许从外部到命名空间的流量
        "${SUDO_CMD[@]}" "$IPTABLES_CMD" $iptables_compat_flag -D "${IPTABLES_CHAIN_PREFIX}_FORWARD" -d "$subnet" -j ACCEPT $comment_args 2>/dev/null || true
        if ! "${SUDO_CMD[@]}" "$IPTABLES_CMD" $iptables_compat_flag -A "${IPTABLES_CHAIN_PREFIX}_FORWARD" -d "$subnet" -j ACCEPT $comment_args 2>/dev/null; then
            log "ERROR" "无法为实例 $i (命名空间: $ns_name) 添加FORWARD (inbound) 规则。"
            return 1
        fi
        
        # 添加POSTROUTING MASQUERADE规则
        comment_args="-m comment --comment \"${IPTABLES_COMMENT_PREFIX}-MASQ-$subnet\""
        "${SUDO_CMD[@]}" "$IPTABLES_CMD" $iptables_compat_flag -t nat -D "${IPTABLES_CHAIN_PREFIX}_POSTROUTING" -s "$subnet" -j MASQUERADE $comment_args 2>/dev/null || true
        if ! "${SUDO_CMD[@]}" "$IPTABLES_CMD" $iptables_compat_flag -t nat -A "${IPTABLES_CHAIN_PREFIX}_POSTROUTING" -s "$subnet" -j MASQUERADE $comment_args 2>/dev/null; then
            log "ERROR" "无法为实例 $i (命名空间: $ns_name) 添加POSTROUTING MASQUERADE规则。"
            return 1
        fi

        log "INFO" "✅ 实例 $i 创建成功，代理监听在 127.0.0.1:$host_port"
    done
    log "INFO" "✅✅✅ WARP 代理池创建完成！"

    # --- 生成 warp_pool_config.json ---
    log "INFO" "📝 生成 ${WARP_POOL_CONFIG_FILE}..."
    local json_content="["
    for i in $(seq 0 $(($POOL_SIZE-1))); do
        local ns_name="ns$i"
        local host_port=$((BASE_PORT + i))
        
        if [[ "$i" -gt 0 ]]; then
            json_content+=","
        fi
        
        json_content+=$(printf '{"id": %d, "namespace": "%s", "port": %d}' "$i" "$ns_name" "$host_port")
    done
    json_content+="]"
    
    echo "$json_content" > "$WARP_POOL_CONFIG_FILE"
    log "INFO" "✅ ${WARP_POOL_CONFIG_FILE} 已生成。"
}

# --- 状态检查 ---
show_status() {
    log "INFO" "📊 服务状态检查..."
    
    # 1. API 进程状态
    if [[ -f "$PID_FILE" ]] && ps -p "$(cat "$PID_FILE")" > /dev/null; then
        log "INFO" "   - API 服务: ✅ 运行中 (PID: $(cat "$PID_FILE"))"
    else
        # 尝试通过进程名检查
        if pgrep -f "$PROXY_MANAGER_SCRIPT" >/dev/null; then
            log "INFO" "   - API 服务: ✅ 运行中 (通过进程名检测)"
        else
            log "INFO" "   - API 服务: ❌ 已停止"
        fi
    fi

    # 2. 代理池实例状态
    log "INFO" "   - 代理池实例:"
    if [[ ! -f "$WARP_POOL_CONFIG_FILE" ]]; then
        log "INFO" "     - 配置文件 ${WARP_POOL_CONFIG_FILE} 未找到，无法检查实例状态。"
    else
        # 使用python解析json，更健壮
        local python_checker_code="
import json, sys, os, subprocess, socket
def check_port_connectivity(host, port, timeout=5):
    try:
        with socket.create_connection((host, port), timeout=timeout):
            return True
    except (socket.timeout, socket.error):
        return False

def check_warp_proxy_port(ns, internal_port, timeout=5):
    # 在命名空间内直接检查WARP代理端口是否监听
    try:
        result = subprocess.run(['sudo', 'ip', 'netns', 'exec', ns, 'ss', '-tlnp'],
                               capture_output=True, text=True, timeout=timeout)
        if f':{internal_port} ' in result.stdout:
            return True
    except (subprocess.TimeoutExpired, subprocess.CalledProcessError, Exception):
        pass
    return False

try:
    with open(sys.argv[1]) as f:
        proxies = json.load(f)
    for p in proxies:
        ns = p['namespace']
        port = p['port']
        # 计算对应的内部端口
        internal_port = 40000 + p['id']
        
        # 检查端口连通性
        try:
            # 增加超时时间以适应网络命名空间转发
            if check_port_connectivity('127.0.0.1', port, timeout=15):
                listen_status = '✅'
            else:
                # 如果连通性检查失败，检查命名空间内端口是否监听
                if check_warp_proxy_port(ns, internal_port, timeout=10):
                    listen_status = '✅ (命名空间内监听)'
                else:
                    listen_status = '❌'
        except Exception as e:
            # 如果出现异常，仍然检查命名空间内端口是否监听
            if check_warp_proxy_port(ns, internal_port, timeout=10):
                listen_status = '✅ (命名空间内监听)'
            else:
                listen_status = f'❌ (错误: {str(e)})'
        
        # 检查WARP连接状态
        try:
            warp_result = subprocess.run(['sudo', 'ip', 'netns', 'exec', ns, 'warp-cli', '--accept-tos', 'status'],
                                       capture_output=True, text=True, timeout=10)
            # 检查输出中是否包含Connected状态
            if 'Connected' in warp_result.stdout:
                warp_status = '✅'
            else:
                warp_status = '❌'
        except (subprocess.TimeoutExpired, subprocess.CalledProcessError, Exception) as e:
            # 记录具体的错误信息，便于调试
            print(f\"     - 实例 {p['id']} ({ns}): 检查WARP状态时出错: {e}\", file=sys.stderr)
            warp_status = '❌'
            
        print(f\"     - 实例 {p['id']} ({ns}): 代理端口 127.0.0.1:{port} [监听: {listen_status}] | WARP连接 [状态: {warp_status}]\")
except Exception as e:
    print(f'Error checking status: {e}', file=sys.stderr)
"
        "$PYTHON_CMD" -c "$python_checker_code" "$WARP_POOL_CONFIG_FILE"
    fi

    # 3. iptables 规则状态
    log "INFO" "   - iptables 规则摘要:"
    # 重新检测iptables命令以确保使用正确的命令
    local current_iptables_cmd="iptables"
    if command -v iptables-legacy &> /dev/null; then
        current_iptables_cmd="iptables-legacy"
    elif command -v iptables-nft &> /dev/null; then
        current_iptables_cmd="iptables-nft"
    fi
    
    # 检查是否在nftables模式下运行，如果是则使用兼容模式
    local iptables_compat_flag=""
    if [[ "$current_iptables_cmd" == "iptables-nft" ]] || [[ "$current_iptables_cmd" == "iptables" && -n "$(iptables -V | grep -i nft)" ]]; then
        iptables_compat_flag="--compat"
    fi
    
    # 检查自定义链是否存在
    local chains_exist=true
    if ! "${SUDO_CMD[@]}" "$current_iptables_cmd" $iptables_compat_flag -t nat -L "${IPTABLES_CHAIN_PREFIX}_PREROUTING" -n >/dev/null 2>&1; then
        log "WARNING" "     自定义链 ${IPTABLES_CHAIN_PREFIX}_PREROUTING 不存在。"
        chains_exist=false
    fi
    
    if ! "${SUDO_CMD[@]}" "$current_iptables_cmd" $iptables_compat_flag -L "${IPTABLES_CHAIN_PREFIX}_FORWARD" -n >/dev/null 2>&1; then
        log "WARNING" "     自定义链 ${IPTABLES_CHAIN_PREFIX}_FORWARD 不存在。"
        chains_exist=false
    fi
    
    # 如果链存在，则获取并显示规则
    if [[ "$chains_exist" == true ]]; then
        # 获取并显示PREROUTING链中的DNAT规则
        local prerouting_rules
        prerouting_rules=$("${SUDO_CMD[@]}" "$current_iptables_cmd" $iptables_compat_flag -t nat -L "${IPTABLES_CHAIN_PREFIX}_PREROUTING" -n -v --line-numbers 2>/dev/null | grep "DNAT" | sed 's/^/     /' || true)
        if [[ -n "$prerouting_rules" ]]; then
            echo "$prerouting_rules"
        else
            log "WARNING" "     PREROUTING链中未找到DNAT规则。"
        fi
        
        # 获取并显示FORWARD链中的ACCEPT规则
        local forward_rules
        forward_rules=$("${SUDO_CMD[@]}" "$current_iptables_cmd" $iptables_compat_flag -L "${IPTABLES_CHAIN_PREFIX}_FORWARD" -n -v --line-numbers 2>/dev/null | grep "ACCEPT" | sed 's/^/     /' || true)
        if [[ -n "$forward_rules" ]]; then
            echo "$forward_rules"
        else
            log "WARNING" "     FORWARD链中未找到ACCEPT规则。"
        fi
    else
        log "WARNING" "     由于自定义链不存在，跳过规则详细检查。"
    fi
}


# --- 主逻辑 ---
main() {
    # --- 全局清理陷阱 ---
    # 捕获SIGINT (Ctrl+C) 和 SIGTERM 信号，确保脚本中断时能清理资源
    trap '
        echo
        log "WARNING" "接收到中断信号，开始执行清理..."
        stop_api
        cleanup_resources
        log "WARNING" "清理完成，脚本退出。"
        exit 130
    ' SIGINT SIGTERM

    # 确保日志文件和目录存在且权限正确
    "${SUDO_CMD[@]}" mkdir -p "$(dirname "$LOG_FILE")"
    "${SUDO_CMD[@]}" touch "$LOG_FILE"
    "${SUDO_CMD[@]}" chmod 640 "$LOG_FILE"

    # 启动sudo会话保持
    if [[ -n "$SUDO" ]]; then
        log "INFO" "启动sudo会话保持进程..."
        # 检查是否可以无密码sudo
        if "${SUDO_CMD[@]}" -n true 2>/dev/null; then
            while true; do "${SUDO_CMD[@]}" -n true; sleep 60; kill -0 "$$" || exit; done &>/dev/null &
            SUDO_KEEPALIVE_PID=$!
            trap '"${SUDO_CMD[@]}" kill "$SUDO_KEEPALIVE_PID" &>/dev/null' EXIT
        fi
    fi

    local action="${1:-help}"
    local foreground=false
    if [[ "${2:-}" == "--foreground" ]]; then
        foreground=true
    fi

    # 检查root权限，但允许status和help命令
    if [[ "$action" != "status" && "$action" != "help" && "$EUID" -ne 0 ]]; then
        log "ERROR" "此命令需要root权限。请使用 'sudo' 运行。"
        exit 1
    fi

    case "$action" in
        start)
            (
                flock -xn 200 || { log "ERROR" "脚本已在运行，请勿重复执行。"; exit 1; }
                log "INFO" "命令: start"
                cleanup_resources
                create_pool
                start_api "$foreground"
                log "INFO" "🎉 服务启动完成。"
            ) 200>"$LOCK_FILE"
            ;;
        refresh-ip)
            # 刷新指定命名空间的WARP IP
            local ns_name="$2"
            local idx="$3"
            if [[ -z "$ns_name" || -z "$idx" ]]; then
                log "ERROR" "refresh-ip 命令需要命名空间名称和索引参数。"
                exit 1
            fi
            log "INFO" "命令: refresh-ip $ns_name $idx"
            refresh_warp_ip "$ns_name" "$idx"
            ;;
        stop)
            (
                flock -xn 200 || { log "ERROR" "脚本已在运行，请勿重复执行。"; exit 1; }
                log "INFO" "命令: stop"
                stop_api
                cleanup_resources
                log "INFO" "🎉 服务已停止并清理。"
            ) 200>"$LOCK_FILE"
            ;;
        restart)
            (
                flock -xn 200 || { log "ERROR" "脚本已在运行，请勿重复执行。"; exit 1; }
                log "INFO" "命令: restart"
                stop_api
                cleanup_resources
                create_pool
                start_api "$foreground"
                log "INFO" "🎉 服务重启完成。"
            ) 200>"$LOCK_FILE"
            ;;
        status)
            show_status
            ;;
        cleanup)
            (
                flock -xn 200 || { log "ERROR" "脚本已在运行，请勿重复执行。"; exit 1; }
                log "INFO" "命令: cleanup"
                cleanup_resources
            ) 200>"$LOCK_FILE"
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