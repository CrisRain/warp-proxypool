#!/bin/bash
# 增强脚本健壮性：
# -e: 遇到错误立即退出
# -u: 使用未定义变量时报错
# -o pipefail: 管道中任一命令失败则整个管道失败
set -euo pipefail

# --- 配置参数 ---
POOL_SIZE=5      # 代理池大小，即创建多少个WARP实例
BASE_PORT=10800  # SOCKS5代理的基础端口号，每个WARP实例的SOCKS5端口将在此基础上递增

# WARP+ 许可证密钥 (可选, 如果你有的话)
# 获取方法: 手机上使用1.1.1.1 App，菜单 -> 账户 -> 按键
WARP_LICENSE_KEY=""

# 自定义WARP端点IP和端口 (可选, 例如: 162.159.192.1:2408)
# 可以从这里找到优选IP: https://stock.hostmonit.com/CloudFlareYes
WARP_ENDPOINT=""

# --- 前置检查 ---
# 检查 warp-cli 命令是否存在
if ! command -v warp-cli &> /dev/null; then
    echo "错误：warp-cli 命令未找到。请确保已正确安装 Cloudflare WARP 客户端。" >&2
    exit 1
fi
echo "✅ warp-cli 命令检查通过。"

# 检查是否以root权限运行
if [ "$EUID" -ne 0 ]; then
  echo "错误：请以root权限运行此脚本 (使用 sudo)。" >&2
  exit 1
fi
echo "✅ root权限检查通过。"

# --- 函数定义 ---

# 清理函数：用于删除所有由本脚本创建的网络资源
cleanup() {
    echo "🧹 开始清理旧的网络配置 (如果存在)..."

    # --- 清理iptables规则 ---
    echo "   - 清理iptables规则..."
    # 清理 MASQUERADE 规则
    while sudo iptables -t nat -C POSTROUTING -s 10.0.0.0/24 -j MASQUERADE &> /dev/null; do
        sudo iptables -t nat -D POSTROUTING -s 10.0.0.0/24 -j MASQUERADE
    done
    # 清理每个实例的 DNAT 和 FORWARD 规则
    SOCKS_PORT_IN_NAMESPACE=40000
    for i in $(seq 0 $(($POOL_SIZE-1))); do
        HOST_PORT=$((BASE_PORT + $i))
        NAMESPACE_IP="10.0.0.$((i+2))"
        while sudo iptables -t nat -C PREROUTING -p tcp --dport $HOST_PORT -j DNAT --to-destination $NAMESPACE_IP:$SOCKS_PORT_IN_NAMESPACE &> /dev/null; do
            sudo iptables -t nat -D PREROUTING -p tcp --dport $HOST_PORT -j DNAT --to-destination $NAMESPACE_IP:$SOCKS_PORT_IN_NAMESPACE
        done
        while sudo iptables -C FORWARD -p tcp -d $NAMESPACE_IP --dport $SOCKS_PORT_IN_NAMESPACE -j ACCEPT &> /dev/null; do
            sudo iptables -D FORWARD -p tcp -d $NAMESPACE_IP --dport $SOCKS_PORT_IN_NAMESPACE -j ACCEPT
        done
    done
    echo "   ✅ 旧的iptables规则已清理。"

    # --- 清理网络命名空间和veth设备 ---
    echo "   - 清理网络命名空间和veth设备..."
    for i in $(seq 0 $(($POOL_SIZE-1))); do
        if sudo ip netns list | grep -q "ns$i"; then
            sudo ip netns del ns$i &> /dev/null || true
        fi
        if ip link show veth$i &> /dev/null; then
            sudo ip link del veth$i &> /dev/null || true
        fi
    done
    echo "   ✅ 旧的网络命名空间和veth设备已清理。"
    
    # --- 杀死所有warp-svc进程 ---
    # 注意：这会杀死系统上所有的warp-svc进程，在多用户环境下需谨慎
    echo "   - 停止所有残留的warp-svc进程..."
    sudo pkill -f warp-svc || true
    echo "   ✅ warp-svc进程已清理。"

    echo "✅ 旧的网络配置清理完成。"
}

# 创建函数：用于创建整个代理池
create_pool() {
    # 启用IP转发
    echo "🚀 开始启用IP转发..."
    sudo sysctl -w net.ipv4.ip_forward=1 || { echo "错误：启用IP转发失败。" >&2; exit 1; }
    echo "✅ IP转发已启用。"

    echo "🚀 开始创建 WARP 代理池..."
    # 循环创建代理池中的每个WARP实例
    for i in $(seq 0 $(($POOL_SIZE-1))); do
        echo "-----------------------------------------------------"
        echo "✨ 正在创建 WARP 实例 $i (端口: $((BASE_PORT + $i)))..."
        echo "-----------------------------------------------------"

        # 1. 创建网络命名空间
        echo "   - 步骤1/8: 创建网络命名空间 ns$i..."
        sudo ip netns add ns$i || { echo "错误：创建网络命名空间 ns$i 失败。" >&2; exit 1; }
        echo "   ✅ 网络命名空间 ns$i 创建成功。"

        # 1.5. 为命名空间配置DNS解析
        sudo mkdir -p "/etc/netns/ns$i"
        echo "nameserver 8.8.8.8" | sudo tee "/etc/netns/ns$i/resolv.conf" > /dev/null
        echo "   ✅ 为 ns$i 配置了DNS (8.8.8.8)。"

        # 2. 创建虚拟以太网设备对
        echo "   - 步骤2/8: 创建虚拟以太网设备 veth$i <--> veth${i}-ns..."
        sudo ip link add veth$i type veth peer name veth${i}-ns || { echo "错误：创建虚拟以太网设备对失败。" >&2; exit 1; }
        echo "   ✅ 虚拟以太网设备对创建成功。"

        # 3. 配置虚拟以太网设备
        echo "   - 步骤3/8: 配置虚拟以太网设备..."
        sudo ip link set veth${i}-ns netns ns$i || { echo "错误：将 veth${i}-ns 移入 ns$i 失败。" >&2; exit 1; }
        NAMESPACE_IP="10.0.0.$((i+2))"
        sudo ip netns exec ns$i ip addr add $NAMESPACE_IP/24 dev veth${i}-ns || { echo "错误：为 veth${i}-ns@ns$i 分配IP地址失败。" >&2; exit 1; }
        sudo ip addr add 10.0.0.1/24 dev veth$i || { echo "错误：为 veth$i 分配IP地址失败。" >&2; exit 1; }
        echo "   ✅ 虚拟以太网设备配置成功。"

        # 4. 启动虚拟以太网设备
        echo "   - 步骤4/8: 启动虚拟以太网设备..."
        sudo ip link set veth$i up || { echo "错误：启动 veth$i 失败。" >&2; exit 1; }
        sudo ip netns exec ns$i ip link set veth${i}-ns up || { echo "错误：启动 veth${i}-ns@ns$i 失败。" >&2; exit 1; }
        echo "   ✅ 虚拟以太网设备已启动。"

        # 5. 设置命名空间内的默认路由
        echo "   - 步骤5/8: 设置 ns$i 内的默认路由..."
        sudo ip netns exec ns$i ip route add default via 10.0.0.1 || { echo "错误：在 ns$i 中设置默认路由失败。" >&2; exit 1; }
        echo "   ✅ ns$i 默认路由设置成功。"

        # 6. 配置NAT
        echo "   - 步骤6/8: 配置NAT规则 (MASQUERADE)..."
        if ! sudo iptables -t nat -C POSTROUTING -s 10.0.0.0/24 -j MASQUERADE &> /dev/null; then
            sudo iptables -t nat -A POSTROUTING -s 10.0.0.0/24 -j MASQUERADE || { echo "错误：配置NAT规则失败。" >&2; exit 1; }
            echo "   ✅ NAT (MASQUERADE) 规则已添加。"
        else
            echo "   ℹ️  NAT (MASQUERADE) 规则已存在。"
        fi

        # 7. 初始化WARP
        SOCKS_PORT_IN_NAMESPACE=40000
        echo "   - 步骤7/8: 在 ns$i 中初始化WARP..."
        echo "     - 启动WARP服务守护进程..."
        sudo ip netns exec ns$i warp-svc &
        sleep 2

        echo "     - 注册WARP并接受服务条款 (TOS)..."
        sudo ip netns exec ns$i warp-cli --accept-tos registration new || true
        
        echo "     - 等待WARP服务完全就绪..."
        MAX_SVC_WAIT_ATTEMPTS=15
        SVC_WAIT_COUNT=0
        SVC_READY=false
        while [ $SVC_WAIT_COUNT -lt $MAX_SVC_WAIT_ATTEMPTS ]; do
            if sudo ip netns exec ns$i test -S /run/cloudflare-warp/warp_service; then
                echo "       WARP服务IPC Socket已就绪。"
                SVC_READY=true
                break
            fi
            echo "       等待中... (尝试 $((SVC_WAIT_COUNT+1))/$MAX_SVC_WAIT_ATTEMPTS)"
            sleep 2
            SVC_WAIT_COUNT=$((SVC_WAIT_COUNT+1))
        done

        if [ "$SVC_READY" = false ]; then
            echo "错误：等待WARP服务 (warp-svc) 超时。" >&2
            sudo ip netns exec ns$i ps aux | grep warp || true
            exit 1
        fi

        echo "     - 设置WARP为SOCKS5代理模式..."
        sudo ip netns exec ns$i warp-cli --accept-tos mode proxy || { echo "错误：设置WARP代理模式失败。" >&2; exit 1; }
        sudo ip netns exec ns$i warp-cli --accept-tos proxy set-port $SOCKS_PORT_IN_NAMESPACE || { echo "错误：设置SOCKS5端口失败。" >&2; exit 1; }
        
        if [ -n "$WARP_LICENSE_KEY" ]; then
            echo "     - 尝试使用许可证密钥升级到WARP+..."
            sudo ip netns exec ns$i warp-cli --accept-tos registration license "$WARP_LICENSE_KEY" || echo "警告：许可证密钥设置失败。"
        fi

        if [ -n "$WARP_ENDPOINT" ]; then
            echo "     - 设置自定义WARP端点: $WARP_ENDPOINT..."
            sudo ip netns exec ns$i warp-cli --accept-tos tunnel endpoint reset || echo "警告：重置端点失败。"
            sudo ip netns exec ns$i warp-cli --accept-tos tunnel endpoint set "$WARP_ENDPOINT" || echo "警告：设置自定义端点失败。"
        fi

        echo "     - 连接WARP..."
        sudo ip netns exec ns$i warp-cli --accept-tos connect || { echo "错误：连接WARP失败。" >&2; exit 1; }
        
        if ! sudo ip netns exec ns$i warp-cli --accept-tos status | grep -q "Status: Connected"; then
            echo "错误：连接WARP后状态检查失败。" >&2
            sudo ip netns exec ns$i warp-cli --accept-tos status >&2
            exit 1
        fi
        echo "   ✅ WARP在 ns$i 中已成功初始化并连接。"

        # 8. 创建端口映射
        HOST_PORT=$((BASE_PORT + $i))
        echo "   - 步骤8/8: 创建端口映射 主机端口 $HOST_PORT -> $NAMESPACE_IP:$SOCKS_PORT_IN_NAMESPACE..."
        if ! sudo iptables -t nat -C PREROUTING -p tcp --dport $HOST_PORT -j DNAT --to-destination $NAMESPACE_IP:$SOCKS_PORT_IN_NAMESPACE &> /dev/null; then
            sudo iptables -t nat -A PREROUTING -p tcp --dport $HOST_PORT -j DNAT --to-destination $NAMESPACE_IP:$SOCKS_PORT_IN_NAMESPACE || { echo "错误：创建DNAT规则失败。" >&2; exit 1; }
        fi
        if ! sudo iptables -C FORWARD -p tcp -d $NAMESPACE_IP --dport $SOCKS_PORT_IN_NAMESPACE -j ACCEPT &> /dev/null; then
            sudo iptables -A FORWARD -p tcp -d $NAMESPACE_IP --dport $SOCKS_PORT_IN_NAMESPACE -j ACCEPT || { echo "错误：创建FORWARD规则失败。" >&2; exit 1; }
        fi
        echo "   ✅ 端口映射创建成功。"

        echo "🎉 WARP 实例 $i 创建成功，SOCKS5代理监听在主机端口: $HOST_PORT"
    done

    echo "====================================================="
    echo "✅✅✅ WARP 代理池创建完成！共 $POOL_SIZE 个实例。"
    echo "每个实例的SOCKS5代理端口从 $BASE_PORT 开始递增。"
    echo "====================================================="
}

# --- 主逻辑 ---
main() {
    if [ "${1:-}" == "cleanup" ]; then
        cleanup
    else
        # 默认行为：先清理，再创建
        cleanup
        create_pool
    fi
}

# 执行主函数，并传递所有脚本参数
main "$@"