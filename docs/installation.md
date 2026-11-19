# 安装、后台服务与发布

新用户先看根目录的 [README](../README.md)。这里写安装后应用自己做了什么、怎么发布安装包，方便排查。

## 应用包里有什么

`Tacit.app` 自带后台需要的一切，运行不依赖源码目录，也不需要用户自己装 Bun：

| 位置 | 内容 |
| --- | --- |
| `Contents/MacOS/Tacit` | 菜单栏应用（采集端） |
| `Contents/MacOS/ra-audio-worker` | 本机转写进程 |
| `Contents/MacOS/bun` | 后台运行时，保留 Bun 官方签名 |
| `Contents/PlugIns/TacitWidget.appex` | 中号和大号桌面小组件，与主应用使用同一张证书签名 |
| `Contents/Resources/runtime/` | 后台服务、整理、内置数据源和网页的固定快照 |
| `Contents/Resources/uninstall.sh` | 卸载脚本 |

## 首次打开与升级后打开

应用必须从“应用程序”（`/Applications` 或 `~/Applications`）打开。从安装盘或被系统临时挪动的位置打开时，只提示用户拖进“应用程序”并退出，不注册任何后台服务。

每次从“应用程序”打开，应用都在后台运行一次 `bun runtime/hub/src/cli.ts setup --app <应用路径>`，输出写到 `logs/setup.log`（`hub/src/setup.ts`）：

- 应用路径或构建号与 `app-setup.json` 记录的不同（首次打开、升级）时完整准备：创建数据目录，在钥匙串里创建或读取数据库密钥并试开数据库，更新 `collector.json`，把已连接的 Claude Code、Codex 迁到新路径，关闭冻结的 Git、终端、文件、剪贴板来源。
- 写三个 LaunchAgent：`dev.record-anything.hub`、`dev.record-anything.distill` 和 `dev.record-anything.collector`。内容有变化或刚完整准备过时，重启后台服务和整理，等后台健康检查通过；没有变化时什么都不做。
- 后台服务和整理的 PATH 先取用户登录 shell 的 PATH，再补常见位置，用来找到本机已登录的 `codex`、`claude`。优先用稳定的同名入口，CLI 升级只改链接目标时不用重新准备。后来才装 CLI 的，重新打开 Tacit 即可。
- 关闭登录启动时，启动项保存在数据目录的 `launch-agents/`，升级沿用这个选择。

整理每 15 分钟处理一轮，异常退出后由 launchd 重新拉起，重启间隔至少 60 秒，以后台、低优先级 I/O 和 Nice 10 运行。日志在 `~/Library/Application Support/record-anything/logs/`。模型配置位于数据目录的 `models.json`；文件不存在时默认使用本机已登录的 Claude CLI（minute 用 haiku，hour、day 用 sonnet）。CLI 的登录由各自管理，Tacit 不读取它们的令牌。

后台服务在开始监听前失败时，数据目录里的 `hub-startup-error.json` 会记录失败时间、错误码和说明，监听成功后删除。准备日志 `logs/setup.log` 达到 5 MiB 时轮转，保留最近两份副本。

## 语音模型

第一次开启录音时，应用调用 `cli.ts audio-models` 把约 270MB 的模型下载到数据目录的 `models/`，逐个校验 sha256 后再放进去（`hub/src/audio-models.ts`）。SenseVoice 优先从 Hugging Face 单独下载，失败时改从 GitHub 下载约 1GB 的整包取出。下载失败的，录音状态里会显示原因，60 秒后随下一次启动录音重试。

## 从源码安装

`./install.sh` 准备推理库（`scripts/fetch-audio-lib.sh`）、构建网页、构建并签名应用、装进“应用程序”，然后运行同一个 `setup`，并额外启动菜单栏应用。从旧名称 Record Anything 升级时先校验签名，并在数据目录的 `install-rollback` 保存原应用包、启动项和采集端配置。

升级时暂存已有的 Tacit 应用包。切换或后台准备失败时恢复原应用和启动项，并尝试重新加载原先运行的任务。

不希望整理自动运行时执行 `RA_NO_DISTILL=1 ./install.sh`：停用整理并记住这个选择，之后打开应用也不会加回来。再运行一次不带这个变量的 `./install.sh` 即可恢复。

## 桌面小组件

从“应用程序”打开 Tacit 后，在桌面空白处右键选择“编辑小组件”，搜索 Tacit 并添加“Tacit 时间线”。点击小组件应打开当日时间线。主程序在启动、唤醒、记录变更和每 10 分钟检查一次当天整理结果，变化时刷新小组件。

主程序把当天概述和最近三段的开始时刻、标题写到 `~/Library/Application Support/record-anything/widget/today.json`。该目录只给小组件沙盒授予只读访问。跨天后小组件切到新的一天，主程序在零点或重新运行时移除旧文件。卸载时即使保留历史记录也会清理该目录。

自签名扩展已在关闭 SIP 的 macOS 27.2.1 上通过桌面渲染验证。在开启 SIP 的机器上，首次打开后用虚构记录生成当天整理，再从图库添加小组件。确认首次添加和随后的刷新都不弹出“访问其他 App 的数据”授权，显示的内容与当天时间线一致，并核对点击跳转和跨天清理。

## 发布安装包

1. 改版本号：`package.json`、`collector/build.sh` 的 `CFBundleShortVersionString`、`hub/src/agent-cli/mcp.ts` 的 serverInfo（以及对应测试）。提交并打 `v<版本号>` tag。
2. 在这台有签名证书的 Mac 上运行 `scripts/release-dmg.sh`。它只在干净工作区、tag 指向当前提交时构建，输出 `dist/Tacit-<版本号>.dmg` 和 `.sha256`，并从挂载的安装包里校验签名和自带运行时。
3. 推送 tag，用 `gh release create` 建 Release 并上传这两个文件。

签名证书 “Record Anything Dev” 在 `~/Library/Keychains/ra-dev.keychain-db`，钥匙串密码在 `~/Library/Keychains/ra-dev.pass`。用户授予的系统权限绑定在这张证书上：换了证书，已安装的用户升级后要重新授予辅助功能、录屏、麦克风等权限。两个文件要一起备份；发布脚本在证书缺失时直接失败，不会新建。
