# 安装、后台服务与发布

新用户先看根目录的 [README](../README.md)。这里写安装后应用自己做了什么、怎么发布安装包，方便排查。

## 应用包里有什么

`Tacit.app` 自带后台需要的一切，运行不依赖源码目录，也不需要用户自己装 Bun：

| 位置 | 内容 |
| --- | --- |
| `Contents/MacOS/Tacit` | 菜单栏应用（采集端） |
| `Contents/MacOS/ra-audio-worker` | 本机转写进程 |
| `Contents/Helpers/Tacit` | 后台运行时（Bun），来源须为 Bun 官方签名版本，拷入后改名并用本应用证书重签，沿用原有权限；系统“后台运行”提示因此显示 Tacit |
| `Contents/PlugIns/TacitWidget.appex` | 中号和大号桌面小组件，与主应用使用同一张证书签名 |
| `Contents/Resources/runtime/` | 后台服务、整理、内置数据源和网页的固定快照 |
| `Contents/Resources/uninstall.sh` | 卸载脚本 |

## 首次打开与升级后打开

应用必须从“应用程序”（`/Applications` 或 `~/Applications`）打开。从安装盘或被系统临时挪动的位置打开时，只提示用户拖进“应用程序”并退出，不注册任何后台服务。

每次从“应用程序”打开，应用都在后台运行一次 `bun runtime/hub/src/cli.ts setup --app <应用路径>`，输出写到 `logs/setup.log`（`hub/src/setup.ts`）：

- 应用路径或构建号与 `app-setup.json` 记录的不同（首次打开、升级）时完整准备：创建数据目录，在钥匙串里创建或读取数据库密钥并试开数据库，更新 `collector.json`，并将已连接的 Claude Code、Codex 迁到新路径。
- 写三个 LaunchAgent：`dev.record-anything.hub`、`dev.record-anything.distill` 和 `dev.record-anything.collector`。内容有变化或刚完整准备过时，重启后台服务和整理，等后台健康检查通过；没有变化时什么都不做。
- 后台服务和整理的 PATH 先取用户登录 shell 的 PATH，再补常见位置，用来找到本机已登录的 `codex`、`claude`。优先用稳定的同名入口，CLI 升级只改链接目标时不用重新准备。后来才装 CLI 的，重新打开 Tacit 即可。
- 关闭登录启动时，启动项保存在数据目录的 `launch-agents/`，升级沿用这个选择。

整理每 15 分钟处理一轮，异常退出后由 launchd 重新拉起，重启间隔至少 60 秒，以后台、低优先级 I/O 和 Nice 10 运行。日志在 `~/Library/Application Support/record-anything/logs/`。模型配置位于数据目录的 `models.json`；文件不存在时默认使用本机已登录的 Claude CLI（minute 用 haiku，hour、day 用 sonnet）。CLI 的登录由各自管理，Tacit 不读取它们的令牌。

后台服务在开始监听前失败时，数据目录里的 `hub-startup-error.json` 会记录失败时间、错误码和说明，监听成功后删除。准备日志 `logs/setup.log` 达到 5 MiB 时轮转，保留最近两份副本。

## 语音模型

第一次开启录音时，应用调用 `cli.ts audio-models` 把约 270MB 的模型下载到数据目录的 `models/`，逐个校验 sha256 后再放进去（`hub/src/audio-models.ts`）。SenseVoice 优先从 Hugging Face 单独下载，失败时改从 GitHub 下载约 1GB 的整包取出。下载失败的，录音状态里会显示原因，60 秒后随下一次启动录音重试。

## 从源码安装

`./install.sh` 准备推理库（`scripts/fetch-audio-lib.sh`）、构建网页、构建并签名应用、装进“应用程序”，然后运行同一个 `setup`，并额外启动菜单栏应用。升级前会校验签名并在数据目录的 `install-rollback` 暂存原应用包、启动项和采集端配置。

升级时暂存已有的 Tacit 应用包。切换或后台准备失败时恢复原应用和启动项，并尝试重新加载原先运行的任务。

不希望整理自动运行时执行 `RA_NO_DISTILL=1 ./install.sh`：停用整理并记住这个选择，之后打开应用也不会加回来。再运行一次不带这个变量的 `./install.sh` 即可恢复。

## 桌面小组件

从“应用程序”打开 Tacit 后，在桌面空白处右键选择“编辑小组件”，搜索 Tacit 并添加“Tacit 时间线”。点击小组件应打开当日时间线。主程序在启动、唤醒、记录变更和每 10 分钟检查一次当天整理结果，变化时刷新小组件。

主程序把中号和大号小组件所需的当天概述、活动时段和最近几段（大号展示四至五段）写到 `~/Library/Application Support/record-anything/widget/today.json`。该目录只给小组件沙盒授予只读访问。跨天后小组件切到新的一天，主程序在零点或重新运行时移除旧文件。卸载时即使保留历史记录也会清理该目录。

在开启 SIP 的全新机器上验证小组件时，建议首次打开后生成当天整理再从图库添加小组件，确认首次添加与后续刷新均不弹出“访问其他 App 的数据”授权，显示的内容与当天时间线一致，并核对点击跳转和跨天清理。

## 发布安装包

Mac 和 Android 各自发版、版本号各自递增，哪端有改动就只发哪端。Mac 安装包里带着后台服务（含服务端 Docker 形态），两者算一端。两端靠设备协议（`docs/contracts.md` 第 6 节的 `v`）兼容，应用版本号不必对齐；协议有不兼容的改动时，在 Release 说明里写明需要的对端最低版本。

Mac：

1. 改版本号：`package.json`、`collector/build.sh` 的 `CFBundleShortVersionString`、`hub/src/agent-cli/mcp.ts` 的 serverInfo（以及对应测试）；`scripts/release-version.test.ts` 检查这几处一致。若改动了官网源码 `site/src/`，顺手运行 `bun site/build.ts` 同步 `site/dist/`。提交并打 `mac-v<版本号>` tag。
2. 在已配置代码签名证书的 Mac 上运行 `scripts/release-dmg.sh`。它只在干净工作区、tag 指向当前提交时构建，输出 `dist/Tacit-<版本号>.dmg` 和 `.sha256`，并从挂载的安装包里校验签名和自带运行时。
3. 推送 tag，建 Release 并上传这两个文件：`gh release create mac-v<版本号> dist/Tacit-<版本号>.dmg dist/Tacit-<版本号>.dmg.sha256 --prerelease --title "Tacit v<版本号> - Mac" --notes-file <说明>`。

Android：

1. 改 `android/app/build.gradle.kts` 的 `versionName`，`versionCode` 加 1。提交并打 `android-v<版本号>` tag。
2. 在已配置 Android 正式签名钥匙的环境下运行 `scripts/release-apk.sh`，前提条件同上，输出 `dist/Tacit-<版本号>.apk` 和 `.sha256`，只打 arm64-v8a。
3. 推送 tag，建 Release 并上传这两个文件：`gh release create android-v<版本号> dist/Tacit-<版本号>.apk dist/Tacit-<版本号>.apk.sha256 --prerelease --latest=false --title "Tacit v<版本号> - Android" --notes-file <说明>`。`--latest=false` 免得 Android 版被标成最新。注意 GitHub 的 `releases/latest` 不认预发布版，两端都是预发布时这个地址是 404，所以 README 和官网的下载链接指向 `releases` 列表页。

Release 标题只用 `Tacit v<版本号> - Mac` 和 `Tacit v<版本号> - Android` 两种，“开发预览”由 GitHub 的 Pre-release 标记表达，不写进标题。

> 签名一致性说明：macOS 用户授予的辅助功能、录屏、麦克风等系统权限绑定在固定的自签名代码签名证书上；Android 覆盖升级同样依赖同一把正式签名钥匙。证书和签名钥匙需妥善离线备份，缺失时发布脚本会直接失败而不会自动新建。未配置正式 Android 钥匙的机器，调试构建会自动退回 Android 默认调试钥匙。
