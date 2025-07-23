# 使用Ubuntu作为基础镜像，因为项目需要完整的Linux工具集
FROM ubuntu:22.04

# 避免在安装过程中出现交互式提示
ARG DEBIAN_FRONTEND=noninteractive

# 设置标签
LABEL maintainer="crisrain"
LABEL description="WARP Proxy Pool Manager"

# 设置工作目录
WORKDIR /app

# 安装项目依赖
RUN apt-get update && apt-get install -y \
    curl \
    gnupg \
    iptables \
    iproute2 \
    python3 \
    python3-pip \
    python3-venv \
    sudo \
    && rm -rf /var/lib/apt/lists/*

# 安装Cloudflare WARP客户端
# 对于Ubuntu 22.04 (jammy)，直接使用确定的发行版代号
RUN curl https://pkg.cloudflareclient.com/pubkey.gpg | gpg --yes --dearmor --output /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg \
    && echo "deb [signed-by=/usr/share/keyrings/cloudflare-warp-archive-keyring.gpg] https://pkg.cloudflareclient.com/ jammy main" | tee /etc/apt/sources.list.d/cloudflare-client.list \
    && apt-get update \
    && apt-get install -y cloudflare-warp \
    && rm -rf /var/lib/apt/lists/*

# 创建WARP配置目录并设置权限
RUN mkdir -p /var/lib/cloudflare-warp \
    && chmod 700 /var/lib/cloudflare-warp

# 创建一个脚本来自动生成WARP配置并接受服务条款
RUN echo '#!/bin/bash\n\
mkdir -p /var/lib/cloudflare-warp\n\
chmod 700 /var/lib/cloudflare-warp\n\
touch /var/lib/cloudflare-warp/reg.json\n\
chmod 600 /var/lib/cloudflare-warp/reg.json\n\
echo "{\n\
  \"accept_tos\": true,\n\
  \"tos_accepted_at\": \"$(date -Iseconds)\",\n\
  \"effective_config\": {\n\
    \"tos_accepted_at\": \"$(date -Iseconds)\"\n\
  }\n\
}" > /var/lib/cloudflare-warp/reg.json' > /usr/local/bin/setup-warp-tos.sh \
    && chmod +x /usr/local/bin/setup-warp-tos.sh

# 复制项目文件
COPY . .

# 安装Python依赖
RUN pip3 install -r requirements.txt

# 创建warp用户并设置权限
RUN useradd -m -s /bin/bash warp \
    && echo "warp ALL=(ALL) NOPASSWD: ALL" >> /etc/sudoers

# 设置脚本权限
RUN chmod +x manage_pool.sh src/proxy_manager.py

# 创建必要的目录
RUN mkdir -p /var/lib/warp-configs /run/warp-sockets /var/log \
    && chown -R warp:warp /var/lib/warp-configs /run/warp-sockets /var/log

# 切换到warp用户
USER warp

# 暴露API端口和SOCKS5端口
EXPOSE 5000 10880

# 设置默认命令，在启动时先运行WARP服务条款设置脚本
CMD ["/bin/bash", "-c", "setup-warp-tos.sh && ./manage_pool.sh start --foreground"]