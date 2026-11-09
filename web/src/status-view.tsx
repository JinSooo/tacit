import React, { useEffect, useState } from "react";
import { relativeTime, type Api } from "./distillation.ts";
import { sourceColor, sourceNames } from "./history.ts";
import { countList, fetchStatus, formatBytes, formatMs, formatNumber, formatUptime, frameNames, pendingNames, speakerNames, STATUS_REFRESH_MS, threadNames, tierNames, type HubStatus } from "./status.ts";
const message = (error: unknown) => error instanceof Error ? error.message : "请求失败，请重试";

function Since({ at }: { at: string | null }) {
  return at ? <time dateTime={at} title={at}>{relativeTime(at)}</time> : <>—</>;
}
function Stats({ items }: { items: [string, React.ReactNode][] }) {
  return <dl className="status-stats">{items.map(([label, value]) => <div key={label}><dd>{value}</dd><dt>{label}</dt></div>)}</dl>;
}
function Counts({ items }: { items: { key: string; label: string; count: number }[] }) {
  return items.length ? <>{items.map((item, index) => <span key={item.key}>{index > 0 && " · "}{item.label} {formatNumber(item.count)}</span>)}</> : <>无</>;
}

export function StatusView({ api }: { api: Api }) {
  const [status, setStatus] = useState<HubStatus>();
  const [error, setError] = useState("");
  const [revision, setRevision] = useState(0);
  useEffect(() => {
    let controller: AbortController | undefined;
    const load = () => {
      if (document.hidden) return;
      controller?.abort();
      const current = controller = new AbortController();
      fetchStatus(api, current.signal).then(data => { if (!current.signal.aborted) { setStatus(data); setError(""); } })
        .catch(error => { if (!current.signal.aborted) setError(message(error)); });
    };
    load();
    const timer = setInterval(load, STATUS_REFRESH_MS);
    document.addEventListener("visibilitychange", load);
    return () => { clearInterval(timer); document.removeEventListener("visibilitychange", load); controller?.abort(); };
  }, [api, revision]);

  if (!status) return <section className="distillation-view">{error ? <p className="error" role="alert">{error} <button onClick={() => setRevision(value => value + 1)}>重试</button></p> : <p role="status">正在读取…</p>}</section>;
  const { hub, listen, database, records, distill, llm_today: usage, audio } = status;
  const pendingTotal = Object.values(distill.pending_open).reduce((n, v) => n + v, 0);
  return <section className="distillation-view status-view">
    <div className="status-head">
      <h2 className="day-heading">中枢</h2>
      <span className="activity-time">{error ? <span className="error" role="alert">刷新失败：{error}</span> : <>更新于 <time dateTime={status.generated_at}>{status.generated_at.slice(11, 19)}</time></>}</span>
    </div>
    <Stats items={[
      ["运行时长", <span title={`启动于 ${hub.started_at}`}>{formatUptime(hub.uptime_s)}</span>],
      ["监听", <span className="mono">{listen.host}:{listen.port}</span>],
      ["数据库", <span title={database.file}>{formatBytes(database.bytes)}</span>],
      ["记录", formatNumber(records.total)],
      ["墓碑", formatNumber(records.tombstones)],
      ["今日 Agent 读取", formatNumber(status.agent_reads_today)],
    ]} />

    <div className="status-columns">
      <div>
        <h2 className="day-heading">来源</h2>
        <div className="audit-table-wrap"><table className="audit-table status-table"><thead><tr><th>来源</th><th className="num">记录</th><th className="num">最近入库</th></tr></thead><tbody>
          {records.by_source.map(row => <tr key={row.source}><td><span className="source-dot" style={{ "--source-color": sourceColor(row.source) } as React.CSSProperties} />{sourceNames[row.source] ?? row.source}</td><td className="num">{formatNumber(row.count)}</td><td className="num"><Since at={row.last_received} /></td></tr>)}
          {!records.by_source.length && <tr><td colSpan={3}>没有记录</td></tr>}
        </tbody></table></div>
      </div>
      <div>
        <h2 className="day-heading">设备</h2>
        <div className="audit-table-wrap"><table className="audit-table status-table"><thead><tr><th>设备</th><th className="num">记录</th><th className="num">最近入库</th></tr></thead><tbody>
          {records.by_device.map(row => <tr key={row.device}><td>{row.device}</td><td className="num">{formatNumber(row.count)}</td><td className="num"><Since at={row.last_received} /></td></tr>)}
          {!records.by_device.length && <tr><td colSpan={3}>没有记录</td></tr>}
        </tbody></table></div>
      </div>
    </div>

    <h2 className="day-heading">提炼</h2>
    <Stats items={[
      ["最近一轮", <Since at={distill.last_round_at} />],
      ["最近整理", <Since at={distill.last_slow_round_at} />],
      ["心跳", <Since at={distill.heartbeat_at} />],
      ["待归属片段", formatNumber(distill.frames.new ?? 0)],
      ["待确认", formatNumber(pendingTotal)],
    ]} />
    <dl className="context status-lines">
      <dt>片段</dt><dd><Counts items={countList(distill.frames, frameNames)} /></dd>
      <dt>线程</dt><dd><Counts items={countList(distill.threads, threadNames)} /></dd>
      <dt>待重写</dt><dd>线程 {distill.needs_regen.threads} · 项目 {distill.needs_regen.projects} · 日记 {distill.needs_regen.days}</dd>
      {distill.requests && <><dt>请求</dt><dd>{distill.requests.by_status ? <Counts items={countList(distill.requests.by_status, {})} /> : `${formatNumber(distill.requests.total)} 条`}</dd></>}
      {pendingTotal > 0 && <><dt>待确认</dt><dd><Counts items={countList(distill.pending_open, pendingNames)} /></dd></>}
      <dt>启用于</dt><dd>{distill.enabled_at ? <time dateTime={distill.enabled_at}>{distill.enabled_at.slice(0, 16).replace("T", " ")}</time> : "尚未启用"}{distill.enabled_at && !distill.backfill_done && "，历史批量整理未完成"}</dd>
      {distill.last_error && <><dt>最近错误</dt><dd><span className="error">{distill.last_error.error}</span> <span className="muted">（{tierNames[distill.last_error.tier] ?? distill.last_error.tier}，<Since at={distill.last_error.at} />）</span></dd></>}
    </dl>

    <h2 className="day-heading">今日模型用量</h2>
    <div className="audit-table-wrap"><table className="audit-table status-table"><thead><tr><th>档位</th><th>模型</th><th className="num">调用</th><th className="num">成功</th><th className="num">失败</th><th className="num">输入 token</th><th className="num">输出 token</th><th className="num">耗时</th></tr></thead><tbody>
      {usage.by_tier.map(row => <tr key={row.tier}><td>{tierNames[row.tier] ?? row.tier}</td><td>{row.models.join("、") || "—"}</td><td className="num">{formatNumber(row.calls)}</td><td className="num">{formatNumber(row.ok)}</td><td className={row.failed ? "num error" : "num"}>{formatNumber(row.failed)}</td><td className="num">{formatNumber(row.input_tokens)}</td><td className="num">{formatNumber(row.output_tokens)}</td><td className="num">{formatMs(row.ms)}</td></tr>)}
      {usage.by_tier.length > 1 && <tr className="status-total"><td>合计</td><td /><td className="num">{formatNumber(usage.total.calls)}</td><td className="num">{formatNumber(usage.total.ok)}</td><td className={usage.total.failed ? "num error" : "num"}>{formatNumber(usage.total.failed)}</td><td className="num">{formatNumber(usage.total.input_tokens)}</td><td className="num">{formatNumber(usage.total.output_tokens)}</td><td className="num">{formatMs(usage.total.ms)}</td></tr>}
      {!usage.by_tier.length && <tr><td colSpan={8}>今天还没有调用</td></tr>}
    </tbody></table></div>

    <h2 className="day-heading">音频</h2>
    <dl className="context status-lines">
      <dt>说话人</dt><dd><Counts items={countList(audio.speakers, speakerNames)} /></dd>
      <dt>声纹</dt><dd>{formatNumber(audio.voice_conversations)} 段对话</dd>
      <dt>试听样本</dt><dd>{audio.sample_requests_open ? `${audio.sample_requests_open} 个请求等设备上传` : "无待上传"}</dd>
      <dt>删除</dt><dd>{audio.deletes_pending ? `${audio.deletes_pending} 段对话等设备同步删除` : "无待同步"}</dd>
      <dt>转写</dt><dd className="muted">在各设备本地进行，中枢没有转写队列</dd>
    </dl>
  </section>;
}
