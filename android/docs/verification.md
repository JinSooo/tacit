# Tacit Android 验证

## 离线构建

使用 JDK 17 和 Android SDK 35，将 `sherpa-onnx-2.0.1.aar` 与 `sherpa-onnx-2.0.1-qnn-arm64.aar` 置于 `app/libs/`。运行 `./scripts/verify.sh` 检查语音 ABI、运行 JVM 单测、构建 APK、运行 lint 并编译仪器测试 APK。完整上游 ABI 对照还需要官方 QNN APK 缓存，可通过 TACIT_SPEECH_ABI_APK 指定本地文件。

```sh
./gradlew --offline testDebugUnitTest assembleDebug lintDebug
```

调试 APK 位于 `app/build/outputs/apk/debug/app-debug.apk`，应用 ID 为 `top.jinso.tacit`。检查包信息和签名时，可在 SDK 35 的 build-tools 中使用 `aapt dump badging` 和 `apksigner verify --print-certs`。

## 后续设备验收

- 用同一签名从 0.4.1 覆盖安装，确认录下的对话、录音声纹和本机语音模型仍可用，系统设置里不再出现 Tacit 的通知使用权和使用情况访问，桌面上旧的“写一条记录”快捷方式已停用。
- 在对话页点“开启”开始录音，试听标记“我”。分别测试只有他人的对话和有“我”的对话，核对前者无历史记录、后者可在本机转写。按硬件分别核对 QNN 与 CPU 路径。
- 在 HyperOS 上重启或停止服务后打开 Tacit，确认录音自动接上；在设置里关掉后再打开，确认不会自动开始、页首出现“录音没有开启”。测试转写脱敏、复制及删除。

## 真机仪器测试

只用 `ANDROID_HOME=$HOME/Library/Android/sdk python3 scripts/verify-device.py`（覆盖安装，不卸载、不清数据）；它不编译，先跑 `./scripts/verify.sh` 产出两份 APK。不要用 Gradle 的 `connectedDebugAndroidTest`，它会卸载应用、清空手机数据。

语音和 NPU 用例需要两样测试素材，缺了会以“前提不满足”跳过，脚本把这类跳过算作错误：

- 合成语音：在 Mac 上用装好的中文语音生成含“本地”“记录”的句子，转成 16 kHz 单声道小端 16 位原始 PCM，放进应用私有目录 `files/speech-fixture.pcm`：

  ```sh
  say -v Tingting -o fx.aiff "这是一段本地记录的测试语音。今天的本地记录已经整理好了，记录会保存在手机上。"
  afconvert -f WAVE -d LEI16@16000 -c 1 fx.aiff fx.wav   # 再去掉 WAV 头得到 fx.pcm
  adb shell "run-as top.jinso.tacit tee files/speech-fixture.pcm > /dev/null" < fx.pcm
  ```

  部分中文语音（Eddy、Flo、Ting-Ting）在 Mac 上没下载时只输出 0.01 秒，先确认时长。
- SM8650 的 QNN 模型：从 `QnnCatalog.archive` 的地址下载，核对 `QnnCatalog` 里的大小和 SHA-256，只解出 `model.bin`、`tokens.txt`，放进 `no_backup/qnn-models/incoming/`，测试会自行校验并启用。启用后应用平时转写会自动走 NPU；用户没开过加速时，测完删掉 `no_backup/qnn-models/` 下的模型目录和 `current`，恢复只用 CPU。

覆盖安装会停掉录音服务，测完打开一次 Tacit 让录音自动接上。

## 配对与同步

JVM 单测从仓库读取中枢生成的向量，逐字节验证配对、同步请求及两种回复。测试覆盖邀请过期、回执校验、发送副本的设备编号、分页保存与确认顺序，以及收到明文 401 后停止请求。

JDK、Android SDK 和 Gradle 依赖就绪后，使用 Bun 与仓库已有的中枢依赖运行端到端脚本。若依赖已安装在其他 checkout，可通过 Bun 的 `NODE_PATH` 指向其 `node_modules`。

```sh
./scripts/e2e-hub.sh
```

脚本用临时目录和注入的测试密钥启动真实中枢。Android 应用的纯 Kotlin 协议层执行地址核验、配对、上传、重复回执和单条拒收、手机发起的删除、接收 Mac 修正和删除、确认下发、录音清理指令的确认，以及移除后的 401。脚本退出时关闭服务并清理数据目录。SQLCipher、Keystore、相机、Bonjour、WorkManager 和麦克风由 Android 测试或真机流程验证。

### 实现约定

- 原记录留在加密库中。发送时以 `Vault.uploadableWire` 为准，仅改写发送副本的 `device`。接入前已有的旧通知、旧录音和已撤来源继续留在手机。0.4.2 起手机不再写入新的聊天通知和应用使用，旧版本已采集、尚未发送的这两类记录照常发送。待发送记录在重新配对后继续发送，已确认和被拒的状态保留。断开会丢弃旧配对的删除队列。Mac 按原设备 ID 管理已收到的记录，重新配对会分配新 ID。
- Android 的网络安全配置只能按域名配置明文权限。Mac 地址和任意手填地址由运行时确定，所以应用允许明文 HTTP，由设备传输代码限制到两个协议路径、禁止重定向并核对 Mac 身份。邀请、记录、声纹和变更通过加密信封传输。模型下载的每一跳仍强制 HTTPS。
- 一页下发变更在 SQLCipher 事务中应用后确认。录音删除先清理对应素材及本地转写缓存。按日期清理只清旧音频，保留历史中的文字。Mac 的非空声纹与阈值优先；没有 Mac 声纹时使用本机标记。Mac 声纹只和手机上聚好的整个声音（累计至少 6 秒）比，不和单句比；比中的声音既决定这场对话能否转写，也在转写里标成“我”。上传限每批 200 条及 8 MiB。Android 为单页回复设置 24 MiB 接收上限以限制内存占用，异常大的修正页需等服务端支持更小分页后才能完成同步。
- 如果 Mac 移除最后一台手机并关闭局域网监听，手机只能看到连接失败。监听仍在线且返回明文 401 时，页面显示“已在 Mac 上移除，需重新配对”。

### 真机配对与同步验收

1. 同签名覆盖安装，确认历史仍可读。分别扫码、拒绝相机后粘贴、用过期链接连接，并核对页面上的 Mac 名称。
2. 切换 Wi-Fi、移动网络和手填地址。确认 Mac 换 IP 后可重新发现，错误提示与实际网络一致。移除一台设备时保留另一台配对设备，让局域网入口仍开放，确认收到 401 后停止同步。
3. 录一段新对话并确认转写完成，查看待发送数量约 30 秒后变化；断网积攒后恢复网络。检查应用退到后台及 HyperOS 电量限制下的周期任务和退避。
4. 双向删除及从 Mac 修正，检查手机重启后仍正确，已删除的记录不被重传，手机上收到的 Mac 修正不作为新的手机记录上传。
5. 在 Mac 确认“我”的声纹后录制本人和他人的样本，核对转写门槛与手机本机标记的回退。测试 Mac 的保留期、清理和删除对话，确认只留应保留的素材及历史文字。
