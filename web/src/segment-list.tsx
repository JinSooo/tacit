// 历史记录的活动段列表：每段一行（线程名或应用名、摘要、涉及的应用和时长），点开再列原始记录。
import { useEffect, useMemo, useState, type ReactNode } from "react";
import type { Api } from "./distillation.ts";
import { dateTitle, duration, durationText, sourceNames, timeRange, type HistoryRow } from "./history.ts";
import { appName, dayRecords, daySegments, foldSegments, segmentTitle, spanText, type Segment } from "./segments.ts";

const message = (error: unknown) => error instanceof Error ? error.message : "读取失败";

/** 没提炼的段没有摘要，用记录标题里窗口那一截说明在看什么；"无标题"和与应用名相同的不显示。 */
function windows(segment: Segment, rows: HistoryRow[] | undefined): string {
  if (!rows) return "";
  const seen = new Set(["无标题", "（无标题）", segmentTitle(segment)]), out: string[] = [];
  for (const r of rows) {
    const i = r.title.indexOf(" · ");
    if (i > 0) seen.add(r.title.slice(0, i).trim());
    const t = (i > 0 ? r.title.slice(i + 3) : r.title).trim();
    if (!t || seen.has(t)) continue;
    seen.add(t); out.push(t);
    if (out.length === 3) break;
  }
  return out.join("、");
}

/** collapse 每变一次（历史记录里按 Esc）就收起所有展开的段和记录。 */
export function SegmentList({ api, day, device, focus, revision, collapse, renderDetail, onEarlier }: {
  api: Api; day: string; device: string; focus: string | null; revision: number; collapse: number;
  renderDetail: (id: string, onDelete: (ids: string[]) => void) => ReactNode; onEarlier: () => void;
}) {
  const [segments, setSegments] = useState<Segment[] | null>(null);
  const [error, setError] = useState("");
  const [open, setOpen] = useState<Set<string>>(new Set());
  const [byId, setById] = useState<Map<string, HistoryRow> | null>(null);
  const [selected, setSelected] = useState<string | null>(null);
  const [retry, setRetry] = useState(0);

  useEffect(() => {
    const controller = new AbortController();
    setSegments(null); setById(null); setError(""); setOpen(new Set()); setSelected(null);
    Promise.all([daySegments(api, day, device, controller.signal), dayRecords(api, day, device, controller.signal)])
      .then(([list, records]) => { if (!controller.signal.aborted) { setSegments(list); setById(records); } })
      .catch(e => { if (!controller.signal.aborted) setError(message(e)); });
    return () => controller.abort();
  }, [api, day, device, revision, retry]);

  useEffect(() => {
    if (!collapse) return;
    setOpen(new Set()); setSelected(null);
  }, [collapse]);

  const items = useMemo(() => foldSegments(segments ?? []), [segments]);

  function toggle(id: string) {
    setOpen(previous => { const next = new Set(previous); if (next.has(id)) next.delete(id); else next.add(id); return next; });
  }
  const rowsOf = (segment: Segment) => byId ? segment.record_ids.flatMap(id => byId.get(id) ?? []).reverse() : undefined;

  // 从条带图点到某条记录：展开它所在的段（以及折叠组），选中并滚过去。
  useEffect(() => {
    if (!focus || !segments) return;
    const segment = segments.find(s => s.record_ids.includes(focus));
    if (!segment) return;
    const group = items.find(i => i.kind === "minor" && i.segments.some(s => s.id === segment.id));
    setOpen(previous => new Set([...previous, segment.id, ...(group ? [group.id] : [])]));
    setSelected(focus);
    requestAnimationFrame(() => requestAnimationFrame(() => document.getElementById(`row-${focus}`)?.scrollIntoView({ block: "center", behavior: "smooth" })));
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [focus, segments]);

  function removeRecords(ids: string[]) {
    setById(previous => { if (!previous) return previous; const next = new Map(previous); for (const id of ids) next.delete(id); return next; });
    setSelected(null);
  }

  function segmentRow(segment: Segment) {
    const expanded = open.has(segment.id), list = rowsOf(segment);
    const sub = segment.thread?.brief || (!segment.thread ? windows(segment, list) : "");
    const showApps = Boolean(segment.thread) || segment.apps.length > 1;
    const count = segment.record_ids.length;
    // 应用名后面跟它在这段里的活跃时长（重叠只算一次），不到 1 分钟的不写时长；同名的只列一次。
    const named = [...new Map(segment.apps.map(a => [appName(a), a] as const)).entries()];
    const apps = named.slice(0, 4).map(([name, a]) => a.seconds >= 60 ? `${name} ${durationText(a.seconds)}` : name).join("、") + (named.length > 4 ? ` 等 ${named.length} 个应用` : "");
    return <article key={segment.id} id={`segment-${segment.id}`} className={expanded ? "segment expanded" : "segment"}>
      <button className={segment.thread ? "segment-row thread" : "segment-row"} aria-expanded={expanded} onClick={() => toggle(segment.id)}>
        <span className="record-time">{spanText(segment.start_ms, segment.end_ms)}</span>
        <span className="segment-main">
          <span className="segment-title">{segmentTitle(segment)}{segment.thread?.project_name && <span className="segment-tag">{segment.thread.project_name}</span>}{segment.private > 0 && <span className="segment-tag" title={`${segment.private} 条私密记录`}>私密</span>}</span>
          {sub && <span className={segment.thread ? "segment-brief" : "segment-windows"}>{sub}</span>}
          {showApps && <span className="segment-apps">{apps}</span>}
        </span>
        <span className="record-meta">{durationText(segment.active_seconds) && <span title="这段时间里实际活跃的时长">{durationText(segment.active_seconds)}</span>}<span>{count} 条记录</span></span>
      </button>
      {expanded && <div className="segment-records">{!list ? <p className="muted segment-loading">正在读取…</p> : list.map(record => <div key={record.id} id={`row-${record.id}`} className={selected === record.id ? "record expanded" : "record"}>
        <button className="record-row" aria-expanded={selected === record.id} onClick={() => setSelected(selected === record.id ? null : record.id)}>
          <span className="record-time">{timeRange(record)}</span><span className="record-title">{record.title}</span><span className="record-meta">{sourceNames[record.source] ?? record.source}{duration(record) && <span>{duration(record)}</span>}</span>
        </button>
        {selected === record.id && renderDetail(record.id, removeRecords)}
      </div>)}</div>}
    </article>;
  }

  if (error) return <div className="list-status" role="alert"><span className="error">{error}</span><button onClick={() => setRetry(v => v + 1)}>重试</button></div>;
  if (!segments) return <div className="list-status" role="status">正在读取…</div>;
  return <section aria-label={dateTitle(day)}>
    {!segments.length && <p className="empty"><strong>这一天没有记录</strong></p>}
    <div className="day-records segments">{items.map(item => item.kind === "single" ? segmentRow(item.segment) : <div key={item.id} className="segment-group">
      <button className="segment-row minor" aria-expanded={open.has(item.id)} onClick={() => toggle(item.id)}>
        <span className="record-time">{spanText(item.segments.at(-1)!.start_ms, item.segments[0]!.end_ms)}</span>
        <span className="segment-windows">{[...new Set(item.segments.flatMap(s => s.apps.map(appName)))].slice(0, 4).join("、")}</span>
        <span className="record-meta">{item.segments.length} 段零碎活动</span>
      </button>
      {open.has(item.id) && item.segments.map(segmentRow)}
    </div>)}</div>
    <div className="list-status"><button className="text-button" onClick={onEarlier}>查看前一天</button></div>
  </section>;
}
