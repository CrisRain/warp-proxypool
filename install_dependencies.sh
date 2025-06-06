#!/bin/bash
# 安装系统依赖
sudo apt update
sudo apt install -y net-tools iproute2 python3-pip python3-venv

# 安装Cloudflare WARP
curl https://pkg.cloudflareclient.com/pubkey.gpg | sudo gpg --yes --dearmor --output /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg
echo "deb [arch=amd64 signed-by=/usr/share/keyrings/cloudflare-warp-archive-keyring.gpg] https://pkg.cloudflareclient.com/ $(lsb_release -cs) main" | sudo tee /etc/apt/sources.list.d/cloudflare-client.list
sudo apt update && sudo apt install -y cloudflare-warp

# 初始化WARP的步骤已移至 create_warp_pool.sh 中，
# 在独立的网络命名空间中执行，以避免污染全局环境。
# 此处仅确保 warp-cli 命令可用即可。
echo "✅ Cloudflare WARP 客户端安装完成。"
echo "ℹ️  请注意：WARP的注册和配置将在启动代理池时在独立的网络命名空间中自动完成。"