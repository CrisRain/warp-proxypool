#!/bin/bash
# 增强脚本健壮性：
# -e: 遇到错误立即退出
# -u: 使用未定义变量时报错
# -o pipefail: 管道中任一命令失败则整个管道失败
set -euo pipefail

# --- 配置参数 ---
POOL_SIZE=3      # 代理池大小，即创建多少个WARP实例
BASE_PORT=10800  # SOCKS5代理的基础端口号

# WARP+ 许可证密钥 (可选)
WARP_LICENSE_KEY=""

# 自定义WARP端点IP和端口 (可选)
WARP_ENDPOINT=""

# 自定义WARP代理端口 (可选)
CUSTOM_PROXY_PORT=""

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
    echo "   - 停止所有残留的 WARP 进程..."
    sudo pkill -f warp-svc || true
    sudo pkill -f warp-cli || true
    sleep 2 # 等待进程完全退出
    echo "   ✅ WARP 进程已清理。"

    # 清理 iptables 规则
    echo "   - 清理iptables规则..."
    SOCKS_PORT_IN_NAMESPACE=${CUSTOM_PROXY_PORT:-40000}
    for i in $(seq 0 $(($POOL_SIZE-1))); do
        HOST_PORT=$((BASE_PORT + $i))
        SUBNET_THIRD_OCTET=$i
        NAMESPACE_IP="10.0.${SUBNET_THIRD_OCTET}.2"
        
        # 清理 DNAT 规则
        while sudo iptables -t nat -C PREROUTING -p tcp --dport $HOST_PORT -j DNAT --to-destination $NAMESPACE_IP:$SOCKS_PORT_IN_NAMESPACE &> /dev/null; do
            sudo iptables -t nat -D PREROUTING -p tcp --dport $HOST_PORT -j DNAT --to-destination $NAMESPACE_IP:$SOCKS_PORT_IN_NAMESPACE
        done
        # 清理 FORWARD 规则
        while sudo iptables -C FORWARD -p tcp -d $NAMESPACE_IP --dport $SOCKS_PORT_IN_NAMESPACE -j ACCEPT &> /dev/null; do
            sudo iptables -D FORWARD -p tcp -d $NAMESPACE_IP --dport $SOCKS_PORT_IN_NAMESPACE -j ACCEPT
        done
    done
    
    # 清理通用的 MASQUERADE 和 FORWARD 规则
    for i in $(seq 0 $(($POOL_SIZE-1))); do
        SUBNET="10.0.$i.0/24"
        while sudo iptables -t nat -C POSTROUTING -s $SUBNET -j MASQUERADE &> /dev/null; do
            sudo iptables -t nat -D POSTROUTING -s $SUBNET -j MASQUERADE
        done
        while sudo iptables -C FORWARD -s $SUBNET -j ACCEPT &> /dev/null; do
            sudo iptables -D FORWARD -s $SUBNET -j ACCEPT
        done
        while sudo iptables -C FORWARD -d $SUBNET -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT &> /dev/null; do
            sudo iptables -D FORWARD -d $SUBNET -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
        done
    done
    echo "   ✅ 旧的iptables规则已清理。"

    # 清理网络命名空间和veth设备
    echo "   - 清理网络命名空间和veth设备..."
    for i in $(seq 0 $(($POOL_SIZE-1))); do
        if sudo ip netns list | grep -q "ns$i"; then
            sudo ip netns del "ns$i" &> /dev/null || true
        fi
        if ip link show "veth$i" &> /dev/null; then
            sudo ip link del "veth$i" &> /dev/null || true
        fi
    done
    echo "   ✅ 旧的网络命名空间和veth设备已清理。"
    
    # 清理锁文件
    rm -f /tmp/warp_pool.lock
    
    echo "✅ 旧的网络配置清理完成。"
}

# 创建函数
create_pool() {
    echo "🚀 开始启用IP转发..."
    sudo sysctl -w net.ipv4.ip_forward=1 || { echo "错误：启用IP转发失败。" >&2; exit 1; }
    echo "✅ IP转发已启用。"

    echo "🚀 开始创建 WARP 代理池..."
    for i in $(seq 0 $(($POOL_SIZE-1))); do
        (
            # 使用全局锁确保实例创建过程串行化
            flock -x 200
            
            echo "-----------------------------------------------------"
            echo "✨ 正在创建 WARP 实例 $i (端口: $((BASE_PORT + $i)))..."
            echo "-----------------------------------------------------"

            # 每个实例使用独立的子网，避免IP冲突
            SUBNET_THIRD_OCTET=$i
            GATEWAY_IP="10.0.${SUBNET_THIRD_OCTET}.1"
            NAMESPACE_IP="10.0.${SUBNET_THIRD_OCTET}.2"
            SUBNET="${GATEWAY_IP%.*}.0/24"

            # 1. 创建网络命名空间
            echo "   - 步骤1/8: 创建网络命名空间 ns$i..."
            sudo ip netns add "ns$i" || { echo "错误：创建网络命名空间 ns$i 失败。" >&2; exit 1; }
            echo "   ✅ 网络命名空间 ns$i 创建成功。"

            # 1.2. 启动命名空间内的loopback接口
            echo "   - 步骤1.2/8: 启动 ns$i 内的 loopback 接口..."
            sudo ip netns exec "ns$i" ip link set lo up || { echo "错误：启动 ns$i 内的 loopback 接口失败。" >&2; exit 1; }
            echo "   ✅ ns$i loopback 接口已启动。"

            # 1.5. 为命名空间配置DNS解析
            echo "   - 步骤1.5/8: 为 ns$i 配置DNS..."
            sudo mkdir -p "/etc/netns/ns$i"
            # 根据您的要求，强制使用 1.1.1.1 作为 DNS
            # 使用 Cloudflare 和 Google 的 DNS，增加冗余
            cat <<EOF | sudo tee "/etc/netns/ns$i/resolv.conf" > /dev/null
nameserver 1.1.1.1
nameserver 8.8.8.8
EOF
            echo "   ✅ 已配置DNS为 1.1.1.1 和 8.8.8.8。"

            # 2. 创建虚拟以太网设备对
            echo "   - 步骤2/8: 创建虚拟以太网设备 veth$i <--> veth${i}-ns..."
            sudo ip link add "veth$i" type veth peer name "veth${i}-ns" || { echo "错误：创建虚拟以太网设备对失败。" >&2; exit 1; }
            echo "   ✅ 虚拟以太网设备对创建成功。"

            # 3. 配置虚拟以太网设备
            echo "   - 步骤3/8: 配置虚拟以太网设备..."
            sudo ip link set "veth${i}-ns" netns "ns$i" || { echo "错误：将 veth${i}-ns 移入 ns$i 失败。" >&2; exit 1; }
            sudo ip netns exec "ns$i" ip addr add "$NAMESPACE_IP/24" dev "veth${i}-ns" || { echo "错误：为 veth${i}-ns@ns$i 分配IP地址失败。" >&2; exit 1; }
            sudo ip addr add "$GATEWAY_IP/24" dev "veth$i" || { echo "错误：为 veth$i 分配IP地址失败。" >&2; exit 1; }
            echo "   ✅ 虚拟以太网设备配置成功。"

            # 4. 启动虚拟以太网设备
            echo "   - 步骤4/8: 启动虚拟以太网设备..."
            sudo ip link set "veth$i" up || { echo "错误：启动 veth$i 失败。" >&2; exit 1; }
            sudo ip netns exec "ns$i" ip link set "veth${i}-ns" up || { echo "错误：启动 veth${i}-ns@ns$i 失败。" >&2; exit 1; }
            echo "   ✅ 虚拟以太网设备已启动。"

            # 4.5. 禁用反向路径过滤 (解决某些环境下NAT转发问题)
            echo "   - 步骤4.5/8: 禁用 veth$i 上的反向路径过滤..."
            sudo sysctl -w "net.ipv4.conf.veth$i.rp_filter=0" >/dev/null || { echo "警告：禁用反向路径过滤失败，可能会影响连接。" >&2; }
            echo "   ✅ veth$i 反向路径过滤已禁用。"

            # 5. 设置命名空间内的默认路由
            echo "   - 步骤5/8: 设置 ns$i 内的默认路由..."
            sudo ip netns exec "ns$i" ip route add default via "$GATEWAY_IP" || { echo "错误：在 ns$i 中设置默认路由失败。" >&2; exit 1; }
            echo "   ✅ ns$i 默认路由设置成功。"

            # 6. 配置NAT和转发规则
            echo "   - 步骤6/8: 配置NAT和转发规则..."
            if ! sudo iptables -t nat -C POSTROUTING -s "$SUBNET" -j MASQUERADE &> /dev/null; then
                sudo iptables -t nat -I POSTROUTING -s "$SUBNET" -j MASQUERADE || { echo "错误：配置NAT规则失败。" >&2; exit 1; }
            fi
            if ! sudo iptables -C FORWARD -s "$SUBNET" -j ACCEPT &> /dev/null; then
                sudo iptables -I FORWARD -s "$SUBNET" -j ACCEPT || { echo "错误：配置出向FORWARD规则失败。" >&2; exit 1; }
            fi
            if ! sudo iptables -C FORWARD -d "$SUBNET" -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT &> /dev/null; then
                sudo iptables -I FORWARD -d "$SUBNET" -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT || { echo "错误：配置入向FORWARD规则失败。" >&2; exit 1; }
            fi
            echo "   ✅ NAT和转发规则配置成功。"

            # 7. 初始化WARP
            SOCKS_PORT_IN_NAMESPACE=${CUSTOM_PROXY_PORT:-40000}
            echo "   - 步骤7/8: 在 ns$i 中初始化WARP (内部SOCKS5端口: $SOCKS_PORT_IN_NAMESPACE)..."
            
            sudo ip netns exec "ns$i" bash -c '
                set -euo pipefail
                
                # 从参数中获取变量
                i="$1"
                CUSTOM_PROXY_PORT="$2"
                WARP_LICENSE_KEY="$3"
                WARP_ENDPOINT="$4"
                
                echo "     - (预清理) 尝试断开连接并删除旧注册..."
                warp-cli --accept-tos disconnect || true
                warp-cli --accept-tos registration delete || true
                sleep 1

                # 检查外网连通性
                echo "     - 检查外网连通性..."
                # 使用 ping 代替 nslookup 进行连通性测试，-c 1 表示只发送一个包
                if ! timeout 10s ping -c 1 api.cloudflareclient.com >/dev/null 2>&1; then
                    sleep 2
                    if ! timeout 10s ping -c 1 api.cloudflareclient.com >/dev/null 2>&1; then
                        echo "错误：命名空间 ns$i 无法 ping 通 api.cloudflareclient.com，请检查网络配置。" >&2
                        exit 1
                    fi
                fi
                echo "   ✅ ping api.cloudflareclient.com 成功。"

                echo "     - 强制清理残留的 socket 文件 (如果存在)..."
                rm -f /run/cloudflare-warp/warp_service || true

                echo "     - 启动WARP服务守护进程..."
                warp-svc &
                sleep 8 # 给 warp-svc 更多启动时间

                echo "     - 等待WARP服务IPC Socket就绪..."
                _MAX_SVC_WAIT_ATTEMPTS=20
                _SVC_WAIT_COUNT=0
                while ! test -S /run/cloudflare-warp/warp_service; do
                    _SVC_WAIT_COUNT=$(($_SVC_WAIT_COUNT + 1))
                    if [ $_SVC_WAIT_COUNT -gt $_MAX_SVC_WAIT_ATTEMPTS ]; then
                        echo "错误：等待WARP服务 (warp-svc) 超时。" >&2
                        ps aux | grep warp || true
                        exit 1
                    fi
                    echo "       等待中... 尝试 $_SVC_WAIT_COUNT / $_MAX_SVC_WAIT_ATTEMPTS"
                    sleep 2
                done
                echo "       WARP服务IPC Socket已就绪。"

                echo "     - 注册WARP并接受服务条款 (TOS)..."
                if ! warp-cli --accept-tos registration new; then
                     if warp-cli --accept-tos status | grep -q "Status: Registered"; then
                         echo "   ℹ️  WARP 已注册，继续..."
                     else
                         echo "错误：注册WARP失败。请检查 warp-svc 是否正常运行，以及网络连接。" >&2
                         warp-cli --accept-tos status >&2
                         exit 1
                     fi
                else
                    echo "   ✅ WARP新注册成功。"
                fi
                
                echo "     - 设置WARP为SOCKS5代理模式..."
                warp-cli --accept-tos mode proxy || { echo "错误：设置WARP代理模式失败。" >&2; exit 1; }
                
                if [ -n "$CUSTOM_PROXY_PORT" ]; then
                    echo "     - 设置自定义SOCKS5代理端口: $CUSTOM_PROXY_PORT..."
                    warp-cli --accept-tos proxy port "$CUSTOM_PROXY_PORT" || echo "警告：设置自定义代理端口失败，可能warp-cli版本不支持。"
                fi
                
                if [ -n "$WARP_LICENSE_KEY" ]; then
                    echo "     - 尝试使用许可证密钥升级到WARP+..."
                    warp-cli --accept-tos registration license "$WARP_LICENSE_KEY" || echo "警告：许可证密钥设置失败。"
                fi

                if [ -n "$WARP_ENDPOINT" ]; then
                    echo "     - 设置自定义WARP端点: $WARP_ENDPOINT..."
                    warp-cli --accept-tos tunnel endpoint reset || echo "警告：重置端点失败。"
                    warp-cli --accept-tos tunnel endpoint set "$WARP_ENDPOINT" || echo "警告：设置自定义端点失败。"
                fi

                echo "     - 连接WARP..."
                warp-cli --accept-tos connect || { echo "错误：连接WARP失败。" >&2; exit 1; }

                echo "     - 等待WARP连接成功..."
                MAX_CONNECT_WAIT_ATTEMPTS=30
                CONNECT_WAIT_COUNT=0
                while ! warp-cli --accept-tos status | grep -q "Status: Connected"; do
                    CONNECT_WAIT_COUNT=$(($CONNECT_WAIT_COUNT+1))
                    if [ $CONNECT_WAIT_COUNT -gt $MAX_CONNECT_WAIT_ATTEMPTS ]; then
                        echo "错误：连接WARP后状态检查失败 (超时)。" >&2
                        warp-cli --accept-tos status >&2
                        exit 1
                    fi
                    echo "       (尝试 $CONNECT_WAIT_COUNT/$MAX_CONNECT_WAIT_ATTEMPTS) 等待连接..."
                    sleep 3
                done
                echo "   ✅ WARP在 ns$i 中已成功初始化并连接。"
            ' bash "$i" "$CUSTOM_PROXY_PORT" "$WARP_LICENSE_KEY" "$WARP_ENDPOINT" || { echo "错误：在 ns$i 中初始化WARP失败。" >&2; exit 1; }

            # 8. 创建端口映射
            HOST_PORT=$((BASE_PORT + $i))
            echo "   - 步骤8/8: 创建端口映射 主机端口 $HOST_PORT -> $NAMESPACE_IP:$SOCKS_PORT_IN_NAMESPACE..."
            if ! sudo iptables -t nat -C PREROUTING -p tcp --dport $HOST_PORT -j DNAT --to-destination $NAMESPACE_IP:$SOCKS_PORT_IN_NAMESPACE &> /dev/null; then
                sudo iptables -t nat -I PREROUTING -p tcp --dport $HOST_PORT -j DNAT --to-destination $NAMESPACE_IP:$SOCKS_PORT_IN_NAMESPACE || { echo "错误：创建DNAT规则失败。" >&2; exit 1; }
            fi
            if ! sudo iptables -C FORWARD -p tcp -d $NAMESPACE_IP --dport $SOCKS_PORT_IN_NAMESPACE -j ACCEPT &> /dev/null; then
                sudo iptables -I FORWARD -p tcp -d $NAMESPACE_IP --dport $SOCKS_PORT_IN_NAMESPACE -j ACCEPT || { echo "错误：创建FORWARD规则失败。" >&2; exit 1; }
            fi
            echo "   ✅ 端口映射创建成功。"

            echo "🎉 WARP 实例 $i 创建成功，SOCKS5代理监听在主机端口: $HOST_PORT"
            
        ) 200>/tmp/warp_pool.lock
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
        cleanup
        create_pool
    fi
}

# 执行主函数
main "$@"