# WARP 代理池管理器 (WARP Proxy Pool Manager)

## 1. 项目简介

本项目是一个功能强大的 WARP 代理池管理解决方案。它通过创建多个相互隔离的 Cloudflare WARP 实例，并提供一个统一的 API 和 SOCKS5 接口，来为您的应用程序提供高可用、可轮换的出口代理。

核心功能包括：
- **多实例隔离:** 利用网络命名空间为每个 WARP 实例提供完全隔离的运行环境。
- **统一访问入口:** 通过一个中央 SOCKS5 代理和一套 RESTful API 来管理和使用所有后端代理。
- **自动 IP 轮换:** 在每次代理使用结束后，系统会自动刷新其 IP 地址，确保出口 IP 的多样性。
- **生命周期管理:** 提供一个健壮的 `manage_pool.sh` 脚本来处理整个代理池的创建、启动、停止和清理。
- **状态监控:** 可通过 API 实时查看代理池的状态。

## 2. 架构概述

本系统由两个核心组件构成：`manage_pool.sh` 和 `proxy_manager.py`。

- **`manage_pool.sh` (资源管理器):**
  这是一个 Bash 脚本，作为整个系统的基础。它负责所有底层资源的创建和管理，包括：
  - 创建网络命名空间 (`ns0`, `ns1`, ...)。
  - 在每个命名空间内独立运行 `warp-cli` 进程。
  - 配置 `iptables` 规则，将主机的特定端口（如 `10800`, `10801`）映射到对应的 WARP 实例。
  - 启动和停止 `proxy_manager.py` API 服务。

- **`proxy_manager.py` (服务管理器):**
  这是一个 Python 服务，提供面向应用的高层接口。它包含：
  - **一个 Flask API 服务器:** 用于显式地获取和释放代理。
  - **一个中央 SOCKS5 代理服务器:** 为客户端提供一个单一的、稳定的代理入口点。它会自动从后端池中选择一个可用实例进行连接。

- **`src/warp_pool_config.json` (配置文件):**
  这个文件是 `manage_pool.sh` 和 `proxy_manager.py` 之间的通信桥梁。`manage_pool.sh` 在创建好代理池后，会将每个实例的端口等信息写入此文件，`proxy_manager.py` 在启动时读取它来初始化代理池。

**工作流程:** `manage_pool.sh` 构建底层网络设施，然后启动 `proxy_manager.py` 来管理这些设施并为上层应用提供服务。

## 3. 安装与依赖

### 系统要求
在运行此项目之前，请确保您的系统 (推荐 Ubuntu/Debian) 已安装以下依赖：
- `warp-cli`: Cloudflare WARP 的官方命令行工具。
- `iptables`: 用于配置网络规则。
- `iproute2`: 提供 `ip` 命令，用于管理网络命名空间和设备。
- `python3` 和 `python3-venv`

### 安装依赖
项目所需的 Python 依赖项在 `requirements.txt` 中定义。`manage_pool.sh` 脚本会在首次启动时自动创建虚拟环境并安装它们。

如果您想手动安装，可以运行：
```bash
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
```

## 4. 使用方法

**重要提示:** `manage_pool.sh` 脚本的大部分命令都需要 `sudo` 权限来操作网络资源。

### 4.1. 管理代理池 (`manage_pool.sh`)

- **启动服务:**
  此命令会清理任何旧的配置，创建新的代理池，并启动 API 服务。
  ```bash
  sudo ./manage_pool.sh start
  ```

- **停止服务:**
  此命令会停止 API 服务并清理所有相关的网络资源（命名空间、iptables 规则等）。
  ```bash
  sudo ./manage_pool.sh stop
  ```

- **重启服务:**
  相当于 `stop` 后再 `start`。
  ```bash
  sudo ./manage_pool.sh restart
  ```

- **查看状态:**
  检查 API 服务和网络资源的当前状态。
  ```bash
  ./manage_pool.sh status
  ```

- **清理资源:**
  仅清理网络资源，不会停止正在运行的 API 服务。
  ```bash
  sudo ./manage_pool.sh cleanup
  ```

- **刷新WARP IP:**
  刷新指定命名空间的WARP IP地址。
  ```bash
  sudo ./manage_pool.sh refresh-ip ns0 0
  ```

### 4.2. 与 API 交互 (`proxy_manager.py`)

API 服务默认运行在 `5000` 端口。所有请求都需要一个安全令牌。

**安全令牌 (`API_SECRET_TOKEN`):**
为了安全，您必须在启动服务前设置一个环境变量 `API_SECRET_TOKEN`。
```bash
export API_SECRET_TOKEN="your-super-secret-and-long-token"
sudo -E ./manage_pool.sh start
```
**注意:** `sudo` 默认不会传递环境变量，使用 `-E` 选项来保留它们。

#### **端点:**

- **`GET /acquire`**
  获取一个代理的使用权。
  ```bash
  curl -X GET http://127.0.0.1:5000/acquire \
       -H "Authorization: Bearer your-super-secret-and-long-token"
  ```
  **成功响应:**
  ```json
  {
    "proxy_to_use": "socks5://127.0.0.1:10880",
    "backend_port_token_for_release": 10801,
    "message": "请连接到中央SOCKS5服务器 '127.0.0.1:10880'。 调用 /release 接口时请使用 'backend_port_token_for_release' (10801)。"
  }
  ```
  您的应用程序现在应该通过 `proxy_to_use` 指定的地址进行连接。请务必保存 `backend_port_token_for_release` 的值。

- **`POST /release/<backend_port_token>`**
  释放一个已获取的代理，并触发其 IP 刷新。
  ```bash
  curl -X POST http://127.0.0.1:5000/release/10801 \
       -H "Authorization: Bearer your-super-secret-and-long-token"
  ```
  **成功响应:**
  ```json
  {
    "status": "已为后端端口 10801 发起释放和IP刷新流程"
  }
  ```

- **`GET /status`**
  获取代理池的当前状态（此接口无需认证）。
  ```bash
  curl http://127.0.0.1:5000/status
  ```

### 4.3. 直接使用中央 SOCKS5 代理

对于不支持调用 API 的客户端，您可以直接将其 SOCKS5 代理设置为 API 服务器的地址和端口（默认为 `127.0.0.1:10880`）。`proxy_manager` 会在每次新连接时自动分配一个后端 WARP 实例，并在连接结束后自动释放和刷新它。

## 5. 安全注意事项

- **`sudo` 权限:** `manage_pool.sh` 脚本需要 `sudo` 权限来管理系统级的网络资源。请确保您信任此脚本。
- **`API_SECRET_TOKEN`:** 这个令牌是保护您 API 的关键。**切勿** 在生产环境中使用脚本自动生成的临时令牌。请务必设置一个强大、唯一的 `API_SECRET_TOKEN` 环境变量。任何能访问此 API 的人都可以使用您的代理资源。

## 6. Docker 支持

本项目支持通过Docker部署，这可以简化安装过程并提高环境一致性。预构建的镜像可通过 GitHub Packages 获取。

### 6.1. 使用预构建的Docker镜像

从GitHub Packages拉取预构建的镜像：

```bash
docker pull ghcr.io/crisrain/warp-proxypool:latest
```

### 6.2. 使用Docker运行

由于项目需要网络命名空间和iptables权限，必须以特权模式运行：

```bash
docker run -d \
  --name warp-proxy-pool \
  --privileged \
  --network host \
  -e API_SECRET_TOKEN="your-super-secret-and-long-token" \
  -e POOL_SIZE=3 \
  -e BASE_PORT=10800 \
  ghcr.io/crisrain/warp-proxypool:latest
```

### 6.3. 使用Docker Compose运行

创建一个 `.env` 文件来设置环境变量：

```bash
API_SECRET_TOKEN=your-super-secret-and-long-token
POOL_SIZE=3
BASE_PORT=10800
# 如果有WARP+许可证，可以设置
# WARP_LICENSE_KEY=your-license-key
```

然后运行：

```bash
docker-compose up -d
```

### 6.4. Docker环境变量

- `API_SECRET_TOKEN` (必需): API访问令牌
- `POOL_SIZE` (可选): 代理池大小，默认为3
- `BASE_PORT` (可选): SOCKS5代理的基础端口号，默认为10800
- `WARP_LICENSE_KEY` (可选): WARP+许可证密钥
- `WARP_ENDPOINT` (可选): 自定义WARP端点IP和端口
- `WARP_CONFIG_BASE_DIR` (可选): WARP配置目录，默认为`/var/lib/warp-configs`
- `WARP_IPC_BASE_DIR` (可选): WARP IPC目录，默认为`/run/warp-sockets`
- `WARP_LOG_FILE` (可选): 日志文件路径，默认为`/var/log/warp-pool.log`

### 6.5. 注意事项

1. **特权模式**: 由于项目需要操作网络命名空间和iptables规则，必须使用 `--privileged` 标志。
2. **主机网络**: 使用 `--network host` 以确保容器可以正确访问网络资源。
3. **系统模块**: 容器需要访问 `/lib/modules` 以加载必要的内核模块。
4. **持久化存储**: 使用Docker Compose时，配置、IPC和日志数据将存储在命名卷中，确保数据持久化。

### 6.6. 构建自己的Docker镜像

如果您需要构建自己的Docker镜像，可以使用项目中的Dockerfile：

```bash
docker build -t warp-proxy-pool .
```

注意：Dockerfile已经修复了`lsb_release`命令未找到的问题，现在可以正常构建。