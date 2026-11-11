// 历史记录按活动段显示（与 Mac 客户端一致，契约见 docs/contracts.md 4.5.1）。
import type { Api } from "./distillation.ts";
import { dayRange, durationText, sourceNames, type HistoryRow } from "./history.ts";

export interface SegmentApp { app: string | null; name: string | null; source: string; records: number; seconds: number }
export interface SegmentThread { id: string; title: string; brief: string | null; status: string; domain: string | null; project_id: string | null; project_name: string | null }
export interface Segment {
  id: string; kind: "thread" | "app"; start_ms: number; end_ms: number; thread: SegmentThread | null;
  apps: SegmentApp[]; active_seconds: number; record_ids: string[]; private: number;
}
/** 列表里一行：一段活动，或连续几段零碎活动折成的一行。 */
export type SegmentItem = { kind: "single"; id: string; segment: Segment } | { kind: "minor"; id: string; segments: Segment[] };

/** 一场对话：被静音切开的几条录音记录合成一组，id 是第一条记录的 id。title 要等总结写好才有。 */
export interface Conversation { id: string; record_ids: string[]; start_ms: number; end_ms: number; app: string | null; title: string | null }
/** 活动段展开后的一行：一条记录，或同一场对话的几条记录合成的一行。 */
export type RecordItem = { kind: "record"; id: string; record: HistoryRow } | { kind: "conversation"; id: string; conversation: Conversation; records: HistoryRow[] };

/** 打开一条对话记录时看的整场对话：整理过的原文（turns）和总结。state 说明总结的情况。 */
export interface ConversationDetail {
  id: string; record_ids: string[]; start: string; end: string; app: string | null;
  state: "ready" | "waiting" | "short" | "private"; title: string | null; summary: string | null; points: string[];
  turns: { at: string; speaker: string; text: string }[];
}
export function conversationDetail(api: Api, recordId: string, signal?: AbortSignal): Promise<ConversationDetail> {
  return api<ConversationDetail>(`/v1/conversations/${encodeURIComponent(recordId)}`, { signal });
}

export async function daySegments(api: Api, day: string, device: string, signal?: AbortSignal): Promise<{ segments: Segment[]; conversations: Conversation[] }> {
  const { from, to } = dayRange(day);
  const params = new URLSearchParams({ from, to });
  if (device) params.set("device", device);
  const result = await api<{ segments: Segment[]; conversations?: Conversation[] }>(`/v1/history/segments?${params}`, { signal });
  return { segments: result.segments, conversations: result.conversations ?? [] };
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

/** 同一场对话的记录合成一行，放在它在列表里第一次出现的位置；不属于任何一场的记录原样保留。 */
export function collapseConversations(rows: HistoryRow[], conversations: Conversation[]): RecordItem[] {
  const owner = new Map<string, Conversation>();
  for (const c of conversations) for (const id of c.record_ids) owner.set(id, c);
  const out: RecordItem[] = [], groups = new Map<string, HistoryRow[]>();
  for (const record of rows) {
    const c = record.source === "mac.audio" ? owner.get(record.id) : undefined;
    if (!c) { out.push({ kind: "record", id: record.id, record }); continue; }
    const records = groups.get(c.id);
    if (records) { records.push(record); continue; }
    groups.set(c.id, [record]);
    out.push({ kind: "conversation", id: c.id, conversation: c, records: groups.get(c.id)! });
  }
  return out;
}
/** 删掉记录后本地先把它从所在的那场对话里去掉：中枢会连带删掉这场的总结，标题清空；整场删光的不再列出。 */
export function withoutRecords(conversations: Conversation[], ids: string[], rows: Map<string, HistoryRow>): Conversation[] {
  const gone = new Set(ids);
  return conversations.flatMap(c => {
    if (!c.record_ids.some(id => gone.has(id))) return [c];
    const record_ids = c.record_ids.filter(id => !gone.has(id));
    if (!record_ids.length) return [];
    const left = record_ids.flatMap(id => rows.get(id) ?? []);
    const start_ms = left.length ? Math.min(...left.map(r => Date.parse(r.t_start))) : c.start_ms;
    const end_ms = left.length ? Math.max(...left.map(r => Date.parse(r.t_end ?? r.t_start))) : c.end_ms;
    return [{ ...c, id: record_ids[0]!, record_ids, start_ms, end_ms, title: null }];
  });
}
export function conversationTitle(c: Conversation): string {
  if (c.title?.trim()) return `对话：${c.title.trim()}`;
  // 不到 1 分钟的不写时长，免得出现"对话 不到 1 分钟"。
  const seconds = Math.floor((c.end_ms - c.start_ms) / 1000);
  return seconds >= 60 ? `对话 ${durationText(seconds)}` : "对话";
}

const pad = (n: number) => String(n).padStart(2, "0");
export const clockMs = (ms: number) => { const d = new Date(ms); return `${pad(d.getHours())}:${pad(d.getMinutes())}`; };
export function spanText(startMs: number, endMs: number): string {
  const a = clockMs(startMs), b = clockMs(endMs);
  return a === b ? a : `${a}–${b}`;
}
