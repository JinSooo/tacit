import React, { useEffect, useState } from "react";
import { relativeTime, type Api } from "./distillation.ts";
import { sourceNames } from "./history.ts";
import { toLocalIso } from "./record-helpers.ts";
import { clockMs } from "./segments.ts";
import { cooldownNames, countList, errorName, errorNeedsAttention, fetchStatus, formatBytes, formatClock, formatDateTime, formatMs, formatNumber, formatUptime, frameNames, pendingNames, requestNames, speakerNames, STATUS_REFRESH_MS, threadNames, tierNames, type HubStatus } from "./status.ts";

function Since({ at }: { at: string | null }) {
  return at ? <time dateTime={at} title={formatDateTime(at)}>{relativeTime(at)}</time> : <>—</>;
}
function Stats({ items }: { items: [string, React.ReactNode][] }) {
  return <dl className="stats">{items.map(([label, value]) => <div key={label}><dd>{value}</dd><dt>{label}</dt></div>)}</dl>;
}
/** 只列不为 0 的计数。 */
function Counts({ items, unit = "" }: { items: { key: string; label: string; count: number }[]; unit?: string }) {
  return <>{items.filter(item => item.count > 0).map(item => `${item.label} ${formatNumber(item.count)}${unit}`).join("，")}</>;
}
const nonZero = (items: { count: number }[]) => items.some(item => item.count > 0);

function CollectorAge({ update, now }: { update: { updated_at: string; stale: boolean }; now: string }) {
  if (!update.stale) return null;
  const minutes = Math.max(0, Math.floor((Date.parse(now) - Date.parse(update.updated_at)) / 60_000));
  return <span className="error">，本机状态已 {formatNumber(minutes)} 分钟没更新</span>;
}

function Tokens({ value, incomplete }: { value: number | null; incomplete: boolean }) {
  return value === null ? <>未知</> : <>{formatNumber(value)}{incomplete && <span className="muted">，部分未知</span>}</>;
}

/** 启动以来的累计值，不把重启后清零的数字称为全天统计。 */
export function BusyStatus({ busy }: { busy: HubStatus["hub"]["busy"] }) {
  if (busy.total === 0) return null;
  return <dl className="status-lines"><dt>忙时自动重试</dt><dd>
    启动以来 {formatNumber(busy.total)} 次{busy.last_at && <>，最近一次 <Since at={busy.last_at} /></>}
  </dd></dl>;
}

/**
 * 后台服务的状态。数字的含义（见 hub/src/status.ts）：
 * 记录总数不含已删除的；已删除是删除后留下的墓碑数；读取次数是今天 AI 工具每次读取或添加留下的读取记录条数。
 */
export function StatusView({ api, focus }: { api: Api; focus?: "usage" }) {
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

  // 从 Mac 的“查看详细用量”进来时，第一次读到状态后跳到用量那一块。
  const [focused, setFocused] = useState(false);
  useEffect(() => {
    if (!status || focused || !focus) return;
    setFocused(true);
    document.getElementById(focus)?.scrollIntoView();
  }, [status, focus, focused]);

  if (!status) return <section className="distillation-view">{failed
    ? <div className="list-status" role="alert"><span className="error">没能读取状态</span> <button onClick={() => setRevision(value => value + 1)}>重试</button></div>
    : <p className="list-status" role="status">正在读取…</p>}</section>;
  return <StatusContent status={status} refreshFailed={failed} />;
}

export function StatusContent({ status, refreshFailed }: { status: HubStatus; refreshFailed?: boolean }) {
  const { hub, listen, database, records, distill, llm_today: usage, audio, collector } = status;
  const { transcription } = audio;
  const now = Date.parse(status.generated_at);
  const pending = countList(distill.pending_open, pendingNames);
  const regen = distill.needs_regen;
  const deviceName = (id: string) => status.devices?.find(device => device.id === id)?.name
    ?? (id === "mac" ? "这台 Mac" : id === "web" ? "网页" : id.startsWith("android-") ? "已移除的手机" : id.startsWith("mac-") ? "已移除的 Mac" : id);
  // 整理服务 90 秒没心跳算没响应，和 Mac 的判断一致。
  const heartbeat = Date.parse(distill.heartbeat_at ?? "");
  const unresponsive = !!distill.enabled_at && (!Number.isFinite(heartbeat) || now - heartbeat > 90_000);
  const outboxTrouble = collector && (collector.outbox_bytes > 0 || collector.outbox_dropped > 0 || collector.outbox_degraded || collector.stale);
  const lastError = distill.last_error;
  return <section className="distillation-view status-view">
    <div className="status-head">
      <h2 className="section-title">后台服务</h2>
      <span className="caption">{refreshFailed && <><span className="error" role="alert">刷新失败</span>，</>}每 15 秒刷新，上次 <time dateTime={status.generated_at}>{formatClock(status.generated_at)}</time></span>
    </div>
    <div className="group">
      <Stats items={[
        ["已运行", <span title={`启动于 ${formatDateTime(hub.started_at, now)}`}>{formatUptime(hub.uptime_s)}</span>],
        ["地址", <code>{listen.host}:{listen.port}</code>],
        ...(listen.lan_port ? [["设备连接端口", <code>{listen.lan_port}</code>] as [string, React.ReactNode]] : []),
        ["数据库大小", <span title={database.file}>{formatBytes(database.bytes)}</span>],
        ["记录", `${formatNumber(records.total)} 条`],
        ...(records.tombstones > 0 ? [["已删除", `${formatNumber(records.tombstones)} 条`] as [string, React.ReactNode]] : []),
        ["今天 AI 工具读取", `${formatNumber(status.agent_reads_today)} 次`],
      ]} />
      <BusyStatus busy={hub.busy} />
      {(!collector || outboxTrouble) && <dl className="status-lines">
        <dt>本机待发送记录</dt><dd>{collector ? <>
          <span className={collector.outbox_degraded || collector.outbox_dropped > 0 ? "error" : undefined}>
            {formatBytes(collector.outbox_bytes)}{collector.outbox_dropped > 0 && `，本次运行已丢弃 ${formatNumber(collector.outbox_dropped)} 条`}{collector.outbox_degraded && "，待发送队列异常"}
          </span>
          <CollectorAge update={collector} now={status.generated_at} />
        </> : "暂时读不到本机状态"}</dd>
      </dl>}
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
          {records.by_device.map(row => <tr key={row.device}><td>{deviceName(row.device)}</td><td className="num">{formatNumber(row.count)} 条</td><td className="num"><Since at={row.last_received} /></td></tr>)}
          {!records.by_device.length && <tr><td colSpan={3} className="muted">还没有记录</td></tr>}
        </tbody></table></div>
      </div>
    </div>

    <h2 className="section-title">整理</h2>
    <div className="group">
      <Stats items={[
        ["最近整理", <Since at={distill.last_ok_at} />],
        ["上次实时整理", <Since at={distill.last_round_at} />],
        ["上次每小时汇总", <Since at={distill.last_slow_round_at} />],
      ]} />
      <dl className="status-lines">
        {unresponsive && <><dt>整理服务</dt><dd className="error">没有响应{Number.isFinite(heartbeat) && <>，上次响应 <Since at={distill.heartbeat_at} /></>}</dd></>}
        {distill.config_error && <><dt>模型设置</dt><dd className="error">{errorName("config_error")}</dd></>}
        {nonZero(countList(distill.frames, frameNames)) && <><dt>活动片段</dt><dd><Counts items={countList(distill.frames, frameNames)} unit=" 段" /></dd></>}
        {nonZero(countList(distill.threads, threadNames)) && <><dt>事项</dt><dd><Counts items={countList(distill.threads, threadNames)} unit=" 件" /></dd></>}
        {regen.threads + regen.projects + regen.days > 0 && <><dt>等待更新</dt><dd>{[
          regen.threads && `事项 ${formatNumber(regen.threads)} 件`, regen.projects && `项目 ${formatNumber(regen.projects)} 个`, regen.days && `每日时间线 ${formatNumber(regen.days)} 天`,
        ].filter(Boolean).join("，")}</dd></>}
        {distill.requests.total > 0 && <><dt>手动整理</dt><dd>
          <Counts items={countList(distill.requests.by_status, requestNames)} unit=" 次" />
          <ul className="status-requests">{distill.requests.recent.map(request => <li key={request.id}>
            <time dateTime={request.created_at} className="muted">{formatDateTime(request.created_at, now)}</time>
            {" "}{requestNames[request.status]}
            {request.total !== null && `，已处理 ${formatNumber(request.done ?? 0)}/${formatNumber(request.total)}`}
            {request.status === "failed" && <span className="error">，{errorName(request.error)}</span>}
          </li>)}</ul>
        </dd></>}
        {nonZero(pending) && <><dt>待确认</dt><dd><Counts items={pending} unit=" 项" /></dd></>}
        <dt>启用时间</dt><dd>{distill.enabled_at ? <time dateTime={distill.enabled_at}>{formatDateTime(distill.enabled_at, now)}</time> : "还没启用"}{distill.enabled_at && !distill.backfill_done && "，之前的历史还没整理完"}</dd>
        {distill.cooldown && <><dt>暂停</dt><dd className="error">{distill.cooldown.kind === "budget"
          ? "已达到今天的用量上限，明天 0 点恢复"
          : <>因{cooldownNames[distill.cooldown.kind] ?? "模型服务出错"}，整理暂停到 <time dateTime={distill.cooldown.until}>{clockMs(Date.parse(distill.cooldown.until))}</time></>}</dd></>}
        {lastError && <><dt>最近出错</dt><dd className={errorNeedsAttention(lastError, distill.last_ok_at, now) ? "error" : "muted"}>
          {lastError.tier && Object.hasOwn(tierNames, lastError.tier) ? `${tierNames[lastError.tier]}，` : ""}
          <Since at={lastError.at} />：{errorName(lastError.error)}{lastError.recovered && "之后已恢复。"}
        </dd></>}
      </dl>
    </div>

    <h2 className="section-title" id="usage">今天的模型用量</h2>
    {usage.by_tier.length ? <>
      <p className="muted">今天已用 {formatNumber(usage.used_tokens)} token{usage.token_limit !== null && `，上限 ${formatNumber(usage.token_limit)} token`}</p>
      <div className="group table-wrap"><table className="data-table stack-table"><thead><tr><th scope="col">用途</th><th scope="col">模型</th><th scope="col" className="num">调用</th><th scope="col" className="num">输入 token</th><th scope="col" className="num">输出 token</th><th scope="col" className="num">总耗时</th></tr></thead><tbody>
        {usage.by_tier.map(row => <tr key={row.tier}><td>{tierNames[row.tier] ?? row.tier}</td><td className="end">{row.models.join("、") || "—"}</td><td className="num" data-label="调用">{formatNumber(row.calls)} 次{row.failed > 0 && <span className="error">，失败 {formatNumber(row.failed)} 次</span>}</td><td className="num end" data-label="输入 token"><Tokens value={row.input_tokens} incomplete={row.input_tokens_incomplete} /></td><td className="num" data-label="输出 token"><Tokens value={row.output_tokens} incomplete={row.output_tokens_incomplete} /></td><td className="num end" data-label="耗时">{formatMs(row.ms)}</td></tr>)}
        {usage.by_tier.length > 1 && <tr className="total"><td>合计</td><td className="end" /><td className="num" data-label="调用">{formatNumber(usage.total.calls)} 次{usage.total.failed > 0 && <span className="error">，失败 {formatNumber(usage.total.failed)} 次</span>}</td><td className="num end" data-label="输入 token"><Tokens value={usage.total.input_tokens} incomplete={usage.total.input_tokens_incomplete} /></td><td className="num" data-label="输出 token"><Tokens value={usage.total.output_tokens} incomplete={usage.total.output_tokens_incomplete} /></td><td className="num end" data-label="耗时">{formatMs(usage.total.ms)}</td></tr>}
      </tbody></table></div>
    </> : <p className="muted">今天还没有调用模型{usage.token_limit !== null && `，每天上限 ${formatNumber(usage.token_limit)} token`}</p>}

    <h2 className="section-title">录音与转写</h2>
    <div className="group">
      <dl className="status-lines">
        {nonZero(countList(audio.speakers, speakerNames)) && <><dt>说话人</dt><dd><Counts items={countList(audio.speakers, speakerNames)} unit=" 个" /></dd></>}
        {audio.voice_conversations > 0 && <><dt>认出说话人的对话</dt><dd>{formatNumber(audio.voice_conversations)} 段</dd></>}
        {audio.sample_requests_open > 0 && <><dt>试听样本</dt><dd>{formatNumber(audio.sample_requests_open)} 个在等设备上传</dd></>}
        {audio.deletes_pending > 0 && <><dt>待删除录音</dt><dd>{formatNumber(audio.deletes_pending)} 段对话等设备删除</dd></>}
        <dt>本机转写队列</dt><dd>{transcription ? <>
          {transcription.pending > 0 ? `待转写 ${formatNumber(transcription.pending)} 段` : "没有待转写的录音"}
          {transcription.failed > 0 && <span className="error">，失败 {formatNumber(transcription.failed)} 段</span>}
          <CollectorAge update={transcription} now={status.generated_at} />
        </> : audio.transcription_disabled ? "录音没开" : "暂时读不到本机状态"}</dd>
      </dl>
    </div>

    <h2 className="section-title">密钥备份</h2>
    <p className="muted">数据库和音频的密钥只存在这台 Mac 的钥匙串里，丢了就打不开记录，请在 Tacit 的“设置 → 维护 → 密钥备份”复制后存进密码管理器。</p>
  </section>;
}
