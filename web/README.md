# History 网页

在仓库根目录运行：

```sh
bunx vite build --config web/vite.config.ts
bun hub/src/cli.ts serve
bun hub/src/cli.ts open
```

开发时运行 `bunx vite --config web/vite.config.ts`，`/v1` 代理到本机 47823 端口。类型检查用 `bunx tsc -p web`，纯函数测试随根目录 `bun test` 一起执行。

如果根目录的 `node_modules` 是指向只读位置的软链接，先执行 `mkdir -p web/node_modules/.vite-temp`。Vite 在读取配置前会把配置编译缓存写到最近的 `node_modules/.vite-temp`，这一步尚不能使用配置里的 `cacheDir`；该本地目录不安装依赖，包仍从根目录解析，依赖缓存则写到 `web/.vite`。

页面使用系统字体和系统明暗模式，以日期、时间列和细分隔线组织记录；来源用细色条区分。设备框可直接输入设备名，已读取记录里的设备会作为候选项。没有额外的设备枚举接口。

## 提炼视图与联调

顶部切换 History、此刻和待确认，当前页写在地址栏片段里（如 `#/now`），刷新和前进后退都能恢复。此刻页按项目展示活跃线程，其下是 3 天内有活动的暂停线程，再下方项目可展开查看详细版及全部状态的线程。证据按需读取，点击记录标题会清空 History 的来源、设备和日期筛选，再搜索该标题。待确认的处理先隐藏卡片并给 5 秒撤销，到时或离开待确认页才写入；写入失败卡片回来并显示错误。修正 fact 写入成功后重新读取详情。

4.5 节尚未完整定义返回字段。前端待联调的数据结构集中在 `src/distillation.ts`，当前 mock 采用：

- 列表：`{ threads, next_cursor }`、`{ projects }`、`{ pending }`；线程列表遍历游标，项目项包含 `thread_count`。
- 单条：直接返回线程或项目对象；`detail` 为对象，`facts` 为有效事实数组；evidence 级别增加顶层 `evidence: [{ id, title, t_start }]`，fact 的 `evidence` 为记录 ID 数组。
- project 待确认 payload：`{ project_id, name, keys: { repos, hosts, chats }, threads: [{ id, title, brief? }] }`；thread_done payload：`{ thread_id, title, brief }`。
- 修正 fact：发送 `kind`、`text`、原事实的 `thread_id` / `project_id`、`evidence` 及 `supersedes`。`origin=user`、ID 和时间由 hub 填充。
- 契约只列出 `merge` 待确认类型，没有它的 payload 和操作语义，前端保留分组展示，不提供猜测的处理操作。需先补齐契约后联调。

`test/distillation.test.ts` 使用合成数据，覆盖 facts 分组、相对时间、pending 依据摘要、读取级别、分页、待确认七种动作及修正请求。
