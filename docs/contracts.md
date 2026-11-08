# 接口契约（v1）

这三份契约是各模块并行开发的共同边界，改动要先在这里改，再改实现。

## 1. 记录格式

- 唯一来源：`schema/record.schema.json`。TS 类型和校验在 `packages/record/index.ts`（`RecordV1`、`validateRecord`）。
- `id` 是生产方生成的 ULID（`ulid()`）。
- `source_ref`：来源内部的稳定键。凡是会重复读取外部存储的来源（会话日志、浏览器历史、git、shell 日志），**必须**填，hub 以 `(source, source_ref)` 唯一，重复发送是空操作。
- 时间一律 RFC 3339 带时区（`toLocalIso()`）。`kind=span` 必须有 `t_end`。
- `title` 一行，能用规则拼就不调模型；`body` 是详细正文。
- 记录写入后不可修改。修正是一条 `source: "manual.correction"`、`corrects` 指向原记录的新记录。
- 生产方不做模型调用。密钥拦截以 hub 为准（hub 写库前一定再过一遍）；生产方能先拦更好，拦了就把数量写进 `redactions`。

`source` 命名（v1）：

| source | 生产方 |
|---|---|
| `mac.screen` | Mac 采集端（AX / OCR） |
| `mac.app` | Mac 采集端：应用切换事件 |
| `mac.clipboard`、`mac.file`、`mac.calendar` | Mac 采集端 |
| `mac.shell` | plugins/shell |
| `mac.git` | plugins/git |
| `mac.browser` | plugins/browser |
| `claude_code.session`、`codex.session` | plugins/agent-sessions |
| `manual.note`、`manual.correction` | 网页手动补写 / 修正 |

## 2. 插件协议

插件是一个可执行程序（v1 用 Bun + TS 写，放在 `plugins/<名字>/`），**一次性运行**：读增量、输出、退出。由采集端（或开发期的 `hub run-plugin`）定时调用。

```
<plugin> --device <设备名> [--state <state.json>] [--since <RFC3339>]
```

- **stdout**：每行一个 JSON，两种：
  - `{"type":"record","record":{…RecordV1}}`
  - `{"type":"checkpoint","state":{…任意 JSON}}`，最后输出一次，代表"处理到这里了"。
- **stderr**：日志。**exit 0** 表示成功；非 0 时 runner 丢弃这次的 checkpoint，记录已发的照常入库（靠 `source_ref` 去重）。
- **state 文件插件只读不写**。runner 在 hub 接收成功后把最后一个 checkpoint 写进 state 文件，下次传回来。这样采集失败不会丢数据。
- 首次运行（没有 state）默认只回溯 7 天，`--since` 可覆盖。
- 插件不联网、不调模型、不写任何文件（临时复制数据库到 `os.tmpdir()` 并在退出前删除除外）。
- 插件只用 `packages/record`（相对路径导入）和 Bun / Node 内置模块。

## 3. Hub 接口

只监听 `127.0.0.1`，默认端口 `47823`，所有请求带 `Authorization: Bearer <token>`。

### 写入

`POST /v1/ingest`

```json
{ "device": "mac", "records": [ { …RecordV1 } ] }
```

响应 `200`：

```json
{ "accepted": 12, "duplicates": 3, "rejected": [ { "index": 5, "errors": ["/t_end must be string"] } ] }
```

- 逐条校验，坏的一条不影响其他条。
- 幂等：`id` 已存在，或 `(source, source_ref)` 已存在，算 duplicate。
- 墓碑：被删除过的 `id` 或 `(source, source_ref)` 算 duplicate，不再入库。
- 写库前做密钥拦截，替换成 `[已脱敏:类型]`，`redactions` 累加，`sensitivity` 若原为 `normal` 且有替换则改为 `redacted`。
- hub 填 `t_received`。

### 读取（网页和后续的 MCP 用）

| 方法 | 路径 | 说明 |
|---|---|---|
| GET | `/v1/records?from&to&device&source&q&limit&cursor` | 时间倒序；`q` 走全文检索；`cursor` 分页；默认不返回 `body`，`?body=1` 才返回 |
| GET | `/v1/records/:id` | 单条，带 body，带挂在它上面的修正 |
| POST | `/v1/records` | 手动补写或修正（body 是一条 RecordV1，`source` 必须是 `manual.*`） |
| DELETE | `/v1/records/:id` | 真删：记录、全文索引一起删，留墓碑（只存 id、source、source_ref、内容哈希、删除时间） |
| GET | `/v1/health` | 不需要 token |
