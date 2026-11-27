# Agent 会话插件

```sh
bun plugins/agent-sessions/main.ts --device mac [--state /path/state.json] [--since 2026-11-01T00:00:00+08:00]
```

stdout 按契约输出 record，最后输出 checkpoint。state 文件只读，由 runner 在接收成功后保存。

| 工具 | 默认读取目录 | 根目录覆盖 | 记录来源 |
| --- | --- | --- | --- |
| Claude Code | `~/.claude/projects/` | `RA_CLAUDE_DIR`（默认 `~/.claude`） | `claude_code.session` |
| Codex | `~/.codex/sessions/`、`~/.codex/archived_sessions/` | `RA_CODEX_DIR`（默认 `~/.codex`） | `codex.session` |
| Antigravity 桌面、CLI、IDE | `~/.gemini/antigravity/`、`~/.gemini/antigravity-cli/`、`~/.gemini/antigravity-ide/` | `RA_ANTIGRAVITY_DIR`（默认 `~/.gemini`） | `antigravity.session` |
| Gemini CLI | `~/.gemini/tmp/<项目>/chats/session-*.jsonl` | `RA_GEMINI_DIR`；`GEMINI_CLI_HOME` 覆盖主目录 | `gemini_cli.session` |
| Qwen Code | `~/.qwen/projects/<项目>/chats/<会话 ID>.jsonl` | `RA_QWEN_DIR`、`QWEN_RUNTIME_DIR`、`QWEN_HOME` | `qwen_code.session` |
| OpenCode（v1.2.0 起） | `~/.local/share/opencode/opencode.db` | `RA_OPENCODE_DIR`、`OPENCODE_DB`、`OPENCODE_DATA_DIR`、`XDG_DATA_HOME` | `opencode.session` |

Claude Code 和 Codex 读取 JSONL 及 Zstandard 压缩归档。Antigravity 在每个数据目录下读取 `brain/<会话 ID>/.system_generated/logs/transcript_full.jsonl`，缺少完整转录时读取同目录的 `transcript.jsonl`。工作目录和子会话关系来自同一数据目录下的 `conversation_summaries.db`。索引无法读取时仍采集转录，工作目录留空。采集范围限于表中列出的三个 Antigravity 数据目录及这两种转录文件。

Gemini CLI 按上游源码实现、未真机验证。工作目录优先取 `~/.gemini/projects.json`，再取项目的 `.project_root` 或会话首行的 `directories[0]`。Seatbelt 沙盒的会话从 `~/.cache/.gemini/tmp/` 读取。只采 `chats/` 下的主会话，元数据更新、补丁和回退事件按非消息跳过。

Qwen Code 按上游源码实现、未真机验证。工作目录取逐条记录中的 `cwd`。当 `QWEN_RUNTIME_DIR` 未设置时，运行时目录优先取设置中的 `runtimeOutputDir`，然后使用 `QWEN_HOME` 或默认目录。

OpenCode 按上游源码实现、未真机验证。只读查询 SQLite 的 `session`、`message` 和 `part` 表，工作目录来自 `session.directory`。按消息与内容块的更新时间推进游标，回复完成后才收录。数据库锁住时保留游标，下一轮重试。频道版数据库可通过 `OPENCODE_DB` 指定，旧版 `storage/` 下的 JSON 不采集。

Kimi 只接查询，不读会话：逐条时刻未核实。待核对的新版主会话日志位于 `~/.kimi-code/sessions/<分桶>/<会话 ID>/agents/main/wire.jsonl`。旧版会话目录为 `~/.kimi/sessions/<工作目录哈希>/<会话 ID>/`。

- `filters.ts` 集中列出丢弃规则及原因。只读取双方可见文字；澄清回答只保留用户答案。消息内部保留真实换行，消息之间空一行，各以 `[我] ` 或 `[AI] ` 开头。
- 首次默认按文件 mtime 和消息时间回溯七天。已有 checkpoint 时再传 `--since` 表示重新导入：该时刻之后改过的文件从头重读，只取该时刻之后的消息；八天窗口内已输出的消息靠 seen 哈希跳过，更早的会以相同 `source_ref` 再输出一次由 hub 去重；checkpoint 的 since 和重放下界不倒退。普通 JSONL 按完整行字节偏移续读，末尾未换行的半行下次再读。完整行 JSON 损坏则跳过，结束时仅向 stderr 汇总“跳过 N 行损坏数据”，不回显路径或正文。
- `json-lines.ts` 按 64 KiB 块读取并投影 JSON，只保存消息所需的字段；工具输出、图片和其他大字符串不拼接进内存。字段顺序不影响结果。可见文本字段仅保存有界前缀，超长消息在输出时附截断标记。
- `.zst` 使用 `createZstdDecompress()` 流式解压，未变化时不读，变化后重新解压并以消息摘要去重。压缩文件 offset 按解压后的字节计，允许归档最后一行不带换行。
- 同一会话在活动目录和归档目录统一去重。source_ref 的小时使用 UTC RFC3339，避免机器时区变化影响稳定键。记录时间使用共享的 `toLocalIso()`。
- 会话文件三分钟未改、桶里最早一条未输出的消息已过十五分钟，或桶结束超过十分钟，就输出这一批；同一小时之后的内容用 `#2`、`#3` 接着编号。采集端每 5 分钟运行一次插件，所以 AI 会话最晚约 20 分钟进库。超过 150000 字符的桶按消息边界拆成多条；单条消息超限则截断，前缀和标记也计入此上限，不截断 Unicode 代理对。AI 单条回复仍保留原有的四千码点上限。拆分和关闭后的迟到追加共用桶内连续的 `#2`、`#3` part 计数器。
- checkpoint v2 按小时保存 seen 哈希。八天以前、已输出且没有待处理消息的桶会清理哈希与 part 进度；消失的文件删除，无未关闭桶且八天没有活动的会话删除。保留仍在磁盘上的文件偏移、session id 和 cwd，休眠会话无需重读旧前缀即可恢复追加。
- 清理同时推进重放时间下界，已清理的历史桶不会在归档迁移或重读时复活；八天以外的旧时间戳不再作为增量重放。未输出的消息不会因哈希清理而丢失。v1 checkpoint 会自动迁移；没有时间戳的旧哈希保守保留至迁移后八天。
- 文件替换、缩短或同大小改写会去重重读；不支持保持身份且同时追加时改写先前字节的日志编辑。state 损坏、压缩流损坏或记录校验失败仍非零退出，不发 checkpoint。

## 验证

`bun test plugins/agent-sessions`、`bun test`、`bunx tsc --noEmit -p .`。所有 fixture 均为合成数据，覆盖过滤、关闭时机、拆桶、迟到追加、字节增量、UTF-8 半行、巨型工具输出、字段乱序、压缩流、文件替换、八天清理及恢复、v1 迁移、CLI 协议和逐条 schema 校验。Antigravity 用例还覆盖子会话过滤、索引不可读、追加和旧游标续用。真机验证仅保留统计。
