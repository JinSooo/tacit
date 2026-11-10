# 安装与整理进程自启

新用户先看根目录的 [README](../README.md)。这里写安装脚本做了什么，方便排查。

运行 `./install.sh` 会构建并注册当前用户的 LaunchAgent：hub、采集端和
`dev.record-anything.distill`。安装时先启动 hub，通过健康检查后才启动提炼。
LaunchAgent 在用户登录时启动；提炼每 15 分钟处理一轮，异常退出后由 launchd
重新拉起，重启间隔至少 60 秒，并以后台、低优先级 I/O 和 Nice 10 运行。

不希望提炼自动运行时，执行：

```sh
RA_NO_DISTILL=1 ./install.sh
```

这也会停止已注册的提炼进程并删除其 plist，保留数据和模型配置。以后运行
`./install.sh` 可恢复提炼自启。`./uninstall.sh` 会一并移除三个 LaunchAgent。

提炼标准输出与错误都写入
`~/Library/Application Support/record-anything/logs/distill.log`。模型配置位于
`~/Library/Application Support/record-anything/models.json`；文件不存在时默认使用
本机已登录的 Claude CLI（minute 用 haiku，hour、day 用 sonnet）。已有配置按文件生效。

安装脚本通过 `command -v codex` 和 `command -v claude` 找到命令，用 realpath
解析符号链接，把真实目录、必要的同名入口目录、Bun 目录及系统目录加入提炼的 PATH。
临时 shim 不会写入 PATH：优先解析到稳定的真实入口，否则查找 mise shims、
`~/.local/bin`、`~/.bun/bin`、`~/.npm-global/bin`、Homebrew 等稳定位置。
只有临时或无效入口且找不到稳定替代时，安装报错退出；完全未找到某个 CLI 时会提示并跳过。
安装或移动 CLI 后需重新运行安装脚本更新 PATH。CLI 的登录仍由各自管理，安装脚本不读取令牌。
