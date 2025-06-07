#!/bin/bash
# 增强脚本健壮性
set -euo pipefail

# --- 配置参数 ---
# 这些参数需要和 create_warp_pool.sh 中保持一致，以确保能正确清理所有资源
# 您可以根据 create_warp_pool.sh 中的实际值修改它们
POOL_SIZE=3      # 代理池大小，即创建了多少个WARP实例
BASE_PORT=10800  # SOCKS5代理的基础端口号

# --- 清理函数 ---
# 这个函数被设计为可以独立运行，彻底清理由 create_warp_pool.sh 创建的所有网络资源。
cleanup() {
    echo "🧹 开始进行彻底清理，确保环境干净..."
    
    # 停止并禁用 systemd 服务 (如果存在)
    if command -v systemctl &> /dev/null; then
        if systemctl is-active --quiet warp-svc; then
            echo "   - 停止并禁用 systemd 中的 warp-svc 服务..."
            sudo systemctl stop warp-svc >/dev/null 2>&1 || true
            sudo systemctl disable warp-svc >/dev/null 2>&1 || true
            echo "   ✅ systemd warp-svc 服务已停止并禁用。"
        fi
    fi

    # 1. 优先清理网络命名空间、内部进程、veth设备和相关配置
    echo "   - 步骤1: 清理网络命名空间、内部进程、veth设备和DNS配置..."
    for i in $(seq 0 $(($POOL_SIZE-1))); do
        NS_NAME="ns$i"
        VETH_HOST="veth$i"
        
        # 检查命名空间是否存在
        if sudo ip netns list | grep -q -w "$NS_NAME"; then
            echo "     - 正在清理命名空间 $NS_NAME..."
            
            # 强制杀死命名空间内的所有进程
            echo "       - 停止 $NS_NAME 内的所有进程..."
            if pids=$(sudo ip netns pids "$NS_NAME" 2>/dev/null); then
                [ -n "$pids" ] && sudo kill -9 $pids >/dev/null 2>&1 || true
            fi
            sleep 1 # 给进程一点时间退出
            
            # 删除命名空间
            echo "       - 删除命名空间 $NS_NAME..."
            sudo ip netns del "$NS_NAME" >/dev/null 2>&1 || true
        fi
        
        # 删除veth设备
        if ip link show "$VETH_HOST" &> /dev/null; then
            echo "     - 删除 veth 设备 $VETH_HOST..."
            sudo ip link del "$VETH_HOST" >/dev/null 2>&1 || true
        fi

        # 清理DNS配置文件
        if [ -d "/etc/netns/$NS_NAME" ]; then
            echo "     - 删除DNS配置 /etc/netns/$NS_NAME..."
            sudo rm -rf "/etc/netns/$NS_NAME" >/dev/null 2>&1 || true
        fi
    done
    echo "   ✅ 网络命名空间、veth设备及相关配置已清理。"

    # 2. 清理 iptables 规则
    echo "   - 步骤2: 清理iptables规则..."
    SOCAT_LISTEN_PORT=40001 # socat 监听的端口
    for i in $(seq 0 $(($POOL_SIZE-1))); do
        HOST_PORT=$((BASE_PORT + $i))
        SUBNET_THIRD_OCTET=$i
        NAMESPACE_IP="10.0.${SUBNET_THIRD_OCTET}.2"
        SUBNET="10.0.$i.0/24"
        
        # 清理 DNAT 规则 (PREROUTING 和 OUTPUT)
        while sudo iptables -t nat -C PREROUTING -p tcp --dport $HOST_PORT -j DNAT --to-destination $NAMESPACE_IP:$SOCAT_LISTEN_PORT &> /dev/null; do
            sudo iptables -t nat -D PREROUTING -p tcp --dport $HOST_PORT -j DNAT --to-destination $NAMESPACE_IP:$SOCAT_LISTEN_PORT >/dev/null 2>&1
        done
        while sudo iptables -t nat -C OUTPUT -p tcp --dport $HOST_PORT -j DNAT --to-destination $NAMESPACE_IP:$SOCAT_LISTEN_PORT &> /dev/null; do
            sudo iptables -t nat -D OUTPUT -p tcp --dport $HOST_PORT -j DNAT --to-destination $NAMESPACE_IP:$SOCAT_LISTEN_PORT >/dev/null 2>&1
        done
        # 清理 FORWARD 规则
        while sudo iptables -C FORWARD -p tcp -d $NAMESPACE_IP --dport $SOCAT_LISTEN_PORT -j ACCEPT &> /dev/null; do
            sudo iptables -D FORWARD -p tcp -d $NAMESPACE_IP --dport $SOCAT_LISTEN_PORT -j ACCEPT >/dev/null 2>&1
        done
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
    echo "   ✅ 旧的iptables规则已清理。"

    # 3. 杀死所有可能残留的全局进程作为最后手段
    echo "   - 步骤3: 停止所有残留的 WARP 和转发进程 (全局)..."
    sudo pkill -9 -f warp-svc >/dev/null 2>&1 || true
    sudo pkill -9 -f warp-cli >/dev/null 2>&1 || true
    sudo pkill -9 -f socat >/dev/null 2>&1 || true
    sleep 1
    echo "   ✅ 全局 WARP 和转发进程已清理。"
    
    # 4. 清理锁文件
    echo "   - 步骤4: 清理锁文件..."
    rm -f /tmp/warp_pool.lock >/dev/null 2>&1 || true
    echo "   ✅ 锁文件已清理。"
    
    echo "✅ 彻底清理完成。"
}

# --- 停止代理管理器 ---
stop_proxy_manager() {
    echo "-----------------------------------------------------"
    echo "🛑 步骤1: 停止代理管理API服务 (proxy_manager.py)..."
    echo "-----------------------------------------------------"
    # 使用 pgrep 和 pkill 查找并杀死包含 "proxy_manager.py" 的进程
    # -f 标志表示匹配完整命令行
    if pgrep -f "proxy_manager.py" &> /dev/null; then
        echo "   - 发现正在运行的 proxy_manager.py 进程，正在尝试停止..."
        # 首先尝试正常停止
        pkill -f "proxy_manager.py" >/dev/null 2>&1 || true
        sleep 2
        # 如果还存在，则强制停止
        if pgrep -f "proxy_manager.py" &> /dev/null; then
            echo "   - 警告：无法通过 pkill 正常停止进程，将使用 kill -9 强制停止。"
            pkill -9 -f "proxy_manager.py" >/dev/null 2>&1 || true
        fi
        echo "   ✅ proxy_manager.py 进程已成功停止。"
    else
        echo "   ℹ️  未发现正在运行的 proxy_manager.py 进程。"
    fi
}

# --- 主逻辑 ---
main() {
    echo "🚀 开始执行代理池停止和清理脚本..."
    
    # 检查root权限，因为清理操作需要sudo
    if [ "$EUID" -ne 0 ]; then
      echo "错误：请以root权限运行此脚本 (使用 sudo)。" >&2
      exit 1
    fi
    echo "✅ root权限检查通过。"

    # 首先停止代理管理器
    stop_proxy_manager
    
    # 然后执行网络清理
    cleanup
    
    echo "====================================================="
    echo "🎉🎉🎉 代理池已成功停止并清理！🎉🎉🎉"
    echo "====================================================="
}

# 执行主函数
main "$@"