import React, { useEffect, useRef, useState } from "react";
import { groupFacts, pendingSummary, relativeTime, type DistillationApi, type Evidence, type Fact, type Pending, type Project, type Resolution, type Thread } from "./distillation.ts";

export type View = "history" | "now" | "pending";
const message = (error: unknown) => error instanceof Error ? error.message : "请求失败，请重试";
function useResource<T>(load: (signal: AbortSignal) => Promise<T>, deps: React.DependencyList) {
  const [data, setData] = useState<T>();
  const [error, setError] = useState("");
  const [revision, setRevision] = useState(0);
  useEffect(() => {
    const controller = new AbortController();
    setData(undefined); setError("");
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
  return <div className="fact-evidence"><button className="text-button compact" aria-expanded={open} onClick={() => setOpen(!open)}>证据</button>{open && <div>
    {error ? <div role="alert" className="error">{error} <button onClick={() => setRevision(value => value + 1)}>重试</button></div> : !records ? <span role="status">正在读取…</span> : <>
      {records.filter(record => fact.evidence.includes(record.id)).map(record => <button className="evidence-link text-button" key={record.id} onClick={() => onHistory(record.title)}><span>{record.title}</span><time dateTime={record.t_start}>{new Date(record.t_start).toLocaleString("zh-CN")}</time></button>)}
      {!records.some(record => fact.evidence.includes(record.id)) && <p className="muted">暂无可用证据</p>}
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
  }}><h2 id="fact-correction-title">修正这条内容</h2><p>{fact.text}</p><label>正确的内容<textarea required autoFocus rows={5} value={text} onChange={event => setText(event.target.value)} /></label>{error && <p className="error" role="alert">{error}</p>}<div className="actions"><button disabled={busy || !text.trim()} type="submit">{busy ? "提交中…" : "提交修正"}</button><button disabled={busy} type="button" onClick={onClose}>取消</button></div></form></dialog>;
}
function Facts({ facts, api, loadEvidence, onHistory, onChanged }: { facts: Fact[]; api: DistillationApi; loadEvidence: () => Promise<Evidence[]>; onHistory: (title: string) => void; onChanged: () => void }) {
  const [correcting, setCorrecting] = useState<Fact>();
  return <>{groupFacts(facts).map(group => <section className="fact-group" key={group.kind}><h3>{group.label}</h3><ul>{group.facts.map(fact => <li key={fact.id}><p>{fact.text}{group.kind === "inference" && <span className="confidence">置信度 {fact.confidence == null ? "未知" : `${Math.round(fact.confidence * 100)}%`}</span>}</p>{fact.reason && <p className="muted">{fact.reason}</p>}<div className="fact-tools"><EvidenceList fact={fact} load={loadEvidence} onHistory={onHistory} />{(fact.kind === "decision" || fact.kind === "inference") && <button className="text-button compact" onClick={() => setCorrecting(fact)}>这条不对</button>}</div></li>)}</ul></section>)}{correcting && <CorrectionDialog fact={correcting} api={api} onClose={() => setCorrecting(undefined)} onSaved={() => { setCorrecting(undefined); onChanged(); }} />}</>;
}
export function ThreadContent({ thread, api, onHistory }: { thread: Thread; api: DistillationApi; onHistory: (title: string) => void }) {
  const resource = useResource(signal => api.thread(thread.id, "detail", signal), [api, thread.id]);
  if (!resource.data) return <Status error={resource.error} retry={resource.retry} />;
  const data = resource.data;
  return <div className="entity-detail"><section><h3>目标</h3><p>{data.detail?.goal || "暂无目标"}</p></section><section><h3>进展</h3><p>{data.detail?.progress || "暂无进展"}</p></section><Facts facts={data.facts} api={api} loadEvidence={async () => (await api.thread(thread.id, "evidence")).records ?? []} onHistory={onHistory} onChanged={resource.retry} /></div>;
}
function ThreadRows({ threads, api, onHistory }: { threads: Thread[]; api: DistillationApi; onHistory: (title: string) => void }) {
  const [expanded, setExpanded] = useState<string>();
  return <div className="entity-list">{threads.map(thread => <article className={expanded === thread.id ? "entity expanded" : "entity"} key={thread.id}><button className="entity-row" aria-expanded={expanded === thread.id} aria-controls={`thread-${thread.id}`} onClick={() => setExpanded(expanded === thread.id ? undefined : thread.id)}><span><strong>{thread.title}</strong>{thread.brief && <span className="entity-brief">{thread.brief}</span>}</span><ActivityTime value={thread.last_ms} /></button>{expanded === thread.id && <div id={`thread-${thread.id}`}><ThreadContent thread={thread} api={api} onHistory={onHistory} /></div>}</article>)}</div>;
}
export function ProjectContent({ project, api, onHistory }: { project: Project; api: DistillationApi; onHistory: (title: string) => void }) {
  const resource = useResource(async signal => {
    const [detail, threads] = await Promise.all([api.project(project.id, "detail", signal), api.threads(project.id, signal)]);
    return { detail, threads };
  }, [api, project.id]);
  if (!resource.data) return <Status error={resource.error} retry={resource.retry} />;
  const { detail, threads } = resource.data;
  return <div className="entity-detail"><section><h3>目标</h3><p>{detail.detail?.goal || "暂无目标"}</p></section><section><h3>进展</h3><p>{detail.detail?.status || "暂无进展"}</p></section>{!!detail.detail?.people?.length && <p>{detail.detail.people.join("、")}</p>}<Facts facts={detail.facts} api={api} loadEvidence={async () => (await api.project(project.id, "evidence")).records ?? []} onHistory={onHistory} onChanged={resource.retry} /><h3>线程</h3>{threads.length ? <ThreadRows threads={threads} api={api} onHistory={onHistory} /> : <p className="muted">暂无线程</p>}</div>;
}
function NowView({ projects, api, onHistory }: { projects: Project[]; api: DistillationApi; onHistory: (title: string) => void }) {
  const now = useResource(signal => api.now(signal), [api]);
  const threads = useResource(signal => api.threads(undefined, signal), [api]);
  const [expanded, setExpanded] = useState<string>();
  const groups = new Map<string | null, Thread[]>();
  for (const thread of threads.data ?? []) {
    if (!groups.has(thread.project_id)) groups.set(thread.project_id, []);
    groups.get(thread.project_id)!.push(thread);
  }
  return <div className="distillation-view">
    <section className="now-brief" aria-label="当前摘要">{now.data ? <p>{now.data.now?.brief || "暂无当前摘要"}</p> : <Status error={now.error} retry={now.retry} />}</section>
    <section><h2 className="day-heading">活跃线程</h2>{!threads.data ? <Status error={threads.error} retry={threads.retry} /> : !threads.data.length ? <p className="empty">暂无活跃线程</p> : [...groups].map(([id, rows]) => {
      const project = projects.find(project => project.id === id);
      return <section className="thread-group" key={id ?? "unassigned"}><h3>{project?.name ?? (id ? "未知项目" : "未归属项目")}{project && !project.confirmed && <span className="muted unconfirmed">未确认</span>}</h3><ThreadRows threads={rows} api={api} onHistory={onHistory} /></section>;
    })}</section>
    <section><h2 className="day-heading">项目</h2>{!projects.length && <p className="empty">暂无项目</p>}<div className="entity-list">{projects.map(project => <article key={project.id} className={expanded === project.id ? "entity expanded" : "entity"}><button className="entity-row project-row" aria-expanded={expanded === project.id} aria-controls={`project-${project.id}`} onClick={() => setExpanded(expanded === project.id ? undefined : project.id)}><span><strong>{project.name}</strong>{!project.confirmed && <span className="muted unconfirmed">未确认</span>}{project.brief && <span className="entity-brief">{project.brief}</span>}</span><span className="muted">{project.thread_count} 个线程</span><ActivityTime value={project.last_ms} /></button>{expanded === project.id && <div id={`project-${project.id}`}><ProjectContent project={project} api={api} onHistory={onHistory} /></div>}</article>)}</div></section>
  </div>;
}
function PendingRow({ item, projects, api, onResolved }: { item: Pending; projects: Project[]; api: DistillationApi; onResolved: (id: string) => void }) {
  const [mode, setMode] = useState<"rename" | "merge_into">();
  const [name, setName] = useState(item.payload.name ?? "");
  const [target, setTarget] = useState("");
  const [error, setError] = useState("");
  const [busy, setBusy] = useState(false);
  async function resolve(resolution: Resolution) {
    setBusy(true); setError("");
    try { await api.resolve(item.id, resolution); onResolved(item.id); } catch (error) { setError(message(error)); } finally { setBusy(false); }
  }
  return <article className="pending-row"><h3>{item.kind === "project" ? item.payload.name : item.kind === "merge" ? `${item.payload.a_name} 和 ${item.payload.b_name}` : item.payload.title}</h3>{item.kind === "project" ? <ul className="pending-basis muted">{pendingSummary(item.payload).map((line, index) => <li key={index}>{line}</li>)}</ul> : <p>{item.kind === "merge" ? item.payload.reason : item.payload.brief}</p>}
    {item.kind === "project" && <div className="actions"><button disabled={busy} onClick={() => void resolve({ action: "confirm" })}>确认</button><button disabled={busy} onClick={() => setMode("rename")}>改名</button><button disabled={busy} onClick={() => setMode("merge_into")}>并入</button><button disabled={busy} onClick={() => void resolve({ action: "ignore" })}>不是项目</button></div>}
    {item.kind === "merge" && <div className="actions"><button disabled={busy} onClick={() => void resolve({ action: "merge" })}>合并</button><button disabled={busy} onClick={() => void resolve({ action: "keep" })}>保持分开</button></div>}
    {item.kind === "thread_done" && <div className="actions"><button disabled={busy} onClick={() => void resolve({ action: "done" })}>完成</button><button disabled={busy} onClick={() => void resolve({ action: "continue" })}>继续</button><button disabled={busy} onClick={() => void resolve({ action: "abandon" })}>放弃</button></div>}
    {mode && <form className="pending-form" onSubmit={event => { event.preventDefault(); void resolve(mode === "rename" ? { action: "rename", name: name.trim() } : { action: "merge_into", target }); }}>{mode === "rename" ? <label>项目名<input autoFocus required value={name} onChange={event => setName(event.target.value)} /></label> : <label>并入项目<select autoFocus required value={target} onChange={event => setTarget(event.target.value)}><option value="">选择已有项目</option>{projects.filter(project => project.id !== item.payload.project_id).map(project => <option value={project.id} key={project.id}>{project.name}</option>)}</select></label>}<div className="actions"><button type="submit" disabled={busy || (mode === "rename" ? !name.trim() : !target)}>提交</button><button type="button" disabled={busy} onClick={() => setMode(undefined)}>取消</button></div></form>}
    {error && <p className="error" role="alert">{error}</p>}
  </article>;
}
export function DistillationWorkspace({ view, api, onHistory, onCount }: { view: View; api: DistillationApi; onHistory: (title: string) => void; onCount: (count: number) => void }) {
  const [revision, setRevision] = useState(0);
  const projects = useResource(signal => api.projects(signal), [api, revision]);
  const pending = useResource(signal => api.pending(signal), [api]);
  const [resolved, setResolved] = useState<string[]>([]);
  const items = (pending.data?.pending ?? []).filter(item => !resolved.includes(item.id));
  useEffect(() => { onCount(items.length); }, [pending.data, resolved, onCount]);
  if (view === "history") return null;
  if (!projects.data) return <Status error={projects.error} retry={projects.retry} />;
  if (view === "now") return <NowView key={revision} projects={projects.data.projects} api={api} onHistory={onHistory} />;
  return <div className="distillation-view">{!pending.data ? <Status error={pending.error} retry={pending.retry} /> : !items.length ? <p className="empty">没有待确认项</p> : (["project", "thread_done", "merge"] as const).map(kind => {
    const rows = items.filter(item => item.kind === kind);
    return rows.length > 0 && <section key={kind}><h2 className="day-heading">{{ project: "项目", thread_done: "线程完成", merge: "合并" }[kind]}</h2>{rows.map(item => <PendingRow key={item.id} item={item} projects={projects.data!.projects} api={api} onResolved={id => { setResolved(values => [...values, id]); setRevision(value => value + 1); }} />)}</section>;
  })}</div>;
}
