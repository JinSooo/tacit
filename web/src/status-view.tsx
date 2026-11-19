import React, { useEffect, useState } from "react";
import { relativeTime, type Api } from "./distillation.ts";
import { sourceNames } from "./history.ts";
import { toLocalIso } from "./record-helpers.ts";
import { clockMs } from "./segments.ts";
import { countList, errorName, fetchStatus, formatBytes, formatMs, formatNumber, formatUptime, frameNames, pendingNames, requestNames, speakerNames, STATUS_REFRESH_MS, threadNames, tierNames, type HubStatus } from "./status.ts";

function Since({ at }: { at: string | null }) {
  return at ? <time dateTime={at} title={at}>{relativeTime(at)}</time> : <>—</>;
}
function Stats({ items }: { items: [string, React.ReactNode][] }) {
  return <dl className="stats">{items.map(([label, value]) => <div key={label}><dd>{value}</dd><dt>{label}</dt></div>)}</dl>;
}
function Counts({ items, unit = "" }: { items: { key: string; label: string; count: number }[]; unit?: string }) {
  return items.length ? <>{items.map(item => `${item.label} ${formatNumber(item.count)}${unit}`).join("，")}</> : <>没有</>;
}

function CollectorAge({ update, now }: { update: { updated_at: string; stale: boolean }; now: string }) {
  if (!update.stale) return null;
  const minutes = Math.floor((Date.parse(now) - Date.parse(update.updated_at)) / 60_000);
  return <span className="error">，采集端 {formatNumber(minutes)} 分钟没更新</span>;
}

function Tokens({ value, incomplete }: { value: number | null; incomplete: boolean }) {
  return value === null ? <>未知</> : <>{formatNumber(value)}{incomplete && <span className="muted">（部分未知）</span>}</>;
}

/** 启动以来的累计值，不把重启后清零的数字称为全天统计。 */
export function BusyStatus({ busy }: { busy: HubStatus["hub"]["busy"] }) {
  if (busy.total === 0) return null;
  return <dl className="status-lines"><dt>后台服务忙，自动重试</dt><dd>
    启动以来 {formatNumber(busy.total)} 次{busy.last_at && <>，最近一次 <Since at={busy.last_at} /></>}
  </dd></dl>;
}

/**
 * 后台服务的状态。数字的含义（见 hub/src/status.ts）：
 * 记录总数不含已删除的；已删除是删除后留下的墓碑数；读取次数是今天 AI 工具每次读取或添加留下的读取记录条数。
 */
export function StatusView({ api }: { api: Api }) {
  const [status, setStatus] = useState<HubStatus>();
  const [failed, setFailed] = useState(false);
  const [revision, setRevision] = useState(0);
  useEffect(() => {
    let controller: AbortController | undefined;
    const load = () => {
      if (document.hidden) return;
      controller?.abort();
      const current = controller = new AbortController();
      fetchStatus(api, current.signal).then(data => { if (!current.signal.aborted) { setStatus(data); setFailed(false); } })
        .catch(() => { if (!current.signal.aborted) setFailed(true); });
    };
    load();
    const timer = setInterval(load, STATUS_REFRESH_MS);
    document.addEventListener("visibilitychange", load);
    return () => { clearInterval(timer); document.removeEventListener("visibilitychange", load); controller?.abort(); };
  }, [api, revision]);

  if (!status) return <section className="distillation-view">{failed ? <p className="error" role="alert">没能读取状态 <button onClick={() => setRevision(value => value + 1)}>重试</button></p> : <p className="list-status" role="status">正在读取…</p>}</section>;
  return <StatusContent status={status} refreshFailed={failed} />;
}

export function StatusContent({ status, refreshFailed }: { status: HubStatus; refreshFailed?: boolean }) {
  const { hub, listen, database, records, distill, llm_today: usage, audio, collector } = status;
  const { transcription } = audio;
  const pendingTotal = Object.values(distill.pending_open).reduce((n, v) => n + v, 0);
  const regen = distill.needs_regen;
  return <section className="distillation-view status-view">
    <div className="status-head">
      <h2 className="section-title">后台服务</h2>
      <span className="caption">{refreshFailed ? <span className="error" role="alert">没能刷新状态</span> : <>每 15 秒刷新，上次 <time dateTime={status.generated_at}>{status.generated_at.slice(11, 19)}</time></>}</span>
    </div>
    <div className="group">
      <Stats items={[
        ["已运行", <span title={`启动于 ${hub.started_at.slice(0, 16).replace("T", " ")}`}>{formatUptime(hub.uptime_s)}</span>],
        ["地址", <code>{listen.host}:{listen.port}</code>],
        ["数据库大小", <span title={database.file}>{formatBytes(database.bytes)}</span>],
        ["记录", `${formatNumber(records.total)} 条`],
        ["已删除", `${formatNumber(records.tombstones)} 条`],
        ["今天 AI 工具读取", `${formatNumber(status.agent_reads_today)} 次`],
      ]} />
      <BusyStatus busy={hub.busy} />
      <dl className="status-lines">
        <dt>待发送积压（本机）</dt><dd>{collector ? <>
          <span className={collector.outbox_degraded || collector.outbox_dropped > 0 ? "error" : undefined}>
            {formatBytes(collector.outbox_bytes)}{collector.outbox_dropped > 0 && `，本次运行已丢弃 ${formatNumber(collector.outbox_dropped)} 条`}{collector.outbox_degraded && "，待发送队列异常"}
          </span>
          <CollectorAge update={collector} now={status.generated_at} />
        </> : "没有本机采集端状态"}</dd>
      </dl>
    </div>

    <div className="status-columns">
      <div>
        <h2 className="section-title">各来源</h2>
        <div className="group table-wrap"><table className="data-table"><thead><tr><th scope="col">来源</th><th scope="col" className="num">记录</th><th scope="col" className="num">最近收到</th></tr></thead><tbody>
          {records.by_source.map(row => <tr key={row.source}><td>{sourceNames[row.source] ?? row.source}</td><td className="num">{formatNumber(row.count)} 条</td><td className="num"><Since at={row.last_received} /></td></tr>)}
          {!records.by_source.length && <tr><td colSpan={3} className="muted">还没有记录</td></tr>}
        </tbody></table></div>
      </div>
      <div>
        <h2 className="section-title">各设备</h2>
        <div className="group table-wrap"><table className="data-table"><thead><tr><th scope="col">设备</th><th scope="col" className="num">记录</th><th scope="col" className="num">最近收到</th></tr></thead><tbody>
          {records.by_device.map(row => <tr key={row.device}><td>{row.device}</td><td className="num">{formatNumber(row.count)} 条</td><td className="num"><Since at={row.last_received} /></td></tr>)}
          {!records.by_device.length && <tr><td colSpan={3} className="muted">还没有记录</td></tr>}
        </tbody></table></div>
      </div>
    </div>

    <h2 className="section-title">整理</h2>
    <div className="group">
      <Stats items={[
        ["实时整理", <Since at={distill.last_round_at} />],
        ["每小时汇总", <Since at={distill.last_slow_round_at} />],
        ["整理进程上次响应", <Since at={distill.heartbeat_at} />],
        ["等待整理的活动", `${formatNumber(distill.frames.new ?? 0)} 条`],
        ["待确认", `${formatNumber(pendingTotal)} 项`],
      ]} />
      <dl className="status-lines">
        <dt>活动片段</dt><dd><Counts items={countList(distill.frames, frameNames)} /></dd>
        <dt>事项</dt><dd><Counts items={countList(distill.threads, threadNames)} /></dd>
        {regen.threads + regen.projects + regen.days > 0 && <><dt>等待更新</dt><dd>{[regen.threads && `事项 ${regen.threads}`, regen.projects && `项目 ${regen.projects}`, regen.days && `每日回顾 ${regen.days} 天`].filter(Boolean).join("，")}</dd></>}
        {distill.requests.total > 0 && <><dt>手动整理</dt><dd>
          <Counts items={countList(distill.requests.by_status, requestNames)} unit=" 次" />
          <ul className="status-requests">{distill.requests.recent.map(request => <li key={request.id}>
            <time dateTime={request.created_at} className="muted">{toLocalIso(new Date(request.created_at)).slice(5, 16).replace("T", " ")}</time>
            {" "}{requestNames[request.status]}
            {request.total !== null && `，已处理 ${formatNumber(request.done ?? 0)}/${formatNumber(request.total)}`}
            {request.status === "failed" && <span className="error">，{errorName(request.error)}</span>}
          </li>)}</ul>
        </dd></>}
        {pendingTotal > 0 && <><dt>待确认</dt><dd><Counts items={countList(distill.pending_open, pendingNames)} /></dd></>}
        <dt>开始整理</dt><dd>{distill.enabled_at ? <time dateTime={distill.enabled_at}>{distill.enabled_at.slice(0, 16).replace("T", " ")}</time> : "还没开始"}{distill.enabled_at && !distill.backfill_done && "，之前的历史还没整理完"}</dd>
        {distill.cooldown && <><dt>模型状态</dt><dd className="error">模型暂停调用到 <time dateTime={distill.cooldown.until}>{clockMs(Date.parse(distill.cooldown.until))}</time>（原因：{errorName(distill.cooldown.kind)}）</dd></>}
        {distill.last_error && <><dt>最近出错</dt><dd className={distill.last_error.recovered ? "muted" : "error"}>
          {distill.last_error.tier && Object.hasOwn(tierNames, distill.last_error.tier) ? `${tierNames[distill.last_error.tier]}，` : ""}
          <Since at={distill.last_error.at} />，{errorName(distill.last_error.error)}{distill.last_error.recovered && "，同类调用之后已恢复"}
        </dd></>}
      </dl>
    </div>

    <h2 className="section-title">今天的模型用量</h2>
    {usage.by_tier.length ? <div className="group table-wrap"><table className="data-table stack-table"><thead><tr><th scope="col">用途</th><th scope="col">模型</th><th scope="col" className="num">调用</th><th scope="col" className="num">输入 token</th><th scope="col" className="num">输出 token</th><th scope="col" className="num">总耗时</th></tr></thead><tbody>
      {usage.by_tier.map(row => <tr key={row.tier}><td>{tierNames[row.tier] ?? row.tier}</td><td className="end">{row.models.join("、") || "—"}</td><td className="num" data-label="调用">{formatNumber(row.calls)} 次{row.failed > 0 && <span className="error">，失败 {formatNumber(row.failed)}</span>}</td><td className="num end" data-label="输入"><Tokens value={row.input_tokens} incomplete={row.input_tokens_incomplete} /></td><td className="num" data-label="输出"><Tokens value={row.output_tokens} incomplete={row.output_tokens_incomplete} /></td><td className="num end" data-label="耗时">{formatMs(row.ms)}</td></tr>)}
      {usage.by_tier.length > 1 && <tr className="total"><td>合计</td><td className="end" /><td className="num" data-label="调用">{formatNumber(usage.total.calls)} 次{usage.total.failed > 0 && <span className="error">，失败 {formatNumber(usage.total.failed)}</span>}</td><td className="num end" data-label="输入"><Tokens value={usage.total.input_tokens} incomplete={usage.total.input_tokens_incomplete} /></td><td className="num" data-label="输出"><Tokens value={usage.total.output_tokens} incomplete={usage.total.output_tokens_incomplete} /></td><td className="num end" data-label="耗时">{formatMs(usage.total.ms)}</td></tr>}
    </tbody></table></div> : <p className="muted">今天还没有调用模型</p>}

    <h2 className="section-title">声音</h2>
    <div className="group">
      <dl className="status-lines">
        <dt>说话人</dt><dd><Counts items={countList(audio.speakers, speakerNames)} /></dd>
        <dt>有声纹的对话</dt><dd>{formatNumber(audio.voice_conversations)} 段</dd>
        <dt>试听样本</dt><dd>{audio.sample_requests_open ? `${formatNumber(audio.sample_requests_open)} 个在等设备上传` : "没有待上传的试听样本"}</dd>
        <dt>删除音频</dt><dd>{audio.deletes_pending ? `${formatNumber(audio.deletes_pending)} 段对话等设备删除` : "没有待删除的"}</dd>
        <dt>转写队列（本机）</dt><dd>{transcription ? <>
          待转写 {formatNumber(transcription.pending)} 段，失败 {formatNumber(transcription.failed)} 段
          <CollectorAge update={transcription} now={status.generated_at} />
        </> : audio.transcription_disabled ? "录音未开启" : "没有本机采集端状态"}</dd>
      </dl>
    </div>

    <h2 className="section-title">密钥备份</h2>
    <p className="muted">数据库和音频的密钥只存在这台 Mac 的钥匙串里，丢了就再也打不开记录。在 Mac 客户端的“设置 → 维护 → 密钥备份”里复制，存进密码管理器。</p>
  </section>;
}
