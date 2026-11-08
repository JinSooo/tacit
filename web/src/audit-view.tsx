import React, { useEffect, useRef, useState } from "react";
import { auditPath, auditResults, auditSummary, auditTargets, type AuditPage, type AuditRead, type AuditTarget, type AuditTargetCache } from "./audit.ts";
import type { Api, DistillationApi } from "./distillation.ts";
import { ProjectContent, ThreadContent } from "./distillation-views.tsx";
const message = (error: unknown) => error instanceof Error ? error.message : "请求失败，请重试";
type Selection = { id: string; kind: "thread" | "project"; rowId?: string };
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
    <article className="entity expanded"><div className="entity-row"><h2>{target?.title}</h2><button onClick={() => setSelection(undefined)}>收起</button></div>
      {detailError ? <p className="error" role="alert">{detailError}</p> : !target ? <p role="status">正在读取…</p> : target.kind === "thread" ? <ThreadContent thread={target.item} api={distillation} onHistory={onHistory} /> : target.kind === "project" ? <ProjectContent project={target.item} api={distillation} onHistory={onHistory} /> : null}
    </article>
  </div>;
  return <section className="distillation-view" aria-label="读取记录">
    <div className="toolbar"><select aria-label="工具筛选" value={tool} onChange={event => setTool(event.target.value)}><option value="">所有工具</option>{[...new Set(["claude-code", "codex", ...reads.map(row => row.tool)])].map(value => <option key={value} value={value}>{value}</option>)}</select></div>
    {selection && !expandedRow && detail}
    <div className="audit-table-wrap" role="region" aria-label="读取审计列表" tabIndex={0}><table className="audit-table"><thead><tr>{["时间", "工具", "接口", "参数", "大小", "结果"].map(title => <th key={title} scope="col">{title}</th>)}</tr></thead><tbody>{reads.map(row => {
      const results = auditResults(row.result_ids, targets);
      return <React.Fragment key={row.id}><tr><td><time dateTime={row.at}>{new Date(row.at).toLocaleString("zh-CN", { hour12: false })}</time></td><td>{row.tool}</td><td>{row.kind}</td><td><div>{auditSummary(row.args)}</div><div className="audit-ids">{results.items.map(({ id, target }) => target.kind === "record" ? <button className="text-button compact" key={id} onClick={() => onHistory(target.title)}>{target.title}</button> : <a key={id} href={`?${target.kind}=${encodeURIComponent(id)}`} title={id} aria-expanded={selection?.id === id && selection.kind === target.kind && expandedRow === row.id} aria-controls={`audit-row-${row.id}`} onClick={event => { if (event.metaKey || event.ctrlKey || event.shiftKey || event.altKey) return; event.preventDefault(); toggle(id, target.kind, row.id); }}>{target.title}{target.kind === "project" && !target.item.confirmed && <span className="muted unconfirmed">未确认</span>}</a>)}{results.unresolved > 0 && <span className="muted">另 {results.unresolved} 项</span>}</div></td><td>{row.bytes.toLocaleString()} B</td><td className={row.ok ? "" : "error"}>{row.ok ? "成功" : "失败"}</td></tr>{selection && expandedRow === row.id && <tr><td colSpan={6}>{detail}</td></tr>}</React.Fragment>;
    })}</tbody></table></div>
    {!reads.length && !busy && !error && <p className="empty">没有读取记录</p>}
    <div className="list-status">{busy ? <span role="status">正在读取…</span> : error ? <><span className="error" role="alert">{error}</span><button onClick={() => void load(cursor, controller.current!.signal)}>重试</button></> : cursor && <button onClick={() => void load(cursor, controller.current!.signal)}>加载更多</button>}</div>
  </section>;
}
