import React, { useEffect, useRef, useState } from "react";
import { auditAction, auditPath, auditResults, auditSummary, auditTargets, auditVisible, toolNames, type AuditPage, type AuditRead, type AuditTarget, type AuditTargetCache } from "./audit.ts";
import type { Api, DistillationApi } from "./distillation.ts";
import { ProjectContent, ThreadContent } from "./distillation-views.tsx";
const message = (error: unknown) => error instanceof Error ? error.message : "请求失败，请重试";
type Selection = { id: string; kind: "thread" | "project"; rowId?: string };
const pad = (n: number) => String(n).padStart(2, "0");
/** 今天只写时刻，今年写月日，更早的带年份；完整时间放在悬停提示里。 */
function auditTime(at: string, now = new Date()) {
  const d = new Date(at), clock = `${pad(d.getHours())}:${pad(d.getMinutes())}`;
  if (d.toDateString() === now.toDateString()) return `今天 ${clock}`;
  return `${d.getFullYear() !== now.getFullYear() ? `${d.getFullYear()}年` : ""}${d.getMonth() + 1}月${d.getDate()}日 ${clock}`;
}
export function AuditView({ api, distillation, onHistory }: { api: Api; distillation: DistillationApi; onHistory: (title: string) => void }) {
  const [tool, setTool] = useState("");
  const [reads, setReads] = useState<AuditRead[]>([]);
  const [cursor, setCursor] = useState<string | null>(null);
  const [busy, setBusy] = useState(true);
  const [error, setError] = useState("");
  const [targets, setTargets] = useState(new Map<string, AuditTarget | null>());
  const [selection, setSelection] = useState<Selection>();
  const [target, setTarget] = useState<AuditTarget>();
  const [detailError, setDetailError] = useState("");
  // 结果多的行默认只列前 3 个，点"还有 N 项"展开。
  const [more, setMore] = useState(new Set<string>());
  const toggleMore = (id: string) => setMore(previous => { const next = new Set(previous); if (next.has(id)) next.delete(id); else next.add(id); return next; });
  const controller = useRef<AbortController>(null);
  const cache = useRef<AuditTargetCache>(new Map());
  const loading = useRef(false);
  async function load(next: string | null, signal: AbortSignal) {
    if (loading.current) return;
    loading.current = true; setBusy(true); setError("");
    try {
      const page = await api<AuditPage>(auditPath(tool, next), { signal });
      if (signal.aborted) return;
      setReads(previous => next ? [...new Map([...previous, ...page.reads].map(row => [row.id, row])).values()] : page.reads);
      const links = await auditTargets(api, page.reads.flatMap(row => row.result_ids), signal, cache.current);
      if (!signal.aborted) { setTargets(previous => new Map([...previous, ...links])); setCursor(page.next_cursor); }
    } catch (error) { if (!signal.aborted) setError(message(error)); }
    finally { if (!signal.aborted) { loading.current = false; setBusy(false); } }
  }
  useEffect(() => {
    const next = new AbortController(); controller.current = next; loading.current = false;
    cache.current = new Map();
    setReads([]); setCursor(null); setTargets(new Map()); setTarget(undefined); setDetailError("");
    const query = new URLSearchParams(location.search);
    const kind = query.has("thread") ? "thread" : "project";
    const id = query.get(kind);
    setSelection(id ? { id, kind } : undefined);
    void load(null, next.signal);
    return () => next.abort();
  }, [api, tool]);
  useEffect(() => {
    if (!selection || busy) return;
    let cancelled = false;
    setTarget(undefined); setDetailError("");
    const { id, kind } = selection;
    void auditTargets(api, [id], controller.current!.signal, cache.current).then(values => {
      if (cancelled) return;
      const item = values.get(id);
      if (!item || item.kind !== kind) setDetailError("内容不存在");
      else setTarget(item);
    }).catch(error => { if (!cancelled && !controller.current?.signal.aborted) setDetailError(message(error)); });
    return () => { cancelled = true; };
  }, [selection, busy, api, tool]);
  const expandedRow = selection && (selection.rowId ?? reads.find(row => row.result_ids.includes(selection.id))?.id);
  const detailId = expandedRow ? `audit-row-${expandedRow}` : "audit-above-table";
  function toggle(id: string, kind: "thread" | "project", rowId: string) {
    setTarget(undefined); setDetailError("");
    setSelection(selection?.id === id && selection.kind === kind && expandedRow === rowId ? undefined : { id, kind, rowId });
  }
  const detail = selection && <div id={detailId}>
    <article className={expandedRow ? "entity audit-detail" : "entity audit-detail group"}><div className="entity-row"><h2>{target?.title}</h2><button onClick={() => setSelection(undefined)}>收起</button></div>
      {detailError ? <p className="error" role="alert">{detailError}</p> : !target ? <p className="muted" role="status">正在读取…</p> : target.kind === "thread" ? <ThreadContent thread={target.item} api={distillation} onHistory={onHistory} /> : target.kind === "project" ? <ProjectContent project={target.item} api={distillation} onHistory={onHistory} /> : null}
    </article>
  </div>;
  return <section className="distillation-view" aria-label="读取记录">
    <div className="status-head"><h2 className="section-title">AI 工具读取了什么</h2><select aria-label="AI 工具" value={tool} onChange={event => setTool(event.target.value)}><option value="">所有 AI 工具</option>{[...new Set([...Object.keys(toolNames), ...reads.map(row => row.tool)])].map(value => <option key={value} value={value}>{toolNames[value] ?? value}</option>)}</select></div>
    {selection && !expandedRow && detail}
    {reads.length > 0 && <div className="group table-wrap"><table className="data-table audit-table stack-table"><thead><tr>{["时间", "AI 工具", "做了什么", "内容"].map(title => <th key={title} scope="col">{title}</th>)}</tr></thead><tbody>{reads.map(row => {
      const results = auditResults(row.result_ids, targets);
      const open = more.has(row.id);
      const visible = auditVisible(results.items, results.unresolved, open);
      const summary = auditSummary(row.args, targets);
      return <React.Fragment key={row.id}><tr><td><time dateTime={row.at} title={new Date(row.at).toLocaleString("zh-CN", { hour12: false })}>{auditTime(row.at)}</time></td><td className="end">{toolNames[row.tool] ?? row.tool}</td><td className="full">{auditAction(row.kind, row.args)}{!row.ok && <span className="error">，失败</span>}</td><td className="full">{summary && <div className="audit-summary">{summary}</div>}<div className="audit-ids">{visible.shown.map(({ id, target }) => target.kind === "record" ? <button className="text-button compact" key={id} onClick={() => onHistory(target.search)}>{target.title}</button> : <a key={id} href={`?${target.kind}=${encodeURIComponent(id)}`} aria-expanded={selection?.id === id && selection.kind === target.kind && expandedRow === row.id} aria-controls={`audit-row-${row.id}`} onClick={event => { if (event.metaKey || event.ctrlKey || event.shiftKey || event.altKey) return; event.preventDefault(); toggle(id, target.kind, row.id); }}>{target.title}{target.kind === "project" && !target.item.confirmed && <span className="unconfirmed">未确认</span>}</a>)}{visible.unresolved > 0 && <span className="muted">{visible.unresolved} 项已删除或认不出</span>}{visible.hidden > 0 ? <button className="text-button compact" onClick={() => toggleMore(row.id)}>还有 {visible.hidden} 项</button> : open && <button className="text-button compact" onClick={() => toggleMore(row.id)}>收起</button>}</div></td></tr>{selection && expandedRow === row.id && <tr><td colSpan={4} className="full audit-detail-cell">{detail}</td></tr>}</React.Fragment>;
    })}</tbody></table></div>}
    {!reads.length && !busy && !error && <p className="empty"><strong>AI 工具还没有读取过</strong>AI 工具每次读取你的记录、往历史记录里添加内容，都会记在这里。</p>}
    <div className="list-status">{busy ? <span role="status">正在读取…</span> : error ? <><span className="error" role="alert">{error}</span><button onClick={() => void load(cursor, controller.current!.signal)}>重试</button></> : cursor && <button onClick={() => void load(cursor, controller.current!.signal)}>加载更多</button>}</div>
  </section>;
}
