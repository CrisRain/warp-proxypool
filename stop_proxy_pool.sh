#!/bin/bash
# 增强脚本健壮性
set -euo pipefail

echo "🚀 开始执行代理池停止脚本..."

# --- 步骤1: 停止所有相关进程 ---
# pkill 会杀死所有 socat 和 proxy_manager.py 进程
# create_warp_pool.sh cleanup 会杀死所有命名空间内的进程
echo "-----------------------------------------------------"
echo "🛑 步骤1: 停止所有相关服务进程..."
echo "-----------------------------------------------------"
# 使用 pgrep 和 pkill 查找并杀死包含 "proxy_manager.py" 的进程
if pgrep -f "proxy_manager.py" &> /dev/null; then
    echo "   - 发现正在运行的 proxy_manager.py 进程，正在尝试停止..."
    pkill -f "proxy_manager.py"
fi
# 停止暴露端口的 socat 进程
if pgrep -f "socat TCP4-LISTEN" &> /dev/null; then
    echo "   - 发现正在运行的 socat 进程，正在尝试停止..."
    pkill -f "socat TCP4-LISTEN"
fi
sleep 2
echo "   ✅ 服务进程已停止。"


# --- 步骤2: 清理网络环境 ---
echo "-----------------------------------------------------"
echo "🧹 步骤2: 调用脚本清理网络资源..."
echo "-----------------------------------------------------"
CREATE_WARP_POOL_SCRIPT="./create_warp_pool.sh"

if [ ! -f "$CREATE_WARP_POOL_SCRIPT" ]; then
    echo "错误：清理脚本 ${CREATE_WARP_POOL_SCRIPT} 未找到！" >&2
    exit 1
fi

# 以root权限执行清理命令
sudo "$CREATE_WARP_POOL_SCRIPT" cleanup || { echo "错误：执行清理脚本失败。" >&2; exit 1; }

echo "====================================================="
echo "🎉🎉🎉 代理池已成功停止并清理！🎉🎉🎉"
echo "====================================================="