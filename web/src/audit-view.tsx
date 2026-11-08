import React, { useEffect, useRef, useState } from "react";
import { auditPath, auditSummary, auditTargets, type AuditPage, type AuditRead } from "./audit.ts";
import type { Api, DistillationApi, Project, Thread } from "./distillation.ts";
import { ProjectContent, ThreadContent } from "./distillation-views.tsx";
const message = (error: unknown) => error instanceof Error ? error.message : "请求失败，请重试";
export function AuditView({ api, distillation, onHistory }: { api: Api; distillation: DistillationApi; onHistory: (title: string) => void }) {
  const [tool, setTool] = useState("");
  const [reads, setReads] = useState<AuditRead[]>([]);
  const [cursor, setCursor] = useState<string | null>(null);
  const [busy, setBusy] = useState(true);
  const [error, setError] = useState("");
  const [targets, setTargets] = useState(new Map<string, "thread" | "project">());
  const [target, setTarget] = useState<{ kind: "thread"; item: Thread } | { kind: "project"; item: Project }>();
  const [detailError, setDetailError] = useState("");
  const [detailBusy, setDetailBusy] = useState(false);
  const controller = useRef<AbortController>(null);
  const loading = useRef(false);
  const detailController = useRef<AbortController>(null);
  async function load(next: string | null, signal: AbortSignal) {
    if (loading.current) return;
    loading.current = true; setBusy(true); setError("");
    try {
      const page = await api<AuditPage>(auditPath(tool, next), { signal });
      if (signal.aborted) return;
      setReads(previous => next ? [...new Map([...previous, ...page.reads].map(row => [row.id, row])).values()] : page.reads);
      setCursor(page.next_cursor);
      const links = await auditTargets(api, [...new Set(page.reads.flatMap(row => row.result_ids))], signal);
      if (!signal.aborted) setTargets(previous => new Map([...previous, ...links]));
    } catch (error) { if (!signal.aborted) setError(message(error)); }
    finally { if (!signal.aborted) { loading.current = false; setBusy(false); } }
  }
  useEffect(() => {
    const next = new AbortController(); controller.current = next; loading.current = false;
    setReads([]); setCursor(null); setTargets(new Map()); setTarget(undefined); setDetailError("");
    detailController.current?.abort(); setDetailBusy(false);
    void load(null, next.signal);
    return () => { next.abort(); detailController.current?.abort(); };
  }, [api, tool]);
  async function open(id: string, kind: "thread" | "project") {
    detailController.current?.abort(); const next = new AbortController(); detailController.current = next;
    setDetailError(""); setDetailBusy(true); setTarget(undefined);
    try {
      const item = await api<Thread & Project>(`/v1/${kind}s/${encodeURIComponent(id)}?level=brief`, { signal: next.signal });
      if (!next.signal.aborted) setTarget({ kind, item });
    } catch (error) { if (!next.signal.aborted) setDetailError(message(error)); }
    finally { if (!next.signal.aborted) setDetailBusy(false); }
  }
  useEffect(() => {
    const query = new URLSearchParams(location.search);
    const kind = query.has("thread") ? "thread" : "project";
    const id = query.get(kind);
    if (id) void open(id, kind);
  }, [api]);
  useEffect(() => { if (target) document.getElementById("audit-detail")?.scrollIntoView({ block: "nearest" }); }, [target]);
  return <section className="distillation-view" aria-label="读取记录">
    <div className="toolbar"><select aria-label="工具筛选" value={tool} onChange={event => setTool(event.target.value)}><option value="">所有工具</option>{[...new Set(["claude-code", "codex", ...reads.map(row => row.tool)])].map(value => <option key={value} value={value}>{value}</option>)}</select></div>
    <div className="audit-table-wrap" role="region" aria-label="读取审计列表" tabIndex={0}><table className="audit-table"><thead><tr>{["时间", "工具", "接口", "参数", "返回条数", "大小", "结果"].map(title => <th key={title} scope="col">{title}</th>)}</tr></thead><tbody>{reads.map(row => <tr key={row.id}><td><time dateTime={row.at}>{new Date(row.at).toLocaleString("zh-CN", { hour12: false })}</time></td><td>{row.tool}</td><td>{row.kind}</td><td><div>{auditSummary(row.args)}</div><div className="audit-ids">{row.result_ids.map(id => <React.Fragment key={id}>{targets.has(id) ? <a href={`?${targets.get(id)}=${encodeURIComponent(id)}#audit-detail`} onClick={event => { if (event.metaKey || event.ctrlKey || event.shiftKey || event.altKey) return; event.preventDefault(); void open(id, targets.get(id)!); }}>{id}</a> : <span>{id}</span>}</React.Fragment>)}</div></td><td>{row.result_ids.length}</td><td>{row.bytes.toLocaleString()} B</td><td className={row.ok ? "" : "error"}>{row.ok ? "成功" : "失败"}</td></tr>)}</tbody></table></div>
    {!reads.length && !busy && !error && <p className="empty">没有读取记录</p>}
    <div className="list-status">{busy ? <span role="status">正在读取…</span> : error ? <><span className="error" role="alert">{error}</span><button onClick={() => void load(cursor, controller.current!.signal)}>重试</button></> : cursor && <button onClick={() => void load(cursor, controller.current!.signal)}>加载更多</button>}</div>
    <div id="audit-detail">{detailBusy && <p role="status">正在读取…</p>}{detailError && <p className="error" role="alert">{detailError}</p>}{target && <article className="entity expanded"><div className="entity-row"><h2>{target.kind === "thread" ? target.item.title : target.item.name}</h2><button onClick={() => setTarget(undefined)}>收起</button></div>{target.kind === "thread" ? <ThreadContent thread={target.item} api={distillation} onHistory={onHistory} /> : <ProjectContent project={target.item} api={distillation} onHistory={onHistory} />}</article>}</div>
  </section>;
}
