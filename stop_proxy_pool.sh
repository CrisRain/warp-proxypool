#!/bin/bash
# 增强脚本健壮性
set -euo pipefail

# --- 配置参数 ---
# 这些参数需要和 create_warp_pool.sh 中保持一致，以确保能正确清理所有资源
# 您可以根据 create_warp_pool.sh 中的实际值修改它们
POOL_SIZE=3      # 代理池大小，即创建了多少个WARP实例
BASE_PORT=10800  # SOCKS5代理的基础端口号
# 与create_warp_pool.sh保持一致
WARP_CONFIG_BASE_DIR="/var/lib/warp-configs"
WARP_IPC_BASE_DIR="/run/warp-sockets"


# --- 清理函数 ---
# 这个函数被设计为可以独立运行，彻底清理由 create_warp_pool.sh 创建的所有网络资源。
cleanup() {
    printf "🧹 开始进行彻底清理，确保环境干净...\n"
    
    # 停止并禁用 systemd 服务 (如果存在)
    if command -v systemctl &> /dev/null; then
        if systemctl is-active --quiet warp-svc; then
            printf "   - 停止并禁用 systemd 中的 warp-svc 服务...\n"
            sudo systemctl stop warp-svc >/dev/null 2>&1 || true
            sudo systemctl disable warp-svc >/dev/null 2>&1 || true
            printf "   ✅ systemd warp-svc 服务已停止并禁用。\n"
        fi
    fi

    # 1. 优先清理网络命名空间、挂载点、内部进程、veth设备和相关配置
    printf "   - 步骤1: 清理网络命名空间、挂载点、内部进程、veth设备和DNS配置...\n"
    for i in $(seq 0 $(($POOL_SIZE-1))); do
        NS_NAME="ns$i"
        VETH_HOST="veth$i"
        INSTANCE_CONFIG_DIR="${WARP_CONFIG_BASE_DIR}/${NS_NAME}"
        INSTANCE_IPC_DIR="${WARP_IPC_BASE_DIR}/${NS_NAME}"
        WARP_SYSTEM_CONFIG_DIR="/var/lib/cloudflare-warp"
        WARP_SYSTEM_IPC_DIR="/run/cloudflare-warp"

        # 检查命名空间是否存在
        if sudo ip netns list | grep -q -w "$NS_NAME"; then
            printf "     - 正在清理命名空间 %s...\n" "$NS_NAME"
            
            # 卸载绑定挂载
            printf "       - 尝试卸载 %s 内的绑定挂载...\n" "$NS_NAME"
            if sudo ip netns exec "$NS_NAME" mount | grep -q "on ${WARP_SYSTEM_CONFIG_DIR} type"; then
                sudo ip netns exec "$NS_NAME" umount "$WARP_SYSTEM_CONFIG_DIR" >/dev/null 2>&1 || true
            fi
            if sudo ip netns exec "$NS_NAME" mount | grep -q "on ${WARP_SYSTEM_IPC_DIR} type"; then
                sudo ip netns exec "$NS_NAME" umount "$WARP_SYSTEM_IPC_DIR" >/dev/null 2>&1 || true
            fi
            
            # 强制杀死命名空间内的所有进程
            printf "       - 停止 %s 内的所有进程...\n" "$NS_NAME"
            if pids=$(sudo ip netns pids "$NS_NAME" 2>/dev/null); then
                [ -n "$pids" ] && sudo kill -9 $pids >/dev/null 2>&1 || true
            fi
            sleep 1 # 给进程一点时间退出
            
            # 删除命名空间
            printf "       - 删除命名空间 %s...\n" "$NS_NAME"
            sudo ip netns del "$NS_NAME" >/dev/null 2>&1 || true
        fi
        
        # 删除veth设备
        if ip link show "$VETH_HOST" &> /dev/null; then
            printf "     - 删除 veth 设备 %s...\n" "$VETH_HOST"
            sudo ip link del "$VETH_HOST" >/dev/null 2>&1 || true
        fi

        # 清理DNS配置文件
        if [ -d "/etc/netns/$NS_NAME" ]; then
            printf "     - 删除DNS配置 /etc/netns/%s...\n" "$NS_NAME"
            sudo rm -rf "/etc/netns/$NS_NAME" >/dev/null 2>&1 || true
        fi

        # 清理独立的WARP配置目录
        if [ -d "$INSTANCE_CONFIG_DIR" ]; then
            printf "     - 删除独立的WARP配置目录 %s...\n" "$INSTANCE_CONFIG_DIR"
            sudo rm -rf "$INSTANCE_CONFIG_DIR" >/dev/null 2>&1 || true
        fi
        # 清理独立的WARP IPC目录
        if [ -d "$INSTANCE_IPC_DIR" ]; then
            printf "     - 删除独立的WARP IPC目录 %s...\n" "$INSTANCE_IPC_DIR"
            sudo rm -rf "$INSTANCE_IPC_DIR" >/dev/null 2>&1 || true
        fi
    done
    printf "   ✅ 网络命名空间、veth设备及相关配置已清理。\n"

    # 2. 清理 iptables 规则
    printf "   - 步骤2: 清理iptables规则...\n"
    for i in $(seq 0 $(($POOL_SIZE-1))); do
        HOST_PORT=$((BASE_PORT + $i))
        # 使用与 create_warp_pool.sh 中一致的子网计算逻辑
        SUBNET_THIRD_OCTET=$((i / 256))
        SUBNET_FOURTH_OCTET=$((i % 256))
        NAMESPACE_IP="10.${SUBNET_THIRD_OCTET}.${SUBNET_FOURTH_OCTET}.2"
        SUBNET="10.${SUBNET_THIRD_OCTET}.${SUBNET_FOURTH_OCTET}.0/24"
        WARP_INTERNAL_PORT=$((40000 + i))

        # 清理 DNAT 规则 (PREROUTING 和 OUTPUT)，现在直接指向 WARP 内部端口
        while sudo iptables -t nat -C PREROUTING -p tcp --dport $HOST_PORT -j DNAT --to-destination $NAMESPACE_IP:$WARP_INTERNAL_PORT &> /dev/null; do
            sudo iptables -t nat -D PREROUTING -p tcp --dport $HOST_PORT -j DNAT --to-destination $NAMESPACE_IP:$WARP_INTERNAL_PORT >/dev/null 2>&1
        done
        while sudo iptables -t nat -C OUTPUT -p tcp -d 127.0.0.1 --dport $HOST_PORT -j DNAT --to-destination $NAMESPACE_IP:$WARP_INTERNAL_PORT &> /dev/null; do
            sudo iptables -t nat -D OUTPUT -p tcp -d 127.0.0.1 --dport $HOST_PORT -j DNAT --to-destination $NAMESPACE_IP:$WARP_INTERNAL_PORT >/dev/null 2>&1
        done
        # 不再需要针对 socat 端口的特定 FORWARD 规则
        # 清理通用的 MASQUERADE 和 FORWARD 规则
        while sudo iptables -t nat -C POSTROUTING -s $SUBNET -j MASQUERADE &> /dev/null; do
            sudo iptables -t nat -D POSTROUTING -s $SUBNET -j MASQUERADE >/dev/null 2>&1
        done
        while sudo iptables -C FORWARD -s $SUBNET -j ACCEPT &> /dev/null; do
            sudo iptables -D FORWARD -s $SUBNET -j ACCEPT >/dev/null 2>&1
        done
        while sudo iptables -C FORWARD -d $SUBNET -j ACCEPT &> /dev/null; do
            sudo iptables -D FORWARD -d $SUBNET -j ACCEPT >/dev/null 2>&1
        done
    done
    printf "   ✅ 旧的iptables规则已清理。\n"

    # 3. 杀死所有可能残留的全局进程作为最后手段
    printf "   - 步骤3: 停止所有残留的 WARP 和转发进程 (全局)...\n"
    sudo pkill -9 -f warp-svc >/dev/null 2>&1 || true
    sudo pkill -9 -f warp-cli >/dev/null 2>&1 || true
    # socat 已被移除，无需再杀死其进程
    sleep 1
    printf "   ✅ 全局 WARP 和转发进程已清理。\n"
    
    # 4. 清理锁文件
    printf "   - 步骤4: 清理锁文件...\n"
    rm -f /tmp/warp_pool.lock >/dev/null 2>&1 || true
    printf "   ✅ 锁文件已清理。\n"
    
    printf "✅ 彻底清理完成。\n"
}

# --- 停止代理管理器 ---
stop_proxy_manager() {
    printf -- "-----------------------------------------------------\n"
    printf "🛑 步骤1: 停止代理管理API服务 (proxy_manager.py)...\n"
    printf -- "-----------------------------------------------------\n"
    # 使用 pgrep 和 pkill 查找并杀死包含 "proxy_manager.py" 的进程
    # -f 标志表示匹配完整命令行
    if pgrep -f "proxy_manager.py" &> /dev/null; then
        printf "   - 发现正在运行的 proxy_manager.py 进程，正在尝试停止...\n"
        # 首先尝试正常停止
        pkill -f "proxy_manager.py" >/dev/null 2>&1 || true
        sleep 2
        # 如果还存在，则强制停止
        if pgrep -f "proxy_manager.py" &> /dev/null; then
            printf "   - 警告：无法通过 pkill 正常停止进程，将使用 kill -9 强制停止。\n"
            pkill -9 -f "proxy_manager.py" >/dev/null 2>&1 || true
        fi
        printf "   ✅ proxy_manager.py 进程已成功停止。\n"
    else
        printf "   ℹ️  未发现正在运行的 proxy_manager.py 进程。\n"
    fi
}

# --- 主逻辑 ---
main() {
    printf "🚀 开始执行代理池停止和清理脚本...\n"
    
    # 检查root权限，因为清理操作需要sudo
    if [ "$EUID" -ne 0 ]; then
      printf "错误：请以root权限运行此脚本 (使用 sudo)。\n" >&2
      exit 1
    fi
    printf "✅ root权限检查通过。\n"

    # 检查无密码sudo权限并启动一个后台进程来保持sudo会话活跃
    if sudo -n true 2>/dev/null; then
        printf "✅ 无密码sudo权限检查通过，启动sudo会话保持进程。\n"
        # 在后台循环中运行 `sudo -v` 来刷新sudo时间戳
        while true; do sudo -n true; sleep 60; kill -0 "$$" || exit; done &>/dev/null &
        SUDO_KEEPALIVE_PID=$!
        # 设置一个陷阱，在脚本退出时杀死后台进程
        trap "kill $SUDO_KEEPALIVE_PID &>/dev/null" EXIT
    else
        printf "警告：无法获取无密码sudo权限。脚本执行期间可能需要您输入密码。\n" >&2
    fi

    # 首先停止代理管理器
    stop_proxy_manager
    
    # 然后执行网络清理
    cleanup
    
    printf -- "=====================================================\n"
    printf "🎉🎉🎉 代理池已成功停止并清理！🎉🎉🎉\n"
    printf -- "=====================================================\n"
}

# 执行主函数
main "$@"