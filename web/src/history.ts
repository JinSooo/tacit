import { AGENT_SESSION_NAMES, AGENT_SESSION_SOURCES } from "../../packages/record/agent-tools.ts";
import type { RecordV1 } from "../../packages/record/index.ts";
import { toLocalIso, ulid } from "./record-helpers.ts";
export type HistoryRow = Omit<RecordV1, "body">;
export type Detail = RecordV1 & { corrections: RecordV1[] };
export function historyDeviceGroup(device: string): string {
  return /^mac-[a-z2-7]{8}$/.test(device) ? "mac" : device;
}
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
/** 时长按 docs/ui.md 写：不足 1 分钟写"不到 1 分钟"，不足 1 小时写"x 分钟"，否则"x 小时 y 分"。0 秒返回空串。 */
export function durationText(seconds: number): string {
  if (!(seconds >= 1)) return "";
  if (seconds < 60) return "不到 1 分钟";
  const minutes = Math.floor(seconds / 60);
  if (minutes < 60) return `${minutes} 分钟`;
  return `${Math.floor(minutes / 60)} 小时${minutes % 60 ? ` ${minutes % 60} 分` : ""}`;
}
/** 说话时长要精确到秒：不足 1 分钟写"x 秒"，其余同 durationText。 */
export function speechText(seconds: number): string {
  const s = Math.round(seconds);
  return s < 60 ? `${s} 秒` : durationText(s);
}
export function duration(record: HistoryRow): string {
  if (record.kind !== "span" || !record.t_end) return "";
  return durationText(Math.max(0, Math.floor((Date.parse(record.t_end) - Date.parse(record.t_start)) / 1000)));
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
  "mac.audio": "对话", "mac.screen": "屏幕", "mac.app": "应用", "mac.clipboard": "剪贴板", "mac.file": "文件", "mac.calendar": "日历", "mac.wechat": "微信",
  "mac.shell": "终端", "mac.git": "Git", "mac.browser": "浏览器", ...AGENT_SESSION_NAMES,
  "manual.note": "补写", "manual.correction": "修正", "manual.agent": "AI 补写",
  "android.audio": "手机录音", "android.notification": "手机聊天", "android.usage": "手机应用", "claude_desktop.session": "Claude Desktop",
};
/**
 * 列表、时间轴、依据和读取记录里显示的记录标题，规则和 Mac 端 RecordTitles 一致：
 * 采集端存的"应用 · 窗口""微信 · 会话 · 发言人"不用中间点拼接，改成冒号；对话标题里是转写当时的说话人编号，只写"对话"。
 * appShown：旁边已经写了应用名（活动段副标题）时去掉应用名。
 */
export function recordTitle(r: { source?: string; title: string }, appShown = false): string {
  const source = r.source ?? "";
  const t = r.title.trim();
  if (!t) return sourceNames[source] ?? source;
  if (source === "mac.audio") return "对话";
  const parts = t.split(" · ").map(p => p.trim()).filter(Boolean);
  if (parts.length < 2) return parts[0] ?? t;
  const [head, ...others] = parts as [string, ...string[]];
  if (source === "mac.screen" || source === "mac.app") {
    const window = others.filter(p => p !== head && p !== "无标题" && p !== "（无标题）").join("，");
    return !window ? head : appShown ? window : `${head}：${window}`;
  }
  if (source === "mac.wechat") return parts.length >= 3 ? `${parts[1]}：${parts.slice(2).join("，")}` : appShown ? others.join("，") : `微信：${others.join("，")}`;
  return `${head}：${others.join("，")}`;
}
/** 记录详情里的"采集方式"，对应 schema 的 capture.method。 */
export const captureNames: Record<string, string> = {
  ax: "读取窗口文字", ocr: "截图识字", asr: "语音转写", db: "读取应用数据", file: "读取文件", hook: "终端记录", api: "应用接口", manual: "手动填写",
};
/** 条带图的泳道：同类来源放在一条里。 */
export const lanes = [
  { key: "screen", label: "屏幕" }, { key: "browser", label: "浏览" }, { key: "agent", label: "AI 工具" },
  { key: "terminal", label: "终端" }, { key: "voice", label: "对话" }, { key: "other", label: "其他" },
] as const;
export type LaneKey = typeof lanes[number]["key"];
export function laneOf(source: string): LaneKey {
  if (source === "mac.screen" || source === "mac.app") return "screen";
  if (source === "mac.browser") return "browser";
  if (AGENT_SESSION_SOURCES.has(source)) return "agent";
  if (source === "mac.shell" || source === "mac.git") return "terminal";
  if (source === "mac.audio" || source === "mac.calendar" || source === "mac.wechat") return "voice";
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
