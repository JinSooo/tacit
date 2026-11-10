import React, { useCallback, useEffect, useRef, useState } from "react";
import { groupFacts, pendingSummary, pendingTitle, recentPaused, recentPausedMs, relativeTime, type DistillationApi, type Evidence, type Fact, type Pending, type Project, type Resolution, type Thread } from "./distillation.ts";
import { createUndoQueue, type UndoEntry, type UndoQueue } from "./undo.ts";
import { speechText } from "./history.ts";

import { knownSpeakers, sameNamedSpeaker, unknownSpeakers, type AudioApi } from "./audio.ts";
import { VoiceSamples } from "./audio-views.tsx";

export type View = "history" | "now" | "pending";
const message = (error: unknown) => error instanceof Error ? error.message : "请求失败，请重试";
/** keep：重新读取时保留上一次的数据，避免刷新时整块闪成"正在读取"。 */
function useResource<T>(load: (signal: AbortSignal) => Promise<T>, deps: React.DependencyList, keep = false) {
  const [data, setData] = useState<T>();
  const [error, setError] = useState("");
  const [revision, setRevision] = useState(0);
  useEffect(() => {
    const controller = new AbortController();
    if (!keep) setData(undefined);
    setError("");
    load(controller.signal).then(value => { if (!controller.signal.aborted) setData(value); }).catch(error => { if (!controller.signal.aborted) setError(message(error)); });
    return () => controller.abort();
  }, [...deps, revision]);
  return { data, error, retry: () => setRevision(value => value + 1) };
}
function Status({ error, retry }: { error: string; retry: () => void }) {
  return error ? <div className="list-status" role="alert"><span className="error">{error}</span><button onClick={retry}>重试</button></div> : <p className="list-status" role="status">正在读取…</p>;
}
function ActivityTime({ value }: { value: number | null }) {
  return <span className="activity-time" title={value === null ? undefined : new Date(value).toLocaleString("zh-CN")}>{relativeTime(value)}</span>;
}
function EvidenceList({ fact, load, onHistory }: { fact: Fact; load: () => Promise<Evidence[]>; onHistory: (title: string) => void }) {
  const [open, setOpen] = useState(false);
  const [records, setRecords] = useState<Evidence[]>();
  const [error, setError] = useState("");
  const [revision, setRevision] = useState(0);
  useEffect(() => {
    if (!open || records) return;
    let cancelled = false;
    setError("");
    load().then(rows => { if (!cancelled) setRecords(rows); }).catch(error => { if (!cancelled) setError(message(error)); });
    return () => { cancelled = true; };
  }, [open, revision]);
  return <div className="fact-evidence"><button className="text-button compact" aria-expanded={open} onClick={() => setOpen(!open)}>{open ? "收起依据" : "依据"}</button>{open && <div>
    {error ? <div role="alert" className="error">{error} <button onClick={() => setRevision(value => value + 1)}>重试</button></div> : !records ? <span role="status">正在读取…</span> : <>
      {records.filter(record => fact.evidence.includes(record.id)).map(record => <button className="evidence-link text-button" key={record.id} onClick={() => onHistory(record.title)}><span>{record.title}</span><time dateTime={record.t_start}>{new Date(record.t_start).toLocaleString("zh-CN", { month: "numeric", day: "numeric", hour: "2-digit", minute: "2-digit", hour12: false })}</time></button>)}
      {!records.some(record => fact.evidence.includes(record.id)) && <p className="muted">依据的记录已删除</p>}
    </>}
  </div>}</div>;
}
function CorrectionDialog({ fact, api, onSaved, onClose }: { fact: Fact; api: DistillationApi; onSaved: () => void; onClose: () => void }) {
  const dialog = useRef<HTMLDialogElement>(null);
  const [text, setText] = useState("");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState("");
  useEffect(() => { dialog.current?.showModal(); }, []);
  return <dialog ref={dialog} aria-labelledby="fact-correction-title" onCancel={event => { event.preventDefault(); if (!busy) onClose(); }}><form onSubmit={async event => {
    event.preventDefault(); setBusy(true); setError("");
    try { await api.correct(fact, text); onSaved(); } catch (error) { setError(message(error)); } finally { setBusy(false); }
  }}><h2 id="fact-correction-title">这条不对，应该是？</h2><p className="quote">{fact.text}</p><label>正确的说法<textarea required autoFocus rows={5} value={text} onChange={event => setText(event.target.value)} /></label>{error && <p className="error" role="alert">{error}</p>}<div className="actions"><button className="primary" disabled={busy || !text.trim()} type="submit">{busy ? "正在保存…" : "保存修正"}</button><button disabled={busy} type="button" onClick={onClose}>取消</button></div></form></dialog>;
}
const factIcons: Record<Fact["kind"], string> = { decision: "M3 8.5l3 3 7-7", rejected: "M4 4l8 8M12 4l-8 8", open: "M5.5 6a2.5 2.5 0 1 1 3.5 2.3c-.6.3-1 .8-1 1.5V11M8 13.5v.01", next: "M3 8h10M9 4l4 4-4 4", inference: "M2.5 9.5c1.5-3 3.5-3 5.5-1s4 2 5.5-1" };
function FactIcon({ kind }: { kind: Fact["kind"] }) {
  return <svg className="fact-icon" viewBox="0 0 16 16" aria-hidden="true"><path d={factIcons[kind]} fill="none" stroke="currentColor" strokeWidth="1.6" strokeLinecap="round" strokeLinejoin="round" /></svg>;
}
/** 目标和进展：没有内容的就不显示。 */
function Summary({ goal, progress }: { goal?: string; progress?: string }) {
  return <>{goal && <section><h3>目标</h3><p>{goal}</p></section>}{progress && <section><h3>进展</h3><p>{progress}</p></section>}</>;
}
function Facts({ facts, api, loadEvidence, onHistory, onChanged }: { facts: Fact[]; api: DistillationApi; loadEvidence: () => Promise<Evidence[]>; onHistory: (title: string) => void; onChanged: () => void }) {
  const [correcting, setCorrecting] = useState<Fact>();
  return <>{groupFacts(facts).map(group => <section className="fact-group" key={group.kind}><h3><FactIcon kind={group.kind} />{group.label}</h3><ul>{group.facts.map(fact => <li key={fact.id}><p>{fact.text}{group.kind === "inference" && fact.confidence != null && <span className="confidence">把握 {Math.round(fact.confidence * 100)}%</span>}</p>{fact.reason && <p className="fact-reason">{fact.reason}</p>}<div className="fact-tools"><EvidenceList fact={fact} load={loadEvidence} onHistory={onHistory} />{(fact.kind === "decision" || fact.kind === "inference") && <button className="text-button compact" onClick={() => setCorrecting(fact)}>这条不对</button>}</div></li>)}</ul></section>)}{correcting && <CorrectionDialog fact={correcting} api={api} onClose={() => setCorrecting(undefined)} onSaved={() => { setCorrecting(undefined); onChanged(); }} />}</>;
}
export function ThreadContent({ thread, api, onHistory }: { thread: Pick<Thread, "id">; api: DistillationApi; onHistory: (title: string) => void }) {
  const resource = useResource(signal => api.thread(thread.id, "detail", signal), [api, thread.id]);
  if (!resource.data) return <Status error={resource.error} retry={resource.retry} />;
  const data = resource.data;
  return <div className="entity-detail"><Summary goal={data.detail?.goal} progress={data.detail?.progress} />{!data.detail?.goal && !data.detail?.progress && !groupFacts(data.facts).length && <p className="muted">还没有整理出详细内容</p>}<Facts facts={data.facts} api={api} loadEvidence={async () => (await api.thread(thread.id, "evidence")).records ?? []} onHistory={onHistory} onChanged={resource.retry} /></div>;
}
function ThreadRows({ threads, api, onHistory }: { threads: Thread[]; api: DistillationApi; onHistory: (title: string) => void }) {
  const [expanded, setExpanded] = useState<string>();
  return <div className="entity-list">{threads.map(thread => <article className={expanded === thread.id ? "entity expanded" : "entity"} key={thread.id}><button className="entity-row" aria-expanded={expanded === thread.id} aria-controls={`thread-${thread.id}`} onClick={() => setExpanded(expanded === thread.id ? undefined : thread.id)}><span><strong>{thread.title}</strong>{thread.brief && <span className="entity-brief">{thread.brief}</span>}</span><span className="entity-meta"><ActivityTime value={thread.last_ms} /></span></button>{expanded === thread.id && <div id={`thread-${thread.id}`}><ThreadContent thread={thread} api={api} onHistory={onHistory} /></div>}</article>)}</div>;
}
export function ProjectContent({ project, api, onHistory }: { project: Project; api: DistillationApi; onHistory: (title: string) => void }) {
  const resource = useResource(async signal => {
    const [detail, threads] = await Promise.all([api.project(project.id, "detail", signal), api.threads(project.id, signal)]);
    return { detail, threads };
  }, [api, project.id]);
  if (!resource.data) return <Status error={resource.error} retry={resource.retry} />;
  const { detail, threads } = resource.data;
  return <div className="entity-detail"><Summary goal={detail.detail?.goal} progress={detail.detail?.status} />{!!detail.detail?.people?.length && <section><h3>相关的人</h3><p>{detail.detail.people.join("、")}</p></section>}<Facts facts={detail.facts} api={api} loadEvidence={async () => (await api.project(project.id, "evidence")).records ?? []} onHistory={onHistory} onChanged={resource.retry} /><h3>全部事项</h3>{threads.length ? <ThreadRows threads={threads} api={api} onHistory={onHistory} /> : <p className="muted">还没有事项</p>}</div>;
}
function NowView({ projects, api, onHistory }: { projects: Project[]; api: DistillationApi; onHistory: (title: string) => void }) {
  const now = useResource(signal => api.now(signal), [api]);
  const threads = useResource(signal => api.threads(undefined, signal), [api]);
  const paused = useResource(signal => api.pausedSince(Date.now() - recentPausedMs, signal), [api]);
  const [expanded, setExpanded] = useState<string>();
  const groups = new Map<string | null, Thread[]>();
  for (const thread of threads.data ?? []) {
    if (!groups.has(thread.project_id)) groups.set(thread.project_id, []);
    groups.get(thread.project_id)!.push(thread);
  }
  const recent = recentPaused(paused.data ?? []);
  return <div className="distillation-view">
    <section className="now-brief" aria-label="此刻在做什么">{now.data ? now.data.now?.brief ? <p>{now.data.now.brief}</p> : <p className="muted">还没有整理出摘要</p> : <Status error={now.error} retry={now.retry} />}</section>
    <section><h2 className="section-title">进行中</h2>{!threads.data ? <Status error={threads.error} retry={threads.retry} /> : !threads.data.length ? <p className="muted">没有进行中的事项</p> : [...groups].map(([id, rows]) => {
      const project = projects.find(project => project.id === id);
      return <section className="thread-group" key={id ?? "unassigned"}><h3>{project?.name ?? (id ? "未知项目" : "不属于任何项目")}{project && !project.confirmed && <span className="unconfirmed">未确认</span>}</h3><ThreadRows threads={rows} api={api} onHistory={onHistory} /></section>;
    })}</section>
    {(paused.error || recent.length > 0) && <section><h2 className="section-title">最近暂停</h2>{paused.error ? <Status error={paused.error} retry={paused.retry} /> : <ThreadRows threads={recent} api={api} onHistory={onHistory} />}</section>}
    <section><h2 className="section-title">项目</h2>{!projects.length && <p className="muted">还没有项目</p>}<div className="entity-list">{projects.map(project => <article key={project.id} className={expanded === project.id ? "entity expanded" : "entity"}><button className="entity-row" aria-expanded={expanded === project.id} aria-controls={`project-${project.id}`} onClick={() => setExpanded(expanded === project.id ? undefined : project.id)}><span><strong>{project.name}</strong>{!project.confirmed && <span className="unconfirmed">未确认</span>}{project.brief && <span className="entity-brief">{project.brief}</span>}</span><span className="entity-meta"><span>{project.thread_count} 个事项</span><ActivityTime value={project.last_ms} /></span></button>{expanded === project.id && <div id={`project-${project.id}`}><ProjectContent project={project} api={api} onHistory={onHistory} /></div>}</article>)}</div></section>
  </div>;
}
/** 待确认的处理先隐藏卡片，等 UNDO_MS 后（或离开待确认页、关闭网页时）才提交。 */
export const UNDO_MS = 5000;
type Decide = (resolution: Resolution) => void;
export function VoicePendingRow({ item, audio, onDecide, error }: { item: Pending; audio: AudioApi; onDecide: Decide; error?: string }) {
  const [mode, setMode] = useState<"rename" | "merge_into">();
  const [name, setName] = useState("");
  const [target, setTarget] = useState("");
  const speakers = useResource(signal => audio.speakers(signal), [audio]);
  const all = speakers.data?.speakers ?? [];
  const known = knownSpeakers(all, item.payload.speaker_id);
  const unknown = unknownSpeakers(all, item.payload.speaker_id);
  // 填的名字已经有人用了就并过去，免得再出现一条同名的。
  const submit = () => sameNamedSpeaker(all, name) ? onDecide({ action: "merge_into", target: sameNamedSpeaker(all, name)!.id }) : onDecide({ action: "rename", name: name.trim() });
  return <article className="pending-row group"><h3>{pendingTitle(item)}</h3><p className="muted">{item.payload.conversations ?? 0} 段对话，说话共 {speechText(item.payload.seconds ?? 0)}</p>
    <VoiceSamples samples={item.payload.samples ?? []} api={audio} />
    {item.payload.samples_pending && <p className="muted">还有样本在等设备上传</p>}
    <div className="actions"><button className="primary" onClick={() => onDecide({ action: "me" })}>是我</button><button aria-expanded={mode === "rename"} onClick={() => setMode("rename")}>填名字</button><button aria-expanded={mode === "merge_into"} onClick={() => setMode("merge_into")}>是已有的人</button><button onClick={() => onDecide({ action: "ignore" })}>忽略</button></div>
    {mode && <form className="pending-form" onSubmit={event => { event.preventDefault(); if (mode === "rename" ? !name.trim() : !target) return; mode === "rename" ? submit() : onDecide({ action: "merge_into", target }); }}>
      {mode === "rename" ? <label>名字<input autoFocus required value={name} onChange={event => setName(event.target.value)} /></label> : <><label>是谁<select autoFocus required value={target} onChange={event => setTarget(event.target.value)}><option value="">选择</option>{known.map(speaker => <option key={speaker.id} value={speaker.id}>{speaker.name}</option>)}{unknown.length > 0 && <optgroup label="还没确认的声音">{unknown.map(speaker => <option key={speaker.id} value={speaker.id}>{speaker.name}，{speaker.conversations} 段对话</option>)}</optgroup>}</select></label>{!speakers.data && <Status error={speakers.error} retry={speakers.retry} />}</>}
      <div className="actions"><button className="primary" type="submit" disabled={mode === "rename" ? !name.trim() : !target}>确定</button><button type="button" onClick={() => setMode(undefined)}>取消</button></div>
    </form>}{error && <p className="error" role="alert">{error}</p>}
  </article>;
}
function PendingRow({ item, projects, api, onDecide, onHistory, error }: { item: Pending; projects: Project[]; api: DistillationApi; onDecide: Decide; onHistory: (title: string) => void; error?: string }) {
  const [mode, setMode] = useState<"rename" | "merge_into">();
  const [name, setName] = useState(item.payload.name ?? "");
  const [target, setTarget] = useState("");
  const [thread, setThread] = useState(false);
  const threadId = item.kind === "thread_done" ? item.payload.thread_id : undefined;
  return <article className="pending-row group"><h3>{pendingTitle(item)}</h3>{item.kind === "project" ? <ul className="pending-basis">{pendingSummary(item.payload).map((line, index) => <li key={index}>{line}</li>)}</ul> : (item.kind === "merge" ? item.payload.reason : item.payload.brief) && <p>{item.kind === "merge" ? item.payload.reason : item.payload.brief}</p>}
    {threadId && <><button className="text-button compact" aria-expanded={thread} aria-controls={`pending-thread-${item.id}`} onClick={() => setThread(!thread)}>{thread ? "收起" : "查看这件事"}</button>{thread && <div id={`pending-thread-${item.id}`}><ThreadContent thread={{ id: threadId }} api={api} onHistory={onHistory} /></div>}</>}
    {item.kind === "project" && <div className="actions"><button className="primary" onClick={() => onDecide({ action: "confirm" })}>是项目</button><button aria-expanded={mode === "rename"} onClick={() => setMode("rename")}>改名后确认</button><button aria-expanded={mode === "merge_into"} onClick={() => setMode("merge_into")}>并入已有项目</button><button onClick={() => onDecide({ action: "ignore" })}>不是项目</button></div>}
    {item.kind === "merge" && <div className="actions"><button className="primary" onClick={() => onDecide({ action: "merge" })}>合并</button><button onClick={() => onDecide({ action: "keep" })}>保持分开</button></div>}
    {item.kind === "thread_done" && <div className="actions"><button className="primary" onClick={() => onDecide({ action: "done" })}>完成了</button><button onClick={() => onDecide({ action: "continue" })}>还在做</button><button onClick={() => onDecide({ action: "abandon" })}>不做了</button></div>}
    {mode && <form className="pending-form" onSubmit={event => { event.preventDefault(); onDecide(mode === "rename" ? { action: "rename", name: name.trim() } : { action: "merge_into", target }); }}>{mode === "rename" ? <label>项目名<input autoFocus required value={name} onChange={event => setName(event.target.value)} /></label> : <label>并入哪个项目<select autoFocus required value={target} onChange={event => setTarget(event.target.value)}><option value="">选择</option>{projects.filter(project => project.id !== item.payload.project_id).map(project => <option value={project.id} key={project.id}>{project.name}</option>)}</select></label>}<div className="actions"><button className="primary" type="submit" disabled={mode === "rename" ? !name.trim() : !target}>确定</button><button type="button" onClick={() => setMode(undefined)}>取消</button></div></form>}
    {error && <p className="error" role="alert">{error}</p>}
  </article>;
}
const pendingKinds = { voice: "新声音", project: "新项目", thread_done: "做完了吗", merge: "可能是同一件事" } as const;
const pendingNotes: Partial<Record<keyof typeof pendingKinds, string>> = { voice: "听一下样本，标出这是谁。", thread_done: "这些事有一阵子没动静了。" };
type Decision = { item: Pending; resolution: Resolution };
export function DistillationWorkspace({ view, api, audio, onHistory, onCount }: { view: View; api: DistillationApi; audio: AudioApi; onHistory: (title: string) => void; onCount: (count: number) => void }) {
  const [revision, setRevision] = useState(0);
  const projects = useResource(signal => api.projects(signal), [api, revision]);
  // 进入待确认页、切回窗口、提交完一项后都重新读取，导航角标跟着变。
  const [pendingRevision, setPendingRevision] = useState(0);
  const lastRefresh = useRef(0);
  const refresh = useCallback((force = false) => {
    // focus 和 visibilitychange 常常一起触发，一秒内只读一次。
    if (!force && Date.now() - lastRefresh.current < 1000) return;
    lastRefresh.current = Date.now();
    setPendingRevision(value => value + 1);
  }, []);
  const pending = useResource(signal => api.pending(signal), [api, pendingRevision], true);
  const [resolved, setResolved] = useState<string[]>([]);
  const [submitting, setSubmitting] = useState<string[]>([]);
  const [failures, setFailures] = useState<Record<string, string>>({});
  const [queued, setQueued] = useState<UndoEntry<Decision>[]>([]);
  const apiRef = useRef(api);
  apiRef.current = api;
  const queue = useRef<UndoQueue<Decision>>(null);
  queue.current ??= createUndoQueue<Decision>({
    delay: UNDO_MS,
    onChange: setQueued,
    commit: (id, { item, resolution }, flushing) => {
      setSubmitting(values => [...values, id]);
      apiRef.current.resolve(id, resolution, flushing).then(() => {
        setResolved(values => [...values, id]);
        if (item.kind !== "voice") setRevision(value => value + 1);
        refresh(true);
      }).catch(error => setFailures(values => ({ ...values, [id]: message(error) })))
        .finally(() => setSubmitting(values => values.filter(value => value !== id)));
    },
  });
  const first = useRef(true);
  useEffect(() => {
    if (view === "pending") { if (!first.current) refresh(true); }
    else queue.current!.flush();
    first.current = false;
  }, [view, refresh]);
  useEffect(() => {
    const visible = () => { if (!document.hidden) refresh(); };
    const leave = () => queue.current!.flush();
    document.addEventListener("visibilitychange", visible);
    window.addEventListener("focus", visible);
    window.addEventListener("pagehide", leave);
    return () => { document.removeEventListener("visibilitychange", visible); window.removeEventListener("focus", visible); window.removeEventListener("pagehide", leave); leave(); };
  }, [refresh]);
  const hidden = new Set([...resolved, ...submitting, ...queued.map(entry => entry.id)]);
  const items = (pending.data?.pending ?? []).filter(item => !hidden.has(item.id));
  useEffect(() => { onCount(items.length); }, [items.length, onCount]);
  function decide(item: Pending, resolution: Resolution) {
    setFailures(({ [item.id]: _, ...rest }) => rest);
    queue.current!.add(item.id, { item, resolution });
  }
  if (view === "history") return null;
  if (view === "now" && !projects.data) return <Status error={projects.error} retry={projects.retry} />;
  if (view === "now") return <NowView key={revision} projects={projects.data!.projects} api={api} onHistory={onHistory} />;
  return <div className="distillation-view">{!pending.data ? <Status error={pending.error} retry={pending.retry} /> : !items.length ? <p className="empty"><strong>都处理完了</strong>系统拿不准的事会放在这里问你。</p> : (["voice", "project", "thread_done", "merge"] as const).map(kind => {
    const rows = items.filter(item => item.kind === kind);
    return rows.length > 0 && <section key={kind}><h2 className="section-title">{pendingKinds[kind]}</h2>{pendingNotes[kind] && <p className="section-note">{pendingNotes[kind]}</p>}{kind !== "voice" && !projects.data ? <Status error={projects.error} retry={projects.retry} /> : rows.map(item => kind === "voice" ? <VoicePendingRow key={item.id} item={item} audio={audio} error={failures[item.id]} onDecide={resolution => decide(item, resolution)} /> : <PendingRow key={item.id} item={item} projects={projects.data!.projects} api={api} onHistory={onHistory} error={failures[item.id]} onDecide={resolution => decide(item, resolution)} />)}</section>;
  })}
    {queued.length > 0 && <div className="toasts">{queued.map(entry => <div className="toast" role="status" key={entry.id}><span>已处理“{pendingTitle(entry.value.item)}”</span><button className="text-button compact" onClick={() => queue.current!.undo(entry.id)}>撤销</button></div>)}</div>}
  </div>;
}
