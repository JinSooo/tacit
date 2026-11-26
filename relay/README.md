[English](README.en.md) | 简体中文

# Tacit 中转信箱

手机和 Mac 不在同一网络、或 Mac 合盖时，手机把加密信封投进信箱，Mac 醒来再取。信箱只经手端到端加密的密文，看得到消息的时间和大小，看不到内容。协议见 `docs/contracts.md` 6.8。

一套代码，两种部署：

## Cloudflare（Workers 免费档）

需要一个 Cloudflare 账号和一个托管在 Cloudflare 的域名（`workers.dev` 默认地址在一些网络里连不上，配置里已关闭）。在 `relay/` 目录里：

```sh
npx wrangler@4 deploy --route 'relay.example.com/*' --var TACIT_RELAY_CREATE_CODE:<自己定的开通码>
```

不设开通码就是公共信箱：任何人都能开通空间，只受每天开通次数和限额约束。

## Docker

```sh
docker build -t tacit-relay relay
docker run -d --name tacit-relay -p 8787:8787 -v tacit-relay:/data \
  -e TACIT_RELAY_CREATE_CODE=<自己定的开通码> tacit-relay
```

信箱只认 HTTPS，放在 Caddy、Nginx 之类的反向代理后面，并设 `TACIT_RELAY_IP_HEADER=X-Forwarded-For` 让开通限流拿到真实 IP。

## 限额

环境变量（括号里是公共信箱的默认值）：`TACIT_RELAY_MESSAGE_BYTES`（1 MiB）、`TACIT_RELAY_SPACE_BYTES`（100 MiB）、`TACIT_RELAY_RETENTION_DAYS`（30）、`TACIT_RELAY_IDLE_DAYS`（90）、`TACIT_RELAY_DAILY_REQUESTS`（20000）、`TACIT_RELAY_SPACES_PER_IP`（3）。

## 开发

```sh
bun test relay/
bun relay/src/bun.ts   # 本机起一个，默认 :8787，库在 /data/relay.db，可用 TACIT_RELAY_DB 改
```
