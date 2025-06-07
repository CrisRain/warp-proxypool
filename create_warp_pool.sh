#!/bin/bash
# 增强脚本健壮性：
# -e: 遇到错误立即退出
# -u: 使用未定义变量时报错
# -o pipefail: 管道中任一命令失败则整个管道失败
set -euo pipefail

# --- 配置参数 ---
POOL_SIZE=1                 # 代理池大小 (调试模式：只创建一个)
BASE_PORT=10800             # WARP实例在各自命名空间中监听的SOCKS5基础端口
MANAGER_NS="ns_manager"     # 管理器所在的命名空间
MANAGER_IP="10.255.255.254" # 管理器的IP地址
MANAGER_API_PORT=5000       # 管理器API暴露到主机的端口
MANAGER_SOCKS_PORT=10880    # 管理器中央SOCKS暴露到主机的端口

# WARP+ 许可证密钥 (可选)
WARP_LICENSE_KEY=""

# 自定义WARP端点IP和端口 (可选)
WARP_ENDPOINT=""

# --- 前置检查 ---
if ! command -v warp-cli &> /dev/null; then
    echo "错误：warp-cli 命令未找到。请确保已正确安装 Cloudflare WARP 客户端。" >&2
    exit 1
fi
echo "✅ warp-cli 命令检查通过。"

if [ "$EUID" -ne 0 ]; then
  echo "错误：请以root权限运行此脚本 (使用 sudo)。" >&2
  exit 1
fi
echo "✅ root权限检查通过。"

# --- 函数定义 ---

# 清理函数
cleanup() {
    echo "🧹 开始清理旧的网络配置 (如果存在)..."
    
    # 停止并禁用 systemd 服务 (如果存在)
    if command -v systemctl &> /dev/null; then
        if systemctl is-active --quiet warp-svc; then
            echo "   - 停止并禁用 systemd 中的 warp-svc 服务..."
            sudo systemctl stop warp-svc
            sudo systemctl disable warp-svc
            echo "   ✅ systemd warp-svc 服务已停止并禁用。"
        fi
    fi

    # 杀死所有残留的 warp-svc 和 warp-cli 进程
    echo "   - 停止所有残留的 WARP 和转发进程..."
    sudo pkill -f warp-svc || true
    sudo pkill -f warp-cli || true
    sudo pkill -f socat || true
    sleep 2 # 等待进程完全退出
    echo "   ✅ WARP 和转发进程已清理。"

    # 清理 iptables 规则
    echo "   - 清理iptables规则..."
    for i in $(seq 0 $(($POOL_SIZE-1))); do
        SUBNET="10.0.$i.0/24"
        while sudo iptables -t nat -C POSTROUTING -s $SUBNET -j MASQUERADE &> /dev/null; do
            sudo iptables -t nat -D POSTROUTING -s $SUBNET -j MASQUERADE
        done
        while sudo iptables -C FORWARD -s $SUBNET -j ACCEPT &> /dev/null; do
            sudo iptables -D FORWARD -s $SUBNET -j ACCEPT
        done
        while sudo iptables -C FORWARD -d $SUBNET -j ACCEPT &> /dev/null; do
            sudo iptables -D FORWARD -d $SUBNET -j ACCEPT
        done
    done
    echo "   ✅ 旧的iptables规则已清理。"

    # 清理网络命名空间和veth设备
    echo "   - 清理网络命名空间和veth设备..."
    for i in $(seq 0 $(($POOL_SIZE-1))); do
        if sudo ip netns list | grep -q "ns$i"; then
            if mount | grep -q "/var/lib/cloudflare-warp-ns$i"; then
                sudo umount "/var/lib/cloudflare-warp-ns$i" &> /dev/null || true
            fi
            sudo ip netns del "ns$i" &> /dev/null || true
        fi
        if ip link show "veth-warp$i" &> /dev/null; then
            sudo ip link del "veth-warp$i" &> /dev/null || true
        fi
        if [ -d "/var/lib/cloudflare-warp-ns$i" ]; then
            sudo rm -rf "/var/lib/cloudflare-warp-ns$i"
        fi
    done
    # 清理管理器命名空间
    if sudo ip netns list | grep -q "$MANAGER_NS"; then
        sudo ip netns del "$MANAGER_NS"
    fi
    if ip link show "veth-manager" &> /dev/null; then
        sudo ip link del "veth-manager" &> /dev/null || true
    fi
    echo "   ✅ 旧的网络命名空间、veth设备和WARP配置已清理。"
    
    # 清理锁文件
    rm -f /tmp/warp_pool.lock
    
    echo "✅ 旧的网络配置清理完成。"
}

# 创建函数
create_pool() {
    echo "🚀 开始启用IP转发..."
    sudo sysctl -w net.ipv4.ip_forward=1 || { echo "错误：启用IP转发失败。" >&2; exit 1; }
    echo "✅ IP转发已启用。"

    # --- 步骤1: 创建中心管理器网络命名空间 ---
    echo "-----------------------------------------------------"
    echo "🏗️  步骤1: 创建中心管理器命名空间 ($MANAGER_NS)..."
    echo "-----------------------------------------------------"
    sudo ip netns add "$MANAGER_NS"
    sudo ip netns exec "$MANAGER_NS" ip link set lo up
    sudo ip netns exec "$MANAGER_NS" mkdir -p /etc
    echo "nameserver 1.1.1.1" | sudo ip netns exec "$MANAGER_NS" tee /etc/resolv.conf > /dev/null

    # --- 步骤2: 创建独立的WARP实例并连接到管理器 ---
    echo "-----------------------------------------------------"
    echo "🚀 步骤2: 循环创建 $POOL_SIZE 个独立的WARP实例..."
    echo "-----------------------------------------------------"
    # --- 调试模式：只创建一个实例 ---
    i=0
    WARP_NS="ns$i"
    WARP_CONFIG_DIR="/var/lib/cloudflare-warp-$WARP_NS"
    VETH_WARP="veth-w$i"
    VETH_MANAGER="veth-m$i"
    WARP_IP="10.0.$i.2"
    MANAGER_GW_IP="10.0.$i.1"
    WARP_SOCKS_PORT=$((BASE_PORT + i))

    echo "✨ 正在创建 WARP 实例 $i (命名空间: $WARP_NS)..."

    # 1. 创建WARP网络命名空间
    sudo ip netns add "$WARP_NS"
    sudo ip netns exec "$WARP_NS" ip link set lo up
    sudo mkdir -p "/etc/netns/$WARP_NS"
    echo "nameserver 1.1.1.1" | sudo tee "/etc/netns/$WARP_NS/resolv.conf" > /dev/null

    # 2. 创建veth对，连接WARP命名空间和管理器命名空间
    sudo ip link add "$VETH_WARP" type veth peer name "$VETH_MANAGER"
    sudo ip link set "$VETH_WARP" netns "$WARP_NS"
    sudo ip link set "$VETH_MANAGER" netns "$MANAGER_NS"
    sudo ip netns exec "$WARP_NS" ip addr add "$WARP_IP/24" dev "$VETH_WARP"
    sudo ip netns exec "$MANAGER_NS" ip addr add "$MANAGER_GW_IP/24" dev "$VETH_MANAGER"
    sudo ip netns exec "$WARP_NS" ip link set "$VETH_WARP" up
    sudo ip netns exec "$MANAGER_NS" ip link set "$VETH_MANAGER" up
    sudo ip netns exec "$WARP_NS" ip route add default via "$MANAGER_GW_IP"

    # 3. 初始化WARP
    sudo mkdir -p "$WARP_CONFIG_DIR"
    sudo chmod 700 "$WARP_CONFIG_DIR"
    
    sudo ip netns exec "$WARP_NS" bash -c '
        set -euo pipefail

        WARP_SOCKS_PORT_TO_SET="$1"
        HOST_WARP_CONFIG_DIR="$2"

        mkdir -p /var/lib/cloudflare-warp
        mount --bind "$HOST_WARP_CONFIG_DIR" /var/lib/cloudflare-warp
        
        nohup warp-svc >/dev/null 2>&1 &
        
        echo "     - 等待 WARP daemon (warp-svc) 完全就绪..."
        _MAX_SVC_WAIT_ATTEMPTS=20
        _SVC_WAIT_COUNT=0
        until warp-cli --accept-tos status &>/dev/null; do
            _SVC_WAIT_COUNT=$(($_SVC_WAIT_COUNT + 1))
            if [ $_SVC_WAIT_COUNT -gt $_MAX_SVC_WAIT_ATTEMPTS ]; then
                echo "错误：等待WARP服务 (warp-svc) 超时。" >&2
                exit 1
            fi
            echo "       (尝试 $_SVC_WAIT_COUNT/$_MAX_SVC_WAIT_ATTEMPTS) 等待中..."
            sleep 2
        done
        echo "   ✅ WARP daemon 已就绪。"

        warp-cli --accept-tos registration new
        warp-cli --accept-tos mode proxy
        warp-cli --accept-tos proxy port "$WARP_SOCKS_PORT_TO_SET"
        warp-cli --accept-tos connect
    ' bash "$WARP_SOCKS_PORT" "$WARP_CONFIG_DIR"

    echo "✅ WARP 实例 $i 创建成功。"

    echo "====================================================="
    echo "✅✅✅ 网络环境创建完成！共 $POOL_SIZE 个WARP实例。"
    echo "✅ 管理器命名空间 ($MANAGER_NS) 已准备就绪。"
    echo "====================================================="
}

# --- 主逻辑 ---
main() {
    if [ "${1:-}" == "cleanup" ]; then
        cleanup
    else
        cleanup
        create_pool
    fi
}

# 执行主函数
main "$@"