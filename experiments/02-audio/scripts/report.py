#!/usr/bin/env python3
"""汇总不含转写文字的数值 JSON。"""
import json
from pathlib import Path

root = Path(__file__).resolve().parent.parent
runs = [json.loads((root / f"out/{m}-t{t}.json").read_text())
        for m in ("int8", "fp32") for t in (1, 2, 4)]
(root / "out/results.json").write_text(json.dumps(runs, ensure_ascii=False, indent=2) + "\n")
lines = ["# 实验 2 实测结果", "", "测量日期：2026-11-09。本机 macOS 27.0.1，arm64；Swift 6.4.2，构建 SDK macOS 27.2。",
         "CPU 型号的 sysctl 查询被沙箱拒绝，因此不把任务描述中的 M5 Pro 当成已实测硬件信息。",
         "", "## 2-A 流水线基准", "", "| 模型 | 线程 | 总加载 s | ASR 加载 s | 峰值 RSS MiB | 600s 处理 s | 600s RTF | 全输入 RTF | 长输入 VAD 段数 | 向量维度 |", "|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|"]
for r in runs:
    long = r['files'][-1]
    lines.append(f"| {r['model']} | {r['num_threads']} | {r['load_seconds']['total']:.3f} | {r['load_seconds']['asr']:.3f} | {r['peak_rss_bytes']/1048576:.1f} | {long['processing_seconds']:.3f} | {long['rtf']:.4f} | {r['overall_rtf']:.4f} | {long['vad_segments']} | {r['embedding_dim']} |")
lines += ["", "RTF 包含读 WAV、VAD、逐段转写和逐段声纹，不包含模型加载和额外相似度探针；线程数同时设在三个模型上。每个配置独立进程、顺序执行，不并跑推理；各配置只测一次，文件缓存已热，结果不是冷启动或统计显著的速度排名。峰值 RSS 是 macOS getrusage 的进程峰值（字节），包含模型、输入缓冲及相似度探针。", "", "### 五个短文件", "", "| 模型/线程 | 文件 | 音频 s | 处理 s | RTF | VAD 段数 |", "|---|---|---:|---:|---:|---:|"]
for r in runs:
    for f in r['files'][:-1]:
        lines.append(f"| {r['model']}/{r['num_threads']} | {f['file']} | {f['audio_seconds']:.3f} | {f['processing_seconds']:.3f} | {f['rtf']:.4f} | {f['vad_segments']} |")
lines += ["", "### 阶段耗时（600 秒输入）", "", "| 模型/线程 | 读入 s | VAD 及开销 s | ASR s | 声纹 s | CPU s | 有效语音 s |", "|---|---:|---:|---:|---:|---:|---:|"]
for r in runs:
    f = r['files'][-1]
    lines.append(f"| {r['model']}/{r['num_threads']} | {f['read_seconds']:.3f} | {f['vad_and_overhead_seconds']:.3f} | {f['asr_seconds']:.3f} | {f['speaker_seconds']:.3f} | {f['cpu_seconds']:.3f} | {f['speech_seconds']:.3f} |")
r = runs[0]
lines += ["", "### 声纹相似度（int8 / 1 线程）", "", "| 同文件 | 取样方式 | 余弦相似度 |", "|---|---|---:|"]
for v in r['same_file_similarity']:
    lines.append(f"| {v['file']} | {v['method']} | {v['cosine']:.4f} |")
lines += ["", "| 不同文件 | 余弦相似度 |", "|---|---:|"]
for v in r['cross_file_similarity']:
    lines.append(f"| {v['a']} / {v['b']} | {v['cosine']:.4f} |")
lines += ["", "同文件视为同说话人的粗略假设，未人工核实身份；优先比较不同 VAD 段，只有一段时取原始 WAV 前后不重叠窗口（最长各 3 秒，可能含静音）。跨语言比较用每个文件第一个 VAD 段，不同文件按不同人粗看；不能据此确定声纹阈值，也不表示声纹能区分语言。长输入是同一批样例重复拼接，不代表真实十分钟会议。其余配置的完整相似度和各模型加载耗时见 out/*.json（忽略文件，不入库）。", "", "## 2-B 编译与 SDK 核对", "", "bench、probe 的 release 构建均成功。未运行 mic/tap/both，未签名或申请权限。只运行 probe --help 验证启动。",
          "", "核对了本机 CommandLineTools 和实际构建使用的 Xcode macOS 27.2 SDK：CoreAudio.framework/Headers/AudioHardwareTapping.h、CATapDescription.h、AudioHardware.h。创建/销毁 process tap 仍为 macOS 14.2 起可用；CATapDescription 的基础混音构造方法、tap 格式和 aggregate tap list 仍存在。bundleIDs 和 processRestoreEnabled 标为 macOS 26.0 新增。AudioHardware.h 另有 macOS 27.0 新增的 kAudioDevicePropertySuggestedReferenceDevice（VAD 回声消除参考设备），不属于本探针使用的 tap 创建链路。未发现该链路上标示为 macOS 27 的破坏性变更；仅有当前 SDK 无法证明所有历史版本都无变化，权限及实际录音行为仍需真机验证。Swift 导入的 processes 参数是 [AudioObjectID]，不能照 Objective-C 声明传 [NSNumber]。", "", "## 构建与验证记录", "", "- 首次构建暴露 Swift refined API 参数类型不匹配，改为 [AudioObjectID] 后编译及链接成功。", "- 默认 Swift Build 构建器在 dSYM 生成时 Operation not permitted；加 -debug-info-format none 后完整构建成功。", "- scripts/build.sh：成功；缓存、scratch、config、security 均放实验目录，使用 --disable-sandbox（SwiftPM 子进程沙箱）；未改 HOME、TMPDIR。", "- bench generate：成功，600.000 秒、16kHz、mono PCM WAV。", "- bench int8/fp32 × 1/2/4：六个配置全部完成，分别覆盖五个短文件和长输入。", "- probe --help：成功；实际录音由用户运行。", "- 未跑 bun test / bunx tsc：按本任务环境补充，以 Swift 构建与实际基准为验证边界。", "", "## Open questions", "", "- 用户真机上麦克风、全局/指定 PID tap 的授权、OSStatus、是否有声音、两路首帧差及长期时钟漂移还未验证。", "- 在 SIP 开启设备复验权限；本机不能替代正常 TCC 环境验收。", "- 需要真实多人、多设备和跨会话样本再确定声纹阈值；本实验不实现用户声纹筛选、会议例外和 History 写入。", "- 持续录音 CPU、RSS、耗电和降采样音质仍待长时间真机测试；线性重采样没有抗混叠滤波，不作为生产方案定论。", ""]
(root / "RESULTS.md").write_text("\n".join(lines))
print("已汇总 out/results.json 与 RESULTS.md（不含转写内容）")

readme = root / "README.md"
text = readme.read_text()
start = text.index("<!-- measured-table -->")
end_marker = "<!-- /measured-table -->"
end = text.find(end_marker, start)
if end < 0:
    end = start + len("<!-- measured-table -->")
else:
    end += len(end_marker)
header = lines.index("## 2-A 流水线基准")
table_start = header + 2
table_end = table_start + 8
table = "<!-- measured-table -->\n\n" + "\n".join(lines[table_start:table_end]) + "\n\n<!-- /measured-table -->"
readme.write_text(text[:start] + table + text[end:])
