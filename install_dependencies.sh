#!/bin/bash
# 安装系统依赖
sudo apt update
sudo apt install -y net-tools iproute2 python3-pip python3-venv

# 安装Cloudflare WARP
curl https://pkg.cloudflareclient.com/pubkey.gpg | sudo gpg --yes --dearmor --output /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg
echo "deb [arch=amd64 signed-by=/usr/share/keyrings/cloudflare-warp-archive-keyring.gpg] https://pkg.cloudflareclient.com/ $(lsb_release -cs) main" | sudo tee /etc/apt/sources.list.d/cloudflare-client.list
sudo apt update && sudo apt install -y cloudflare-warp

# 初始化WARP
warp-cli register
warp-cli set-mode proxy