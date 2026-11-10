import React, { useEffect, useLayoutEffect, useRef, useState } from "react";
import { chapterSpans, dayRange, durationText, laneOf, lanes, sourceNames, timeRange, type HistoryRow } from "./history.ts";

type Api = <T>(path: string, init?: RequestInit) => Promise<T>;
interface Diary { brief?: string; detail?: { summary?: string; timeline?: { start: string; end: string; text: string }[] } }
const message = (error: unknown) => error instanceof Error ? error.message : "请求失败，请重试";
const diaryKey = "record-anything-diary-expanded";
const pad = (n: number) => String(n).padStart(2, "0");
const clock = (ms: number) => { const d = new Date(ms); return `${pad(d.getHours())}:${pad(d.getMinutes())}`; };

/** 重叠的时段只算一次。 */
function activeSeconds(rows: HistoryRow[]) {
  const spans = rows.filter(r => r.t_end).map(r => [Date.parse(r.t_start), Date.parse(r.t_end!)] as const).filter(([a, b]) => b > a).sort((x, y) => x[0] - y[0]);
  let total = 0, cur: [number, number] | null = null;
  for (const [a, b] of spans) {
    if (cur && a <= cur[1]) cur[1] = Math.max(cur[1], b);
    else { if (cur) total += cur[1] - cur[0]; cur = [a, b]; }
  }
  if (cur) total += cur[1] - cur[0];
  return total / 1000;
}
function longDate(key: string) {
  const d = new Date(`${key}T12:00:00`);
  return { date: `${d.getFullYear() !== new Date().getFullYear() ? `${d.getFullYear()} 年 ` : ""}${d.getMonth() + 1} 月 ${d.getDate()} 日`, weekday: `星期${"日一二三四五六"[d.getDay()]}` };
}

/**
 * 历史记录顶部：这一天的日期、统计、日记和条带图。点条带图里的一段，列表从那条记录开始显示。
 * revision 变了（删除、补写、修正之后）就重新读取，读取期间保留旧数据；换日期才清空。
 */
export function DayOverview({ api, day, revision, selected, onPick }: { api: Api; day: string; revision: number; selected: string | null; onPick: (record: HistoryRow) => void }) {
  const [rows, setRows] = useState<HistoryRow[]>();
  const [diary, setDiary] = useState<Diary | null>(null);
  const [error, setError] = useState("");
  const [retry, setRetry] = useState(0);
  const shownDay = useRef(day);
  const [expanded, setExpanded] = useState(() => { try { return localStorage.getItem(diaryKey) === "1"; } catch { return false; } });
  useEffect(() => {
    const controller = new AbortController();
    if (shownDay.current !== day) { shownDay.current = day; setRows(undefined); setDiary(null); }
    setError("");
    const { from, to } = dayRange(day);
    (async () => {
      const all: HistoryRow[] = [];
      let cursor: string | null = null, pages = 0;
      do {
        const params = new URLSearchParams({ from, to, limit: "500" });
        if (cursor) params.set("cursor", cursor);
        const page = await api<{ records: HistoryRow[]; next_cursor: string | null }>(`/v1/records?${params}`, { signal: controller.signal });
        all.push(...page.records); cursor = page.next_cursor; pages++;
      } while (cursor && pages < 20);
      const diary = await api<Diary>(`/v1/days/${day}`, { signal: controller.signal }).catch(error => {
        if (error && typeof error === "object" && "status" in error && error.status === 404) return null;
        throw error;
      });
      if (!controller.signal.aborted) { setRows(all); setDiary(diary); }
    })().catch(error => { if (!controller.signal.aborted) setError(message(error)); });
    return () => controller.abort();
  }, [api, day, revision, retry]);
  function toggleDiary() {
    setExpanded(value => { try { localStorage.setItem(diaryKey, value ? "0" : "1"); } catch { /* 存储不可用时只在本页记住。 */ } return !value; });
  }
  const { date, weekday } = longDate(day);
  const summary = diary?.detail?.summary || diary?.brief;
  const first = rows?.length ? Math.min(...rows.map(r => Date.parse(r.t_start))) : null;
  return <section className="day-overview" aria-label={`${date}概览`}>
    <div className="day-title">
      <h2>{date}<span>{weekday}</span></h2>
      {/* 记录数：这一天开始的记录条数；活跃：有起止时间的记录合起来的时长，重叠只算一次；最早：第一条记录的开始时间。 */}
      {!!rows?.length && <dl className="day-stats"><div><dt>条记录</dt><dd>{rows.length.toLocaleString("zh-CN")}</dd></div>{activeSeconds(rows) >= 1 && <div><dt>活跃时长</dt><dd>{durationText(activeSeconds(rows))}</dd></div>}{first !== null && <div><dt>最早一条</dt><dd>{clock(first)}</dd></div>}</dl>}
    </div>
    {summary && <div className="diary"><p className={expanded ? "" : "clamped"}>{summary}</p><button className="text-button compact" onClick={toggleDiary}>{expanded ? "收起日记" : "展开日记"}</button></div>}
    {error ? <p className="error" role="alert">{error} <button onClick={() => setRetry(v => v + 1)}>重试</button></p>
      : !rows ? <div className="strata-placeholder group" role="status">正在读取…</div>
      : rows.length > 0 && <Strata rows={rows} day={day} chapters={chapterSpans(day, diary?.detail?.timeline)} selected={selected} onPick={onPick} />}
  </section>;
}

const labelWidth = 60, axis = 20, chapterH = 22, laneH = 16, gap = 5;
function Strata({ rows, day, chapters, selected, onPick }: { rows: HistoryRow[]; day: string; chapters: { start: number; end: number; text: string }[]; selected: string | null; onPick: (record: HistoryRow) => void }) {
  const box = useRef<HTMLDivElement>(null);
  const [width, setWidth] = useState(900);
  const [hover, setHover] = useState<{ x: number; text: string; sub: string } | null>(null);
  useLayoutEffect(() => {
    const el = box.current; if (!el) return;
    const observer = new ResizeObserver(([entry]) => setWidth(Math.max(320, entry!.contentRect.width)));
    observer.observe(el);
    return () => observer.disconnect();
  }, []);
  const { start: dayStart, end: dayEnd } = dayRange(day);
  const now = Date.now();
  const isToday = now >= dayStart && now < dayEnd;
  const hour = 3600000;
  const times = [...rows.flatMap(r => [Date.parse(r.t_start), Date.parse(r.t_end ?? r.t_start)]), ...chapters.flatMap(c => [c.start, c.end]), ...(isToday ? [now] : [])];
  let lo = Math.max(dayStart, Math.floor(Math.min(...times) / hour) * hour);
  let hi = Math.min(dayEnd, Math.ceil(Math.max(...times) / hour) * hour);
  if (hi - lo < 4 * hour) { hi = Math.min(dayEnd, lo + 4 * hour); lo = Math.min(lo, hi - 4 * hour); }
  const used = lanes.filter(lane => rows.some(r => laneOf(r.source) === lane.key));
  const plotW = width - labelWidth - 6;
  const x = (t: number) => labelWidth + (t - lo) / (hi - lo) * plotW;
  const lanesTop = axis + 4 + (chapters.length ? chapterH + 8 : 0);
  const height = lanesTop + used.length * (laneH + gap);
  const step = (hi - lo) > 14 * hour ? 3 : (hi - lo) > 7 * hour ? 2 : 1;
  const ticks: number[] = [];
  for (let t = Math.ceil(lo / hour) * hour; t <= hi; t += hour) ticks.push(t);
  const charW = 12.5;
  return <div className="strata group" ref={box} onMouseLeave={() => setHover(null)}>
    <svg width={width} height={height} role="img" aria-label="这一天的活动条带图">
      {ticks.map(t => { const h = new Date(t).getHours(); const major = h % step === 0; return <g key={t}>
        <line x1={x(t)} x2={x(t)} y1={axis} y2={height} className={major ? "tick major" : "tick"} />
        {major && <text x={x(t)} y={12} className="tick-label">{pad(h)}</text>}
      </g>; })}
      {chapters.map((c, i) => {
        const a = x(Math.max(c.start, lo)), b = x(Math.min(c.end, hi)), w = b - a - 1;
        if (w <= 1) return null;
        const fits = Math.floor((w - 12) / charW);
        const label = fits >= 2 ? (c.text.length > fits ? `${c.text.slice(0, fits - 1)}…` : c.text) : "";
        return <g key={i} className="chapter" onMouseMove={() => setHover({ x: a, text: c.text, sub: `${clock(c.start)}–${clock(c.end)}` })}>
          {label ? <rect x={a + .5} y={axis + 4} width={w} height={chapterH} rx={6} className={i % 2 ? "odd" : ""} /> : <rect x={a + .5} y={axis + 4 + chapterH / 2 - 3} width={w} height={6} rx={3} className="thin" />}
          {label && <text x={a + 6} y={axis + 4 + chapterH / 2 + 4}>{label}</text>}
        </g>;
      })}
      {used.map((lane, i) => <g key={lane.key}>
        <text x={0} y={lanesTop + i * (laneH + gap) + laneH / 2 + 4} className="lane-label">{lane.label}</text>
        <rect x={labelWidth} y={lanesTop + i * (laneH + gap)} width={plotW} height={laneH} rx={4} className="lane" />
      </g>)}
      {rows.map(r => {
        const i = used.findIndex(lane => lane.key === laneOf(r.source));
        const y = lanesTop + i * (laneH + gap);
        const a = x(Date.parse(r.t_start)), b = x(Date.parse(r.t_end ?? r.t_start));
        const span = r.kind === "span" && b - a >= 2;
        const props = span ? { x: a, y: y + 2, width: b - a, height: laneH - 4, rx: 3 } : { x: a - 1, y: y + 3, width: 2, height: laneH - 6, rx: 1 };
        return <rect key={r.id} {...props} className={r.id === selected ? "seg selected" : "seg"}
          onMouseMove={() => setHover({ x: a, text: r.title, sub: `${timeRange(r)}，${sourceNames[r.source] ?? r.source}` })}
          onClick={() => onPick(r)} />;
      })}
      {isToday && <g className="now"><line x1={x(now)} x2={x(now)} y1={axis - 2} y2={height} /><circle cx={x(now)} cy={axis - 2} r={3} /></g>}
    </svg>
    {hover && <div className="strata-tip" style={{ left: Math.min(Math.max(0, hover.x - 24), width - 300) }}><span>{hover.sub}</span>{hover.text}</div>}
  </div>;
}
