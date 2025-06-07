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

# WARP 实例的独立配置目录
WARP_CONFIG_BASE_DIR="/var/lib/warp-configs"
# WARP 实例的独立IPC Socket目录
WARP_IPC_BASE_DIR="/run/warp-sockets"

# --- 前置检查 ---
if ! command -v warp-cli &> /dev/null; then
    printf "错误：warp-cli 命令未找到。请确保已正确安装 Cloudflare WARP 客户端。\n" >&2
    exit 1
fi
printf "✅ warp-cli 命令检查通过。\n"

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

# --- 函数定义 ---

# 清理函数
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
    printf "   ✅ 旧的iptables规则已清理。\n"

    # 3. 杀死所有可能残留的全局进程作为最后手段
    printf "   - 步骤3: 停止所有残留的 WARP 和转发进程 (全局)...\n"
    sudo pkill -9 -f warp-svc >/dev/null 2>&1 || true
    sudo pkill -9 -f warp-cli >/dev/null 2>&1 || true
    sudo pkill -9 -f socat >/dev/null 2>&1 || true
    sleep 1
    printf "   ✅ 全局 WARP 和转发进程已清理。\n"
    
    # 4. 清理锁文件
    printf "   - 步骤4: 清理锁文件...\n"
    rm -f /tmp/warp_pool.lock >/dev/null 2>&1 || true
    printf "   ✅ 锁文件已清理。\n"
    
    printf "✅ 彻底清理完成。\n"
}

# 创建函数
create_pool() {
    printf "🚀 开始启用IP转发...\n"
    sudo sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1 || { printf "错误：启用IP转发失败。\n" >&2; exit 1; }
    # 允许将发往127.0.0.1的流量进行路由，这是让iptables OUTPUT链规则对localhost生效的关键
    sudo sysctl -w net.ipv4.conf.all.route_localnet=1 >/dev/null 2>&1 || { printf "警告：设置 route_localnet 失败，直接访问127.0.0.1的端口可能不工作。\n" >&2; }
    printf "✅ IP转发和本地网络路由已启用。\n"

    printf "🚀 开始创建 WARP 代理池...\n"
    for i in $(seq 0 $(($POOL_SIZE-1))); do
        (
            # 使用全局锁确保实例创建过程串行化
            flock -x 200
            
            printf -- "-----------------------------------------------------\n"
            printf "✨ 正在创建 WARP 实例 %s (端口: %s)...\n" "$i" "$((BASE_PORT + $i))"
            printf -- "-----------------------------------------------------\n"

            # 每个实例使用独立的子网，避免IP冲突
            SUBNET_THIRD_OCTET=$i
            GATEWAY_IP="10.0.${SUBNET_THIRD_OCTET}.1"
            NAMESPACE_IP="10.0.${SUBNET_THIRD_OCTET}.2"
            SUBNET="${GATEWAY_IP%.*}.0/24"

            # 1. 创建网络命名空间
            printf "   - 步骤1/12: 创建网络命名空间 ns%s...\n" "$i"
            sudo ip netns add "ns$i" || { printf "错误：创建网络命名空间 ns%s 失败。\n" "$i" >&2; exit 1; }
            printf "   ✅ 网络命名空间 ns%s 创建成功。\n" "$i"

            # 2. 创建并绑定独立的配置和IPC目录，以完全隔离每个WARP实例
            printf "   - 步骤2/12: 为 ns%s 创建并绑定独立配置和IPC目录...\n" "$i"
            INSTANCE_CONFIG_DIR="${WARP_CONFIG_BASE_DIR}/ns$i"
            INSTANCE_IPC_DIR="${WARP_IPC_BASE_DIR}/ns$i"
            WARP_SYSTEM_CONFIG_DIR="/var/lib/cloudflare-warp"
            WARP_SYSTEM_IPC_DIR="/run/cloudflare-warp"
            
            sudo mkdir -p "$INSTANCE_CONFIG_DIR"
            sudo mkdir -p "$INSTANCE_IPC_DIR"
            
            # 在命名空间内创建挂载点并执行绑定挂载
            sudo ip netns exec "ns$i" mkdir -p "$WARP_SYSTEM_CONFIG_DIR"
            sudo ip netns exec "ns$i" mount --bind "$INSTANCE_CONFIG_DIR" "$WARP_SYSTEM_CONFIG_DIR"
            
            sudo ip netns exec "ns$i" mkdir -p "$WARP_SYSTEM_IPC_DIR"
            sudo ip netns exec "ns$i" mount --bind "$INSTANCE_IPC_DIR" "$WARP_SYSTEM_IPC_DIR"
            
            printf "   ✅ 已为 ns%s 绑定独立配置目录: %s\n" "$i" "$INSTANCE_CONFIG_DIR"
            printf "   ✅ 已为 ns%s 绑定独立IPC目录: %s\n" "$i" "$INSTANCE_IPC_DIR"

            # 3. 启动命名空间内的loopback接口
            printf "   - 步骤3/12: 启动 ns%s 内的 loopback 接口...\n" "$i"
            sudo ip netns exec "ns$i" ip link set lo up || { printf "错误：启动 ns%s 内的 loopback 接口失败。\n" "$i" >&2; exit 1; }
            printf "   ✅ ns%s loopback 接口已启动。\n" "$i"

            # 4. 为命名空间配置DNS解析
            printf "   - 步骤4/12: 为 ns%s 配置DNS...\n" "$i"
            sudo mkdir -p "/etc/netns/ns$i"
            printf "nameserver 1.1.1.1\nnameserver 8.8.8.8\n" | sudo tee "/etc/netns/ns$i/resolv.conf" > /dev/null
            printf "   ✅ 已配置DNS为 1.1.1.1 和 8.8.8.8。\n"

            # 5. 创建虚拟以太网设备对
            printf "   - 步骤5/12: 创建虚拟以太网设备 veth%s <--> veth%s-ns...\n" "$i" "$i"
            sudo ip link add "veth$i" type veth peer name "veth${i}-ns" || { printf "错误：创建虚拟以太网设备对失败。\n" >&2; exit 1; }
            printf "   ✅ 虚拟以太网设备对创建成功。\n"

            # 6. 配置虚拟以太网设备
            printf "   - 步骤6/12: 配置虚拟以太网设备...\n"
            sudo ip link set "veth${i}-ns" netns "ns$i" || { printf "错误：将 veth%s-ns 移入 ns%s 失败。\n" "$i" "$i" >&2; exit 1; }
            sudo ip netns exec "ns$i" ip addr add "$NAMESPACE_IP/24" dev "veth${i}-ns" || { printf "错误：为 veth%s-ns@ns%s 分配IP地址失败。\n" "$i" "$i" >&2; exit 1; }
            sudo ip addr add "$GATEWAY_IP/24" dev "veth$i" || { printf "错误：为 veth%s 分配IP地址失败。\n" "$i" >&2; exit 1; }
            printf "   ✅ 虚拟以太网设备配置成功。\n"

            # 7. 启动虚拟以太网设备
            printf "   - 步骤7/12: 启动虚拟以太网设备...\n"
            sudo ip link set "veth$i" up || { printf "错误：启动 veth%s 失败。\n" "$i" >&2; exit 1; }
            sudo ip netns exec "ns$i" ip link set "veth${i}-ns" up || { printf "错误：启动 veth%s-ns@ns%s 失败。\n" "$i" "$i" >&2; exit 1; }
            # 为命名空间内的veth设备设置MTU，防止因WARP封装导致的数据包过大问题
            sudo ip netns exec "ns$i" ip link set dev "veth${i}-ns" mtu 1420 || { printf "警告：为 veth%s-ns 设置MTU失败，可能会影响连接稳定性。\n" "$i" >&2; }
            printf "   ✅ 虚拟以太网设备已启动并设置MTU。\n"

            # 8. 禁用反向路径过滤 (解决某些环境下NAT转发问题)
            printf "   - 步骤8/12: 禁用 veth%s 上的反向路径过滤...\n" "$i"
            sudo sysctl -w "net.ipv4.conf.veth$i.rp_filter=0" >/dev/null || { printf "警告：禁用反向路径过滤失败，可能会影响连接。\n" >&2; }
            printf "   ✅ veth%s 反向路径过滤已禁用。\n" "$i"

            # 9. 设置命名空间内的默认路由
            printf "   - 步骤9/12: 设置 ns%s 内的默认路由...\n" "$i"
            sudo ip netns exec "ns$i" ip route add default via "$GATEWAY_IP" || { printf "错误：在 ns%s 中设置默认路由失败。\n" "$i" >&2; exit 1; }
            printf "   ✅ ns%s 默认路由设置成功。\n" "$i"

            # 10. 配置NAT和转发规则
            printf "   - 步骤10/12: 配置NAT和转发规则...\n"
            if ! sudo iptables -t nat -C POSTROUTING -s "$SUBNET" -j MASQUERADE &> /dev/null; then
                sudo iptables -t nat -I POSTROUTING -s "$SUBNET" -j MASQUERADE || { printf "错误：配置NAT规则失败。\n" >&2; exit 1; }
            fi
            # 简化转发规则：允许子网的所有出站和入站流量
            if ! sudo iptables -C FORWARD -s "$SUBNET" -j ACCEPT &> /dev/null; then
                sudo iptables -I FORWARD -s "$SUBNET" -j ACCEPT || { printf "错误：配置出向FORWARD规则失败。\n" >&2; exit 1; }
            fi
            if ! sudo iptables -C FORWARD -d "$SUBNET" -j ACCEPT &> /dev/null; then
                sudo iptables -I FORWARD -d "$SUBNET" -j ACCEPT || { printf "错误：配置入向FORWARD规则失败。\n" >&2; exit 1; }
            fi
            printf "   ✅ NAT和转发规则配置成功。\n"

            # 11. 初始化WARP并启动转发
            WARP_INTERNAL_PORT=40000
            SOCAT_LISTEN_PORT=40001
            printf "   - 步骤11/12: 在 ns%s 中初始化WARP并启动转发...\n" "$i"
            
            # 在执行命令前，确保挂载命名空间对当前shell可见
            sudo ip netns exec "ns$i" bash -c '
                # 使用printf代替echo以获得更好的格式控制
                printf "     - 检查外网连通性...\n"
                if ! timeout 10s ping -c 1 api.cloudflareclient.com >/dev/null 2>&1; then
                    sleep 2
                    if ! timeout 10s ping -c 1 api.cloudflareclient.com >/dev/null 2>&1; then
                        printf "错误：命名空间 ns%s 无法 ping 通 api.cloudflareclient.com，请检查网络配置。\n" "$1" >&2
                        exit 1
                    fi
                fi
                printf "     ✅ ping api.cloudflareclient.com 成功。\n"

                printf "     - 强制清理残留的 socket 文件 (如果存在)...\n"
                rm -f /run/cloudflare-warp/warp_service || true

                printf "     - 启动WARP服务守护进程...\n"
                nohup warp-svc >/dev/null 2>&1 &
                sleep 8

                printf "     - 等待WARP服务IPC Socket就绪...\n"
                _MAX_SVC_WAIT_ATTEMPTS=20
                _SVC_WAIT_COUNT=0
                while ! test -S /run/cloudflare-warp/warp_service; do
                    _SVC_WAIT_COUNT=$(($_SVC_WAIT_COUNT + 1))
                    if [ $_SVC_WAIT_COUNT -gt $_MAX_SVC_WAIT_ATTEMPTS ]; then
                        printf "错误：等待WARP服务 (warp-svc) 超时。\n" >&2
                        ps aux | grep warp || true
                        exit 1
                    fi
                    printf "       等待中... 尝试 %s / %s\n" "$_SVC_WAIT_COUNT" "$_MAX_SVC_WAIT_ATTEMPTS"
                    sleep 2
                done
                printf "       WARP服务IPC Socket已就绪。\n"

                printf "     - (预清理) 尝试断开连接并删除旧注册...\n"
                warp-cli --accept-tos disconnect >/dev/null 2>&1 || true
                warp-cli --accept-tos registration delete >/dev/null 2>&1 || true
                sleep 1

                printf "     - 注册WARP并接受服务条款 (TOS)...\n"
                if ! warp-cli --accept-tos registration new >/dev/null 2>&1; then
                     if warp-cli --accept-tos status | grep -q "Status: Registered"; then
                         printf "     ℹ️  WARP 已注册，继续...\n"
                     else
                         printf "错误：注册WARP失败。请检查 warp-svc 是否正常运行，以及网络连接。\n" >&2
                         warp-cli --accept-tos status >&2
                         exit 1
                     fi
                else
                    printf "     ✅ WARP新注册成功。\n"
                fi
                
                printf "     - 设置WARP为SOCKS5代理模式...\n"
                warp-cli --accept-tos mode proxy >/dev/null 2>&1 || { printf "错误：设置WARP代理模式失败。\n" >&2; exit 1; }
                
                if [ -n "$2" ]; then
                    printf "     - 设置WARP SOCKS5代理端口: %s...\n" "$2"
                    warp-cli --accept-tos proxy port "$2" >/dev/null 2>&1 || printf "警告：设置自定义代理端口失败，可能warp-cli版本不支持。\n"
                fi
                
                if [ -n "$4" ]; then
                    printf "     - 尝试使用许可证密钥升级到WARP+...\n"
                    warp-cli --accept-tos registration license "$4" >/dev/null 2>&1 || printf "警告：许可证密钥设置失败。\n"
                fi

                if [ -n "$5" ]; then
                    printf "     - 设置自定义WARP端点: %s...\n" "$5"
                    warp-cli --accept-tos tunnel endpoint reset >/dev/null 2>&1 || printf "警告：重置端点失败。\n"
                    warp-cli --accept-tos tunnel endpoint set "$5" >/dev/null 2>&1 || printf "警告：设置自定义端点失败。\n"
                fi

                printf "     - 连接WARP...\n"
                warp-cli --accept-tos connect >/dev/null 2>&1 || { printf "错误：连接WARP失败。\n" >&2; exit 1; }

                printf "     - 等待WARP连接成功...\n"
                MAX_CONNECT_WAIT_ATTEMPTS=30
                CONNECT_WAIT_COUNT=0
                while ! warp-cli --accept-tos status | grep -E -q "Status( update)?:[[:space:]]*Connected"; do
                    CONNECT_WAIT_COUNT=$(($CONNECT_WAIT_COUNT+1))
                    if [ $CONNECT_WAIT_COUNT -gt $MAX_CONNECT_WAIT_ATTEMPTS ]; then
                        printf "错误：连接WARP后状态检查失败 (超时)。\n" >&2
                        warp-cli --accept-tos status >&2
                        exit 1
                    fi
                    printf "       (尝试 %s/%s) 等待连接...\n" "$CONNECT_WAIT_COUNT" "$MAX_CONNECT_WAIT_ATTEMPTS"
                    sleep 3
                done
                printf "   ✅ WARP在 ns%s 中已成功初始化并连接。\n" "$1"

                printf "     - 使用 endpoint reset 刷新IP...\n"
                warp-cli --accept-tos tunnel endpoint reset >/dev/null 2>&1 || { printf "错误：使用 endpoint reset 刷新IP失败。\n" >&2; exit 1; }
                # 等待命令生效
                sleep 3
                printf "   ✅ WARP在 ns%s 中已成功通过 endpoint reset 刷新IP。\n" "$1"

                printf "     - 使用 socat 将流量从 0.0.0.0:%s 转发到 127.0.0.1:%s...\n" "$3" "$2"
                nohup socat TCP4-LISTEN:"$3",fork,reuseaddr TCP4:127.0.0.1:"$2" >/dev/null 2>&1 &
                sleep 2
                if ! pgrep -f "socat TCP4-LISTEN:$3" > /dev/null; then
                    printf "错误：在 ns%s 中启动 socat 失败。\n" "$1" >&2
                    exit 1
                fi
                printf "   ✅ socat 在 ns%s 中已成功启动。\n" "$1"

            ' bash "$i" "$WARP_INTERNAL_PORT" "$SOCAT_LISTEN_PORT" "$WARP_LICENSE_KEY" "$WARP_ENDPOINT" || { printf "错误：在 ns%s 中初始化WARP或启动socat失败。\n" "$i" >&2; exit 1; }

            # 12. 创建端口映射
            HOST_PORT=$((BASE_PORT + $i))
            printf "   - 步骤12/12: 创建端口映射 主机端口 %s -> %s:%s...\n" "$HOST_PORT" "$NAMESPACE_IP" "$SOCAT_LISTEN_PORT"
            # 为外部流量创建DNAT规则
            if ! sudo iptables -t nat -C PREROUTING -p tcp --dport $HOST_PORT -j DNAT --to-destination $NAMESPACE_IP:$SOCAT_LISTEN_PORT &> /dev/null; then
                sudo iptables -t nat -I PREROUTING -p tcp --dport $HOST_PORT -j DNAT --to-destination $NAMESPACE_IP:$SOCAT_LISTEN_PORT || { printf "错误：创建PREROUTING DNAT规则失败。\n" >&2; exit 1; }
            fi
            # 为本机流量(127.0.0.1)创建DNAT规则
            if ! sudo iptables -t nat -C OUTPUT -p tcp -d 127.0.0.1 --dport $HOST_PORT -j DNAT --to-destination $NAMESPACE_IP:$SOCAT_LISTEN_PORT &> /dev/null; then
                sudo iptables -t nat -I OUTPUT -p tcp -d 127.0.0.1 --dport $HOST_PORT -j DNAT --to-destination $NAMESPACE_IP:$SOCAT_LISTEN_PORT || { printf "错误：创建OUTPUT DNAT规则失败。\n" >&2; exit 1; }
            fi
            printf "   ✅ 端口映射创建成功。\n"

            printf "🎉 WARP 实例 %s 创建成功，SOCKS5代理监听在主机端口: %s\n" "$i" "$HOST_PORT"
            
        ) 200>/tmp/warp_pool.lock
        
        # 在创建下一个实例前加入一个延迟，以避免因请求过于密集导致Cloudflare后端分配相同IP的潜在问题。
        if [ "$i" -lt "$(($POOL_SIZE-1))" ]; then
            printf "   ⏳ 实例 %s 创建完毕，等待5秒后继续...\n" "$i"
            sleep 5
        fi
    done

    printf -- "=====================================================\n"
    printf "✅✅✅ WARP 代理池创建完成！共 %s 个实例。\n" "$POOL_SIZE"
    printf "每个实例的SOCKS5代理端口从 %s 开始递增。\n" "$BASE_PORT"
}

# --- 主逻辑 ---
main() {
    printf "🚀 开始执行 WARP 代理池创建脚本...\n"
    
    # 首先执行清理，确保环境干净
    cleanup
    
    # 然后创建新的代理池
    create_pool
    
    printf "🎉🎉🎉 脚本执行完毕！\n"
}

# 执行主函数
main "$@"