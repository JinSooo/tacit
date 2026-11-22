<p align="center">
  <img src="assets/readme/cover.svg" alt="Tacit：让 AI 接上你的上下文" width="100%">
</p>

<p align="center">
  <b>把每天在 Mac 上做的事整理成一条时间线，给你回看，也让 AI 接着用。</b>
</p>

<p align="center">
  <a href="https://github.com/JinSooo/tacit/releases/latest"><img src="https://img.shields.io/badge/%E4%B8%8B%E8%BD%BD-Tacit.dmg-3b7468?style=flat-square" alt="下载"></a>
  <img src="https://img.shields.io/badge/macOS-14%2B-211f1d?style=flat-square&logo=apple" alt="macOS 14+">
  <img src="https://img.shields.io/badge/Apple_%E8%8A%AF%E7%89%87-arm64-211f1d?style=flat-square" alt="Apple 芯片">
  <img src="https://img.shields.io/badge/%E7%8A%B6%E6%80%81-%E5%BC%80%E5%8F%91%E9%A2%84%E8%A7%88-9d2933?style=flat-square" alt="开发预览">
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-211f1d?style=flat-square" alt="MIT"></a>
</p>

<p align="center">
  <a href="https://tacit.jinso.top">官网</a> ·
  <a href="#开始使用">开始使用</a> ·
  <a href="#它能做什么">功能</a> ·
  <a href="#连接-ai">连接 AI</a> ·
  <a href="#数据与隐私">数据与隐私</a> ·
  <a href="#常见问题">常见问题</a> ·
  <a href="#开发">开发</a>
</p>

---

每开一个新的 AI 会话，都要把背景重新讲一遍：这个项目做到哪了、上次定了什么、还卡在哪。Tacit 在后台记下你和 AI 的对话、微信聊天和录音，在本机整理成每天发生的事和你做的决定，再让 Claude Code、Codex 直接来读。你自己也能在时间线上回看一天，每条结论都能点回原文。

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="assets/readme/widget-dark.png">
    <img src="assets/readme/widget-light.png" alt="Tacit 桌面小组件：大号和中号，显示当天概述、活动条和最近几段活动" width="760">
  </picture>
  <br>
  <sub>桌面小组件（示例数据）：当天概述、今天的活动条和最近几段，点一下打开当天时间线。</sub>
</p>

## 它能做什么

**📅 一天一条时间线**
每段连续的活动一行：几点开始、做了什么、用了哪些应用。顶部是 2–4 句的当天概述，每小时更新一次，打开时间线时还会按需补一次。点开一段，原地展开它的原始记录。想看细节就切到详细档，按来源分泳道，看全天每条记录。

**📁 项目现在怎么样了**
项目页上面是一句话概况，接着是正在推进的几件事，每件写明进展和还没定的事，点开就能读这件事跨天的经过。再往下按天列出这个项目最近的进展。AI 记错了的地方，可以在这里改正。

**🤖 让 AI 接着做**
Claude Code、Codex 新开会话时，自动带入当前项目正在推进的事。AI 也能主动查询：昨天下午在做什么、上次定了什么、这条结论出自哪段对话。

**🔍 找回看过的东西**
屏幕和浏览器上的文字都能搜到，可以按日期、来源或设备筛选，搜到的结果直接展开原文。

**🎙️ 会议与聊天**
录音在本机转写，按场整理出总结和去掉口头禅的原文，只分“我”和“对方”。微信对话默认关闭，开启后按聊天拆成消息。

**🪟 桌面小组件**
中号和大号两种，抬眼就能看到今天做了哪些事。

## 工作方式

<p align="center">
  <img src="assets/readme/how-it-works.svg" alt="记录来源经本机整理，进入给你看的时间线和给 AI 的查询接口" width="100%">
</p>

不同来源的权重不一样，按离你本人的意图远近排：你说的、写的最重要，别人对你说的其次，你看过的最低。所以 AI 会话、聊天和录音是整理的主体，屏幕和浏览器只提供时间骨架（应用、标题、时长），上面的文字可以搜，但不参与整理。

截图只在内存里给识字用，从不保存。数据库加密存在本机。

## 开始使用

需要 Apple 芯片的 Mac，系统 macOS 14 或更新。

1. 从 [Releases](https://github.com/JinSooo/tacit/releases/latest) 下载 `Tacit-<版本号>.dmg`，打开后把 Tacit 拖进“应用程序”。
2. 从“应用程序”打开 Tacit。安装包没有经过 Apple 公证，第一次打开会被系统拦下：点“完成”，打开 **系统设置 › 隐私与安全性**，在页面下方的 Tacit 旁边点 **仍要打开**，输入密码。如果没有这个按钮，在终端运行 `xattr -dr com.apple.quarantine /Applications/Tacit.app` 后再打开。
3. 菜单栏出现 Tacit 图标后，后台服务会自动准备好，不需要用命令行。

打开主窗口后，时间线顶部会列出还没完成的几步，做完一项就少一项：

- **系统授权**：在数据源页面授予需要的权限。
- **整理模型**：在 **设置 › AI 模型** 选择模型并测试连接。默认用本机已登录的 Claude Code，也可以改用 Codex，或者直接填 API。
- **记录来源**：在 **设置 › 数据源** 选择要记录什么。第一次开启录音时，会下载约 270MB 的本机语音模型。
- **连接 AI 工具**：在 **设置 › AI 工具** 一键连接 Claude Code、Codex，再到 **维护 › 密钥备份** 保存一份密钥备份。

遇到启动、记录或转写问题时，见[常见问题](docs/troubleshooting.md)。

想加桌面小组件：在桌面空白处右键，选“编辑小组件”，搜索 Tacit。

> [!NOTE]
> 整理每 15 分钟跑一轮，调用模型会消耗你的 API 额度或账号用量。花多少取决于当天的活动量、是否导入历史，以及你选的模型。

## 连接 AI

| 工具 | 主动查询历史 | 新会话带入项目进展 |
| --- | :---: | :---: |
| Claude Code | ✓ | ✓ |
| Codex | ✓ | ✓ |

连上之后，可以直接这样问：

```text
昨天下午我主要在做什么？
这个项目上次定了哪些事，还有什么没做完？
把这次讨论的结论记到历史里。
```

AI 以读取为主，每次读取都留审计记录。往历史里补写内容只在你明确要求时发生，只追加、不修改，写入前会拦截密钥。

整理用的模型和 AI 工具可以分开选。支持 Anthropic、OpenAI 兼容接口、自定义服务地址，以及本机已登录的 Claude Code / Codex。

## 数据与隐私

> [!IMPORTANT]
> 数据保存在本机，不等于永远不离开本机。用云端模型整理时，相关文字会发给你配置的模型服务；AI 工具查询到的内容也会进入它的会话。Tacit 不收集遥测，也不提供云端托管。

- **加密存储**：数据库、原始音频和待发送记录都加密保存，密钥在 macOS 钥匙串里。密钥丢了，内容就无法恢复，记得做密钥备份。
- **不存截图**：截图只在内存里用来识字。原始音频默认保留 7 天，可以改天数；转写出的文字、事项和时间线不受这个期限影响。
- **录音**：只在本机转写。没有你声音的对话不转写，开会时例外。
- **私密内容**：标成 `private` 的记录不参加整理，也不会自动带入新会话；AI 主动查询时仍然能读到。
- **密钥拦截**：已知格式的密钥和令牌在写入前拦下，从不落盘，但识别不了所有格式的秘密。

<details>
<summary>采集过滤和其他细节</summary>

- 屏幕采集跳过 Apple 密码、钥匙串访问、1Password、Bitwarden、LastPass、Dashlane 和 Proton Pass。
- 浏览器隐私窗口靠标题识别，部分浏览器或语言可能漏判，处理私密内容前请先暂停记录。
- 目前不能自定义排除哪些应用。
- 后台只监听本机，不对局域网开放。
- 第三方数据源只能读取你确认过的范围，不能联网、写文件或启动子进程；系统隔离不可用时拒绝运行。
- 数据在 `~/Library/Application Support/record-anything/`，不会进源码仓库。提交 Issue 时，请不要附上历史正文、密钥、音频或别人的隐私内容。

</details>

## 常见问题

<details>
<summary><b>和录屏回放类工具有什么不同？</b></summary>

Tacit 不保存截图，也不做画面回放。它关心的是“你做了什么、定了什么”：主要读 AI 会话、聊天和录音，整理成能点回原文的结论，再交给 AI 接着用。屏幕只提供时间和应用信息。

</details>

<details>
<summary><b>第一次打开为什么被系统拦下？</b></summary>

安装包用固定的自签名证书签名，没有经过 Apple 公证。放行一次以后，后续升级都用同一张证书，已经授予的系统权限会保留。

</details>

<details>
<summary><b>不想用云端模型可以吗？</b></summary>

整理模型可以选本机已登录的 Claude Code / Codex，或任意 OpenAI 兼容接口（包括自己部署的服务）。录音转写一直在本机完成。

</details>

<details>
<summary><b>支持 Intel Mac、Windows 或手机吗？</b></summary>

目前只有 Apple 芯片 Mac 版。Android（只录音，汇总到 Mac）排在 Mac 版验收完成之后。

</details>

<details>
<summary><b>AI 会不会把我的记录改乱？</b></summary>

AI 只能读取和追加，不能修改或删除。AI 记错的地方，你可以在项目页或事项里改正；你写的内容优先于自动推断。

</details>

## 当前状态

Tacit 是**开发预览**，已经在开发机上持续使用，以下几项还在验收或尚未覆盖：

- 全天资源占用和记录准确率还在验收；总结可能遗漏或理解错，重要结论请点回原文核对。
- Git、终端命令、文件、剪贴板、日历这几个来源已删除，已有记录仍可搜索；第三方插件安装和本地模型的入口暂时收起。
- 开发机关闭了 SIP，文件类权限还要在开启 SIP 的 Mac 上复核；首次打开的系统放行流程还没在全新 Mac 上实测。
- 还不支持 Android、多设备配对和同步。

## 更新与卸载

**更新**：下载新版本的 dmg，先从菜单栏右键菜单退出 Tacit，再把新版本拖进“应用程序”替换。数据、设置、系统权限和 AI 工具连接都会保留。

**卸载**：在终端运行下面这行，它会问你要不要一并删除数据。

```sh
sh /Applications/Tacit.app/Contents/Resources/uninstall.sh
```

## 开发

| 目录 | 内容 |
| --- | --- |
| `collector/` | Swift / SwiftUI 菜单栏应用、采集、录音、本地转写和桌面小组件 |
| `hub/` | Bun 后台服务、加密数据库、整理任务和 AI 接口（MCP） |
| `web/` | 网页状态页 |
| `site/` | 官网 [tacit.jinso.top](https://tacit.jinso.top)，零依赖静态页，部署见 `site/README.md` |
| `plugins/`、`schema/` | 内置数据源、记录格式与跨端测试样例 |

<details>
<summary>从源码安装</summary>

需要完整的 Xcode（Swift 6 及以上，含 `actool`）和 [Bun](https://bun.sh)。先打开一次 Xcode 装好组件，只有 Command Line Tools 不够编译应用资源。

```sh
git clone https://github.com/JinSooo/tacit.git
cd tacit
bun install --frozen-lockfile
./install.sh
```

仓库目前是私有的，克隆需要有权限的 GitHub 账号。`./install.sh` 在本机构建、签名并装进“应用程序”，然后执行和安装包第一次打开时相同的准备流程；重复运行就是升级，`./uninstall.sh` 卸载。

</details>

<details>
<summary>测试</summary>

在仓库根目录运行：

```sh
bun test
bun x tsc --noEmit
bun x vite build --config web/vite.config.ts

# 需要先准备安装脚本下载的本机音频库
python3 scripts/guarded-run.py --memory-mb 3072 --seconds 240 -- collector/swift.sh test -j 2
./scripts/export-icons.sh --check
```

测试只用合成记录和临时数据目录。`./install.sh` 会改动本机安装和后台服务，不要把它当作测试命令。

</details>

更多文档：[设计与验收](docs/design.md) · [安装与发布](docs/installation.md) · [接口契约](docs/contracts.md) · [界面规范](docs/ui.md) · [插件开发](docs/plugins.md) · [性能采样](scripts/performance-sampling.md)

## 许可证

代码采用 [MIT License](LICENSE)。第三方依赖、字体和下载的模型遵循各自的许可证；内置 Phosphor 字体的许可证见 [资源目录](collector/Resources/Phosphor/LICENSE)。
