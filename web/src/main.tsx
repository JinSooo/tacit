import { AuditView } from "./audit-view.tsx";
import React, { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { createRoot } from "react-dom/client";
import type { RecordV1 } from "../../packages/record/index.ts";
import { buildCorrection, buildNote, dateTitle, dayKey, duration, groupRecords, latestCorrection, safeUrl, sourceColor, sourceNames, timeRange, type Detail, type HistoryRow } from "./history.ts";
import { DayOverview } from "./day-overview.tsx";
import { toLocalIso } from "./record-helpers.ts";
import { createDistillationApi } from "./distillation.ts";
import { DistillationWorkspace, type View } from "./distillation-views.tsx";
import { createApi } from "./api.ts";
import { createAudioApi, speakerNames, type Speaker } from "./audio.ts";
import { AudioSettings } from "./audio-views.tsx";
import "./style.css";

const tokenKey = "record-anything-token";
function readToken(): string {
  const hash = new URLSearchParams(location.hash.slice(1));
  const supplied = hash.get("token");
  if (location.hash) history.replaceState(null, "", location.pathname + location.search);
  try {
    if (supplied !== null) sessionStorage.setItem(tokenKey, supplied);
    return supplied ?? sessionStorage.getItem(tokenKey) ?? "";
  } catch { return supplied ?? ""; }
}
const initialToken = readToken();
type Api = <T>(path: string, init?: RequestInit) => Promise<T>;
const message = (error: unknown) => error instanceof Error ? error.message : "请求失败，请重试";

function Body({ text }: { text: string }) {
  const [full, setFull] = useState(false);
  const lines = text.split("\n");
  return <><pre className="body-text">{full ? text : lines.slice(0, 40).join("\n")}</pre>{lines.length > 40 && <button className="text-button" onClick={() => setFull(!full)}>{full ? "收起正文" : `展开全部 ${lines.length} 行`}</button>}</>;
}
function RecordDetail({ id, api, onDelete, speakers }: { id: string; api: Api; speakers: Speaker[]; onDelete: (ids: string[]) => void }) {
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
    {!detail && !error && <p role="status">正在读取…</p>}
    {detail && current && <>
      {detail.source === "mac.audio" && !!detail.people?.length && <p>{speakerNames(detail.people, speakers).join("、")}</p>}
      <Body key={current.id} text={current.body} />
      {current !== detail && <details className="original"><summary>原文</summary><Body text={detail.body} /></details>}
      {detail.context && <dl className="context">{Object.entries({ URL: detail.context.url, 仓库: detail.context.repo, 目录: detail.context.cwd, 窗口: detail.context.window }).filter(([, value]) => value).map(([label, value]) => <React.Fragment key={label}><dt>{label}</dt><dd>{label === "URL" && safeUrl(value!) ? <a href={safeUrl(value!)} target="_blank" rel="noreferrer">{value}</a> : value}</dd></React.Fragment>)}</dl>}
      <p className="capture">采集方式：{detail.capture.method}</p>
      {editing ? <form onSubmit={correct} className="correction-form"><label htmlFor={`correction-${id}`}>修正正文</label><textarea id={`correction-${id}`} autoFocus rows={10} value={text} maxLength={200000} onChange={event => setText(event.target.value)} /><div className="actions"><button type="submit" disabled={busy}>{busy ? "提交中…" : "提交修正"}</button><button type="button" onClick={() => setEditing(false)}>取消</button></div></form> : <div className="actions"><button onClick={() => { setText(current.body); setEditing(true); }}>修正</button><button className="danger text-button" onClick={() => deletion.current?.showModal()}>删除</button></div>}
      <dialog ref={deletion} aria-labelledby={`delete-${id}`}><h2 id={`delete-${id}`}>删除这条记录？</h2><p>删除后不能恢复，已经发给云端模型的内容收不回来。</p><div className="actions"><button className="danger" disabled={busy} onClick={remove}>{busy ? "删除中…" : "确认删除"}</button><button disabled={busy} onClick={() => deletion.current?.close()}>取消</button></div></dialog>
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
    <h2 id="note-heading">补写 History</h2>
    <div className="time-fields"><label>开始时间<input autoFocus required type="datetime-local" value={start} onChange={event => setStart(event.target.value)} /></label><label>结束时间（可空）<input type="datetime-local" min={start} value={end} onChange={event => setEnd(event.target.value)} /></label></div>
    <label>标题<input required maxLength={200} value={title} onChange={event => setTitle(event.target.value)} /></label>
    <label>正文<textarea rows={10} maxLength={200000} value={body} onChange={event => setBody(event.target.value)} /></label>
    {error && <p role="alert" className="error">{error}</p>}
    <div className="actions"><button type="submit" disabled={busy}>{busy ? "提交中…" : "补写"}</button><button type="button" onClick={onClose}>取消</button></div>
  </form></dialog>;
}
function App() {
  const [token, setToken] = useState(initialToken);
  const [view, setView] = useState<View | "audit" | "settings">(() => /[?&](thread|project)=/.test(location.search) ? "audit" : "history");
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
    try { sessionStorage.removeItem(tokenKey); } catch { /* 浏览器可能禁用了存储。 */ }
    setToken("");
  }), [token]);
  const audioApi = useMemo(() => createAudioApi(api), [api]);
  const [speakers, setSpeakers] = useState<Speaker[]>([]);
  const [speakerError, setSpeakerError] = useState("");
  useEffect(() => {
    if (!token || view !== "history") return;
    const controller = new AbortController();
    setSpeakerError("");
    audioApi.speakers(controller.signal).then(data => { if (!controller.signal.aborted) setSpeakers(data.speakers); }).catch(error => { if (!controller.signal.aborted) setSpeakerError(message(error)); });
    return () => controller.abort();
  }, [audioApi, token, view, revision]);
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
      setDevices(previous => [...new Set([...previous, ...page.records.map(record => record.device)])].sort());
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
  function pick(record: HistoryRow) {
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
      if (event.key === "Escape") { setExpanded(null); search.current?.blur(); }
      if (event.key === "/" && !event.metaKey && !event.ctrlKey && !event.altKey && !target.closest("input,textarea,select,[contenteditable]")) { event.preventDefault(); search.current?.focus(); }
    };
    document.addEventListener("keydown", keyboard);
    return () => document.removeEventListener("keydown", keyboard);
  }, []);
  if (!token) return <p className="token-prompt">在终端运行 <code>bun hub/src/cli.ts open</code></p>;
  return <><a className="skip" href="#content">跳到内容</a><main>
    <header><div className="heading-row"><h1>Record Anything</h1><nav aria-label="视图切换">{([["history", "History"], ["now", "当前"], ["pending", "待确认"], ["audit", "读取记录"], ["settings", "设置"]] as const).map(([key, label]) => <button key={key} aria-current={view === key ? "page" : undefined} onClick={() => setView(key)}>{label}{key === "pending" && pendingCount > 0 && <span className="pending-count">{pendingCount}</span>}</button>)}</nav></div>{view === "history" && <div className="toolbar">
      <input ref={search} type="search" aria-label="搜索 History" placeholder="搜索 History" value={q} onChange={event => setQ(event.target.value)} />
      <select aria-label="来源筛选" value={source} onChange={event => setSource(event.target.value)}><option value="">所有来源</option>{Object.entries(sourceNames).map(([value, name]) => <option key={value} value={value}>{name}</option>)}</select>
      <input className="device" list="devices" aria-label="设备筛选" placeholder="所有设备" value={device} onChange={event => setDevice(event.target.value)} /><datalist id="devices">{devices.map(device => <option key={device} value={device} />)}</datalist>
      <input className="date" type="date" aria-label="跳到日期" value={date} onChange={event => setDate(event.target.value)} />
      <button onClick={() => setNote(true)}>补写</button>
    </div>}</header>
    <div id="content" tabIndex={-1}>
    <DistillationWorkspace view={view === "audit" || view === "settings" ? "history" : view} audio={audioApi} api={distillationApi} onCount={setPendingCount} onHistory={title => { setQ(title); setSource(""); setDevice(""); setDate(""); setView("history"); setRevision(value => value + 1); }} />
    {view === "settings" && <AudioSettings api={audioApi} />}
    {view === "audit" && <AuditView api={api} distillation={distillationApi} onHistory={title => { setQ(title); setSource(""); setDevice(""); setDate(""); setView("history"); setRevision(value => value + 1); }} />}
    {view === "history" && !q.trim() && <DayOverview api={api} day={date || dayKey(new Date())} selected={expanded} onPick={pick} />}
    {view === "history" && anchor && <p className="anchor-note">从 {timeRange({ ...records.find(r => r.id === anchor.id) ?? { kind: "event", t_start: anchor.t_start } } as HistoryRow)} 起显示 <button className="text-button compact" onClick={() => setAnchor(null)}>回到最新</button></p>}
    <div id="timeline" hidden={view !== "history"} tabIndex={-1} aria-busy={busy}>
      {speakerError && records.some(record => record.source === "mac.audio") && <p className="error" role="alert">说话人名字读取失败：{speakerError} <button onClick={() => setRevision(value => value + 1)}>重试</button></p>}
      {groupRecords(records).map(group => <section key={group.day} aria-label={dateTitle(group.day)}><h2 className="day-heading">{dateTitle(group.day)}</h2><div className="day-records">{group.records.map(record => <article key={record.id} id={`row-${record.id}`} className={expanded === record.id ? "record expanded" : "record"}>
        <button className="record-row" style={{ "--source-color": sourceColor(record.source) } as React.CSSProperties} aria-expanded={expanded === record.id} aria-controls={`detail-${record.id}`} onClick={() => setExpanded(expanded === record.id ? null : record.id)}>
          <span className="record-time">{timeRange(record)}</span><span className="record-title">{record.title}{record.context?.url && safeUrl(record.context.url) && <span className="record-host">{new URL(record.context.url).host}</span>}</span><span className="record-meta">{sourceNames[record.source] ?? record.source}{duration(record) && <span>{duration(record)}</span>}</span>
        </button>
        {expanded === record.id && <RecordDetail id={record.id} api={api} speakers={speakers} onDelete={ids => { setRecords(previous => previous.filter(record => !ids.includes(record.id))); setExpanded(null); }} />}
      </article>)}</div></section>)}
      {!records.length && !busy && !error && <p className="empty">没有记录</p>}
      {error && <div className="list-status" role="alert"><span className="error">{error}</span><button onClick={() => void load(cursor, generation.current)}>重试</button></div>}
      <div ref={sentinel} className="list-status" role="status">{busy ? "正在读取…" : ""}</div>
    </div>
    </div>
    {note && <NoteDialog api={api} onClose={() => setNote(false)} onSaved={() => { setNote(false); setRevision(value => value + 1); }} />}
  </main></>;
}
createRoot(document.getElementById("root")!).render(<App />);
