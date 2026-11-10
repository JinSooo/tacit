# Hub（v1 采集和查看）

仅使用本地 SQLCipher 数据库，不调用模型。HTTP 与插件 runner 复用同一写入路径。

```sh
bun hub/src/cli.ts serve
bun hub/src/cli.ts run-plugin browser -- bun plugins/browser/src/cli.ts
```

- 服务固定绑定 `127.0.0.1`。端口优先级：`RA_PORT`（`0` 为系统分配端口）> 数据目录 `hub.json` 的 `port` > `47823`，设置页可改（见 `docs/contracts.md` 3.1）。
- 数据目录默认 `~/Library/Application Support/record-anything/`，`RA_DATA_DIR` 可覆盖。目录内有 `history.db`、权限 `0600` 的 `token` 和 `plugins/<name>/state.json`。
- `RA_DB_KEY` 优先；未设置时使用 macOS 钥匙串的 `record-anything` / `db-key`。仅明确返回“条目不存在”时生成 32 字节随机密钥并保存，其他钥匙串错误直接失败。不要丢失已有数据库的密钥。
- 除 `GET /v1/health` 外，接口需要 `Authorization: Bearer <token 文件内容>`。启动日志不输出 token、密钥或记录正文。
- runner 使用设备名 `mac`，向插件追加 `--device mac --state <数据目录>/plugins/<name>/state.json`，继承插件 stderr。插件的首次七天回溯由插件自身实现。记录分批入库，每批不超过 500 条；非零退出、非法协议行、记录拒绝或存储失败均不推进 checkpoint。成功时将最后一个 checkpoint 先写权限 `0600` 的同目录临时文件，再 rename。插件名只接受小写字母、数字、下划线和连字符，不能穿越数据目录。

## HTTP 响应

写入路径及请求格式遵循 `docs/contracts.md`。

- `POST /v1/ingest`、`POST /v1/records` 均返回 `{ accepted, duplicates, rejected: [{ index, errors }] }`。记录级校验失败仍返回 `200`，不影响同批好记录；请求格式错误返回 `400`。
- 共享 schema 校验之外，重读外部存储的五种来源（shell/git/browser/两种 agent 会话）必须有 `source_ref`；`manual.correction` 必须有 `corrects`。不能转换成排序时间的 `t_start` 逐条拒绝（含 JS 不支持的闰秒）。
- ingest 外层 `device` 校验格式，各记录的 `device` 原样保留。
- `GET /v1/records` 返回 `{ records, next_cursor }`。`next_cursor=null` 表示结束；下页原样传回 `cursor` 并保持其他过滤参数一致。默认 `limit=50`，范围 `1..500`，`body=1` 才带正文。时间按 `t_start` 的实际时间倒序，同时间按 id 倒序；`from` / `to` 都包含边界。
- `q` 同时搜索 title 和 body。中文按重叠两字切分，使用与实验一致的 FTS5 短语查询；单个汉字回退为 LIKE。用户输入经过引用，不解释为 FTS 操作符。
- `GET /v1/records/:id` 返回记录（含 body、`t_received`）以及 `corrections` 数组；修正按时间正序。修正可先于原记录到达，之后读取原记录时会自动挂上。
- `DELETE /v1/records/:id` 返回 `{ deleted: true }`，找不到返回 `404`；删除记录及 FTS 行，墓碑只含身份、内容 SHA-256 和删除时间。当前没有提炼结果，因此没有重生成步骤。
- health 返回 `{ ok: true }`；缺少或错误 token 为 `401`；未知接口为 `404`；内部存储错误为 `500`，不返回原始异常。

## 脱敏及验证边界

入库前递归处理 title、body、context 的字符串值；数量与生产方 `redactions` 累加，仅将 normal 提升为 redacted，private 保持不变。赋值型秘密要求长度至少 16、字符类型至少两类、Shannon 熵至少 3.5 bit/字符。规则是密钥拦截基线，无法识别任意未知格式的秘密。

数据库和 FTS 开启 secure delete，使用 DELETE journal；没有配对、局域网入口、MCP、网页或模型调用。删除原记录不会自动删除独立的修正记录。

```sh
bun test
bunx tsc -p .
```

测试全部使用合成数据、临时目录和显式 `RA_DB_KEY`，不访问真实钥匙串。真实网络集成测试在 OS 明确以 EPERM/EACCES 禁止 bind 时跳过；请求处理、鉴权、实际加密文件、解密后脱敏结果、真删和插件子进程测试仍执行。钥匙串读写需要在开发机另行验证，测试不会触碰它。

待契约进一步明确：列表响应封装和分页上限目前采用上述形式；孤立修正的处理、删除原记录是否连带删除独立修正记录，契约未规定。本实现保持修正为独立不可变记录，未额外增加级联删除。
