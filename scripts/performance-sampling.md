# 全天试用采样

这是可选的独立诊断脚本，用于正常使用时的 CPU 和模型用量验收，不改应用的采集或整理节奏。

- `performance-sample.py` 每 5 秒读取 macOS 进程计数，每 5 分钟调用 `performance-usage.ts` 只读查询模型计量列。
- 数据在 `~/Library/Application Support/record-anything/performance/`，目录 0700、文件 0600。不记录 History、提示词、转写正文、进程命令参数或密钥。
- 按运行机器的本地自然日分文件。`sessions.jsonl` 留开始/停止时间；`errors.jsonl` 只留错误类型。
- 中途启动或做过主动导入、批量重整理的日期不作为正常使用日样本。

## 看结果

```sh
/usr/bin/python3 scripts/performance-sample.py --report 2026-11-13
```

CPU 按单核计算，分母为有效采样间隔中 `mach_absolute_time` 的增量（不含睡眠）；CPU 计数也按 `mach_timebase_info` 换算，不能直接当纳秒。

`collector` 是采集端及其活着、已回收后代的合计；转写 worker 和插件正常由采集端启动并等待退出。每轮整树总量做差，子进程退出转入父进程回收计数时不重复累计。已实测短命子进程、孙进程和活进程退出。孤儿脱离进程树后无法保证完整计量；根进程重启、采样延迟、计数倒退或读取失败会标为覆盖缺口，不用零代替。首个样本只作基线，避免把启动前 CPU 算进来。

`hub`、`distill`、`sampler` 分开报告，不加到采集端验收项；只跟踪三个指定 LaunchAgent 的进程树，不把用户其他 Codex 会话计入。`coreaudiod` 是全系统进程，若权限不允许读计数则 CPU 为 null；即使可读也不能将它的全部开销归因到本应用。采样器不申请更高权限。

内存是采样到的物理占用峰值，5 秒以下的短命 worker 峰值可能漏过，不能当精确峰值。锁屏同时记录布尔状态；锁屏 CPU 项只算采集端自身，并单列最长连续醒着锁屏时长，未满 600 秒不能作锁屏 10 分钟验收。P 核、E 核按同样的 CPU 秒计，darkwake 期间算醒着。

模型文件保存当日以及前一日本地日期的累计用量，按 task/tier/provider/model 分组；每天第一次查询会补全前一天临近午夜的调用。缺失 token 另计 missing_input/missing_output，不解释成零用量。报告中的 `models.at` 是快照时刻，订阅通道的 token 不能直接当实际账单。

`normal_day_candidate` 仅检查当天采样首尾和采集端覆盖缺口，保守筛选完整自然日；跨午夜休眠可能使它为 false。这不是准确率、成本或 CPU 达标判定，不能用短测代替全天验收。

## 后台任务

直接运行 `python3 scripts/performance-sample.py` 开始采样，按 Ctrl+C 停止。若自行注册独立用户 LaunchAgent `dev.record-anything.performance`，登录后会继续运行，关闭终端不会停止；不会自动通知或发送统计数据。

停止当前采样：

```sh
launchctl bootout "gui/$(id -u)/dev.record-anything.performance"
```

此命令停止本次登录会话的任务。若不希望以后登录再启动，将 `~/Library/LaunchAgents/dev.record-anything.performance.plist` 移出 LaunchAgents；历史采样文件仍保留。主应用的安装与卸载脚本不管理这个独立诊断任务。

验证脚本：`/usr/bin/python3 scripts/test_performance_sample.py`。Python 和 Bun 均使用机器上已有的运行环境，无新增依赖。
