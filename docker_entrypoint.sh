#!/bin/bash
set -euo pipefail

# 脚本所在目录
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
CREATE_WARP_POOL_SCRIPT="${SCRIPT_DIR}/create_warp_pool.sh"
PROXY_MANAGER_SCRIPT="${SCRIPT_DIR}/proxy_manager.py"
PYTHON_CMD="python3"

echo "🚀 Docker Entrypoint: 启动代理池服务..."

# 检查 create_warp_pool.sh 是否存在且可执行
if [ ! -f "$CREATE_WARP_POOL_SCRIPT" ]; then
    echo "错误：创建脚本 ${CREATE_WARP_POOL_SCRIPT} 未找到！" >&2
    exit 1
fi
if [ ! -x "$CREATE_WARP_POOL_SCRIPT" ]; then
    echo "错误：创建脚本 ${CREATE_WARP_POOL_SCRIPT} 没有执行权限。" >&2
    exit 1
fi

# 检查 proxy_manager.py 是否存在
if [ ! -f "$PROXY_MANAGER_SCRIPT" ]; then
    echo "错误：代理管理脚本 ${PROXY_MANAGER_SCRIPT} 未找到！" >&2
    exit 1
fi

# 步骤1: 创建网络命名空间和WARP实例
echo "-----------------------------------------------------"
echo "⚙️  步骤1: 调用脚本创建网络命名空间和WARP实例..."
echo "-----------------------------------------------------"
# 在容器内，我们通常以root身份运行，或者 Dockerfile 中已赋予足够权限
# 因此，直接执行脚本，脚本内部的 sudo 命令在 root 用户下执行时是无操作的
"$CREATE_WARP_POOL_SCRIPT" || { echo "错误：执行 ${CREATE_WARP_POOL_SCRIPT} 失败。" >&2; exit 1; }
echo "✅ WARP实例和网络命名空间创建成功 (由 ${CREATE_WARP_POOL_SCRIPT} 完成)。"


# 步骤2: 移交控制权
echo "-----------------------------------------------------"
echo "✅ WARP代理池已创建，入口脚本执行完毕。"
echo "将控制权移交给 docker-compose.yml 中定义的 command..."
echo "-----------------------------------------------------"
exec "$@"