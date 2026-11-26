import React, { useEffect, useState } from "react";
import { relativeTime, type Api } from "./distillation.ts";
import { sourceNames } from "./history.ts";
import { statusLanguage, type Lang } from "./i18n.ts";
import { cooldownNames, countList, errorName, errorNeedsAttention, englishStatusNames, fetchStatus, formatBytes, formatClock, formatDateTime, formatMs, formatNumber, formatUptime, frameNames, pendingNames, requestNames, speakerNames, STATUS_REFRESH_MS, threadNames, tierNames, type HubStatus } from "./status.ts";

function Since({ at, lang = "zh" }: { at: string | null; lang?: Lang }) {
  return at ? <time dateTime={at} title={formatDateTime(at, undefined, lang)}>{relativeTime(at, undefined, lang)}</time> : <>—</>;
}
function Stats({ items }: { items: [string, React.ReactNode][] }) {
  return <dl className="stats">{items.map(([label, value]) => <div key={label}><dd>{value}</dd><dt>{label}</dt></div>)}</dl>;
}
/** 只列不为 0 的计数。 */
function Counts({ items, unit = "", lang = "zh" }: { items: { key: string; label: string; count: number }[]; unit?: string; lang?: Lang }) {
  return <>{items.filter(item => item.count > 0).map(item => `${item.label} ${formatNumber(item.count)}${lang === "zh" ? unit : ""}`).join(lang === "zh" ? "，" : ", ")}</>;
}
const countText = (count: number, zhUnit: string, enUnit: string, lang: Lang, plural = enUnit + "s") =>
  `${formatNumber(count)} ${lang === "zh" ? zhUnit : count === 1 ? enUnit : plural}`;
const nonZero = (items: { count: number }[]) => items.some(item => item.count > 0);

function CollectorAge({ update, now, lang }: { update: { updated_at: string; stale: boolean }; now: string; lang: Lang }) {
  if (!update.stale) return null;
  const minutes = Math.max(0, Math.floor((Date.parse(now) - Date.parse(update.updated_at)) / 60_000));
  return <span className="error">{lang === "zh" ? `，本机状态已 ${formatNumber(minutes)} 分钟没更新` : `, local status last updated ${formatNumber(minutes)} min ago`}</span>;
}

function Tokens({ value, incomplete, lang }: { value: number | null; incomplete: boolean; lang: Lang }) {
  return value === null ? <>{lang === "zh" ? "未知" : "Unknown"}</> : <>{formatNumber(value)}{incomplete && <span className="muted">{lang === "zh" ? "，部分未知" : ", partial count"}</span>}</>;
}

/** 启动以来的累计值，不把重启后清零的数字称为全天统计。 */
export function BusyStatus({ busy, lang = "zh" }: { busy: HubStatus["hub"]["busy"]; lang?: Lang }) {
  if (busy.total === 0) return null;
  return <dl className="status-lines"><dt>{lang === "zh" ? "忙时自动重试" : "Automatic retries"}</dt><dd>
    {lang === "zh" ? `启动以来 ${formatNumber(busy.total)} 次` : `${countText(busy.total, "次", "retry", lang, "retries")} since startup`}{busy.last_at && <>{lang === "zh" ? "，最近一次 " : ", most recently "}<Since at={busy.last_at} lang={lang} /></>}
  </dd></dl>;
}

/**
 * 后台服务的状态。数字的含义（见 hub/src/status.ts）：
 * 记录总数不含已删除的；已删除是删除后留下的墓碑数；读取次数是今天 AI 工具每次读取或添加留下的读取记录条数。
 */
export function StatusView({ api, focus, fallback = "zh", onLanguage }: { api: Api; focus?: "usage"; fallback?: Lang; onLanguage?: (lang: Lang) => void }) {
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

  const lang = statusLanguage(status?.language, fallback);
  useEffect(() => { onLanguage?.(lang); }, [lang, onLanguage]);

  if (!status) return <section className="distillation-view">{failed
    ? <div className="list-status" role="alert"><span className="error">{lang === "zh" ? "没能读取状态" : "Could not load status"}</span> <button onClick={() => setRevision(value => value + 1)}>{lang === "zh" ? "重试" : "Retry"}</button></div>
    : <p className="list-status" role="status">{lang === "zh" ? "正在读取…" : "Loading…"}</p>}</section>;
  return <StatusContent status={status} refreshFailed={failed} lang={lang} />;
}

export function StatusContent({ status, refreshFailed, lang = statusLanguage(status.language, "zh") }: { status: HubStatus; refreshFailed?: boolean; lang?: Lang }) {
  const t = (zh: string, en: string) => lang === "zh" ? zh : en;
  const comma = t("，", ", ");
  const names: Record<keyof typeof englishStatusNames, Record<string, string>> = lang === "en" ? englishStatusNames : {
    tier: tierNames, frame: frameNames, thread: threadNames, pending: pendingNames,
    request: requestNames, speaker: speakerNames, cooldown: cooldownNames, source: sourceNames,
  };
  const recordsText = (count: number) => countText(count, "条", "record", lang);
  const count = (value: number, zhUnit: string, enUnit: string) => countText(value, zhUnit, enUnit, lang);
  const { hub, listen, database, records, distill, llm_today: usage, audio, collector } = status;
  const { transcription } = audio;
  const now = Date.parse(status.generated_at);
  const pending = countList(distill.pending_open, names.pending);
  const regen = distill.needs_regen;
  const deviceName = (id: string) => status.devices?.find(device => device.id === id)?.name
    ?? (id === "mac" ? t("这台 Mac", "This Mac") : id === "web" ? t("网页", "Web view") : id.startsWith("android-") ? t("已移除的手机", "Removed phone") : id.startsWith("mac-") ? t("已移除的 Mac", "Removed Mac") : id);
  // 整理服务 90 秒没心跳算没响应，和 Mac 的判断一致。
  const heartbeat = Date.parse(distill.heartbeat_at ?? "");
  const unresponsive = !!distill.enabled_at && (!Number.isFinite(heartbeat) || now - heartbeat > 90_000);
  const outboxTrouble = collector && (collector.outbox_bytes > 0 || collector.outbox_dropped > 0 || collector.outbox_degraded || collector.stale);
  const lastError = distill.last_error;
  return <section className="distillation-view status-view">
    <div className="status-head">
      <h2 className="section-title">{t("后台服务", "Background service")}</h2>
      <span className="caption">{refreshFailed && <><span className="error" role="alert">{t("刷新失败", "Could not refresh")}</span>{comma}</>}{t("每 15 秒刷新，上次 ", "Refreshes every 15 sec, last at ")}<time dateTime={status.generated_at}>{formatClock(status.generated_at, lang)}</time></span>
    </div>
    <div className="group">
      <Stats items={[
        [t("已运行", "Uptime"), <span title={t(`启动于 ${formatDateTime(hub.started_at, now)}`, `Started ${formatDateTime(hub.started_at, now, lang)}`)}>{formatUptime(hub.uptime_s, lang)}</span>],
        [t("地址", "Address"), <code>{listen.host}:{listen.port}</code>],
        ...(listen.lan_port ? [[t("设备连接端口", "Device connection port"), <code>{listen.lan_port}</code>] as [string, React.ReactNode]] : []),
        [t("数据库大小", "Database size"), <span title={database.file}>{formatBytes(database.bytes)}</span>],
        [t("记录", "Records"), recordsText(records.total)],
        ...(records.tombstones > 0 ? [[t("已删除", "Deleted"), recordsText(records.tombstones)] as [string, React.ReactNode]] : []),
        [t("今天 AI 工具读取", "AI tool reads today"), count(status.agent_reads_today, "次", "read")],
      ]} />
      <BusyStatus busy={hub.busy} lang={lang} />
      {(!collector || outboxTrouble) && <dl className="status-lines">
        <dt>{t("本机待发送记录", "Local records waiting to send")}</dt><dd>{collector ? <>
          <span className={collector.outbox_degraded || collector.outbox_dropped > 0 ? "error" : undefined}>
            {formatBytes(collector.outbox_bytes)}{collector.outbox_dropped > 0 && t(`，本次运行已丢弃 ${formatNumber(collector.outbox_dropped)} 条`, `, dropped ${recordsText(collector.outbox_dropped)} since startup`)}{collector.outbox_degraded && t("，待发送队列异常", ", outgoing queue error")}
          </span>
          <CollectorAge update={collector} now={status.generated_at} lang={lang} />
        </> : t("暂时读不到本机状态", "Local status is unavailable")}</dd>
      </dl>}
    </div>

    <div className="status-columns">
      <div>
        <h2 className="section-title">{t("各来源", "Sources")}</h2>
        <div className="group table-wrap"><table className="data-table"><thead><tr><th scope="col">{t("来源", "Source")}</th><th scope="col" className="num">{t("记录", "Records")}</th><th scope="col" className="num">{t("最近收到", "Last received")}</th></tr></thead><tbody>
          {records.by_source.map(row => <tr key={row.source}><td>{names.source[row.source] ?? row.source}</td><td className="num">{recordsText(row.count)}</td><td className="num"><Since at={row.last_received} lang={lang} /></td></tr>)}
          {!records.by_source.length && <tr><td colSpan={3} className="muted">{t("还没有记录", "No records yet")}</td></tr>}
        </tbody></table></div>
      </div>
      <div>
        <h2 className="section-title">{t("各设备", "Devices")}</h2>
        <div className="group table-wrap"><table className="data-table"><thead><tr><th scope="col">{t("设备", "Device")}</th><th scope="col" className="num">{t("记录", "Records")}</th><th scope="col" className="num">{t("最近收到", "Last received")}</th></tr></thead><tbody>
          {records.by_device.map(row => <tr key={row.device}><td>{deviceName(row.device)}</td><td className="num">{recordsText(row.count)}</td><td className="num"><Since at={row.last_received} lang={lang} /></td></tr>)}
          {!records.by_device.length && <tr><td colSpan={3} className="muted">{t("还没有记录", "No records yet")}</td></tr>}
        </tbody></table></div>
      </div>
    </div>

    <h2 className="section-title">{t("整理", "Summarizing")}</h2>
    <div className="group">
      <Stats items={[
        [t("最近整理", "Last successful summary"), <Since at={distill.last_ok_at} lang={lang} />],
        [t("上次实时整理", "Last live run"), <Since at={distill.last_round_at} lang={lang} />],
        [t("上次每小时汇总", "Last hourly roundup"), <Since at={distill.last_slow_round_at} lang={lang} />],
      ]} />
      <dl className="status-lines">
        {unresponsive && <><dt>{t("整理服务", "Summary service")}</dt><dd className="error">{t("没有响应", "Not responding")}{Number.isFinite(heartbeat) && <>{comma}{t("上次响应 ", "last response ")}<Since at={distill.heartbeat_at} lang={lang} /></>}</dd></>}
        {distill.config_error && <><dt>{t("模型设置", "Model settings")}</dt><dd className="error">{errorName("config_error", lang)}</dd></>}
        {nonZero(countList(distill.frames, names.frame)) && <><dt>{t("活动片段", "Activities")}</dt><dd><Counts items={countList(distill.frames, names.frame)} unit=" 段" lang={lang} /></dd></>}
        {nonZero(countList(distill.threads, names.thread)) && <><dt>{t("事项", "Tasks")}</dt><dd><Counts items={countList(distill.threads, names.thread)} unit=" 件" lang={lang} /></dd></>}
        {regen.threads + regen.projects + regen.days > 0 && <><dt>{t("等待更新", "Waiting for update")}</dt><dd>{[
          regen.threads && t(`事项 ${formatNumber(regen.threads)} 件`, count(regen.threads, "件", "task")),
          regen.projects && t(`项目 ${formatNumber(regen.projects)} 个`, count(regen.projects, "个", "project")),
          regen.days && t(`每日时间线 ${formatNumber(regen.days)} 天`, count(regen.days, "天", "daily timeline")),
        ].filter(Boolean).join(comma)}</dd></>}
        {distill.requests.total > 0 && <><dt>{t("手动整理", "Manual summaries")}</dt><dd>
          <Counts items={countList(distill.requests.by_status, names.request)} unit=" 次" lang={lang} />
          <ul className="status-requests">{distill.requests.recent.map(request => <li key={request.id}>
            <time dateTime={request.created_at} className="muted">{formatDateTime(request.created_at, now, lang)}</time>
            {" "}{names.request[request.status]}
            {request.total !== null && `${comma}${t("已处理 ", "processed ")}${formatNumber(request.done ?? 0)}/${formatNumber(request.total)}`}
            {request.status === "failed" && <span className="error">{comma}{errorName(request.error, lang)}</span>}
          </li>)}</ul>
        </dd></>}
        {nonZero(pending) && <><dt>{t("待确认", "To confirm")}</dt><dd><Counts items={pending} unit=" 项" lang={lang} /></dd></>}
        <dt>{t("启用时间", "Enabled since")}</dt><dd>{distill.enabled_at ? <time dateTime={distill.enabled_at}>{formatDateTime(distill.enabled_at, now, lang)}</time> : t("还没启用", "Not yet enabled")}{distill.enabled_at && !distill.backfill_done && t("，之前的历史还没整理完", ", earlier records are still waiting to be summarized")}</dd>
        {distill.cooldown && <><dt>{t("暂停", "Paused")}</dt><dd className="error">{distill.cooldown.kind === "budget"
          ? t("已达到今天的用量上限，明天 0 点恢复", "Daily usage limit reached. Summarizing resumes at midnight.")
          : <>{lang === "zh"
            ? `因${names.cooldown[distill.cooldown.kind] ?? "模型服务出错"}，整理暂停到 `
            : "Summarizing paused until "}<time dateTime={distill.cooldown.until}>{formatClock(distill.cooldown.until, lang, false)}</time>{lang === "en" && ` because of ${names.cooldown[distill.cooldown.kind] ?? "a model service error"}`}</>}</dd></>}
        {lastError && <><dt>{t("最近出错", "Most recent error")}</dt><dd className={errorNeedsAttention(lastError, distill.last_ok_at, now) ? "error" : "muted"}>
          {lastError.tier && Object.hasOwn(names.tier, lastError.tier) ? `${names.tier[lastError.tier]}${comma}` : ""}
          <Since at={lastError.at} lang={lang} />{t("：", ": ")}{errorName(lastError.error, lang)}{lastError.recovered && t("之后已恢复。", " Recovered since then.")}
        </dd></>}
      </dl>
    </div>

    <h2 className="section-title" id="usage">{t("今天的模型用量", "Model usage today")}</h2>
    {usage.by_tier.length ? <>
      <p className="muted">{t(`今天已用 ${formatNumber(usage.used_tokens)} token`, `Used ${count(usage.used_tokens, "token", "token")} today`)}{usage.token_limit !== null && t(`，上限 ${formatNumber(usage.token_limit)} token`, `, limit ${count(usage.token_limit, "token", "token")}`)}</p>
      <div className="group table-wrap"><table className="data-table stack-table"><thead><tr><th scope="col">{t("用途", "Purpose")}</th><th scope="col">{t("模型", "Model")}</th><th scope="col" className="num">{t("调用", "Calls")}</th><th scope="col" className="num">{t("输入 token", "Input tokens")}</th><th scope="col" className="num">{t("输出 token", "Output tokens")}</th><th scope="col" className="num">{t("总耗时", "Total time")}</th></tr></thead><tbody>
        {usage.by_tier.map(row => <tr key={row.tier}><td>{names.tier[row.tier] ?? row.tier}</td><td className="end">{row.models.join(t("、", ", ")) || "—"}</td><td className="num" data-label={t("调用", "Calls")}>{count(row.calls, "次", "call")}{row.failed > 0 && <span className="error">{t(`，失败 ${formatNumber(row.failed)} 次`, `, ${formatNumber(row.failed)} failed`)}</span>}</td><td className="num end" data-label={t("输入 token", "Input tokens")}><Tokens value={row.input_tokens} incomplete={row.input_tokens_incomplete} lang={lang} /></td><td className="num" data-label={t("输出 token", "Output tokens")}><Tokens value={row.output_tokens} incomplete={row.output_tokens_incomplete} lang={lang} /></td><td className="num end" data-label={t("耗时", "Time")}>{formatMs(row.ms, lang)}</td></tr>)}
        {usage.by_tier.length > 1 && <tr className="total"><td>{t("合计", "Total")}</td><td className="end" /><td className="num" data-label={t("调用", "Calls")}>{count(usage.total.calls, "次", "call")}{usage.total.failed > 0 && <span className="error">{t(`，失败 ${formatNumber(usage.total.failed)} 次`, `, ${formatNumber(usage.total.failed)} failed`)}</span>}</td><td className="num end" data-label={t("输入 token", "Input tokens")}><Tokens value={usage.total.input_tokens} incomplete={usage.total.input_tokens_incomplete} lang={lang} /></td><td className="num" data-label={t("输出 token", "Output tokens")}><Tokens value={usage.total.output_tokens} incomplete={usage.total.output_tokens_incomplete} lang={lang} /></td><td className="num end" data-label={t("耗时", "Time")}>{formatMs(usage.total.ms, lang)}</td></tr>}
      </tbody></table></div>
    </> : <p className="muted">{t("今天还没有调用模型", "No model calls today")}{usage.token_limit !== null && t(`，每天上限 ${formatNumber(usage.token_limit)} token`, `, daily limit ${count(usage.token_limit, "token", "token")}`)}</p>}

    <h2 className="section-title">{t("录音与转写", "Recording and transcription")}</h2>
    <div className="group">
      <dl className="status-lines">
        {nonZero(countList(audio.speakers, names.speaker)) && <><dt>{t("说话人", "Speakers")}</dt><dd><Counts items={countList(audio.speakers, names.speaker)} unit=" 个" lang={lang} /></dd></>}
        {audio.voice_conversations > 0 && <><dt>{t("认出说话人的对话", "Conversations with recognized speakers")}</dt><dd>{count(audio.voice_conversations, "段", "conversation")}</dd></>}
        {audio.sample_requests_open > 0 && <><dt>{t("试听样本", "Audio samples")}</dt><dd>{t(`${formatNumber(audio.sample_requests_open)} 个在等设备上传`, `${count(audio.sample_requests_open, "个", "sample")} waiting for upload`)}</dd></>}
        {audio.deletes_pending > 0 && <><dt>{t("待删除录音", "Recordings awaiting deletion")}</dt><dd>{t(`${formatNumber(audio.deletes_pending)} 段对话等设备删除`, `${count(audio.deletes_pending, "段", "conversation")} waiting for removal from devices`)}</dd></>}
        <dt>{t("本机转写队列", "Local transcription queue")}</dt><dd>{transcription ? <>
          {transcription.pending > 0 ? t(`待转写 ${formatNumber(transcription.pending)} 段`, `${count(transcription.pending, "段", "recording")} waiting`) : t("没有待转写的录音", "No recordings waiting")}
          {transcription.failed > 0 && <span className="error">{t(`，失败 ${formatNumber(transcription.failed)} 段`, `, ${formatNumber(transcription.failed)} failed`)}</span>}
          <CollectorAge update={transcription} now={status.generated_at} lang={lang} />
        </> : audio.transcription_disabled ? t("录音没开", "Recording is off") : t("暂时读不到本机状态", "Local status is unavailable")}</dd>
      </dl>
    </div>

    <h2 className="section-title">{t("密钥备份", "Key backup")}</h2>
    <p className="muted">{t("数据库和音频的密钥只存在这台 Mac 的钥匙串里，丢了就打不开记录，请在 Tacit 的“设置 → 维护 → 密钥备份”复制后存进密码管理器。", "Back up the database and audio keys to a password manager from Settings → Maintenance → Key backup to keep access to your records if this Mac is lost.")}</p>
  </section>;
}
