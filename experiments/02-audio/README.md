# 实验 2：Mac 本地音频前置验证

这是独立 SwiftPM 包（tools 6.0、macOS 14、语言模式与 collector 一样为 Swift 5），不接入 collector / hub，不读用户活动数据。使用已备好的 sherpa-onnx v2.0.1 C API、SenseVoice、Silero 和 eres2net。没有新增依赖、下载、签名或改动系统配置。

## 构建

从仓库根目录：

```sh
experiments/02-audio/scripts/build.sh
```

脚本将 CLANG_MODULE_CACHE_PATH、SWIFTPM_MODULECACHE_OVERRIDE、scratch、cache、config、security 全部指向本目录。实际成功命令是：

```sh
cd experiments/02-audio
export CLANG_MODULE_CACHE_PATH="$PWD/.cache/clang"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.cache/swiftpm"
swift build --disable-sandbox -debug-info-format none -c release \
  --scratch-path "$PWD/.build" --cache-path "$PWD/.cache" \
  --config-path "$PWD/.cache/config" --security-path "$PWD/.cache/security"
```

本机 Swift 6.4 默认使用 Swift Build，产物是 `.build/out/Products/Release/{bench,probe}`。`--disable-sandbox` 关闭 SwiftPM 的子进程沙箱，不会解除外层 Codex 沙箱。默认 dSYM 生成被外层沙箱拒绝，因此关闭调试信息；未改 HOME 或 TMPDIR。C module map 直接引用 vendor/include；链接器的绝对 rpath 指向当前实验目录的 vendor 库目录，移动仓库后需重新构建。仅 bench 链接 sherpa，probe 不需要 dylib。

## 2-A 基准

```sh
# 仓库根目录，完整矩阵、生成 JSON 和 RESULTS.md
experiments/02-audio/scripts/run-bench.sh

# 或在实验目录单独运行
cd experiments/02-audio
./.build/out/Products/Release/bench generate
./.build/out/Products/Release/bench int8 1
./.build/out/Products/Release/bench fp32 4
python3 scripts/report.py  # 要有全部六组 JSON
```

输入是 vendor 的 zh/en/ja/ko/yue 五个 WAV 和循环这些样例、每个样例后插入 2 秒静音、截到 600 秒的 out/long.wav。AVFoundation 解码，多声道取平均；非 16k 线性重采样。输出 WAV 是 16k、单声道、16-bit PCM。线性重采样未加抗混叠滤波，仅作前置实验。

VAD 使用 CPU、512 样本窗口、threshold=0.5、最短静音 0.5 秒、最短语音 0.25 秒、最长语音 20 秒，60 秒环形缓冲。逐窗喂入后立即取已完成语音段，末尾 flush；每段分别做 SenseVoice（auto language + ITN）和声纹。模型句柄和 C 字符串生命周期完整覆盖推理并显式释放。线程数在 VAD / ASR / 声纹三者均设置为 1、2、4，推理段串行处理。

每个配置独立进程；每个文件打印首个转写段前 40 字供目测。转写不写 JSON 或仓库，不要把终端重定向到版本控制文件。out/ 下仅有样例拼接 WAV 和不含文字的数值 JSON；原始向量也不写盘。详细方法、完整实测表和局限见 [RESULTS.md](RESULTS.md)。

<!-- measured-table -->

| 模型 | 线程 | 总加载 s | ASR 加载 s | 峰值 RSS MiB | 600s 处理 s | 600s RTF | 全输入 RTF | 长输入 VAD 段数 | 向量维度 |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| int8 | 1 | 0.404 | 0.310 | 776.6 | 21.579 | 0.0360 | 0.0366 | 76 | 512 |
| int8 | 2 | 0.346 | 0.280 | 777.0 | 11.956 | 0.0199 | 0.0203 | 76 | 512 |
| int8 | 4 | 0.329 | 0.278 | 779.1 | 7.601 | 0.0127 | 0.0129 | 76 | 512 |
| fp32 | 1 | 0.629 | 0.574 | 1325.4 | 36.999 | 0.0617 | 0.0628 | 76 | 512 |
| fp32 | 2 | 0.533 | 0.474 | 1352.0 | 19.765 | 0.0329 | 0.0335 | 76 | 512 |
| fp32 | 4 | 0.495 | 0.444 | 1325.7 | 11.853 | 0.0198 | 0.0201 | 76 | 512 |

<!-- /measured-table -->

## 2-B 录音探针（用户真机运行）

本次只编译和运行 `--help`，没有运行录音。tap/both 需要 macOS 14.2；目前整个录音入口统一检查 14.2，SwiftPM 最低部署目标仍为 14。

```sh
cd experiments/02-audio
./.build/out/Products/Release/probe --help
./.build/out/Products/Release/probe mic --seconds 10
./.build/out/Products/Release/probe tap --seconds 10
./.build/out/Products/Release/probe tap --seconds 10 --pid 12345
./.build/out/Products/Release/probe both --seconds 10
```

裸二进制不保证获得稳定的 TCC 身份，授权验收请用下述 app 包装。麦克风走 AVAudioEngine；tap 走 CATapDescription → AudioHardwareCreateProcessTap → 读取格式 → private aggregate device → IOProc → AudioDeviceStart。指定 PID 先翻译成 Core Audio process AudioObjectID；目标应正在输出声音。全局 tap 不排除进程、不静音系统播放。IOProc 支持交错/非交错 Float32 little-endian PCM，遇到不支持格式会明确报错。

每个 Core Audio 步骤打印十进制 OSStatus 和 FourCC，包括清理；AVAudioEngine 的 Swift API 打印格式或 Error。退出先停录、移除回调、销毁设备及 tap，再输出 out/mic.wav / out/tap.wav（覆盖同名文件），打印时长、RMS、首帧 hostTime。both 的两路同时保持录制，但依次启动；打印 `tap - mic` 首帧时间戳差，不能把它当作声学延迟或长时漂移。全部音频暂存内存，因此建议先测 10 秒；不用于生产持续采集。CPU 时间是本进程 user+system，峰值 RSS 按 macOS getrusage 字节值输出。

如果声音为零，先看 RMS、应用是否正在播放、PID 映射和各步 OSStatus，不能只凭创建成功认定权限或录音通过。这里只验证编译，实际授权、指定进程隔离、两路声音、设备切换和长期漂移均待用户验收。

## 授权包装和签名（仅说明，未执行）

参考 `../01-tcc/build.sh` 使用的固定自签名身份 `Record Anything Dev`，复用该证书，不重新创建随机签名身份，也不使用 ad-hoc 签名作权限保留结论。用户可在实验目录手动建立 app：

```sh
mkdir -p out/AudioProbe.app/Contents/MacOS
cp .build/out/Products/Release/probe out/AudioProbe.app/Contents/MacOS/probe
```

将以下内容存为 `out/AudioProbe.app/Contents/Info.plist`：

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>dev.record-anything.audio-probe</string>
  <key>CFBundleName</key><string>RA Audio Probe</string>
  <key>CFBundleExecutable</key><string>probe</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.0.1</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSUIElement</key><true/>
  <key>NSMicrophoneUsageDescription</key><string>音频实验需要录制麦克风，以验证本地采集和转写。</string>
  <key>NSAudioCaptureUsageDescription</key><string>音频实验需要录制系统声音，以验证本地双路采集。</string>
</dict></plist>
```

用户确认本机已有证书可用后，手动签名并检查身份：

```sh
codesign --force --sign 'Record Anything Dev' out/AudioProbe.app
codesign --verify --verbose=2 out/AudioProbe.app
codesign -d -r- out/AudioProbe.app
# 从实验目录启动已签名的包内二进制，便于查看终端日志与确定 out/ 位置
./out/AudioProbe.app/Contents/MacOS/probe both --seconds 10
```

如果证书在 `ra-dev.keychain-db`，按 01-tcc 脚本方式由用户自行解锁并给 codesign 指定该 keychain；不要把密码复制进源码或日志。需要时也可通过 `open -n out/AudioProbe.app --args ...` 启动，注意 LaunchServices 的工作目录与日志位置可能不同。首次触发请求后在系统设置的麦克风、屏幕与系统音频录制相关权限中检查授权身份；不同启动方式的实际归因仍需真机验证。实验未启用 App Sandbox / hardened runtime，也未公证，不据此承诺未来沙箱化打包的授权行为。本机 SIP 关闭，权限结论需在 SIP 开启设备复验。

## macOS 27 SDK 结论与待确认项

已读取本机 CLT 和实际编译使用的 Xcode macOS 27.2 SDK 头文件。`AudioHardwareTapping.h` 中创建/销毁 tap 仍标注 14.2；`CATapDescription.h` 中基础构造方法仍存在，bundleIDs / processRestoreEnabled 标注 26.0。AudioHardware.h 还新增了标为 27.0 的 kAudioDevicePropertySuggestedReferenceDevice，用于 VAD 回声消除参考设备，不属于本探针的 tap 创建链路。没有发现上述 tap 接口上标为 27 的破坏性改动，且本探针已在 27.2 SDK 下构建成功；只有当前头文件不能证明历史上所有 API 都没变化，也不能推断运行时权限行为。详见 RESULTS.md 的 Open questions。
