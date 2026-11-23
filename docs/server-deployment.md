# Tacit 中枢服务端独立部署指南

本文档说明如何把 Tacit 中枢（Hub）单独部署在自己的 Linux 服务器或 Docker 主机上（24 小时在线），再由 Mac、Android 等设备经加密协议连接。

独立部署模式下（`RA_HUB_MODE=server`，非 macOS 系统默认启用）：

- 仅常开加密设备端口（默认 `0.0.0.0:47824`，可通过 `RA_LAN_PORT` 修改），只提供 `/v1/device/hello`、`/v1/device`、`/v1/device/events`。
- 默认关闭 `127.0.0.1` 的明文管理端口与网页端，绝不在 `0.0.0.0` 上暴露任何 Bearer token 管理接口。
- 仅支持 API 模型（`anthropic` 与 `openai-compatible`），不支持 `claude-cli` / `codex-cli`；未配置 `models.json` 时整理会保持暂停并在状态中注明原因。
- 所有密钥（数据库密钥、设备密钥、模型 API Key、中转信箱令牌）统一用外部只读根密钥加密后存放在数据目录的 `secrets.enc` 中。

---

## 1. 生成根密钥文件（务必与数据目录分开备份）

根密钥是 32 字节（64 位十六进制）随机数，**永远由你创建并提供，中枢绝不会自动生成**。

在数据目录**之外**的位置生成根密钥文件，并限制权限为 `0400`（容器内运行用户为 `bun`，UID/GID 为 `1000`）：

```bash
mkdir -p /etc/tacit /srv/tacit-data
openssl rand -hex 32 > /etc/tacit/master.key
chown 1000:1000 /etc/tacit/master.key /srv/tacit-data
chmod 0400 /etc/tacit/master.key
chmod 0700 /srv/tacit-data
```

> **重要备份原则**
> - **根密钥文件和数据目录必须分开备份、存放在不同地方**（例如根密钥存进密码管理器或离线介质，数据目录按常规备份）。
> - **不要把根密钥文件放进 `/srv/tacit-data`（`RA_DATA_DIR`）内**——中枢启动时会主动校验并拒绝启动。
> - **根密钥一旦丢失，加密的 `secrets.enc` 和 `history.db` 无法恢复**。
> - 根密钥缺失、权限过宽或与现有 `secrets.enc` 不匹配时，中枢会直接拒绝启动，绝不会新建密钥覆盖数据。

---

## 2. 构建镜像并启动容器

在仓库根目录构建镜像：

```bash
docker build -f hub/Dockerfile -t tacit-hub:local .
```

### 方式一：`docker run`

```bash
docker run -d \
  --name tacit-hub \
  --restart unless-stopped \
  -e TZ=Asia/Shanghai \
  -p 47824:47824 \
  -v /srv/tacit-data:/data \
  -v /etc/tacit/master.key:/run/secrets/tacit_master_key:ro \
  tacit-hub:local
```

单容器入口为 `bun hub/src/cli.ts run`，会同时托管 `serve`（网络服务）与 `distill`（后台整理）两个子进程，转发 `SIGTERM`/`SIGINT` 并在异常退出时按退避自动重启。

### 方式二：Docker Compose 示例

```yaml
services:
  tacit-hub:
    image: tacit-hub:local
    build:
      context: .
      dockerfile: hub/Dockerfile
    restart: unless-stopped
    environment:
      TZ: Asia/Shanghai
      RA_LAN_PORT: "47824"
    ports:
      # 建议仅绑定 Tailscale 或内网网卡 IP，不建议直接暴露在公网
      - "100.64.0.10:47824:47824"
    volumes:
      - /srv/tacit-data:/data
    secrets:
      - source: tacit_master_key
        target: /run/secrets/tacit_master_key
        uid: "1000"
        gid: "1000"
        mode: 0400

secrets:
  tacit_master_key:
    file: /etc/tacit/master.key
```

---

## 3. 时区设置

中枢按本地自然日切分时间线、统计当日模型用量和触发每日整理，服务端**必须显式设置时区**，支持以下任一方式（优先级从高到低）：

1. **环境变量 `TZ`**（推荐）：例如 `-e TZ=Asia/Shanghai`。
2. **`/data/hub.json` 的 `timezone` 字段**：写入合法的 IANA 时区名，例如：
   ```json
   {
     "timezone": "Asia/Shanghai"
   }
   ```

如果两处都没有配置，且容器进程时区为 UTC，中枢启动时会向标准错误输出一条告警，并在状态接口的 `timezone.warning` 字段给出提示。

---

## 4. 配对首台管理设备（`admin`）

在正在运行的容器里执行 `pair --role admin`：

```bash
docker exec -it tacit-hub bun hub/src/cli.ts pair --role admin
```

命令会输出一条一次性的 `tacit://pair?d=...` 配对链接（`admin` 邀请 **5 分钟**内有效；`collect` 和 `view` 邀请 10 分钟内有效）。将链接交给你的 Mac 客户端完成配对即可成为管理员设备。

如果希望配对时同时开通或附带中转信箱，可加 `--relay` 参数：

```bash
docker exec -it tacit-hub bun hub/src/cli.ts pair --role admin --relay https://relay.example.com
```

其他常用的本机设备运维命令（直接操作数据库）：

```bash
docker exec -it tacit-hub bun hub/src/cli.ts devices list
docker exec -it tacit-hub bun hub/src/cli.ts devices set-role <device_id> <collect|view|admin> [--force]
docker exec -it tacit-hub bun hub/src/cli.ts devices remove <device_id> [--force]
```

> 仅在需要通过 SSH 隧道排障时，才可在启动命令后附加 `--local-status-port <port>`，让 `127.0.0.1:<port>` 在容器内短暂开放本机排障接口；日常运行无需开启。

---

## 5. 网络接入建议

- **推荐放在 Tailscale / WireGuard 等私网之后，或通过中转信箱（Relay）同步**。
- **不建议直接把 47824 端口暴露到公网**：虽然设备协议已自带应用层 HPKE 端到端加密与 X25519 双向认证，反向代理无法窥探明文也无法伪造请求，但公网直连仍会暴露服务器 IP 和访问时序元数据。若确需公网访问，请在前方套一层 HTTPS 反向代理（如 Caddy、Nginx 或 Cloudflare Tunnel）并转发到设备端口。

---

## 6. 从旧 Mac 中枢迁移到服务器

如果想保留原有 Mac 上的全部记录和整理结果，按以下顺序操作（顺序不可颠倒）：

1. **导出旧 Mac 的数据库密钥**（在旧 Mac 终端执行，记住输出中 `db-key` 的 64 位十六进制值）：
   ```bash
   bun hub/src/cli.ts keys export
   ```
2. **停止旧 Mac 中枢**，避免拷贝期间写入导致数据库不一致：
   - 在旧 Mac 上退出 Tacit 或停止对应后台服务（确认已没有 `hub` / `distill` 进程在读写 `history.db`）。
3. **拷贝 `history.db` 到服务器数据目录**：
   - 将旧 Mac 的 `~/Library/Application Support/record-anything/history.db` 拷贝到服务器的 `/srv/tacit-data/history.db`，并确保权限为 `0600`、属主为 `1000:1000`。
   - 如果此前已在 Mac 上配置过 API 模型，也可以按需把 `models.json` 拷过去（确保其中只使用 `anthropic` 或 `openai-compatible`，不含 `claude-cli`/`codex-cli`）。
4. **把原 `db-key` 导入服务器 `secrets.enc`**（经标准输入传入，不落命令行参数，也不会回显）：
   ```bash
   printf '%s' '<旧 Mac 导出的 db-key 十六进制值>' | \
     docker run --rm -i \
       -v /srv/tacit-data:/data \
       -v /etc/tacit/master.key:/run/secrets/tacit_master_key:ro \
       tacit-hub:local \
       bun hub/src/cli.ts keys import-db-key
   ```
   命令会先用该密钥只读校验 `/data/history.db` 能否解开，验证通过后才写入 `/data/secrets.enc`。
5. **启动服务器容器并配对首台 `admin` Mac**：
   - 按第 2 节启动容器，再按第 4 节执行 `pair --role admin` 配对你的 Mac。
6. **配置 API 模型与 API Key**：
   - 服务端不自动回退到 CLI 模型；确保 `/data/models.json` 已配置 `anthropic` 或 `openai-compatible`，并设置对应的模型 API Key 后，后台整理会自动恢复。
7. **验证数据完整后，停用旧 Mac 上的本机中枢自启**。
