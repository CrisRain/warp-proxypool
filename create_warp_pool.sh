#!/bin/bash
# 增强脚本健壮性：
# -e: 遇到错误立即退出
# -u: 使用未定义变量时报错
# -o pipefail: 管道中任一命令失败则整个管道失败
set -euo pipefail

# --- 配置参数 ---
POOL_SIZE=5      # 代理池大小，即创建多少个WARP实例
BASE_PORT=10800  # SOCKS5代理的基础端口号，每个WARP实例的SOCKS5端口将在此基础上递增

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

# --- 脚本核心逻辑 ---

# 启用IP转发，允许数据包在不同网络接口间传递
echo "🚀 开始启用IP转发..."
sudo sysctl -w net.ipv4.ip_forward=1 || { echo "错误：启用IP转发失败。" >&2; exit 1; }
echo "✅ IP转发已启用。"

# 清理可能存在的旧规则和命名空间 (可选，但推荐用于幂等性)
echo "🧹 开始清理旧的网络配置 (如果存在)..."
for i in $(seq 0 $(($POOL_SIZE-1))); do
    # 删除可能存在的旧网络命名空间
    if sudo ip netns list | grep -q "ns$i"; then
        echo "   - 删除旧的网络命名空间 ns$i..."
        sudo ip netns del ns$i || echo "警告：删除网络命名空间 ns$i 失败，可能它不存在或已被使用。"
    fi
    # 删除可能存在的旧veth设备
    if ip link show veth$i &> /dev/null; then
        echo "   - 删除旧的虚拟以太网设备 veth$i..."
        sudo ip link del veth$i || echo "警告：删除虚拟以太网设备 veth$i 失败。"
    fi
done
# 清理iptables规则是一个更复杂的操作，这里暂时简化，仅提示
# 注意：更完善的清理需要精确匹配并删除之前添加的iptables规则，避免影响其他服务。
# 例如：sudo iptables -t nat -D POSTROUTING -s 10.0.0.0/24 -j MASQUERADE (需要多次执行直到删除所有匹配规则)
# sudo iptables -t nat -F PREROUTING (会清空整个链，需谨慎)
# sudo iptables -F FORWARD (会清空整个链，需谨慎)
echo "ℹ️  旧的网络命名空间和veth设备清理尝试完成。iptables规则清理请根据实际情况手动操作或完善脚本。"


echo "🚀 开始创建 WARP 代理池..."
# 循环创建代理池中的每个WARP实例
for i in $(seq 0 $(($POOL_SIZE-1))); do
    echo "-----------------------------------------------------"
    echo "✨ 正在创建 WARP 实例 $i (端口: $((BASE_PORT + $i)))..."
    echo "-----------------------------------------------------"

    # 1. 创建网络命名空间
    echo "   - 步骤1/7: 创建网络命名空间 ns$i..."
    sudo ip netns add ns$i || { echo "错误：创建网络命名空间 ns$i 失败。" >&2; exit 1; }
    echo "   ✅ 网络命名空间 ns$i 创建成功。"

    # 2. 创建虚拟以太网设备对 (veth pair)
    # veth$i 在主命名空间, veth${i}-ns 在 ns$i 命名空间
    echo "   - 步骤2/7: 创建虚拟以太网设备 veth$i <--> veth${i}-ns..."
    sudo ip link add veth$i type veth peer name veth${i}-ns || { echo "错误：创建虚拟以太网设备对 veth$i <--> veth${i}-ns 失败。" >&2; exit 1; }
    echo "   ✅ 虚拟以太网设备对创建成功。"

    # 3. 配置虚拟以太网设备
    echo "   - 步骤3/7: 配置虚拟以太网设备..."
    # 将 veth${i}-ns 移入网络命名空间 ns$i
    sudo ip link set veth${i}-ns netns ns$i || { echo "错误：将 veth${i}-ns 移入 ns$i 失败。" >&2; exit 1; }
    # 为命名空间内的 veth${i}-ns 分配IP地址
    sudo ip netns exec ns$i ip addr add 10.0.0.$((i+2))/24 dev veth${i}-ns || { echo "错误：为 veth${i}-ns@ns$i 分配IP地址失败。" >&2; exit 1; } # IP段调整为10.0.0.(i+2) 避免与网关冲突
    # 为主机上的 veth$i 分配IP地址 (作为 ns$i 的网关)
    sudo ip addr add 10.0.0.1/24 dev veth$i || { echo "错误：为 veth$i 分配IP地址失败。" >&2; exit 1; } # 网关固定为10.0.0.1
    echo "   ✅ 虚拟以太网设备配置成功。"

    # 4. 启动虚拟以太网设备
    echo "   - 步骤4/7: 启动虚拟以太网设备..."
    sudo ip link set veth$i up || { echo "错误：启动 veth$i 失败。" >&2; exit 1; }
    sudo ip netns exec ns$i ip link set veth${i}-ns up || { echo "错误：启动 veth${i}-ns@ns$i 失败。" >&2; exit 1; }
    echo "   ✅ 虚拟以太网设备已启动。"

    # 5. 设置命名空间内的默认路由
    # 使命名空间 ns$i 内的流量通过 veth$i (10.0.0.1) 路由出去
    echo "   - 步骤5/7: 设置 ns$i 内的默认路由指向 10.0.0.1..."
    sudo ip netns exec ns$i ip route add default via 10.0.0.1 || { echo "错误：在 ns$i 中设置默认路由失败。" >&2; exit 1; }
    echo "   ✅ ns$i 默认路由设置成功。"

    # 6. 配置NAT (网络地址转换)
    # 允许来自 10.0.0.0/24 网段 (即所有命名空间) 的流量通过主机的出口进行MASQUERADE (源地址伪装)
    # 注意: 这条规则是全局的，只需要设置一次。但为了脚本的幂等性和清晰性，放在循环内问题不大，iptables会自动处理重复规则。
    # 更优的做法是检查规则是否存在，不存在则添加。
    echo "   - 步骤6/7: 配置NAT规则 (MASQUERADE)..."
    if ! sudo iptables -t nat -C POSTROUTING -s 10.0.0.0/24 -j MASQUERADE &> /dev/null; then
        sudo iptables -t nat -A POSTROUTING -s 10.0.0.0/24 -j MASQUERADE || { echo "错误：配置NAT (MASQUERADE) 规则失败。" >&2; exit 1; }
        echo "   ✅ NAT (MASQUERADE) 规则已添加。"
    else
        echo "   ℹ️  NAT (MASQUERADE) 规则已存在。"
    fi

    # 7. 在命名空间中初始化并连接WARP
    echo "   - 步骤7/8: 在 ns$i 中初始化并连接WARP..."
    echo "     - 注册WARP..."
    sudo ip netns exec ns$i warp-cli --accept-tos registration new || echo "警告：WARP注册可能已完成或失败，请检查 warp-cli 日志。"
    echo "     - 连接WARP..."
    sudo ip netns exec ns$i warp-cli connect || { echo "错误：在 ns$i 中连接WARP失败。" >&2; exit 1; }
    # 检查连接状态
    if ! sudo ip netns exec ns$i warp-cli status | grep -q "Status: Connected"; then
        echo "错误：在 ns$i 中连接WARP后状态检查失败。" >&2
        sudo ip netns exec ns$i warp-cli status >&2
        exit 1
    fi
    echo "   ✅ WARP在 ns$i 中已成功初始化并连接。"

    # 8. 在命名空间中启动SOCKS5代理 (dante-server)
    SOCKS_PORT=1080 # SOCKS5服务在命名空间内部监听的端口
    DANTED_CONF_FILE="/tmp/danted_ns${i}.conf"
    NAMESPACE_IP="10.0.0.$((i+2))" # 对应步骤3中分配的IP

    echo "   - 步骤8/8: 在 ns$i 中启动SOCKS5代理 (dante-server)..."
    # 动态生成dante配置文件
    cat > "$DANTED_CONF_FILE" <<EOF
logoutput: stderr
internal: $NAMESPACE_IP port = $SOCKS_PORT
external: veth${i}-ns
method: none
user.privileged: root
user.unprivileged: nobody

client pass {
    from: 0.0.0.0/0 to: 0.0.0.0/0
    log: connect error
}

pass {
    from: 0.0.0.0/0 to: 0.0.0.0/0
    protocol: tcp udp
    log: connect error
}
EOF
    # 在命名空间内启动dante-server
    sudo ip netns exec ns$i danted -f "$DANTED_CONF_FILE" -D || { echo "错误：在 ns$i 中启动dante-server失败。" >&2; exit 1; }
    echo "   ✅ SOCKS5代理 (dante-server) 已在 ns$i 中启动，监听在 $NAMESPACE_IP:$SOCKS_PORT。"

    # 9. 创建端口映射 (DNAT)
    HOST_PORT=$((BASE_PORT + $i))
    echo "   - 步骤9/9: 创建端口映射 主机端口 $HOST_PORT -> $NAMESPACE_IP:$SOCKS_PORT (ns$i)..."
    # PREROUTING链用于DNAT
    if ! sudo iptables -t nat -C PREROUTING -p tcp --dport $HOST_PORT -j DNAT --to-destination $NAMESPACE_IP:$SOCKS_PORT &> /dev/null; then
        sudo iptables -t nat -A PREROUTING -p tcp --dport $HOST_PORT -j DNAT --to-destination $NAMESPACE_IP:$SOCKS_PORT || { echo "错误：创建DNAT规则失败 (PREROUTING)。" >&2; exit 1; }
    fi
    # FORWARD链用于允许数据包通过
    if ! sudo iptables -C FORWARD -p tcp -d $NAMESPACE_IP --dport $SOCKS_PORT -j ACCEPT &> /dev/null; then
        sudo iptables -A FORWARD -p tcp -d $NAMESPACE_IP --dport $SOCKS_PORT -j ACCEPT || { echo "错误：创建FORWARD规则失败。" >&2; exit 1; }
    fi
    echo "   ✅ 端口映射创建成功: 主机 $HOST_PORT <--> ns$i ($NAMESPACE_IP:$SOCKS_PORT)"

    echo "🎉 WARP 实例 $i 创建成功，SOCKS5代理监听在主机端口: $HOST_PORT (内部dante端口: $SOCKS_PORT)"
done

echo "====================================================="
echo "✅✅✅ WARP 代理池创建完成！共 $POOL_SIZE 个实例。"
echo "每个实例的SOCKS5代理端口从 $BASE_PORT 开始递增。"
echo "====================================================="