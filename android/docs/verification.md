# Tacit Android 验证

## 离线构建

使用 JDK 17 和 Android SDK 35，将 `sherpa-onnx-2.0.1.aar` 与 `sherpa-onnx-2.0.1-qnn-arm64.aar` 置于 `app/libs/`。运行 `./scripts/verify.sh` 检查语音 ABI、运行 JVM 单测、构建 APK、运行 lint 并编译仪器测试 APK。完整上游 ABI 对照还需要官方 QNN APK 缓存，可通过 TACIT_SPEECH_ABI_APK 指定本地文件。

```sh
./gradlew --offline testDebugUnitTest assembleDebug lintDebug
```

调试 APK 位于 `app/build/outputs/apk/debug/app-debug.apk`，应用 ID 为 `top.jinso.tacit`。检查包信息和签名时，可在 SDK 35 的 build-tools 中使用 `aapt dump badging` 和 `apksigner verify --print-certs`。

## 后续设备验收

- 用同一签名从 0.3.0 覆盖安装，在历史页确认旧记录能查看和删除，录音声纹和本机语音模型仍可用。
- 启用聊天通知并授权。用两个应用发送虚构消息，确认默认只记录微信。添加第二个聊天应用后检查会话名、发送人和正文，移除后继续发消息应不再保存。检查私密通知、通知分组摘要、快捷回复和隐藏预览。
- 启用应用使用并授权。切换应用、锁屏和解锁后核对前台应用及起止时刻。
- 从录音页开始录音，试听标记“我”。分别测试只有他人的对话和有“我”的对话，核对前者无历史记录、后者可在本机转写。按硬件分别核对 QNN 与 CPU 路径。
- 在 HyperOS 上检查暂停、重启、服务被停止后的恢复提示，确认录音可从前台手动开始。测试桌面快捷补写、内容脱敏、修正及删除。

## 同步接入

`Sources.UPLOADABLE` 给出五个允许的来源。同步接入可按 ID 调用 `Vault.uploadableWire` 获取已通过来源和修正链校验的 JSON。`Vault.wire` 仍可读取本地原始载荷。0.3.0 的通知、旧录音、旧格式修正及已撤来源保留在本机。删除沿用 `Vault.delete`，同一事务删除修正链并为有来源引用的记录写入去重墓碑。配对与传输由后续任务实现。
