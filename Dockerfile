# 使用 Ubuntu 最新版作为基础镜像
FROM ubuntu:latest

# 设置环境变量，避免安装过程中的交互式提示
ENV DEBIAN_FRONTEND=noninteractive

# 更新包列表并安装系统依赖
# sudo 也包含在这里，因为 entrypoint 可能会用到（尽管 create_warp_pool.sh 内部也用）
# 或者确保容器以 root 运行
RUN apt-get update && apt-get install -y \
    iproute2 \
    iptables \
    procps \
    curl \
    gnupg \
    python3 \
    python3-pip \
    sudo \
    lsb-release \
    && rm -rf /var/lib/apt/lists/*

# 安装 warp-cli
RUN curl -fsSL https://pkg.cloudflareclient.com/pubkey.gpg | gpg --dearmor -o /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg && \
    echo "deb [arch=amd64 signed-by=/usr/share/keyrings/cloudflare-warp-archive-keyring.gpg] https://pkg.cloudflareclient.com/ $(lsb_release -cs) main" | tee /etc/apt/sources.list.d/cloudflare-client.list && \
    apt-get update && \
    apt-get install -y warp-cli && \
    rm -rf /var/lib/apt/lists/*

# 设置工作目录
WORKDIR /app

# 复制项目文件
COPY create_warp_pool.sh .
COPY proxy_manager.py .
COPY requirements.txt .
# 我们将创建一个新的 docker_entrypoint.sh，稍后创建这个文件
COPY docker_entrypoint.sh .

# 安装 Python 依赖
RUN pip3 install --no-cache-dir -r requirements.txt

# 确保脚本可执行
RUN chmod +x create_warp_pool.sh docker_entrypoint.sh

# 暴露端口 (这些是 proxy_manager.py 监听的端口)
# SOCKS5 代理端口
EXPOSE 10880
# HTTP API 端口
EXPOSE 5000

# 设置入口点
ENTRYPOINT ["/app/docker_entrypoint.sh"]