# 全天试用采样

这是可选的独立诊断脚本，用于正常使用时的 CPU 和模型用量验收，不改应用的采集或整理节奏。

- `performance-sample.py` 每 5 秒读取 macOS 进程计数和键鼠空闲时间，每 5 分钟调用 `performance-usage.ts` 只读查询模型计量列。
- 数据在 `~/Library/Application Support/record-anything/performance/`，目录 0700、文件 0600。不记录 History、提示词、转写正文、进程命令参数或密钥。
- 按运行机器的本地自然日分文件。`sessions.jsonl` 留开始/停止时间；`errors.jsonl` 只留错误类型。
- 中途启动或做过主动导入、批量重整理的日期不作为正常使用日样本。

## 看结果

```sh
/usr/bin/python3 scripts/performance-sample.py --report 2026-11-13
```

CPU 按单核计算，分母为有效采样间隔中 `mach_absolute_time` 的增量（不含睡眠）；CPU 计数也按 `mach_timebase_info` 换算，不能直接当纳秒。

`collector_acceptance` 按 [设计文档](../docs/design.md) 第 11 节报告采集端自身 CPU。每条样本从 IOKit 读取 `IOHIDSystem.HIDIdleTime`，以秒写入 `hid_idle_s`，不可读时为 `null`。两次采样之间能判定全程空闲满 300 秒才归入「没人用」`idle`，全程未满 300 秒才归入「有人用」`active`。按区间的进程自身 CPU 增量求和，再除以各组覆盖的醒着时间 `awake_s`，分别与严格小于单核 0.5% 和 3% 比较。可能跨过分界、有休眠或时钟不一致迹象（墙上时间与醒着时间增量差超过 1 秒）、空闲读数缺失的区间计入 `unclassified_awake_s`。进程或采样器重启、计数倒退、读取失败和超过 20 秒的采样间隔计入 `missing_awake_s`。旧样本仍可生成报告，两个键鼠状态均显示「数据不足」。锁屏字段和原锁屏指标保留供排查。

`collector_acceptance.memory` 取可读的采集端物理内存占用（footprint，1 MB = 1024² 字节）。从低到高排序，第 `ceil(样本数 × 0.95)` 项是 p95，低于 300 MB 达标。峰值取最大一次采样，只单列观察。状态只比较有数据的覆盖范围。

`roles.collector` 保留采集端及全部后代的累计诊断，包括已回收子进程。相邻两次整树总量做差，子进程退出转入父进程回收计数时不会重复累计。进程脱离原树后会漏计。首个样本作为基线。P 核、E 核按同样的 CPU 秒计，darkwake 期间算醒着。

`audio_worker` 按可执行文件名识别 `ra-audio-worker`，报告采样到的 footprint 峰值和同一进程连续快照间累计的 CPU 秒。进程起止和短命 worker 可能漏计，CPU 秒是下限。旧样本只能单列全部后代的 CPU 秒和单进程采样峰值，里面也包括插件。采集端状态只记录待转写与失败数、上次启动等信息，Hub 的对话起止时间和声纹时长无法对应 worker 实际消耗的输入音频（包括重试、补跑和未产出文字的片段）。每小时音频 CPU 秒因此显示「数据不足」。

`hub`、`distill`、`sampler` 分开报告。只跟踪三个指定 LaunchAgent 的进程树，其他本机进程不纳入。`coreaudiod` 单列全系统进程计数，可读时以全系统计，权限不足时 CPU 为 `null`，本应用引起的部分显示「数据不足」。采样器以当前用户权限运行。

模型文件保存当日以及前一日本地日期的累计用量，按 task/tier/provider/model 分组；每天第一次查询会补全前一天临近午夜的调用。缺失 token 另计 missing_input/missing_output，不解释成零用量。报告中的 `models.at` 是快照时刻，订阅通道的 token 不能直接当实际账单。

`normal_day_candidate` 仅用当天采样首尾和采集端整树覆盖缺口筛选完整自然日。跨午夜休眠可能使它为 false。判断全天是否适合验收还需结合键鼠指标覆盖、导入和批量重整理等情况。

## 后台任务

直接运行 `python3 scripts/performance-sample.py` 开始采样，按 Ctrl+C 停止。若自行注册独立用户 LaunchAgent `dev.record-anything.performance`，登录后会继续运行，关闭终端不会停止；不会自动通知或发送统计数据。

停止当前采样：

```sh
launchctl bootout "gui/$(id -u)/dev.record-anything.performance"
```

此命令停止本次登录会话的任务。若不希望以后登录再启动，将 `~/Library/LaunchAgents/dev.record-anything.performance.plist` 移出 LaunchAgents；历史采样文件仍保留。主应用的安装与卸载脚本不管理这个独立诊断任务。

验证脚本：`/usr/bin/python3 scripts/test_performance_sample.py`。Python 和 Bun 均使用机器上已有的运行环境，无新增依赖。
