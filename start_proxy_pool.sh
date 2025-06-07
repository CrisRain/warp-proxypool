#!/bin/bash
# 增强脚本健壮性：
# -e: 遇到错误立即退出
# -u: 使用未定义变量时报错
# -o pipefail: 管道中任一命令失败则整个管道失败
set -euo pipefail

# --- 配置和常量 ---
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )" # 获取脚本所在目录
CREATE_WARP_POOL_SCRIPT="${SCRIPT_DIR}/create_warp_pool.sh"
PROXY_MANAGER_SCRIPT="${SCRIPT_DIR}/proxy_manager.py"
VENV_DIR="${SCRIPT_DIR}/venv"
REQUIREMENTS_FILE="${SCRIPT_DIR}/requirements.txt"
LOG_FILE="${SCRIPT_DIR}/proxy_manager.log"
PYTHON_CMD="python3" # 默认为python3，可以根据系统调整
PIP_CMD="pip3"       # 默认为pip3

# --- 前置检查 ---
echo "🚀 开始执行代理池启动脚本..."

# 检查是否以root权限运行 (因为 create_warp_pool.sh 需要)
if [ "$EUID" -ne 0 ]; then
  echo "错误：请以root权限运行此脚本 (使用 sudo)，因为需要创建网络命名空间和配置网络。" >&2
  exit 1
fi
echo "✅ root权限检查通过。"

# 检查 create_warp_pool.sh 是否存在且可执行
if [ ! -f "$CREATE_WARP_POOL_SCRIPT" ]; then
    echo "错误：创建脚本 ${CREATE_WARP_POOL_SCRIPT} 未找到！" >&2
    exit 1
fi
if [ ! -x "$CREATE_WARP_POOL_SCRIPT" ]; then
    echo "错误：创建脚本 ${CREATE_WARP_POOL_SCRIPT} 没有执行权限。请先执行 chmod +x ${CREATE_WARP_POOL_SCRIPT}" >&2
    exit 1
fi
echo "✅ WARP池创建脚本 (${CREATE_WARP_POOL_SCRIPT}) 检查通过。"

# 检查 python3 命令是否存在
if ! command -v $PYTHON_CMD &> /dev/null; then
    echo "错误：${PYTHON_CMD} 命令未找到。请确保已安装 Python 3。" >&2
    exit 1
fi
echo "✅ ${PYTHON_CMD} 命令检查通过。"

# 检查 pip3/pip 命令是否存在
if ! command -v $PIP_CMD &> /dev/null; then
    # 尝试使用 pip
    if command -v pip &> /dev/null; then
        PIP_CMD="pip"
    else
        echo "错误：${PIP_CMD} (或 pip) 命令未找到。请确保已安装 pip。" >&2
        exit 1
    fi
fi
echo "✅ ${PIP_CMD} 命令检查通过。"

# 检查 proxy_manager.py 是否存在
if [ ! -f "$PROXY_MANAGER_SCRIPT" ]; then
    echo "错误：代理管理脚本 ${PROXY_MANAGER_SCRIPT} 未找到！" >&2
    exit 1
fi
echo "✅ 代理管理脚本 (${PROXY_MANAGER_SCRIPT}) 检查通过。"


# --- 步骤1: 创建网络环境 ---
echo "-----------------------------------------------------"
echo "⚙️  步骤1: 调用脚本创建网络环境..."
echo "-----------------------------------------------------"
sudo "$CREATE_WARP_POOL_SCRIPT" || { echo "错误：执行 ${CREATE_WARP_POOL_SCRIPT} 失败。" >&2; exit 1; }
echo "✅ 网络环境创建成功。"

# --- 步骤2: 准备Python环境 ---
echo "-----------------------------------------------------"
echo "🐍 步骤2: 准备Python环境..."
echo "-----------------------------------------------------"
if [ ! -d "$VENV_DIR" ]; then
    echo "   - 创建Python虚拟环境到 ${VENV_DIR}..."
    $PYTHON_CMD -m venv "$VENV_DIR" || { echo "错误：创建Python虚拟环境失败。" >&2; exit 1; }
    echo "   ✅ Python虚拟环境创建成功。"
fi
VENV_PYTHON="${VENV_DIR}/bin/python"
VENV_PIP="${VENV_DIR}/bin/pip"
echo "   - 安装Python依赖..."
"$VENV_PIP" install -r "$REQUIREMENTS_FILE" || { echo "错误：使用 ${REQUIREMENTS_FILE} 安装依赖失败。" >&2; exit 1; }
echo "✅ Python环境准备就绪。"

# --- 步骤3: 在命名空间内启动代理管理器 ---
echo "-----------------------------------------------------"
echo "🚀 步骤3: 在管理器命名空间中启动服务..."
echo "-----------------------------------------------------"
# 从 create_warp_pool.sh 中获取变量定义
source <(grep -E '^(POOL_SIZE|BASE_PORT|MANAGER_NS|MANAGER_IP|MANAGER_API_PORT|MANAGER_SOCKS_PORT)=' "$CREATE_WARP_POOL_SCRIPT")

echo "   - 在 $MANAGER_NS 中启动 proxy_manager.py..."
sudo ip netns exec "$MANAGER_NS" "$VENV_PYTHON" "$PROXY_MANAGER_SCRIPT" > "$LOG_FILE" 2>&1 &
sleep 2
echo "   ✅ proxy_manager.py 已启动，日志位于 $LOG_FILE"

# --- 步骤4: 暴露服务端口 ---
echo "-----------------------------------------------------"
echo "🔗 步骤4: 暴露服务端口到宿主机..."
echo "-----------------------------------------------------"
echo "   - 暴露API端口: 127.0.0.1:$MANAGER_API_PORT -> $MANAGER_IP:$MANAGER_API_PORT"
sudo socat TCP4-LISTEN:$MANAGER_API_PORT,fork,reuseaddr,bind=127.0.0.1 TCP4:$MANAGER_IP:$MANAGER_API_PORT &

echo "   - 暴露SOCKS5端口: 127.0.0.1:$MANAGER_SOCKS_PORT -> $MANAGER_IP:$MANAGER_SOCKS_PORT"
sudo socat TCP4-LISTEN:$MANAGER_SOCKS_PORT,fork,reuseaddr,bind=127.0.0.1 TCP4:$MANAGER_IP:$MANAGER_SOCKS_PORT &
echo "✅ 服务端口暴露成功。"

echo "====================================================="
echo "🎉🎉🎉 代理池启动流程完成！🎉🎉🎉"
echo "API服务监听在: 127.0.0.1:$MANAGER_API_PORT"
echo "中央SOCKS5代理监听在: 127.0.0.1:$MANAGER_SOCKS_PORT"
echo "====================================================="