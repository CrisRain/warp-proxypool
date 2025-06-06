#!/bin/bash
# 增强脚本健壮性
set -euo pipefail

echo "🚀 开始执行代理池停止脚本..."

# --- 步骤1: 停止代理管理API服务 (proxy_manager.py) ---
echo "-----------------------------------------------------"
echo "🛑 步骤1: 停止代理管理API服务 (proxy_manager.py)..."
echo "-----------------------------------------------------"
# 使用 pgrep 和 pkill 查找并杀死包含 "proxy_manager.py" 的进程
# -f 标志表示匹配完整命令行
if pgrep -f "proxy_manager.py" &> /dev/null; then
    echo "   - 发现正在运行的 proxy_manager.py 进程，正在尝试停止..."
    pkill -f "proxy_manager.py"
    # 等待一小会儿确保进程已退出
    sleep 2
    if pgrep -f "proxy_manager.py" &> /dev/null; then
        echo "   - 警告：无法通过 pkill 停止进程，可能需要手动干预。"
    else
        echo "   ✅ proxy_manager.py 进程已成功停止。"
    fi
else
    echo "   ℹ️  未发现正在运行的 proxy_manager.py 进程。"
fi

# --- 步骤2: 清理网络命名空间和WARP实例 ---
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