# Tacit for Android

Tacit 在手机上只做一件事：录下有你声音的对话，在本机转写，再同步到 Mac。离开电脑时的当面交谈、开会和电话外放是 Mac 拿不到的，手机补的就是这一块。聊天通知和应用使用 0.4.2 起不再记录。

录音在设备上加密暂存，只有在相同场次的保留素材中识别到已确认的“我”，才会在本机转写并写入历史。应用只有一页，按天列出录下的对话，点开可阅读、复制或删除。

第一次打开时点“开启”授权并开始录音，之后打开 Tacit 就会自动接上；在设置第一行或通知栏可以关掉。首次使用时试听并确认“这是我”。语音模型在录音设置中下载或从已校验的本地模型目录导入。转写使用 SenseVoice CPU 模型，支持的骁龙 8 Gen 3 设备可选 QNN 加速并回退到 CPU。HyperOS 的自启动和电量管理入口见“设置 → 后台运行”。

历史保存在 SQLCipher 数据库中，密钥由 Android Keystore 保护，写入前会脱敏。录音和声音文件用一把随机数据密钥加密，数据密钥由 Android Keystore 包裹、每次启动只解开一次；旧版逐个文件用 Keystore 加密的文件仍能读，小文件在首次加载时改写成新格式。未连接 Mac 时，记录保存在手机。安装包 `Tacit-<版本>.apk` 挂在 GitHub Release 上，只支持 arm64 手机（Android 9 或更新）。覆盖安装需沿用正式签名和 `top.jinso.tacit` 包名，见 [安装说明](../docs/installation.md#发布安装包)。旧版本采集的聊天通知和应用使用记录留在手机上，尚未同步的会继续同步到 Mac，在 Mac 上可以搜索。

## 连接 Mac

1. 在 Mac 的 Tacit 设置里生成配对邀请。邀请 10 分钟有效，只能用一次。
2. 在手机上打开“设置 → 连接 Mac”，扫描二维码或粘贴邀请链接。手机找不到 Mac 时，可以在同一页填写 Mac 地址。
3. 连接后，这台手机的文字记录会同步到 Mac。Mac 对这些记录的删除和修正也会同步到手机。相机只在点击“扫码”时申请权限。

录音仍保存在手机。Mac 上确认过“我”的声音时，手机会优先用该声纹判断是否有“我”；Mac 尚无声纹时，继续用手机上已确认的标记。录音保留期随 Mac 的设置更新。“断开连接”会清除手机上的配对资料。在 Mac 上管理旧设备及其记录。

## 构建

Android SDK 35、JDK 17、已缓存的 Gradle 依赖，以及 `app/libs/` 下的两份 sherpa-onnx AAR。应用打包 arm64-v8a 的 QNN 兼容 AAR。CPU AAR 是生成它时使用的上游依赖。

```sh
export JAVA_HOME=/opt/homebrew/opt/openjdk@17
export ANDROID_HOME="$HOME/Library/Android/sdk"
./scripts/verify.sh
```

两份 AAR 已在本地时，上述验证不联网。缺少 AAR 时，`scripts/prepare-speech.sh` 从固定的上游产物准备并校验依赖，这一步需要网络或已填充的产物缓存。语音模型在应用内单独准备。

更多验证步骤见 [验证说明](docs/verification.md)。
