# WARP Proxy Pool

[![Docker Image CI](https://github.com/CrisRain/warp-proxypool/actions/workflows/docker-image.yml/badge.svg)](https://github.com/CrisRain/warp-proxypool/actions/workflows/docker-image.yml)

这是一个功能强大的WARP代理池项目，旨在通过创建和管理多个Cloudflare WARP实例来提供高可用、高性能的SOCKS5代理服务。它利用Linux网络命名空间（Network Namespace）和`iptables`技术，为每个WARP实例创建一个完全隔离的网络环境，从而实现独立的IP出口。

项目核心是一个用Python Flask编写的智能调度器，它不仅提供了一个中央SOCKS5代理入口，能自动将客户端请求路由到可用的后端WARP实例，还提供了一套RESTful API，允许客户端动态地获取和释放代理，并在释放后自动刷新IP地址，确保IP资源的高效利用和更新。

## ✨ 主要特性

- **多实例代理池**: 自动创建和管理一个由多个WARP实例组成的代理池。
- **完全隔离**: 每个WARP实例运行在独立的网络命名空间中，拥有独立的网络栈和出口IP。
- **智能SOCKS5调度**: 内置一个中央SOCKS5服务器，可自动从代理池中选择一个可用的WARP实例进行连接。
- **动态API管理**:
    - **获取/释放**: 提供RESTful API来动态获取和释放代理。
    - **自动IP刷新**: 释放代理后，会自动在后台为该实例刷新IP地址，然后将其重新加入可用池。
- **强大的管理脚本**: 提供一个统一的`manage_pool.sh`脚本，用于启动、停止、重启、清理和查看整个代理池的状态。
- **Docker化部署**: 提供`Dockerfile`和`docker-compose.yml`，支持一键式容器化部署。
- **灵活配置**: 支持通过环境变量自定义代理池大小、端口、WARP许可证密钥等。
- **健壮的iptables管理**: 自动创建和清理所有必需的`iptables`规则，确保流量被正确转发。

## 🚀 工作原理

![架构图](https://raw.githubusercontent.com/CrisRain/warp-proxypool/main/assets/arch.png)

1.  **实例创建**: `manage_pool.sh`脚本创建指定数量的网络命名空间（例如`ns0`, `ns1`, ...）。
2.  **网络隔离**: 为每个命名空间创建一对`veth`（虚拟以太网）设备，一端连接到主机，另一端在命名空间内部，从而建立独立的网络环境。
3.  **WARP运行**: 在每个命名空间内，启动一个独立的`warp-cli`进程，并设置为代理模式，监听一个内部端口（例如`40000`, `40001`, ...）。
4.  **流量转发**: `iptables`规则被设置为将主机上的特定端口（例如`10800`, `10801`, ...）的入站TCP流量`DNAT`到对应命名空间内的WARP代理端口。
5.  **代理管理器**: `proxy_manager.py`脚本启动：
    - 一个**Flask API服务器**，用于处理代理的获取（`/acquire`）和释放（`/release`）请求。
    - 一个**中央SOCKS5服务器**（默认监听`10880`端口），它会从可用代理池中选择一个后端WARP实例来转发客户端的SOCKS5请求。
6.  **生命周期管理**:
    - **直接使用SOCKS5**: 客户端直接连接中央SOCKS5服务器，管理器会自动分配一个后端实例，使用完毕后自动释放并触发IP刷新。
    - **通过API使用**: 客户端通过API获取一个代理（API返回中央SOCKS5服务器地址），使用完毕后调用API释放。释放后，该实例的IP将被刷新并重新加入可用池。

## ⚙️ 环境要求

- **操作系统**: Linux (需要支持网络命名空间和`iptables`)
- **依赖**: `curl`, `iptables`, `iproute2`, `python3`, `sudo`
- **推荐**: Docker 和 Docker Compose

## 快速开始

### 使用 Docker Compose (推荐)

这是最简单、最推荐的部署方式。

1.  **克隆项目**:
    ```bash
    git clone https://github.com/CrisRain/warp-proxypool.git
    cd warp-proxypool
    ```

2.  **配置环境变量**:
    创建一个`.env`文件，并根据需要设置以下变量：
    ```env
    # (必须) 设置一个安全的API访问令牌
    API_SECRET_TOKEN=your_super_secret_token_here

    # (可选) 代理池的大小，默认为3
    POOL_SIZE=5

    # (可选) 代理池的起始端口，默认为10800
    # 代理将监听从 BASE_PORT 到 BASE_PORT + POOL_SIZE - 1 的端口
    BASE_PORT=10800

    # (可选) 你的WARP+许可证密钥，以获取更好的性能
    WARP_LICENSE_KEY=YOUR_WARP_PLUS_LICENSE_KEY

    # (可选) 自定义WARP端点IP和端口
    # WARP_ENDPOINT=162.159.192.1:2408
    ```

3.  **启动服务**:
    ```bash
    docker-compose up -d
    ```

4.  **查看状态**:
    ```bash
    docker-compose logs -f
    ```

### 使用 `manage_pool.sh` 脚本 (手动部署)

如果你希望在主机上直接运行，可以使用管理脚本。

1.  **克隆项目**:
    ```bash
    git clone https://github.com/CrisRain/warp-proxypool.git
    cd warp-proxypool
    ```

2.  **安装依赖**:
    确保你已经安装了`curl`, `iptables`, `iproute2`, `python3`, `python3-pip`, `sudo`。

3.  **设置环境变量 (可选)**:
    你可以在运行脚本前导出环境变量来覆盖默认配置。
    ```bash
    export POOL_SIZE=5
    export BASE_PORT=10800
    export API_SECRET_TOKEN="your_secret_token"
    ```

4.  **启动服务**:
    脚本需要`sudo`权限来管理网络资源。
    ```bash
    sudo ./manage_pool.sh start
    ```

## 📖 使用方法

### 1. 直接使用中央SOCKS5代理

你可以将你的应用程序直接配置为使用中央SOCKS5代理。管理器会自动处理后端实例的分配和回收。

- **地址**: `127.0.0.1` (或你的服务器IP)
- **端口**: `10880` (默认)

每次新的SOCKS5连接都会从池中获取一个可用的WARP实例。连接断开后，该实例会被自动释放，并触发后台IP刷新任务。

### 2. 通过API管理代理

通过API，你可以获得对代理生命周期更精细的控制。

#### 获取API令牌

API使用Bearer Token进行认证。令牌通过环境变量`API_SECRET_TOKEN`设置。如果未设置，系统会在启动时生成一个临时令牌并显示在日志中。

#### API端点

- **`GET /status`**: 获取代理池的当前状态。
- **`GET /acquire`**: 获取一个可用的代理。
- **`POST /release/<backend_port_token>`**: 释放一个已获取的代理并触发IP刷新。

#### 使用示例 (`curl`)

假设API服务运行在`http://127.0.0.1:5000`，你的令牌是`mysecret`。

1.  **查看状态**:
    ```bash
    curl http://127.0.0.1:5000/status
    ```

2.  **获取一个代理**:
    ```bash
    curl -X GET http://127.0.0.1:5000/acquire \
         -H "Authorization: Bearer mysecret"
    ```
    **成功响应**:
    ```json
    {
      "proxy_to_use": "socks5://127.0.0.1:10880",
      "backend_port_token_for_release": 10801,
      "message": "请连接到中央SOCKS5服务器 '127.0.0.1:10880'。 调用 /release 接口时请使用 'backend_port_token_for_release' (10801)。"
    }
    ```
    **注意**: API返回的是**中央SOCKS5服务器地址**。你的请求将被路由到为你分配的后端实例（此例中是`10801`对应的实例）。

3.  **释放代理**:
    当你使用完代理后，使用上一步获取的`backend_port_token_for_release`来释放它。
    ```bash
    curl -X POST http://127.0.0.1:5000/release/10801 \
         -H "Authorization: Bearer mysecret"
    ```
    **成功响应**:
    ```json
    {
      "status": "已为后端端口 10801 发起释放和IP刷新流程"
    }
    ```
    释放后，该实例将进入IP刷新流程，成功后会重新加入可用代理池。

## 🛠️ 管理脚本 `manage_pool.sh`

`manage_pool.sh`是管理服务生命周期的核心工具。

**用法**: `sudo ./manage_pool.sh <命令>`

- **`start`**: 启动整个服务。如果已有资源存在，会先清理再创建。
- **`stop`**: 停止API服务并清理所有网络资源（命名空间、iptables规则等）。
- **`restart`**: 重启服务（相当于`stop`后`start`）。
- **`status`**: 检查API服务和每个代理实例的运行状态。
- **`cleanup`**: 仅清理所有网络资源，不停止正在运行的API服务。
- **`start-api`**: 仅启动API服务（假设网络资源已存在）。
- **`stop-api`**: 仅停止API服务。
- **`refresh-ip <namespace> <index>`**: 手动刷新指定命名空间实例的IP。

## 📄 许可证

本项目根据 [MIT License](LICENSE) 授权。