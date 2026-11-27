<!-- source: docs/server-deployment.md @ 4b8025c0929d0486b01816e00591fe60b5604b71 -->

[English](../server-deployment.md) | 简体中文

# Tacit 中枢服务端独立部署指南

本文档说明如何把 Tacit 中枢（Hub）单独部署在自己的 Linux 服务器或装了 Docker 的电脑上（24 小时在线），再由 Mac、Android 等设备经加密协议连接。Windows 电脑见[第 7 节](#7-windows-电脑docker-desktop)。

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

## 2. 获取镜像并启动容器

每个 Mac 版本发布时，同一份后台代码的镜像也会推到 GitHub Container Registry（`linux/amd64`、`linux/arm64`），版本号和 Mac 版一致：

```bash
docker pull ghcr.io/jinsooo/tacit-hub:<版本号>
docker tag ghcr.io/jinsooo/tacit-hub:<版本号> tacit-hub:local
```

也可以在仓库根目录自己构建：

```bash
docker build -f hub/Dockerfile -t tacit-hub:local .
```

服务器和 Mac 上的 Tacit 最好用同一个版本；两边靠设备协议兼容，版本不同时以 Release 说明为准。

### 方式一：`docker run`

```bash
docker run -d \
  --name tacit-hub \
  --hostname tacit-hub \
  --restart unless-stopped \
  -e TZ=Asia/Shanghai \
  -p 47824:47824 \
  -v /srv/tacit-data:/data \
  -v /etc/tacit/master.key:/run/secrets/tacit_master_key:ro \
  tacit-hub:local
```

`--hostname` 是设备上显示的后台名字，不设就是一串容器编号。

单容器入口为 `bun hub/src/cli.ts run`，会同时托管 `serve`（网络服务）与 `distill`（后台整理）两个子进程，转发 `SIGTERM`/`SIGINT` 并在异常退出时按退避自动重启。

### 方式二：Docker Compose 示例

```yaml
services:
  tacit-hub:
    image: tacit-hub:local
    hostname: tacit-hub
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

在正在运行的容器里执行 `pair --role admin`，`--address` 填设备能访问到的服务器地址和端口（内网 IP、Tailscale IP 或反向代理后的 https 地址）：

```bash
docker exec -it tacit-hub bun hub/src/cli.ts pair --role admin --address http://192.168.1.20:47824
```

不加 `--address` 时，邀请里只有容器自己看到的地址（如 `172.17.0.3`），设备连不上。

命令会输出一条一次性的 `tacit://pair?d=...` 配对链接（`admin` 邀请 **5 分钟**内有效；`collect` 和 `view` 邀请 10 分钟内有效）。在 Mac 上打开 Tacit，在 **设置 › 后台与连接 › 连接远端后台** 中粘贴这条链接，按向导完成切换，这台 Mac 即成为管理设备。

如果希望配对时同时开通或附带中转信箱，可加 `--relay` 参数：

```bash
docker exec -it tacit-hub bun hub/src/cli.ts pair --role admin --address http://192.168.1.20:47824 --relay https://relay.example.com
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

- **推荐放在 Tailscale / WireGuard 等私网之后，或通过[中转信箱](../../relay/README.zh-CN.md)同步**。
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

---

## 7. Windows 电脑（Docker Desktop）

Windows 10/11 可以用 Docker Desktop（WSL 2 后端）运行同一个镜像。和 Linux 有三处不同，下面的命令都在 PowerShell 里执行：

- **根密钥和数据都放进 Docker 卷，不要挂 Windows 目录。** 从 Windows 目录挂进容器的文件在容器里一律显示为 root 所有、权限 `0777`，中枢会以“根密钥权限过宽”拒绝启动；SQLite 放在 Windows 目录上也慢且不可靠。
- **要有人登录着这台电脑。** Docker Desktop 只在用户登录后运行；在 Docker Desktop 设置里勾选“登录 Windows 时启动 Docker Desktop”，容器用 `--restart unless-stopped` 会随它自动起来。用 SSH 远程启动的 Docker Desktop 在 SSH 断开后会停，也拉不了镜像（读不到 Windows 凭据），不要这样当常驻服务。
- 局域网里的设备连不上时，检查 Windows 防火墙是否放行了 47824 端口。

1. 安装 Docker Desktop，确认 `docker info` 能输出版本，并按第 2 节拉取或构建镜像 `tacit-hub:local`。
2. 在 Docker 卷里生成根密钥，再启动容器：

   ```powershell
   docker volume create tacit-key
   docker volume create tacit-data
   docker run --rm -u 0 -v tacit-key:/key --entrypoint sh tacit-hub:local -c 'umask 077; head -c 32 /dev/urandom | od -An -tx1 -v | tr -d " \n" > /key/master.key; chown bun:bun /key/master.key; chmod 400 /key/master.key'
   docker run -d --name tacit-hub --hostname tacit-hub --restart unless-stopped `
     -e TZ=Asia/Shanghai `
     -e RA_MASTER_KEY_FILE=/run/secrets/tacit/master.key `
     -p 47824:47824 `
     -v tacit-data:/data `
     -v tacit-key:/run/secrets/tacit:ro `
     tacit-hub:local
   ```

3. 把根密钥抄进密码管理器（它只在 `tacit-key` 卷里，删卷或重装 Docker 就没了）：

   ```powershell
   docker run --rm -v tacit-key:/key:ro --entrypoint cat tacit-hub:local /key/master.key
   ```

4. 用这台电脑的局域网或 Tailscale 地址生成管理邀请，到 Mac 上粘贴（同第 4 节）：

   ```powershell
   docker exec tacit-hub bun hub/src/cli.ts pair --role admin --address http://192.168.1.20:47824
   ```

5. 连上后在 Mac 设置的“AI 模型”里配置 API 模型和 Key，写入的是这台服务器。
