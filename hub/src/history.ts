import { HubDB, InputError } from "./db.ts";
import { conversationList } from "./conversations.ts";
import { recordDeviceFilter } from "./record-sources.ts";
import { unionSeconds } from "./durations.ts";
export { unionSeconds } from "./durations.ts";

/**
 * History 列表给人看的"活动段"：同一线程时间上接得上的记录合成一段，还没归属线程的按应用临时分组。
 * 只读已有的提炼结果（frame_records → assignments → threads），不调用模型、不写库。
 * private 记录和 /v1/records 一样照常返回给本机查看界面，只标出数量。
 */

/** 同一线程（或同一应用）两条记录相隔不超过这个间隔就算连续，与切片段用的间隔一致。 */
export const SEGMENT_GAP_MS = 10 * 60_000;
const MAX_RANGE_MS = 31 * 24 * 3600_000;

/** name：给不能查 bundle id 的网页用的显示名，取屏幕记录标题"应用名 · 窗口"里出现最多的应用名；拿不到时为 null。 */
export interface SegmentApp { app: string | null; name: string | null; source: string; records: number; seconds: number }
export interface SegmentThread { id: string; title: string; brief: string | null; status: string; domain: string | null; project_id: string | null; project_name: string | null }
export interface Segment {
  id: string;
  kind: "thread" | "app";
  start_ms: number;
  end_ms: number;
  thread: SegmentThread | null;
  /** 涉及的应用，按活跃时长从多到少；没有 context.app 的记录按来源归类（app 为 null）。 */
  apps: SegmentApp[];
  active_seconds: number;
  /** 按开始时间从早到晚。 */
  record_ids: string[];
  private: number;
}

interface Row { id: string; source: string; title: string; t_start_ms: number; t_end: string | null; context: string | null; sensitivity: string; thread_id: string | null }
interface Item { id: string; source: string; app: string | null; name: string | null; start: number; end: number; private: boolean }

function mostCommon(values: (string | null)[]): string | null {
  const counts = new Map<string, number>();
  for (const v of values) if (v) counts.set(v,(counts.get(v) ?? 0)+1);
  let best: string | null = null, n = 0;
  for (const [v,c] of counts) if (c > n) { best = v; n = c; }
  return best;
}

function appOf(context: string | null): string | null {
  if (!context) return null;
  try { const app = (JSON.parse(context) as { app?: unknown }).app; return typeof app === "string" && app ? app : null; }
  catch { return null; }
}

export function historySegments(hub: HubDB, params: URLSearchParams, include = (_id: string) => true): { segments: Segment[]; conversations: ReturnType<typeof conversationList> } {
  const from = Date.parse(params.get("from") ?? ""), to = Date.parse(params.get("to") ?? "");
  if (!Number.isFinite(from) || !Number.isFinite(to) || from > to) throw new InputError("需要有效的 from 和 to");
  if (to - from > MAX_RANGE_MS) throw new InputError("时间范围不能超过 31 天");
  const device = params.get("device");
  const rows = (hub.db.prepare(`SELECT r.id,r.source,r.title,r.t_start_ms,r.t_end,r.context,r.sensitivity,a.thread_id
    FROM records r LEFT JOIN frame_records fr ON fr.record_id=r.id LEFT JOIN assignments a ON a.frame_id=fr.frame_id
    WHERE r.t_start_ms>=? AND r.t_start_ms<=? ${device ? "AND " + recordDeviceFilter(device) : ""} ORDER BY r.t_start_ms,r.id`).all(...[from,to,...device ? [device] : []]) as Row[]).filter(row => include(row.id));

  const threadIds = [...new Set(rows.flatMap(r => r.thread_id ? [r.thread_id] : []))];
  const threads = new Map<string, SegmentThread>();
  if (threadIds.length) {
    const found = hub.db.prepare(`SELECT t.id,t.title,t.brief,t.status,t.domain,t.project_id,p.name AS project_name
      FROM threads t LEFT JOIN projects p ON p.id=t.project_id WHERE t.id IN (SELECT value FROM json_each(?))`).all(JSON.stringify(threadIds)) as SegmentThread[];
    for (const t of found) threads.set(t.id,{ ...t,brief: t.brief ?? null,domain: t.domain ?? null,project_id: t.project_id ?? null,project_name: t.project_name ?? null });
  }

  interface Open { key: string; thread: SegmentThread | null; app: string; items: Item[]; last: number }
  const groups: Open[] = [], open = new Map<string, Open>();
  for (const r of rows) {
    const start = r.t_start_ms, parsedEnd = r.t_end ? Date.parse(r.t_end) : NaN;
    const app0 = appOf(r.context), sep = r.title.indexOf(" · ");
    const item: Item = { id: r.id,source: r.source,app: app0,name: app0 && sep > 0 ? r.title.slice(0,sep).trim() || null : null,start,end: Number.isFinite(parsedEnd) ? Math.max(start,parsedEnd) : start,private: r.sensitivity === "private" };
    // 归属的线程已不存在时（例如被合并删掉）按未提炼处理，不让记录从列表里消失。
    const thread = r.thread_id ? threads.get(r.thread_id) ?? null : null;
    const app = item.app ?? item.source;
    const key = thread ? `thread:${thread.id}` : `app:${app}`;
    let g = open.get(key);
    if (!g || start - g.last > SEGMENT_GAP_MS) {
      g = { key,thread,app,items: [],last: item.end };
      groups.push(g); open.set(key,g);
    }
    g.items.push(item); g.last = Math.max(g.last,item.end);
  }

  const segments = groups.map((g): Segment => {
    const apps = new Map<string, { app: string | null; source: string; items: Item[] }>();
    for (const it of g.items) {
      const k = it.app ?? it.source;
      const entry = apps.get(k) ?? { app: it.app,source: it.source,items: [] };
      entry.items.push(it); apps.set(k,entry);
    }
    return {
      id: `${g.thread ? "t" : "a"}:${g.items[0]!.id}`,
      kind: g.thread ? "thread" : "app",
      start_ms: g.items[0]!.start,
      end_ms: Math.max(...g.items.map(i => i.end)),
      thread: g.thread,
      apps: [...apps.values()].map(a => ({ app: a.app,name: mostCommon(a.items.map(i => i.name)),source: a.source,records: a.items.length,seconds: unionSeconds(a.items.map(i => [i.start,i.end])) }))
        .sort((a,b) => b.seconds-a.seconds || b.records-a.records || (a.app ?? a.source).localeCompare(b.app ?? b.source)),
      active_seconds: unionSeconds(g.items.map(i => [i.start,i.end])),
      record_ids: g.items.map(i => i.id),
      private: g.items.filter(i => i.private).length,
    };
  });
  // 和 /v1/records 一致：新的在前。
  segments.sort((a,b) => b.start_ms-a.start_ms || (a.id < b.id ? 1 : a.id > b.id ? -1 : 0));
  // 对话按场合并（被静音切开的几条记录是同一场），列表里一场一行，标题用总结里的。
  return { segments,conversations: conversationList(hub,from,to,device ?? undefined) };
}
