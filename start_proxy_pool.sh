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


# --- 步骤1: 创建网络命名空间和WARP实例 ---
echo "-----------------------------------------------------"
echo "⚙️  步骤1: 调用脚本创建网络命名空间和WARP实例..."
echo "-----------------------------------------------------"
# 使用 sudo 执行，因为 create_warp_pool.sh 内部需要root权限
sudo "$CREATE_WARP_POOL_SCRIPT" || { echo "错误：执行 ${CREATE_WARP_POOL_SCRIPT} 失败。" >&2; exit 1; }
echo "✅ WARP实例和网络命名空间创建成功 (由 ${CREATE_WARP_POOL_SCRIPT} 完成)。"


# --- 步骤2: 设置Python环境并启动代理管理API ---
echo "-----------------------------------------------------"
echo "🐍 步骤2: 设置Python环境并启动代理管理API..."
echo "-----------------------------------------------------"

# 1. 创建Python虚拟环境 (如果尚不存在)
if [ ! -d "$VENV_DIR" ]; then
    echo "   - 创建Python虚拟环境到 ${VENV_DIR}..."
    $PYTHON_CMD -m venv "$VENV_DIR" || { echo "错误：创建Python虚拟环境失败。" >&2; exit 1; }
    echo "   ✅ Python虚拟环境创建成功。"
else
    echo "   ℹ️  Python虚拟环境 ${VENV_DIR} 已存在。"
fi

# 2. 激活虚拟环境
# source命令在子shell中执行时不会影响当前shell，所以后续命令需要在同一个上下文中执行
# 或者，我们可以直接使用虚拟环境中的python和pip
VENV_PYTHON="${VENV_DIR}/bin/python"
VENV_PIP="${VENV_DIR}/bin/pip"

echo "   - 使用虚拟环境: ${VENV_DIR}"

# 3. 安装Python依赖
echo "   - 安装Python依赖..."
if [ -f "$REQUIREMENTS_FILE" ]; then
    echo "     - 发现 ${REQUIREMENTS_FILE}，使用它安装依赖..."
    "$VENV_PIP" install -r "$REQUIREMENTS_FILE" || { echo "错误：使用 ${REQUIREMENTS_FILE} 安装依赖失败。" >&2; exit 1; }
    echo "     ✅ 使用 ${REQUIREMENTS_FILE} 安装依赖成功。"
else
    echo "     - 未找到 ${REQUIREMENTS_FILE}。"
    echo "     - 尝试安装默认依赖: flask..."
    "$VENV_PIP" install flask || { echo "错误：安装 flask 失败。" >&2; exit 1; }
    echo "     ✅ flask 安装成功。建议创建 ${REQUIREMENTS_FILE} 文件以管理项目依赖。"
fi

# 4. 从 create_warp_pool.sh 解析配置并导出为环境变量
echo "   - 从 ${CREATE_WARP_POOL_SCRIPT} 解析配置..."

# 使用grep和cut安全地提取值，并去除可能存在的注释和空格
# grep -E '^[[:space:]]*POOL_SIZE=' 匹配以 POOL_SIZE= 开头（允许前面有空格）的行
# cut -d'=' -f2- 获取等号后的所有内容
# cut -d'#' -f1 获取注释前的内容
# xargs echo -n 去除前后的空格
POOL_SIZE_VALUE=$(grep -E '^[[:space:]]*POOL_SIZE=' "$CREATE_WARP_POOL_SCRIPT" | cut -d'=' -f2- | cut -d'#' -f1 | xargs echo -n)
BASE_PORT_VALUE=$(grep -E '^[[:space:]]*BASE_PORT=' "$CREATE_WARP_POOL_SCRIPT" | cut -d'=' -f2- | cut -d'#' -f1 | xargs echo -n)

if [ -z "$POOL_SIZE_VALUE" ] || [ -z "$BASE_PORT_VALUE" ]; then
    echo "错误：无法从 ${CREATE_WARP_POOL_SCRIPT} 中解析 POOL_SIZE 或 BASE_PORT。" >&2
    echo "请确保该文件中包含类似 'POOL_SIZE=3' 和 'BASE_PORT=10800' 的定义。" >&2
    exit 1
fi

echo "     - 解析到 POOL_SIZE=${POOL_SIZE_VALUE}"
echo "     - 解析到 BASE_PORT=${BASE_PORT_VALUE}"

# 将解析出的值导出为环境变量，以便后续的python脚本可以读取
export POOL_SIZE="$POOL_SIZE_VALUE"
export BASE_PORT="$BASE_PORT_VALUE"
echo "   ✅ 配置已作为环境变量导出。"


# 5. 启动代理管理API服务 (后台运行)
echo "   - 启动代理管理API服务 (${PROXY_MANAGER_SCRIPT})..."
echo "     日志将输出到: ${LOG_FILE}"
# 使用虚拟环境中的python执行脚本
# 使用 nohup 和 & 实现后台运行，并将标准输出和标准错误重定向到日志文件
# export过的环境变量会被nohup启动的子进程继承
nohup "$VENV_PYTHON" "$PROXY_MANAGER_SCRIPT" > "$LOG_FILE" 2>&1 &
# 检查nohup命令是否成功启动进程 (注意：这只检查nohup本身，不检查python脚本是否正常运行)
if [ $? -ne 0 ]; then
    echo "错误：启动代理管理API (${PROXY_MANAGER_SCRIPT}) 失败。请检查 ${LOG_FILE} 获取详细信息。" >&2
    exit 1
fi

# 获取nohup启动的进程ID (可选，用于后续管理)
PROXY_PID=$!
echo "   ✅ 代理管理API服务已尝试启动 (PID: $PROXY_PID)。请检查日志 ${LOG_FILE} 确认运行状态。"

echo "====================================================="
echo "🎉🎉🎉 代理池启动流程完成！🎉🎉🎉"
echo "SOCKS5代理服务由 proxy_manager.py 提供，预计监听在 0.0.0.0:10880 (具体请参考 ${PROXY_MANAGER_SCRIPT} 的实现和日志 ${LOG_FILE})"
echo "WARP实例的本地SOCKS5端口由 create_warp_pool.sh 配置 (通常从10800开始)。"
echo "====================================================="