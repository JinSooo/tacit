# Tacit Android 收敛清单

2026-11-16 核对了本地分支的提交树和 Android 工作区。按[收敛任务书 D10 与 T11](refocus-plan-2026-11-16.md#t11-android)，Android 范围为录音、聊天通知和应用使用骨架，整理在 Mac 完成。

## 分支与可复用的代码

| 分支与提交 | 可复用的部分 | 冻结或留在本地的部分 |
|---|---|---|
| `codex/android-audio` · `d724ad3` | Mac 侧音频开发的基础提交 | 提交树没有 `android/` |
| `codex/android-sources` · `de727a2` | 应用使用、通知串行队列和锁屏采集 | 无障碍读取屏幕正文 |
| `codex/android-local-audio-v2` · `8290d2c` | 本机录音、加密音频、场次、声纹和转写，含避免重复写录音索引 | 沿用早期采集器，其中屏幕正文不进入同步 |
| `codex/android-local-sources-v2` · `2b53c24` | 沿用基础通知和应用使用采集 | 这一分支新增的短信、通话元数据、文件、照片、日历和位置采集 |
| `codex/android-local` · `8dde349` | 上述两条开发线的本地存储与录音实现 | 通用本地来源与屏幕正文 |
| `codex/android-onboarding-complete` · `fa5c32e` | 录音准备、通知监听和使用情况权限的引导与恢复 | 其余来源的授权和采集入口 |
| `codex/android-sources-complete` · `c7467c4` | 授权录音目录导入，供录音判断使用的日历会议上下文 | 离线图片 OCR、作为独立来源的日历正文 |
| `codex/android-local-review` · `991f012` | 已集成的录音、通知、使用时长和本地配置恢复 | 对话小结、本机总结模型及图片文字 |
| `codex/android-speech-complete` · `504b57d` | 设备端 VAD、ASR、声纹，SM8650 QNN 加速及 CPU 后备路径 | 从上述分支继承的手机总结和额外采集 |
| `codex/mobile-settings-review` · `81b7195` | 应用名称检索与选择，可接到聊天应用范围设置。录音和来源设置的页面分工 | 额外来源的设置及手机整理入口 |
| `codex/mobile-activity-summary` · `ac065cd` | 原有使用片段仍可作为时间骨架 | 手机每日概览、多段合并、推理断点和模型运行 |
| `codex/android-local-complete` · `012b9fa` | 已集成上述三类采集，可作为对照其他分支的基准 | 同一提交树也含本机日总结、对话总结和额外采集。Android 工作区还有未提交的总结调整和图标等改动 |

`012b9fa` 中，录音入口和加密素材在 `audio/AudioRecorderService.kt` 与 `audio/EncryptedAudioStore.kt`，本机转写在 `audio/AudioProcessor.kt`。通知由 `sources/NotificationSource.kt` 接收，已有权限检查、有界队列和私密通知排除，当前可接收多个应用的通知。同步范围还需限定到用户允许的聊天应用。应用使用由 `sources/UsageWorker.kt` 取得前后台事件，发送范围限应用和时间段。路径相对于 `android/app/src/main/java/top/jinso/tacit/`。

## 配对与同步缺项

1. **设备配对和接收入口**。当前 [Mac 中枢](../hub/src/server.ts)只监听回环地址并校验本机 Host，Android 尚无配对流程或记录上传接口。按[设计第 9.1 节](design.md#91-网络)补设备身份、配对确认、可撤销的设备凭据和 HPKE 接收。手机只取得该设备需要的权限。
2. **按三类来源出队**。Android 的 `data/Vault.kt` 已用 SQLCipher 存本机记录，并在写入时生成含 `schema`、`id`、`device`、`source_ref` 和敏感度的 JSON。仍需对照 [RecordV1 和入库接口](contracts.md#3-hub-接口)验证字段、时区与身份，保存待发送批次和重试状态，按接收结果确认、重发或报告拒绝。录音上传的是转写文字和约定的元数据，原始音频留在本机。
3. **删除和修正回传**。两端已有本机修正与墓碑，现有 `POST /v1/ingest` 支持按 ID 或来源引用去重。还缺配对范围内的删除和修正增量、确认游标，以及重试和乱序时避免已删内容回流的验证。Mac 要按已有删除规则撤下受影响的派生内容。
4. **真实通路验收**。用新配对 Mac 和手机验证三种记录到达、断网后补传、重复发送去重和两端删除与修正。现有 Android 设备报告只证明本地采集、存储和模型相关用例，配对和同步还没有真机结果。

本次核对以提交树、现有 Android 工作区和 Mac 接口为依据，交付这份清单。
