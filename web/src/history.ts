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
  if (seconds < 1) return "";
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
/** 每个来源一种固定颜色，与 Mac 客户端一致；颜色在 style.css 里按深浅色模式定义。 */
const sourceKeys: Record<string, string> = {
  "mac.screen": "screen", "mac.app": "screen", "mac.browser": "browser", "claude_code.session": "claude", "codex.session": "codex",
  "mac.shell": "shell", "mac.git": "git", "mac.clipboard": "clipboard", "mac.file": "file", "mac.calendar": "calendar",
  "mac.audio": "audio", "manual.note": "manual", "manual.correction": "manual",
};
export function sourceColor(source: string): string {
  return `var(--src-${sourceKeys[source] ?? "other"})`;
}
/** 条带图的泳道：同类来源放在一条里。 */
export const lanes = [
  { key: "screen", label: "屏幕" }, { key: "browser", label: "浏览" }, { key: "agent", label: "Agent" },
  { key: "terminal", label: "终端" }, { key: "voice", label: "对话" }, { key: "other", label: "其他" },
] as const;
export type LaneKey = typeof lanes[number]["key"];
export function laneOf(source: string): LaneKey {
  if (source === "mac.screen" || source === "mac.app") return "screen";
  if (source === "mac.browser") return "browser";
  if (source === "claude_code.session" || source === "codex.session") return "agent";
  if (source === "mac.shell" || source === "mac.git") return "terminal";
  if (source === "mac.audio" || source === "mac.calendar") return "voice";
  return "other";
}
/** 本地日历某天的起止（毫秒），以及给 /v1/records 用的 from/to（to 是闭区间）。 */
export function dayRange(key: string): { start: number; end: number; from: string; to: string } {
  const start = new Date(`${key}T00:00:00`);
  const end = new Date(start); end.setDate(end.getDate() + 1);
  const withMs = (date: Date, ms: string) => toLocalIso(date).replace(/(?=[+-]\d\d:\d\d$)/, ms);
  return { start: start.getTime(), end: end.getTime(), from: withMs(start, ".000"), to: withMs(new Date(end.getTime() - 1), ".999") };
}
/** 日记时间线的 "HH:mm" 换成当天的毫秒；结束不晚于开始时（如 "00:00"）视为当天结束。 */
export function chapterSpans(key: string, timeline: { start: string; end: string; text: string }[] = []) {
  const { start: day, end: dayEnd } = dayRange(key);
  const at = (hhmm: string) => {
    const m = /^(\d{1,2}):(\d{2})$/.exec(hhmm);
    return m && Number(m[1]) <= 24 && Number(m[2]) < 60 ? day + (Number(m[1]) * 60 + Number(m[2])) * 60000 : null;
  };
  return timeline.flatMap(item => {
    const start = at(item.start), end = at(item.end);
    if (start === null || end === null) return [];
    return [{ start, end: end <= start ? dayEnd : end, text: item.text }];
  });
}
