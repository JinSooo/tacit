import type { RecordV1 } from "../../packages/record/index.ts";
import { toLocalIso, ulid } from "./record-helpers.ts";
export type HistoryRow = Omit<RecordV1, "body">;
export type Detail = RecordV1 & { corrections: RecordV1[] };
const pad = (n: number) => String(n).padStart(2, "0");
export function dayKey(value: string | Date): string {
  const date = new Date(value);
  return `${date.getFullYear()}-${pad(date.getMonth() + 1)}-${pad(date.getDate())}`;
}
export function dateTitle(key: string, now = new Date()): string {
  if (key === dayKey(now)) return "今天";
  const yesterday = new Date(now);
  yesterday.setDate(yesterday.getDate() - 1);
  if (key === dayKey(yesterday)) return "昨天";
  const date = new Date(`${key}T12:00:00`);
  return `${date.getFullYear() !== now.getFullYear() ? `${date.getFullYear()}年` : ""}${date.getMonth() + 1}月${date.getDate()}日 周${"日一二三四五六"[date.getDay()]}`;
}
export function groupRecords(records: HistoryRow[]): { day: string; records: HistoryRow[] }[] {
  const groups = new Map<string, HistoryRow[]>();
  const sorted = [...records].sort((a, b) => Date.parse(b.t_start) - Date.parse(a.t_start) || b.id.localeCompare(a.id));
  for (const record of sorted) {
    const day = dayKey(record.t_start);
    if (!groups.has(day)) groups.set(day, []);
    groups.get(day)!.push(record);
  }
  return Array.from(groups, ([day, records]) => ({ day, records }));
}
const clock = (value: string) => { const date = new Date(value); return `${pad(date.getHours())}:${pad(date.getMinutes())}`; };
export function timeRange(record: HistoryRow): string {
  if (record.kind !== "span" || !record.t_end) return clock(record.t_start);
  // 同一分钟内开始和结束，只显示一个时间。
  if (dayKey(record.t_start) === dayKey(record.t_end) && clock(record.t_start) === clock(record.t_end)) return clock(record.t_start);
  const end = dayKey(record.t_start) === dayKey(record.t_end) ? clock(record.t_end) : `${new Date(record.t_end).getMonth() + 1}月${new Date(record.t_end).getDate()}日 ${clock(record.t_end)}`;
  return `${clock(record.t_start)}–${end}`;
}
export function duration(record: HistoryRow): string {
  if (record.kind !== "span" || !record.t_end) return "";
  const seconds = Math.max(0, Math.floor((Date.parse(record.t_end) - Date.parse(record.t_start)) / 1000));
  if (seconds < 60) return `${seconds}秒`;
  const minutes = Math.floor(seconds / 60);
  return minutes < 60 ? `${minutes}分钟` : `${Math.floor(minutes / 60)}小时${minutes % 60 ? `${minutes % 60}分钟` : ""}`;
}
export interface NoteInput { start: string; end?: string; title: string; body: string }
export function buildNote(input: NoteInput): RecordV1 {
  const start = new Date(input.start);
  const end = input.end ? new Date(input.end) : undefined;
  if (!Number.isFinite(start.getTime()) || (end && (!Number.isFinite(end.getTime()) || end < start))) throw new Error("请填写有效时间，结束时间不能早于开始时间");
  const title = input.title.replace(/\s+/g, " ").trim();
  if (!title || title.length > 200) throw new Error("标题须为 1–200 个字符");
  if (input.body.length > 200000) throw new Error("正文不能超过 200000 个字符");
  return { id: ulid(), schema: 1, device: "web", source: "manual.note", kind: end ? "span" : "event", t_start: toLocalIso(start), ...(end ? { t_end: toLocalIso(end) } : {}), title, body: input.body, capture: { method: "manual" }, sensitivity: "normal" };
}
export function buildCorrection(original: RecordV1, body: string, now = new Date()): RecordV1 {
  if (body.length > 200000) throw new Error("正文不能超过 200000 个字符");
  // 不继承原记录的来源键、媒体或采集信息；保留其隐私等级。
  return { id: ulid(), schema: 1, device: "web", source: "manual.correction", kind: "event", t_start: toLocalIso(now), title: original.title, body, corrects: original.id, capture: { method: "manual" }, sensitivity: original.sensitivity };
}
export function latestCorrection(detail: Detail): RecordV1 | undefined {
  return [...detail.corrections].sort((a, b) => Date.parse(b.t_start) - Date.parse(a.t_start) || b.id.localeCompare(a.id))[0];
}
export function safeUrl(value: string): string | undefined {
  try { const url = new URL(value); return ["http:", "https:"].includes(url.protocol) ? url.href : undefined; } catch { return undefined; }
}
export const sourceNames: Record<string, string> = {
  "mac.audio": "对话", "mac.screen": "屏幕", "mac.app": "应用", "mac.clipboard": "剪贴板", "mac.file": "文件", "mac.calendar": "日历",
  "mac.shell": "终端", "mac.git": "Git", "mac.browser": "浏览器", "claude_code.session": "Claude Code", "codex.session": "Codex",
  "manual.note": "补写", "manual.correction": "修正",
};
export function sourceColor(source: string): string {
  const colors = ["#658d76", "#7889ae", "#b28a59", "#a77d96", "#699397", "#98905c"];
  return colors[Array.from(source).reduce((sum, char) => sum + char.charCodeAt(0), 0) % colors.length];
}
