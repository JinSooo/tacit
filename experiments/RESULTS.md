# 实验 0 结果

测试机：M5 Pro / macOS 27（Darwin 27.0.0）/ Xcode 27.2 / Bun 1.4.4 / Node 26.10.0。**这台机器的 SIP 是关闭的**，见 0-A。

## 0-D 存储：SQLCipher + FTS5 + 中文检索（`00-storage/`）✅

- `better-sqlite3-multiple-ciphers` 13.0.3 在 Bun 和 Node 上都能用：加密写入、文件头不是明文、错误密钥打不开、正确密钥重开后数据完整。
- 中文检索，11 个查询的命中情况：
  - FTS5 `trigram`：两个字的词全部搜不到（节点、大屏、开会、张三）。
  - jieba 分词：建索引和查询时切法不一致，漏掉"张三"（建索引切成"张/三"，查询时当作一个词）。
  - **重叠两字切分（bigram，不需要词典）+ `unicode61`：全部命中** → 采用这个方案。单字查询退回 `LIKE`。
- 运行：`bun test.mjs` / `node test.mjs`

## 0-A 自签名证书重新构建后权限是否保留（`01-tcc/`）

| 构建 | 签名 | 启动方式 | 辅助功能 |
|---|---|---|---|
| 1 | 自签名 "Record Anything Dev" | open | ✅ 授权后可用 |
| 2 | 同一张证书，二进制已变 | open | ✅ 保留 |
| 3 | ad-hoc（对照） | open | ❌ 丢失 |
| 4 | 自签名 | open | ✅ 恢复 |
| 5 / 7 | ad-hoc | launchd | ❌ |
| 6 / 8 | 自签名 | launchd | ✅ |

- **结论：辅助功能权限跟着固定证书走，重新构建后仍然保留**；改用 ad-hoc 签名就会丢。TCC 库里记录的是 `identifier + certificate leaf` 签名要求。
- **完全磁盘访问在这台机器上测不出来**：SIP 关闭后，ad-hoc 版也能读 Safari 历史、`chat.db`、`~/Library/Mail`，连系统 TCC 库都能读。SIP 开着的机器上才能验证；按 TCC 的机制应该和辅助功能一样，但**未核实**。
- 证书放在单独的钥匙串 `~/Library/Keychains/ra-dev.keychain-db` 里，密码在 `01-tcc/.keychain-pass`（已 gitignore）。删除：`security delete-keychain ~/Library/Keychains/ra-dev.keychain-db`。

## 0-C 子进程是否继承权限 ✅

- 采集端启动的 Swift 子进程，`AXIsProcessTrusted()` 跟着父进程走：父进程是自签名版时为 trusted，ad-hoc 版时为 untrusted。说明子进程用的是父应用的授权。
- 文件访问同样因为 SIP 关闭测不出来。

## 0-B 辅助功能覆盖率 ✅

**前提发现：AX 的 `kAXWindowsAttribute` 只返回当前桌面（Space）上的窗口。** 第一轮遍历所有应用时，大多数应用读到 0 个窗口，原因是它们在别的桌面上。采集端本来就只读前台窗口，所以不受影响，但"后台扫描全部应用"这条路行不通。

第二轮把每个应用切到前台，只读 `AXFocusedWindow`，先设置 `AXManualAccessibility` 再读。只统计字数，不记录内容：

| 应用 | 元素 | 正文字数 | 标签字数 | 耗时 | 结论 |
|---|---|---|---|---|---|
| Mail | 16,761 | 1,587,316 | 1,374 | **88 s** | 能读到，但会把整个邮件列表全吐出来。**必须设时间预算，并且只取可见区域** |
| cmux（终端） | 36 | 8,270 | 267 | 19 ms | 好 |
| Zen（浏览器） | 823 | 2,768 | 2,658 | 99 ms | 好 |
| 钉钉 | 446 | 1,200 | 924 | 98 ms | 可用 |
| Typora | 20 | 1,152 | 36 | 17 ms | 好 |
| ChatGPT 桌面版 | 495 | 1,060 | 4,425 | 74 ms | 可用 |
| Notion（Electron） | 267 | 615 | 548 | 56 ms | 可用；`AXManualAccessibility` 只有它支持 |
| 飞书 | 523 | 536 | 657 | 77 ms | 偏少，要看具体页面 |
| ego lite（浏览器，首页） | 96 | 166 | 636 | 28 ms | 首页内容少，正常 |
| **微信** | 123 | **14** | 968 | 31 ms | **基本读不到正文** → 需要 OCR 兜底或读数据库 |
| **Zed** | 6 | **0** | 27 | 8 ms | **没有 AX 树**（GPUI 自绘）→ 用窗口标题里的文件名加 git 信息，或者 OCR |

对设计的影响：
1. 每次扫描都要有元素数和时间上限（比如 3,000 个元素、200 ms），并且只遍历和窗口可见区域相交的元素，否则 Mail 这类应用会卡住采集。
2. 微信和 Zed 是 OCR 兜底的第一批目标。把 OCR 推到 v1 之后，意味着 v1 里这两个应用只有"应用名 + 窗口标题"。
3. 除了 Notion，其余应用都不接受 `AXManualAccessibility`（返回 unsupported），但大多数照样能读到内容。

## A-1 Android 无障碍读微信（2026-11-19）❌

测试机：小米 14 Ultra / Android 16 / HyperOS 3.0 / 微信 8.0.80，adb 侧载。探针是只读的无障碍服务，限定 `com.tencent.mm`，开了 `flagReportViewIds`、`flagRetrieveInteractiveWindows`、`flagIncludeNotImportantViews`，只记录节点数、id 和文字长度，不记录正文。

| 读取方式 | 聊天列表 | 群聊 | 单聊 |
|---|---|---|---|
| `uiautomator dump`（shell 权限） | 名称、时间、预览都在 | 发送人（头像描述）、正文、时间分隔都在 | “我”的消息头像在右侧，可区分 |
| 第三方无障碍服务 | 根节点 0 个子节点 | 同左 | 同左 |

- 同一时刻系统界面窗口能读到 51 个节点，只有微信的窗口是空的；强制停止后重启微信，结果不变。**微信会对第三方无障碍服务主动返回空界面树**，手机上不能用无障碍读微信。`uiautomator` 走 shell 权限，正式应用拿不到。
- 用 adb 写 `enabled_accessibility_services` 时，HyperOS 会先删掉列表里失效的组件，再整体重写这一项。改动前要先保存原值，测完写回去。
- 下一步：用真实消息测微信通知能带出什么（发送人、群名、是否截断、Mac 微信登录时手机是否还收到通知）。
