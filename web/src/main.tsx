import { RuntimeView } from "./runtime-view.tsx";
import { SegmentList } from "./segment-list.tsx";
import React, { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { createRoot } from "react-dom/client";
import type { RecordV1 } from "../../packages/record/index.ts";
import { buildCorrection, buildNote, captureNames, dateTitle, dayKey, duration, groupRecords, historyDeviceGroup, latestCorrection, recordTitle, safeUrl, sourceNames, timeRange, type Detail, type HistoryRow } from "./history.ts";
import { DayOverview } from "./day-overview.tsx";
import { toLocalIso } from "./record-helpers.ts";
import { createDistillationApi } from "./distillation.ts";
import { DistillationWorkspace } from "./distillation-views.tsx";
import { createApi } from "./api.ts";
import { createAudioApi } from "./audio.ts";
import { clockMs, conversationDetail, type ConversationDetail } from "./segments.ts";
import { AudioSettings } from "./audio-views.tsx";
import { createSettingsApi } from "./settings.ts";
import { AgentSettings, GeneralSettings, HubSettingsBlock, ModelSettings } from "./settings-views.tsx";
import { StatusView } from "./status-view.tsx";
import { browserLanguage, statusPageCopy } from "./i18n.ts";
import { initialPage, pageHash, parseHash, type Page } from "./route.ts";
import "./style.css";

const tokenKey = "record-anything-token";
function storeToken(token: string) {
  try { sessionStorage.setItem(tokenKey, token); } catch { /* 浏览器可能禁用了存储。 */ }
}
function forgetToken() {
  try { sessionStorage.removeItem(tokenKey); } catch { /* 浏览器可能禁用了存储。 */ }
}
// 当前页写在 #/now 这类片段里；旧写法 #token=…（可带 &status）读完立刻换成页面片段，token 不留在地址栏。
const startPage = initialPage(location.hash, location.search);
// Mac 的“查看详细用量”带 &usage，读完地址栏就换掉，先记下来。
const startFocus = new URLSearchParams(location.hash.replace(/^#/, "")).has("usage") ? "usage" as const : undefined;
function readToken(page: Page): string {
  const supplied = parseHash(location.hash).token;
  if (location.hash && location.hash !== pageHash(page)) history.replaceState(null, "", location.pathname + location.search + pageHash(page));
  if (supplied !== null) storeToken(supplied);
  try { return supplied ?? sessionStorage.getItem(tokenKey) ?? ""; } catch { return supplied ?? ""; }
}
type Api = <T>(path: string, init?: RequestInit) => Promise<T>;
const message = (error: unknown) => error instanceof Error ? error.message : "请求失败，请重试";

function Body({ text }: { text: string }) {
  const [full, setFull] = useState(false);
  const lines = text.split("\n");
  return <><pre className="body-text">{full ? text : lines.slice(0, 40).join("\n")}</pre>{lines.length > 40 && <button className="text-button" onClick={() => setFull(!full)}>{full ? "收起" : `显示全部 ${lines.length.toLocaleString("zh-CN")} 行`}</button>}</>;
}
/** 对话记录：先给总结，再给整理过的原文（按人分段）；原始转写折叠在后面。 */
function ConversationBody({ id, revision, api }: { id: string; revision: string; api: Api }) {
  const [conversation, setConversation] = useState<ConversationDetail>();
  const [error, setError] = useState("");
  useEffect(() => {
    const controller = new AbortController();
    setError("");
    conversationDetail(api, id, controller.signal).then(setConversation).catch(error => { if (!controller.signal.aborted) setError(message(error)); });
    return () => controller.abort();
  }, [id, revision, api]);
  if (error) return <p role="alert" className="error">{error}</p>;
  if (!conversation) return <p className="muted" role="status">正在读取…</p>;
  return <>
    {conversation.state === "ready" && conversation.summary && <section className="conversation-summary" aria-label="总结">
      <p>{conversation.summary}</p>
      {conversation.points.length > 0 && <ul>{conversation.points.map((point, i) => <li key={i}>{point}</li>)}</ul>}
    </section>}
    {conversation.state === "waiting" && <p className="muted">总结稍后生成</p>}
    {conversation.state === "private" && <p className="muted">私密内容不生成总结</p>}
    {conversation.turns.length > 0 && <ol className="turns">{conversation.turns.map((turn, i) => <li key={i}>
      <div className="turn-head"><strong>{turn.speaker}</strong><time dateTime={turn.at}>{clockMs(Date.parse(turn.at))}</time></div>
      <p>{turn.text}</p>
    </li>)}</ol>}
  </>;
}
function RecordDetail({ id, api, onDelete, onCorrected }: { id: string; api: Api; onDelete: (ids: string[]) => void; onCorrected: () => void }) {
  const [detail, setDetail] = useState<Detail>();
  const [error, setError] = useState("");
  const [editing, setEditing] = useState(false);
  const [text, setText] = useState("");
  const [busy, setBusy] = useState(false);
  const deletion = useRef<HTMLDialogElement>(null);
  useEffect(() => {
    const controller = new AbortController();
    api<Detail>(`/v1/records/${id}`, { signal: controller.signal }).then(setDetail).catch(error => { if (!controller.signal.aborted) setError(message(error)); });
    return () => controller.abort();
  }, [id, api]);
  const current = detail && (latestCorrection(detail) ?? detail);
  async function correct(event: React.SubmitEvent<HTMLFormElement>) {
    event.preventDefault();
    if (!detail) return;
    setBusy(true); setError("");
    try {
      await saveRecord(api, buildCorrection(detail, text));
      onCorrected();
      setDetail(await api<Detail>(`/v1/records/${id}`));
      setEditing(false);
    } catch (error) { setError(message(error)); } finally { setBusy(false); }
  }
  async function remove() {
    setBusy(true); setError("");
    try {
      await api(`/v1/records/${id}`, { method: "DELETE" });
      onDelete([id, ...(detail?.corrections.map(record => record.id) ?? [])]);
    } catch (error) { setError(message(error)); deletion.current?.close(); } finally { setBusy(false); }
  }
  return <div className="record-detail" id={`detail-${id}`}>
    {error && <p role="alert" className="error">{error}</p>}
    {!detail && !error && <p className="muted" role="status">正在读取…</p>}
    {detail && current && <>
      {detail.source === "mac.audio" ? <>
        <ConversationBody id={id} revision={current.id} api={api} />
        <details className="original"><summary>查看原文</summary><Body key={current.id} text={current.body} />{current !== detail && <details className="original"><summary>修正前的原文</summary><Body text={detail.body} /></details>}</details>
      </> : <>
        <Body key={current.id} text={current.body} />
        {current !== detail && <details className="original"><summary>修正前的原文</summary><Body text={detail.body} /></details>}
      </>}
      <dl className="context">
        {Object.entries({ 网址: detail.context?.url, 仓库: detail.context?.repo, 目录: detail.context?.cwd, 窗口: detail.context?.window }).filter(([, value]) => value).map(([label, value]) => <React.Fragment key={label}><dt>{label}</dt><dd>{label === "网址" && safeUrl(value!) ? <a href={safeUrl(value!)} target="_blank" rel="noreferrer">{value}</a> : label === "仓库" || label === "目录" ? <span className="path">{value}</span> : value}</dd></React.Fragment>)}
        <dt>来源</dt><dd>{sourceNames[detail.source] ?? detail.source}，{captureNames[detail.capture.method] ?? detail.capture.method}</dd>
      </dl>
      {editing ? <form onSubmit={correct} className="correction-form"><label htmlFor={`correction-${id}`}>改成正确的内容，原文会保留</label><textarea id={`correction-${id}`} autoFocus rows={10} value={text} maxLength={200000} onChange={event => setText(event.target.value)} /><div className="actions"><button className="primary" type="submit" disabled={busy}>{busy ? "正在保存…" : "保存修正"}</button><button type="button" onClick={() => setEditing(false)}>取消</button></div></form> : <div className="actions"><button onClick={() => { setText(current.body); setEditing(true); }}>修正</button><button className="danger" onClick={() => deletion.current?.showModal()}>删除</button></div>}
      <dialog ref={deletion} aria-labelledby={`delete-${id}`}><h2 id={`delete-${id}`}>删除这条记录？</h2><p>删除后不能恢复。已经发给云端模型的内容收不回来。</p><div className="actions"><button className="danger" disabled={busy} onClick={remove}>{busy ? "正在删除…" : "删除"}</button><button disabled={busy} onClick={() => deletion.current?.close()}>取消</button></div></dialog>
    </>}
  </div>;
}
async function saveRecord(api: Api, record: RecordV1) {
  const result = await api<{ accepted: number; rejected: { errors: string[] }[] }>("/v1/records", { method: "POST", body: JSON.stringify(record) });
  if (result.accepted !== 1) throw new Error(result.rejected.flatMap(item => item.errors).join("；") || "记录未写入，请重试");
}
function localInputNow() { return toLocalIso(new Date()).slice(0, 16); }
function NoteDialog({ api, onSaved, onClose }: { api: Api; onSaved: () => void; onClose: () => void }) {
  const dialog = useRef<HTMLDialogElement>(null);
  const [start, setStart] = useState(localInputNow);
  const [end, setEnd] = useState("");
  const [title, setTitle] = useState("");
  const [body, setBody] = useState("");
  const [error, setError] = useState("");
  const [busy, setBusy] = useState(false);
  useEffect(() => { dialog.current?.showModal(); }, []);
  async function submit(event: React.SubmitEvent<HTMLFormElement>) {
    event.preventDefault(); setBusy(true); setError("");
    try { await saveRecord(api, buildNote({ start, end, title, body })); onSaved(); }
    catch (error) { setError(message(error)); } finally { setBusy(false); }
  }
  return <dialog ref={dialog} onCancel={event => { event.preventDefault(); onClose(); }} aria-labelledby="note-heading"><form onSubmit={submit}>
    <h2 id="note-heading">补写一条记录</h2>
    <div className="time-fields"><label>开始时间<input autoFocus required type="datetime-local" value={start} onChange={event => setStart(event.target.value)} /></label><label>结束时间<input type="datetime-local" min={start} value={end} onChange={event => setEnd(event.target.value)} /><span className="hint">不填就记成一个时间点</span></label></div>
    <label>标题<input required maxLength={200} value={title} onChange={event => setTitle(event.target.value)} /></label>
    <label>正文<textarea rows={10} maxLength={200000} value={body} onChange={event => setBody(event.target.value)} /></label>
    {error && <p role="alert" className="error">{error}</p>}
    <div className="actions"><button className="primary" type="submit" disabled={busy}>{busy ? "正在保存…" : "保存"}</button><button type="button" onClick={onClose}>取消</button></div>
  </form></dialog>;
}
export function App() {
  const [token, setToken] = useState(() => readToken(startPage));
  const [view, setView] = useState<Page>(startPage);
  useEffect(() => {
    // 前进后退、手改地址栏，以及已打开的页面再收到 #token=… 时同步。其他片段（如锚点）不切页。
    const sync = () => {
      const { page, token: supplied } = parseHash(location.hash);
      if (supplied !== null) {
        storeToken(supplied); setToken(supplied);
        history.replaceState(null, "", location.pathname + location.search + pageHash(page ?? "history"));
      }
      if (page || supplied !== null || !location.hash) setView(page ?? "history");
    };
    window.addEventListener("hashchange", sync);
    return () => window.removeEventListener("hashchange", sync);
  }, []);
  const navigate = useCallback((page: Page) => {
    if (location.hash !== pageHash(page)) location.hash = pageHash(page);
    setView(page);
  }, []);
  // 删除、补写、修正之后：刷新顶部概览，并给一句几秒后消失的提示。
  const [overviewRevision, setOverviewRevision] = useState(0);
  const [notice, setNotice] = useState<{ text: string; at: number }>();
  useEffect(() => {
    if (!notice) return;
    const timer = setTimeout(() => setNotice(undefined), 3000);
    return () => clearTimeout(timer);
  }, [notice]);
  const changed = useCallback((text: string) => { setOverviewRevision(value => value + 1); setNotice({ text, at: Date.now() }); }, []);
  const [collapse, setCollapse] = useState(0);
  const [pendingCount, setPendingCount] = useState(0);
  const [q, setQ] = useState("");
  const [source, setSource] = useState("");
  const [device, setDevice] = useState("");
  const [date, setDate] = useState("");
  const [records, setRecords] = useState<HistoryRow[]>([]);
  const [devices, setDevices] = useState<string[]>([]);
  const [cursor, setCursor] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState("");
  const [expanded, setExpanded] = useState<string | null>(null);
  // 从条带图点到还没加载的记录时，列表改为从那条记录的时间开始。
  const [anchor, setAnchor] = useState<{ id: string; t_start: string } | null>(null);
  const [note, setNote] = useState(false);
  const [revision, setRevision] = useState(0);
  const search = useRef<HTMLInputElement>(null);
  const sentinel = useRef<HTMLDivElement>(null);
  const generation = useRef(0);
  const loading = useRef(false);
  const api = useMemo(() => createApi(token, () => {
    forgetToken();
    setToken("");
  }), [token]);
  const audioApi = useMemo(() => createAudioApi(api), [api]);
  const settingsApi = useMemo(() => createSettingsApi(api), [api]);
  const distillationApi = useMemo(() => createDistillationApi(api), [api]);
  const load = useCallback(async (next: string | null, version: number, signal?: AbortSignal) => {
    if (loading.current) return;
    loading.current = true; setBusy(true); setError("");
    const params = new URLSearchParams({ limit: "50" });
    if (q.trim()) params.set("q", q.trim());
    if (source) params.set("source", source);
    if (device) params.set("device", device);
    if (anchor) params.set("to", anchor.t_start);
    else if (date) params.set("to", toLocalIso(new Date(`${date}T23:59:59.999`)).replace(/(?=[+-]\d\d:\d\d$)/, ".999"));
    if (next) params.set("cursor", next);
    try {
      const page = await api<{ records: HistoryRow[]; next_cursor: string | null }>(`/v1/records?${params}`, { signal });
      if (version !== generation.current) return;
      setRecords(previous => next ? [...new Map([...previous, ...page.records].map(record => [record.id, record])).values()] : page.records);
      setDevices(previous => [...new Set([...previous, ...page.records.map(record => historyDeviceGroup(record.device))])].sort());
      setCursor(page.next_cursor);
    } catch (error) { if (version === generation.current && !signal?.aborted) setError(message(error)); }
    finally { if (version === generation.current) { loading.current = false; setBusy(false); } }
  }, [api, q, source, device, date, anchor]);
  useEffect(() => { setAnchor(null); }, [q, source, device, date]);
  useEffect(() => {
    if (!anchor || !records.some(record => record.id === anchor.id)) return;
    setExpanded(anchor.id);
    requestAnimationFrame(() => document.getElementById(`row-${anchor.id}`)?.scrollIntoView({ block: "center", behavior: "smooth" }));
  }, [anchor, records]);
  // 没有搜索和来源筛选时按活动段看某一天，否则按原始记录逐条列出。
  const segmentMode = !q.trim() && !source && !anchor;
  const shownDay = date || dayKey(new Date());
  function pick(record: HistoryRow) {
    if (segmentMode) { setExpanded(record.id); return; }
    if (records.some(row => row.id === record.id)) {
      setExpanded(record.id);
      requestAnimationFrame(() => document.getElementById(`row-${record.id}`)?.scrollIntoView({ block: "center", behavior: "smooth" }));
    } else setAnchor({ id: record.id, t_start: record.t_start });
  }
  useEffect(() => {
    const version = ++generation.current;
    const controller = new AbortController();
    loading.current = false; setRecords([]); setCursor(null); setExpanded(null); setError(""); setBusy(Boolean(token));
    const timer = setTimeout(() => { if (token) void load(null, version, controller.signal); }, 200);
    return () => { clearTimeout(timer); controller.abort(); generation.current++; };
  }, [load, token, revision]);
  useEffect(() => {
    const target = sentinel.current;
    if (view !== "history" || !target || !cursor || busy || error) return;
    const observer = new IntersectionObserver(entries => { if (entries.some(entry => entry.isIntersecting)) void load(cursor, generation.current); }, { rootMargin: "240px" });
    observer.observe(target);
    return () => observer.disconnect();
  }, [cursor, busy, error, load, view]);
  useEffect(() => {
    const keyboard = (event: KeyboardEvent) => {
      const target = event.target as HTMLElement;
      if (document.querySelector("dialog[open]")) return;
      if (event.key === "Escape") { setExpanded(null); setCollapse(value => value + 1); search.current?.blur(); }
      if (event.key === "/" && !event.metaKey && !event.ctrlKey && !event.altKey && !target.closest("input,textarea,select,[contenteditable]")) { event.preventDefault(); search.current?.focus(); }
    };
    document.addEventListener("keydown", keyboard);
    return () => document.removeEventListener("keydown", keyboard);
  }, []);
  if (!token) return <div className="token-prompt"><strong>请重新打开网页版</strong><p className="muted">在 Mac 客户端的“设置 → 后台服务”里点“在浏览器中打开”。</p></div>;
  return <><a className="skip" href="#content" onClick={event => { event.preventDefault(); document.getElementById("content")?.focus(); }}>跳到内容</a><main>
    <header><div className="heading-row"><h1>Tacit</h1><nav aria-label="页面">{([["history", "历史记录"], ["now", "此刻"], ["pending", "待确认"], ["audit", "运行记录"], ["status", "状态"], ["settings", "设置"]] as const).map(([key, label]) => <button key={key} aria-current={view === key ? "page" : undefined} onClick={() => navigate(key)}>{label}{key === "pending" && pendingCount > 0 && <span className="pending-count" aria-label={`${pendingCount} 项`}>{pendingCount}</span>}</button>)}</nav></div>{view === "history" && <div className="toolbar">
      <input ref={search} type="search" aria-label="搜索历史记录" placeholder="搜索历史记录" value={q} onChange={event => setQ(event.target.value)} />
      <select aria-label="来源" value={source} onChange={event => setSource(event.target.value)}><option value="">全部来源</option>{Object.entries(sourceNames).map(([value, name]) => <option key={value} value={value}>{name}</option>)}</select>
      <input className="device" list="devices" aria-label="设备" placeholder="全部设备" value={device} onChange={event => setDevice(event.target.value)} /><datalist id="devices">{devices.map(device => <option key={device} value={device} />)}</datalist>
      <input className="date" type="date" aria-label="跳到日期" value={date} onChange={event => setDate(event.target.value)} />
      <button onClick={() => setNote(true)}>补写</button>
    </div>}</header>
    <div id="content" tabIndex={-1}>
    <DistillationWorkspace view={view === "audit" || view === "settings" || view === "status" ? "history" : view} audio={audioApi} api={distillationApi} onCount={setPendingCount} onHistory={title => { setQ(title); setSource(""); setDevice(""); setDate(""); navigate("history"); setRevision(value => value + 1); }} />
    {view === "settings" && <section className="distillation-view settings-view" aria-label="设置"><AgentSettings api={settingsApi} /><ModelSettings api={settingsApi} /><GeneralSettings api={settingsApi} /><AudioSettings api={audioApi} /><HubSettingsBlock api={settingsApi} token={token} /></section>}
    {view === "status" && <StatusView api={api} />}
    {view === "audit" && <RuntimeView api={api} distillation={distillationApi} onHistory={title => { setQ(title); setSource(""); setDevice(""); setDate(""); navigate("history"); setRevision(value => value + 1); }} />}
    {view === "history" && !q.trim() && <DayOverview api={api} day={date || dayKey(new Date())} revision={overviewRevision} selected={expanded} onPick={pick} />}
    {view === "history" && anchor && <p className="anchor-note">正在显示 {timeRange({ ...records.find(r => r.id === anchor.id) ?? { kind: "event", t_start: anchor.t_start } } as HistoryRow)} 及更早的记录 <button className="text-button compact" onClick={() => setAnchor(null)}>回到最新</button></p>}
    {view === "history" && segmentMode && <div id="segments" tabIndex={-1}><SegmentList api={api} day={shownDay} device={device} focus={expanded} revision={revision} collapse={collapse}
      renderDetail={(id, onDelete) => <RecordDetail id={id} api={api} onDelete={ids => { onDelete(ids); changed("已删除"); }} onCorrected={() => changed("已修正")} />}
      onEarlier={() => { const d = new Date(`${shownDay}T12:00:00`); d.setDate(d.getDate() - 1); setDate(dayKey(d)); window.scrollTo({ top: 0 }); }} /></div>}
    <div id="timeline" hidden={view !== "history" || segmentMode} tabIndex={-1} aria-busy={busy}>
      {groupRecords(records).map(group => <section key={group.day} aria-label={dateTitle(group.day)}><h2 className="day-heading">{dateTitle(group.day)}</h2><div className="day-records">{group.records.map(record => <article key={record.id} id={`row-${record.id}`} className={expanded === record.id ? "record expanded" : "record"}>
        <button className="record-row" aria-expanded={expanded === record.id} aria-controls={`detail-${record.id}`} onClick={() => setExpanded(expanded === record.id ? null : record.id)}>
          <span className="record-time">{timeRange(record)}</span><span className="record-title">{recordTitle(record)}{record.context?.url && safeUrl(record.context.url) && <span className="record-host">{new URL(record.context.url).host}</span>}</span><span className="record-meta">{sourceNames[record.source] ?? record.source}{duration(record) && <span>{duration(record)}</span>}</span>
        </button>
        {expanded === record.id && <RecordDetail id={record.id} api={api} onDelete={ids => { setRecords(previous => previous.filter(record => !ids.includes(record.id))); setExpanded(null); changed("已删除"); }} onCorrected={() => changed("已修正")} />}
      </article>)}</div></section>)}
      {!records.length && !busy && !error && <p className="empty"><strong>没有找到记录</strong>{(source || device || date) && "换个关键词，或去掉来源、设备、日期筛选再试。"}</p>}
      {error && <div className="list-status" role="alert"><span className="error">{error}</span><button onClick={() => void load(cursor, generation.current)}>重试</button></div>}
      <div ref={sentinel} className="list-status" role="status">{busy ? "正在读取…" : ""}</div>
    </div>
    </div>
    {note && <NoteDialog api={api} onClose={() => setNote(false)} onSaved={() => { setNote(false); setRevision(value => value + 1); changed("已补写"); }} />}
    {notice && <div className="toasts"><div className="toast" role="status" key={notice.at}>{notice.text}</div></div>}
  </main></>;
}
function StatusApp() {
  const [token, setToken] = useState(() => readToken("status"));
  const [fallback] = useState(browserLanguage);
  const [statusLang, setStatusLang] = useState(fallback);
  const lang = token ? statusLang : fallback;
  const copy = statusPageCopy[lang];
  useEffect(() => {
    document.documentElement.lang = lang === "zh" ? "zh-CN" : "en";
    document.title = copy.title;
  }, [lang, copy.title]);
  useEffect(() => {
    const sync = () => setToken(readToken("status"));
    window.addEventListener("hashchange", sync);
    return () => window.removeEventListener("hashchange", sync);
  }, []);
  const api = useMemo(() => createApi(token, () => {
    forgetToken();
    setToken("");
  }), [token]);
  if (!token) return <div className="token-prompt"><strong>{copy.open}</strong><p className="muted">{copy.instructions}</p></div>;
  return <main><header><div className="heading-row"><h1>{copy.title}</h1></div></header><StatusView api={api} focus={startFocus} fallback={fallback} onLanguage={setStatusLang} /></main>;
}

createRoot(document.getElementById("root")!).render(<StatusApp />);
