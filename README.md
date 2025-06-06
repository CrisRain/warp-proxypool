# WARP 动态代理池管理器

本项目是一个基于 Cloudflare WARP 的动态 SOCKS5 代理池管理器。它通过在独立的网络命名空间中创建和管理多个 WARP 实例，提供一个统一的 SOCKS5 代理入口和一个 HTTP API，以实现动态获取、释放和轮换出口 IP 地址的功能。

## ✨ 功能特性

- **代理池管理**: 自动创建和管理一组 WARP 代理实例。
- **统一入口**: 提供一个中央 SOCKS5 代理服务器，客户端只需连接此服务器即可使用代理池。
- **动态 IP**: 每次通过 SOCKS5 建立新连接或通过 API 请求时，都会从池中获取一个可用的 WARP 实例，从而实现出口 IP 的轮换。
- **IP 自动刷新**: 代理在使用完毕并释放后，会自动触发 WARP 的重连机制以刷新出口 IP。
- **HTTP API**: 提供 RESTful API 用于获取、释放和监控代理池状态。
- **容器化部署**: 支持使用 Docker 和 Docker Compose 进行一键部署，简化了环境配置。
- **原生部署**: 同时提供在物理机或虚拟机上直接运行的脚本。

## 🏗️ 工作原理

项目核心由 `proxy_manager.py` 脚本驱动，其主要工作流程如下：

1.  **WARP 实例创建**: `create_warp_pool.sh` 脚本（在 Docker 环境或本地环境中被调用）会创建多个网络命名空间（如 `ns0`, `ns1`, ...），并在每个命名空间内独立运行一个 Cloudflare WARP 实例。每个 WARP 实例都以 SOCKS5 模式监听在不同的本地端口上（如 `40000`, `40001`, ...）。
2.  **中央 SOCKS5 服务器**: `proxy_manager.py` 启动一个中央 SOCKS5 服务器（默认监听在 `10880` 端口）。
3.  **代理调度**: 当客户端通过中央 SOCKS5 服务器发起连接请求时，管理器会从可用的 WARP 代理池中取出一个实例，并将客户端的流量转发至该实例。连接断开后，该 WARP 实例会被释放，并触发 IP 刷新，然后重新回到可用池中。
4.  **API 管理**: `proxy_manager.py` 同时启动一个 Flask HTTP 服务器（默认监听在 `5000` 端口），提供 API 接口来手动管理和监控代理池。

## 🚀 如何使用

您可以选择 Docker 容器化部署（推荐）或在 Linux 主机上原生部署。

### 🐳 Docker 部署 (推荐)

这是最简单、最推荐的部署方式，可以避免复杂的环境依赖问题。

**前提条件**:
*   已安装 [Docker](https://www.docker.com/)
*   已安装 [Docker Compose](https://docs.docker.com/compose/install/)

**启动步骤**:

1.  克隆或下载本项目。
2.  在项目根目录下，执行以下命令来构建并启动服务：

    ```bash
    docker-compose up --build -d
    ```
3.  服务启动后：
    *   **SOCKS5 代理** 将监听在 `10880` 端口。
    *   **HTTP API** 将监听在 `5000` 端口。

**查看日志**:
```bash
docker-compose logs -f
```

**停止服务**:
```bash
docker-compose down
```

### 🐧 Linux 原生部署

如果您希望直接在物理机或虚拟机上运行。

**前提条件**:
*   一个基于 Debian/Ubuntu 的 Linux 系统。
*   已安装 `python3`, `python3-pip`, `curl`, `iproute2`。
*   拥有 `sudo` 权限。
*   已根据 [Cloudflare 官方文档](https://pkg.cloudflareclient.com/) 安装 `warp-cli`。

**启动步骤**:

1.  克隆或下载本项目。
2.  为所有 shell 脚本添加可执行权限：
    ```bash
    chmod +x *.sh
    ```
3.  执行启动脚本。该脚本会自动完成创建 WARP 实例、设置 Python 虚拟环境、安装依赖和启动管理服务的所有步骤。
    ```bash
    sudo ./start_proxy_pool.sh
    ```
4.  服务将在后台运行，日志默认输出到 `proxy_manager.log` 文件。

## 🔌 API 端点

API 服务器默认运行在 `http://127.0.0.1:5000`。

---

### `GET /status`

获取当前代理池的状态。

**成功响应**: `200 OK`
```json
{
    "available_backend_ports_count": 5,
    "available_backend_ports_list": [
        40000,
        40001,
        40002,
        40003,
        40004
    ],
    "backend_warp_pool_size": 5,
    "central_socks5_server_listening_on": "0.0.0.0:10880",
    "in_use_backend_ports_count": 0,
    "in_use_backend_ports_details": {}
}
```

---

### `GET /acquire`

**注意**: 此 API 主要用于与中央 SOCKS5 服务器配合使用。它本身不返回一个可直接使用的代理地址，而是授权客户端在接下来的一段时间内使用中央 SOCKS5 代理。

**成功响应**: `200 OK`
```json
{
    "backend_port_token_for_release": 40000,
    "message": "Connect to the central SOCKS5 server at '127.0.0.1:10880'. Use 'backend_port_token_for_release' (40000) when calling /release.",
    "proxy_to_use": "socks5://127.0.0.1:10880"
}
```
*   `proxy_to_use`: 提示您应该连接的中央 SOCKS5 服务器地址。
*   `backend_port_token_for_release`: 在调用 `/release` 接口时需要用到的凭证。

---

### `POST /release/<int:backend_port_token>`

释放一个通过 `/acquire` 获取的代理，并触发后台 IP 刷新。

**URL 参数**:
*   `backend_port_token`: 调用 `/acquire` 时获取到的 `backend_port_token_for_release` 值。

**成功响应**: `200 OK`
```json
{
    "status": "Release and IP refresh initiated for backend port 40000"
}
```

## ⚙️ 配置

主要的配置项位于以下文件中：

*   `proxy_manager.py`:
    *   `POOL_SIZE`: WARP 代理池的大小，默认为 `5`。
    *   `BACKEND_BASE_PORT`: 后端 WARP 实例的起始端口，默认为 `40000`。
    *   `SOCKS_SERVER_PORT`: 中央 SOCKS5 服务器的监听端口，默认为 `10880`。
*   `create_warp_pool.sh`:
    *   `NUM_INSTANCES`: 要创建的 WARP 实例数量，**必须与 `proxy_manager.py` 中的 `POOL_SIZE` 保持一致**。
    *   `BASE_PORT`: WARP SOCKS5 监听的起始端口，**必须与 `proxy_manager.py` 中的 `BACKEND_BASE_PORT` 保持一致**。