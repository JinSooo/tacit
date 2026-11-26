<!-- source: android/README.md @ 91280eadb388ecfd49a3c557377dcf3b42a5a51a -->

[English](README.md) | 简体中文

# Tacit for Android

Tacit Android 端用于在离开电脑时录下包含你声音的对话，在本机完成语音转写，并与 Mac（或独立部署的 Tacit 中枢）通过端到端加密协议同步。配对为“查看”权限时，首页可直接同步查看中枢整理的各来源时间线；也可以在设置中可选开启手机端单场 AI 总结。使用录音功能请自行遵守当地法律法规并提前告知对话方。

录音在设备上加密暂存，只有在相同场次的保留素材中识别到已确认的“我”，才会在本机转写并写入历史。应用只有一页，按天列出时间线或本机对话，点开可阅读、复制或删除。

第一次打开时点“开启”授权并开始录音，之后打开 Tacit 就会自动接上；在设置第一行或通知栏可以关掉。首次使用时试听并确认“这是我”。语音模型在录音设置中下载或从已校验的本地模型目录导入。转写使用 SenseVoice CPU 模型，支持的骁龙 8 Gen 3 设备可选 QNN 加速并回退到 CPU。部分定制系统（如 HyperOS）的自启动和电量管理入口见“设置 → 后台运行”。

历史保存在 SQLCipher 数据库中，密钥由 Android Keystore 保护，写入前会脱敏。录音和声音文件用一把随机数据密钥加密，数据密钥由 Android Keystore 包裹。未连接中枢时，记录保存在手机本地；若在设置中开启“AI 总结”，非私密对话的转写文本会发送给你配置的 OpenAI 兼容模型服务（默认关闭）。安装包 `Tacit-<版本>.apk` 随 GitHub Releases 提供，只支持 arm64 手机（Android 9 或更新）；覆盖安装需沿用同一正式签名和 `top.jinso.tacit` 包名，见 [安装说明](../docs/zh/installation.md#发布安装包)。内置第三方组件及模型（`sherpa-onnx`、ONNX Runtime、FunASR、Qualcomm QNN、Phosphor）的许可证见 `app/src/main/assets/licenses/`。

## 连接 Mac / 中枢

1. 在 Mac 的 Tacit 设置里生成配对邀请（默认查看权限，可在采集与查看间切换）。邀请 10 分钟有效，只能用一次。
2. 在手机上打开“设置 → 连接 Mac”，扫描二维码或粘贴邀请链接。手机找不到 Mac 时，可以在同一页填写地址或配置中转信箱。
3. 连接后，这台手机的文字记录（及可选的手机端单场总结）会同步到中枢，删除和修正双向同步；查看权限下还会下推中枢整理的时间线。相机只在点击“扫码”时申请权限。

录音仍保存在手机。Mac 上确认过“我”的声音时，手机会优先用该声纹判断是否有“我”；Mac 尚无声纹时，继续用手机上已确认的标记。录音保留期随中枢的设置更新。“断开连接”会清除手机上的配对资料。

## 构建

Android SDK 35、JDK 17、已缓存的 Gradle 依赖，以及 `app/libs/` 下的两份 sherpa-onnx AAR。应用打包 arm64-v8a 的 QNN 兼容 AAR。CPU AAR 是生成它时使用的上游依赖。

```sh
export JAVA_HOME=/opt/homebrew/opt/openjdk@17
export ANDROID_HOME="$HOME/Library/Android/sdk"
./scripts/verify.sh
```

两份 AAR 已在本地时，上述验证不联网。缺少 AAR 时，`scripts/prepare-speech.sh` 从固定的上游产物准备并校验依赖，这一步需要网络或已填充的产物缓存。语音模型在应用内单独准备。
