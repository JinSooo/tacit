# Tacit 官网

中英文多页静态站，无外部依赖，用 Bun 自带能力（含 `Bun.markdown.html`）构建。

```sh
bun site/build.ts           # 构建到 site/dist
bun site/build.ts --serve   # 在 http://127.0.0.1:4300 预览（PORT 可覆盖），请求 HTML 时实时重建
bun test site/              # 运行官网构建、路由与文档链接测试
```

## 路由结构

构建产物在 `site/dist/`，所有页面内联公共样式、脚本和来源符号，共用根目录 `assets/`。供 Mac 应用检查更新的 `latest.json` 保持在根目录。

| 路径 | 产物文件 | 说明 |
| --- | --- | --- |
| `/` | `index.html` | 轻量语言分流入口：有 JS 时按 `localStorage`（`tacit-lang`）或浏览器语言跳转（`zh` 开头进 `/zh/`，其余进 `/en/`）并保留查询参数与 `#` 片段；禁用 JS 时通过 `<meta http-equiv="refresh" content="0; url=en/">` 回落到英文首页（纯静态 HTML 无法在无 JS 下拼接原 query/hash，如需在无 JS 场景保留片段应在托管层配置重定向） |
| `/en/`、`/zh/` | `en/index.html`、`zh/index.html` | 产品首页；Hero 与末尾收尾区按设备仅展示一个主下载按钮，并附「全部平台下载」链接 |
| `/en/download/`、`/zh/download/` | `en/download/index.html`、`zh/download/index.html` | 独立下载页：Mac（含 3 步首次放行与可复制命令）、Android、Docker 独立服务端与计划支持平台 |
| `/en/docs/`、`/zh/docs/` | `en/docs/index.html`、`zh/docs/index.html` | 文档首页概览 |
| `/en/docs/<slug>/`、`/zh/docs/<slug>/` | `en/docs/<slug>/index.html`、`zh/docs/<slug>/index.html` | 直接由仓库 `docs/` Markdown 构建的文档子页（`trial-guide`、`troubleshooting`、`server-deployment`、`installation`、`plugins`） |
| `/latest.json` | `latest.json` | 从 `site/src/latest.json` 原样复制，供 Mac 客户端每日检查更新 |

`site/src/en/` 和 `site/src/zh/` 各有首页骨架 `index.html`、首页区块 `sections/*.html`、独立下载页 `download.html` 以及共享片段 `day-overview.html`。`<!-- include: 路径 -->` 在构建时展开，路径相对包含它的文件。文档站由 `site/build.ts` 直接读取仓库 `docs/` 生成，同时兼容中文在 `docs/<slug>.md`（英文在 `docs/en/<slug>.md`）与英文优先在 `docs/<slug>.md`（中文在 `docs/zh/<slug>.md`）两种布局。页面不请求外部 CDN 资源，不放统计脚本。

## 部署

线上入口为 https://tacit.jinso.top/ ，自动分流至 `/en/`（默认）或 `/zh/`。运行 `bun site/build.ts` 后，将整个 `site/dist/` 上传到静态托管服务（如 Cloudflare Pages、GitHub Pages 或自建 Nginx）。

> 若使用 `wrangler pages deploy` 手动部署，建议先把 `site/dist` 复制到仓库外的临时目录再执行，避免 wrangler 在仓库根目录自动生成配置文件。

## 首页区块

| 顺序 | id | 内容 |
| --- | --- | --- |
| 1 | `hero` | 主张、按设备匹配的单一主下载按钮与全部下载入口、一张会自己写下去的当天时间线 |
| 2 | `day` | 时间线与项目页：简约和详细两档、点开一段看原文、项目现在怎么样了 |
| 3 | `ai` | 新会话自动带入、AI 主动查询并点回原文（终端为深色窗口） |
| 4 | `how` | 工作方式：三层来源按离你意图的远近排，本机整理，两个出口 |
| 5 | `more` | 搜索、会议与聊天、桌面小组件 |
| 6 | `privacy` | 数据与隐私，如实说清什么会离开本机 |
| 7 | `faq` | 常见问题 |
| 8 | `download` | 简洁收尾区：按设备匹配的单一主下载按钮，以及前往下载页和文档页的入口 |

## 视觉方向

一张安静的纸，上面的字一直在往下写。主题来自应用图标「墨轴纪事」：左侧连续时间细轴串联三段由长到短的活动胶囊，顶部铜绿节点表示此刻仍在续写。

- **纸与墨与按块分屏**：底色 `--paper` 与极轻微的交替纸层 `--band` 配合细分隔线划分各块，首页桌面端各块按视口高度独立成屏居中，移动端回落自然流式块。只有一个强调色铜绿 `--accent`，用于链接、当前位置、活动条和少量强调，不铺大面积。
- **终端是唯一的深色块**：`ai` 区块的终端窗口用 `.band-night`，颜色与图标底板同一块暖炭灰。区块本身和文档代码块保持纸面。
- **宋体讲故事，无衬线做界面**：叙述性标题、当天概述、事项标题、文档标题用 `.display` / `.heading` / `.title`（宋体）；正文、按钮、界面复刻里的列表用无衬线；命令、路径、代码用等宽。
- **产品画面用 HTML 复刻，不用截图**：时间线、项目页、终端、小组件都用真实 DOM 画出来，深浅色都清晰、可选中文字。现成的小组件图 `assets/widget-*.png` 可以用在 `more`。
- **统一符号集**：统一用 `assets/sources.svg` 里的 24×24 单色符号（1.6px 描边，`currentColor`），包括顶栏语言切换（`lang`）与深浅色切换（`sun` / `moon`）图标按钮。
- **留白多于装饰**：不加阴影、光晕、渐变背景、毛玻璃、卡片套卡片。分隔用 `--line` 细线或留白。
- **动效克制**：进入视口时淡入（`data-reveal`）；所有动画在 `prefers-reduced-motion: reduce` 下直接显示终态。
- **字号**：只用 `base.css` 里的 6 级变量，一个区块最多 4 级。不用斜体、全大写和字间距。数字和时间加 `.num`（等宽数字）。

## 文案

- 中英文都用短句，说清它做什么、怎么做，不用宣传用语或感叹号。英文用句首大写，叙述性标题和概述使用拉丁衬线字体优先。
- 界面用词按 `docs/ui.md` 第 1 节：事项、整理、自动带入、AI 工具、时间线、段、依据。不出现中枢、提炼、线程、注入、档位、OCR。
- 如实：支持 Apple 芯片 Mac（macOS 14 及以上）与 arm64 Android（Android 9 及以上）；用云端模型整理时相关文字会发给你配置的模型服务；不收集遥测。不承诺尚未支持的能力（Windows 仅写计划支持/敬请期待，Intel Mac 暂不支持，iOS 仍在调研中）。
- 下载链接与版本号：构建时自动从 `site/src/latest.json`（Mac）、`android/app/build.gradle.kts`（Android）和 `package.json`（Docker 服务端）派生，替换首页与下载页中的模板占位符并校验一致性；发版时更新对应版本源后重新运行 `bun site/build.ts` 即可，无需手工修改 HTML。

## 验收

- `bun site/build.ts` 通过，确认中英文路由集合一致、无重复 ID、无未展开引用、下载链接与 `latest.json` 一致、所有站内相对链接与锚点均有效。
- `bun test site/ scripts/release-version.test.ts` 全部通过。
- 使用 `PORT=4312 bun site/build.ts --serve` 验证 `/`、`/en`、`/en/`、`/zh`、`/zh/`、`/en/download`、`/zh/download/`、`/en/docs/`、`/zh/docs/troubleshooting/` 与 `/latest.json` 均可访问，刷新即重建。
- 在 1440、1024、390 三种宽度下，浅色和深色各看一遍：没有横向滚动、截断、重叠；390 宽时顶栏与文档页可正常折叠浏览。
- 键盘能走到每个可交互元素，焦点可见；装饰性图形 `aria-hidden="true"`；`prefers-reduced-motion: reduce` 下所有内容直接可读。
