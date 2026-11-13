# Record Anything

把你在 Mac 上做过的事记成文字，由 AI 整理成“在做哪些事、进展到哪了”，再交给 Claude Code、Codex 这些 AI 工具。新开一个会话，它就已经知道你最近在忙什么。

- 记录屏幕上的文字、浏览器访问、终端命令、AI 会话、录音转写等，只存文字，不存截图。
- 所有数据都在你自己的 Mac 上，加密保存；不收集任何使用数据。
- 只在 Apple 芯片的 Mac 上运行，需要 macOS 14 或更新版本。

## 安装

先装好两样东西（装过可以跳过）：

1. Xcode 命令行工具：在终端运行 `xcode-select --install`
2. bun：在终端运行 `curl -fsSL https://bun.sh/install | bash`，装完重新打开终端

然后把这个仓库下载到本机（`git clone` 或下载 ZIP 解压），在终端进入这个文件夹，运行：

```sh
./install.sh
```

第一次安装要下载语音识别模型，所需时间取决于网速。

## 第一次使用

1. 菜单栏右上角会出现 Record Anything 图标。macOS 会请你在“辅助功能”里允许它，打开后才能开始记录。
2. 点图标，从面板里打开主窗口。“此刻”页会列出还差的几步，跟着点就行：
   - 打开系统权限
   - 确认 AI 能整理你的记录（默认用这台 Mac 上已登录的 Claude Code；也可以在设置 → AI 模型里改成 Codex 或 API）
   - 接入 Claude Code 或 Codex
3. 正常用电脑就好。每 15 分钟整理一次，“此刻”页会出现你正在做的事。
4. 在 Claude Code 或 Codex 里新开一个会话，它会自动带上当前项目的进展；也可以直接问它“我昨天下午在做什么”。

建议做完后备份密钥：设置 → 维护 → 密钥备份。记录都加了密，密钥丢了就打不开。

## 常见问题

**哪些内容不会被记录？** 密码管理器、钥匙串、浏览器隐私窗口里的内容不记录；API key、令牌这类密钥在存之前就会被替换掉。随时可以在菜单栏里暂停记录。完整规则在设置 → 隐私。

**录音会上传吗？** 不会。录音在本机转成文字，原始音频加密存在本机，默认 7 天后自动删除。

**怎么更新？** 在仓库目录运行 `git pull && ./install.sh`。

**怎么卸载？** 运行 `./uninstall.sh`。它会问你要不要把数据一起删掉。

## 更多

- 设计说明：[docs/design.md](docs/design.md)
- 安装细节和整理进程：[docs/installation.md](docs/installation.md)
- 接口和记录格式：[docs/contracts.md](docs/contracts.md)
- 界面规范：[docs/ui.md](docs/ui.md)

MIT 许可证。

### 扩展数据源

Mac 设置 → 数据源 → 安装数据源，选择本地目录或 Git 地址，预览权限和配置后安装，默认停用。详情中可配置、运行、更新及卸载。开发规范与示例见 [docs/plugins.md](docs/plugins.md)。
