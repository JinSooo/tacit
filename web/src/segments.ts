// 历史记录按活动段显示（与 Mac 客户端一致，契约见 docs/contracts.md 4.5.1）。
import type { Api } from "./distillation.ts";
import { dayRange, sourceNames, type HistoryRow } from "./history.ts";

export interface SegmentApp { app: string | null; name: string | null; source: string; records: number; seconds: number }
export interface SegmentThread { id: string; title: string; brief: string | null; status: string; domain: string | null; project_id: string | null; project_name: string | null }
export interface Segment {
  id: string; kind: "thread" | "app"; start_ms: number; end_ms: number; thread: SegmentThread | null;
  apps: SegmentApp[]; active_seconds: number; record_ids: string[]; private: number;
}
/** 列表里一行：一段活动，或连续几段零碎活动折成的一行。 */
export type SegmentItem = { kind: "single"; id: string; segment: Segment } | { kind: "minor"; id: string; segments: Segment[] };

export async function daySegments(api: Api, day: string, device: string, signal?: AbortSignal): Promise<Segment[]> {
  const { from, to } = dayRange(day);
  const params = new URLSearchParams({ from, to });
  if (device) params.set("device", device);
  return (await api<{ segments: Segment[] }>(`/v1/history/segments?${params}`, { signal })).segments;
}

/** 一天的全部原始记录（不含正文），按 id 索引：活动段展开、未提炼段的副标题都从这里取。 */
export async function dayRecords(api: Api, day: string, device: string, signal?: AbortSignal): Promise<Map<string, HistoryRow>> {
  const { from, to } = dayRange(day);
  const out = new Map<string, HistoryRow>();
  let cursor: string | null = null;
  do {
    const params = new URLSearchParams({ from, to, limit: "500" });
    if (device) params.set("device", device);
    if (cursor) params.set("cursor", cursor);
    const page: { records: HistoryRow[]; next_cursor: string | null } = await api(`/v1/records?${params}`, { signal });
    for (const r of page.records) out.set(r.id, r);
    cursor = page.next_cursor;
  } while (cursor);
  return out;
}

export function appName(a: SegmentApp): string {
  return a.name ?? (a.app ? a.app.split(".").pop()! : sourceNames[a.source] ?? a.source);
}
export function segmentTitle(s: Segment): string {
  return s.thread?.title || (s.apps[0] ? appName(s.apps[0]) : "");
}

/** 零碎段：还没归入线程、最多 2 条记录、活跃不到 2 分钟。连续至少 3 段才折成一行。 */
export function isMinor(s: Segment): boolean {
  return !s.thread && s.record_ids.length <= 2 && s.active_seconds < 120;
}
export function foldSegments(segments: Segment[], minRun = 3): SegmentItem[] {
  const out: SegmentItem[] = [];
  let run: Segment[] = [];
  const flush = () => {
    if (run.length >= minRun) out.push({ kind: "minor", id: `minor:${run[0]!.id}`, segments: run });
    else out.push(...run.map(segment => ({ kind: "single" as const, id: segment.id, segment })));
    run = [];
  };
  for (const s of segments) { if (isMinor(s)) run.push(s); else { flush(); out.push({ kind: "single", id: s.id, segment: s }); } }
  flush();
  return out;
}

const pad = (n: number) => String(n).padStart(2, "0");
export const clockMs = (ms: number) => { const d = new Date(ms); return `${pad(d.getHours())}:${pad(d.getMinutes())}`; };
export function spanText(startMs: number, endMs: number): string {
  const a = clockMs(startMs), b = clockMs(endMs);
  return a === b ? a : `${a}–${b}`;
}
