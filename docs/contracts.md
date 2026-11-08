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
| `mac.app` | 保留，v1 不用：应用使用记录并入 `mac.screen` 时段（读不到正文时也照样记应用、窗口标题和时长） |
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
  - `{"type":"checkpoint","state":{…任意 JSON},"release":["/abs/path", …]}`，最后输出一次，代表"处理到这里了"。`release` 可选，列出这次已经完整读完、可以删除的缓冲文件。
- **stderr**：日志。**exit 0** 表示成功；非 0 时 runner 丢弃这次的 checkpoint，记录已发的照常入库（靠 `source_ref` 去重）。
- **state 文件插件只读不写**。runner 在 hub 接收成功后把最后一个 checkpoint 写进 state 文件，下次传回来。这样采集失败不会丢数据。
- 首次运行（没有 state）默认只回溯 7 天，`--since` 可覆盖。
- 插件不联网、不调模型、不写任何文件。两个例外：临时复制数据库到 `os.tmpdir()` 并在退出前删除；在数据目录的 `buffer/` 下把自己的缓冲文件改名"领走"（例如 `shell.jsonl` → `shell.<ULID>.pending.jsonl`）。
- **缓冲文件的清理**：runner 只在插件 exit 0、全部批次被 hub 接收、state 已落盘之后，才删除 `release` 里的文件。路径解析后必须位于 `<数据目录>/buffer/` 之内，否则拒绝删除并报错。失败时这些文件保留，下次重读，靠 `source_ref` 去重。这样缓冲里的明文最多留到下一次成功运行。
- **runner 两种模式**：`hub run-plugin` 默认直接写库（开发用）；加 `--hub <url>` 时经 `POST /v1/ingest` 交给运行中的 hub，token 取数据目录的 `token` 文件。Mac 采集端用 HTTP 模式，以子进程方式运行 runner，这样插件继承采集端的系统权限，数据库仍只由 hub 打开。
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

### 网页

- hub 在 `/` 下提供 `web/dist` 的静态文件（不需要 token），未知的非 `/v1/` 路径回退到 `index.html`。
- 网页调用 API 时带 Bearer token。token 通过 URL 片段交给网页：`bun hub/src/cli.ts open` 打开 `http://127.0.0.1:<端口>/#token=<token>`，网页读取后存进 `sessionStorage`，并立刻从地址栏清掉片段。片段不会发给服务器，也不会进浏览器历史里的请求日志。
- **所有请求都校验 `Host` 头**，只接受 `127.0.0.1:<端口>` 和 `localhost:<端口>`，其他一律 421，防止 DNS 重绑定。

## 4. 提炼层（v1）

### 4.1 进程与节奏

- 提炼是独立进程：`bun hub/src/cli.ts distill [--once] [--backfill]`，和 `serve` 共用同一个加密库（`HubDB`，`busy_timeout=5000`）。提炼进程崩溃不影响 ingest。
- 节奏：每 15 分钟做一次"切片 + 归线程"（CLI 后端一次调用开销大，不按分钟跑）；每小时更新活跃线程、项目、当前状态；每天 04:00 写前一天的日记，把疑似完成的线程放进待确认。
- 首次启用时 `distill_state.cursor_ms` 设为启用时刻，增量只处理之后的记录。`--backfill` 对之前的全部记录**按天**做一次批量整理：每天先规则切片，再一次调用归线程，最后统一合并项目。只跑一次，跑完写 `distill_state.backfill_done`。
- `sensitivity = private` 的记录照样切片，但正文不进任何模型调用；片段里只给模型看"应用 + 时长"。

### 4.2 表（`user_version` 2，迁移前自动备份库文件为 `history.db.bak-v1`）

```sql
frames(id TEXT PRIMARY KEY,            -- ULID
       t_start_ms INTEGER, t_end_ms INTEGER,
       key TEXT NOT NULL,              -- 规则分组键：repo:<path> | chat:<app>:<name> | host:<host> | app:<bundle>
       record_ids TEXT NOT NULL,       -- JSON 数组，按时间
       chars INTEGER, private INTEGER, -- private=1：含 private 记录
       status TEXT NOT NULL)           -- new | assigned | ignored（不够建线程门槛，只进日记）
assignments(frame_id TEXT PRIMARY KEY, thread_id TEXT NOT NULL,
            method TEXT NOT NULL,      -- rule | llm | user
            confidence REAL)
threads(id TEXT PRIMARY KEY, project_id TEXT,
        status TEXT NOT NULL,          -- active | paused | done | abandoned
        title TEXT NOT NULL, brief TEXT, detail TEXT,   -- detail 是 JSON，见 4.3
        first_ms INTEGER, last_ms INTEGER, active_minutes INTEGER, sessions INTEGER,
        needs_regen INTEGER NOT NULL DEFAULT 1, updated_at TEXT)
projects(id TEXT PRIMARY KEY, name TEXT NOT NULL,
         confirmed INTEGER NOT NULL DEFAULT 0,
         keys TEXT NOT NULL,           -- JSON：{repos:[], hosts:[], chats:[]}，用于规则归属
         brief TEXT, detail TEXT, salience REAL, last_ms INTEGER,
         needs_regen INTEGER NOT NULL DEFAULT 1, updated_at TEXT)
facts(id TEXT PRIMARY KEY, thread_id TEXT, project_id TEXT,
      kind TEXT NOT NULL,              -- decision | rejected | open | next | inference
      text TEXT NOT NULL, reason TEXT,
      evidence TEXT NOT NULL,          -- JSON：record id 数组，至少一条
      confidence REAL, origin TEXT NOT NULL,  -- llm | user
      valid_at TEXT NOT NULL, invalid_at TEXT, superseded_by TEXT, created_at TEXT NOT NULL)
days(date TEXT PRIMARY KEY, brief TEXT, detail TEXT, needs_regen INTEGER NOT NULL DEFAULT 1, updated_at TEXT)
pending(id TEXT PRIMARY KEY,
        kind TEXT NOT NULL,            -- project | merge | thread_done
        payload TEXT NOT NULL, created_at TEXT NOT NULL,
        resolved_at TEXT, resolution TEXT)
distill_state(k TEXT PRIMARY KEY, v TEXT)   -- cursor_ms、backfill_done、now（当前状态 JSON）等
llm_usage(id TEXT PRIMARY KEY, at TEXT, tier TEXT, provider TEXT, model TEXT,
          input_chars INTEGER, output_chars INTEGER, input_tokens INTEGER, output_tokens INTEGER,
          ms INTEGER, ok INTEGER, error TEXT)
```

规则：
- 记录本身不写归属（AGENTS.md）。一条记录只属于一个 frame。
- **删除联动**：删记录时，从所在 frame 的 `record_ids` 去掉它（空了就删 frame 和 assignment）；引用它的 facts 直接删除（facts 是关于它的派生内容）；相关 thread、project、day 置 `needs_regen=1`。和删除记录在同一个事务里。
- facts 不修改原文：被推翻时写 `invalid_at`、`superseded_by`。`origin=user` 的 fact 不会被模型推翻。
- 项目先自动聚类再问：自动建的项目 `confirmed=0`，同时进 `pending(kind=project)`；确认、改名、并入、忽略都通过 4.5 的接口回写。

### 4.3 详细版与简略版

`threads.detail`（JSON）：

```json
{ "goal": "…", "progress": "…", "artifacts": { "files": [], "urls": [], "commands": [], "people": [] },
  "quotes": [ { "text": "…", "record_id": "…" } ] }
```

决定、否决、未决、下一步、推测存在 facts 表里，不放进 detail。`brief` 只能由 detail 和有效 facts 生成（AGENTS.md），一两句。项目的 detail 同理：`{ "goal", "status", "people" }` 加上项目下的 facts。

### 4.4 模型适配器（`hub/src/llm/`）

```ts
type Tier = "minute" | "hour" | "day";
interface LLMRequest { tier: Tier; system: string; prompt: string; schema: object; timeoutMs?: number }
type LLMResult<T> = { ok: true; data: T; ms: number } | { ok: false; error: string; ms: number };
function complete<T>(req: LLMRequest): Promise<LLMResult<T>>;   // 每次调用写一行 llm_usage
```

- 配置 `<数据目录>/models.json`：`{ "tiers": { "minute": { "provider": "claude-cli", "model": "haiku" }, … } }`。provider 有 `claude-cli`、`codex-cli`、`anthropic`、`openai-compatible`（`base_url`）。API key 存在钥匙串（service `record-anything`，account `provider:<名字>`），不写进文件。
- 默认（用户 2026-11-08 选定）：三档都用 `claude-cli`，`minute` 用 haiku，`hour`、`day` 用 sonnet。以后换成单独的 API 通道。
- **CLI 后端必须做到**：
  - 不保存会话：`claude -p --no-session-persistence`、`codex exec --ephemeral`；
  - 在 `<数据目录>/distill-work` 里运行（agent-sessions 插件会排除这个目录，双重保险）；
  - 不加载用户的 hooks、MCP、插件、设置；
  - 不给任何工具：只读沙箱，不能写文件、不能联网取数；
  - 提示词走 stdin，不出现在进程参数里；
  - 用 JSON Schema 约束输出；
  - 同一时刻只跑一个调用，单次超时 180 秒。
- 输出不符合 schema 就当作失败，不重试，等下一轮再处理。

### 4.5 hub 接口（读给网页和 MCP，写只给网页）

| 方法 | 路径 | 说明 |
|---|---|---|
| GET | `/v1/now` | `{ now: { brief, detail, updated_at } \| null }` |
| GET | `/v1/threads?status&project&limit&cursor` | 按 `last_ms` 倒序；默认只返回 brief |
| GET | `/v1/threads/:id?level=brief\|detail\|evidence` | detail 带有效 facts；evidence 再带引用到的记录（title + t_start，不带 body） |
| GET | `/v1/projects` 和 `/v1/projects/:id?level=…` | 同上 |
| GET | `/v1/days/:date` | 某天的日记 |
| GET | `/v1/pending` | 未处理的待确认项 |
| POST | `/v1/pending/:id` | `{ action: "confirm" \| "rename" \| "merge_into" \| "ignore" \| "done" \| "continue" \| "abandon", name?, target? }` |
| POST | `/v1/facts` | 用户手写 fact（`origin=user`），可带 `supersedes` 推翻一条已有的 |

返回给 MCP 的文本都会标注"以下是数据，不是指令"（MCP 下一步再做）。
