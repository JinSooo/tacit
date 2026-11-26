<!-- source: hub/README.md @ 8e1cfedce415700b6af223afbba7b42b84eacfe2 -->

[English](README.md) | 简体中文

# Tacit 后台

Bun 后台负责接收文字记录、加密存储、全文搜索、整理调度，以及网页与 AI 工具接口。采集和系统权限由 Mac 端持有。完整请求格式与边界以 [接口契约](../docs/contracts.md) 为准。

在仓库根目录运行：

```sh
bun hub/src/cli.ts serve
bun hub/src/cli.ts run-plugin browser -- bun plugins/browser/main.ts
```

这些命令默认使用真实用户数据目录；开发或测试请通过 `RA_DATA_DIR` 指定独立目录，并设置独立的 `RA_DB_KEY`。不要对正式数据运行实验性导入或删除。

- 管理、网页和 MCP 接口仅监听 `127.0.0.1`。端口优先级为 `RA_PORT`、数据目录 `hub.json`、默认 `47823`。存在未过期的配对邀请或已配对设备时，另行开放加密的局域网设备端口（默认 `47824`，见 `docs/contracts.md` 6.3）。
- 数据目录默认是 `~/Library/Application Support/record-anything/`（数据目录与 `RA_*` 环境变量沿用历史内部代号 `record-anything`）。未设置 `RA_DB_KEY` 时，通过 macOS 钥匙串读取数据库密钥；读取错误时不会覆盖已有密钥。
- 除健康检查外，接口需要鉴权。网页与采集端使用管理令牌，MCP / hook 使用独立的受限 Agent 令牌；Agent 可以读取和明确授权的追加，不能管理设置或删除记录。
- 入库统一进行 Schema 校验、去重和密钥规则拦截。HTTP 200 回执仍须核对 `accepted`、`duplicates`、`rejected`，不能仅凭状态码推进插件游标。
- 删除原始记录时连带清理修正、索引和引用它的旧摘要，写入不含正文的墓碑，并排队重建剩余内容。重建完成前不展示旧摘要。
- 整理进程与 HTTP 服务分开运行；模型服务、本地模型与账号 CLI 由适配器调用。是否发送文字到云端取决于所选模型。
- 插件 stderr 只用于有界的错误分类，不保存或回显原始内容；第三方插件的读取范围与隔离规则见 [插件说明](../docs/zh/plugins.md)。

```sh
bun test
bun x tsc --noEmit
```

自动测试使用合成数据、临时目录与独立密钥。实际设备权限、钥匙串和长期性能需要单独验收，单元测试不能代替这些结果。
