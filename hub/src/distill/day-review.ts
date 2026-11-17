import { toLocalIso } from "../../../packages/record/index.ts";
import { chatKey } from "../chat.ts";
import { groupConversations } from "../conversations.ts";
import type { HubDB } from "../db.ts";
import { unionSeconds } from "../durations.ts";
import { dayEvidence, type DayReference } from "./day-evidence.ts";
import { frameKey } from "./frames.ts";
import type { DayOutput } from "./prompts.ts";

const MINUTE = 60_000;
const MISC_SECONDS = 5 * 60;
const MISC_GAP = 15 * MINUTE;
const CHAT_GAP = 30 * MINUTE;
const MAX_ACTIVITIES = 20;
const SESSION_SOURCES = new Set(["codex.session", "claude_code.session"]);
const SKELETON_SOURCES = new Set(["mac.screen", "mac.browser", "mac.app"]);
const terse = (text: string, max: number) => Array.from(text.replace(/\s+/g, " ").trim()).slice(0, max).join("");

type Span = [number, number];
type ReviewRecord = DayReference & { start: number; end: number; key: string; thread: string | null; app: string | null; chat: string | null };
type Activity = {
  id: string; label: string; start: number; end: number; records: ReviewRecord[];
  spans: Span[]; kind: "thread" | "speech" | "chat" | "session" | "misc";
};
export interface ReviewItem {
  id: string; title: string; description: string; t_start: string; t_end: string;
  active_seconds: number; sources: string[]; evidence: DayReference[];
}
export interface ReviewDetail {
  summary: string | null;
  timeline: { start: string; end: string; text: string }[];
  items: ReviewItem[];
  cutoff: string;
  // 一般可以按记录原日期撤下回顾；跨午夜的活动还要撤下后一日。
  record_ids: string[];
}

function loadRecords(hub: HubDB, start: number, end: number): ReviewRecord[] {
  const rows = hub.db.prepare(`SELECT r.id,r.source,r.source_ref,r.title,r.t_start,r.t_start_ms,r.t_end,r.context,f.key,a.thread_id
    FROM records r
    LEFT JOIN frame_records fr ON fr.record_id=r.id LEFT JOIN frames f ON f.id=fr.frame_id
    LEFT JOIN assignments a ON a.frame_id=f.id
    WHERE r.t_start_ms<? AND (r.t_start_ms>=? OR (r.t_end IS NOT NULL AND julianday(r.t_end)>julianday(?)))
      AND r.sensitivity<>'private'
      AND COALESCE((SELECT sensitivity FROM records c WHERE c.corrects=r.id AND c.source='manual.correction'
        ORDER BY c.t_start_ms DESC,c.id DESC LIMIT 1),'normal')<>'private'
      AND (r.source IN ('mac.screen','mac.browser','mac.app','mac.audio','codex.session','claude_code.session','mac.wechat','manual.note')
        OR (r.source NOT IN ('mac.shell','mac.git','mac.file','mac.clipboard','manual.agent','manual.correction')
          AND json_type(r.context,'$.chat')='text' AND json_extract(r.context,'$.extra.from_me') IN (0,1)))
    ORDER BY r.t_start_ms,r.id`).all(end, start, new Date(start).toISOString()) as {
      id: string; source: string; source_ref: string | null; title: string; t_start: string; t_start_ms: number; t_end: string | null;
      context: string | null; key: string | null; thread_id: string | null;
    }[];
  return rows.map(row => {
    const context = row.context ? JSON.parse(row.context) as { app?: string; chat?: string; url?: string; window?: string } : undefined;
    const key = row.key ?? frameKey({ id: row.id, source: row.source, source_ref: row.source_ref, context } as Parameters<typeof frameKey>[0]);
    return {
      id: row.id, source: row.source, title: terse(row.title, 120) || "原始记录", at: row.t_start,
      start: Math.max(start, row.t_start_ms), end: Math.min(end, Math.max(row.t_start_ms, Date.parse(row.t_end ?? "") || row.t_start_ms)),
      key, thread: row.thread_id, app: context?.app ?? null, chat: context?.chat ?? null,
    };
  });
}

function groupRecords(rows: ReviewRecord[]): Activity[] {
  const audio = groupConversations(rows.filter(r => r.source === "mac.audio")
    .map(r => ({ id: r.id, start_ms: r.start, end_ms: r.end, app: r.app, private: false })));
  const lookup = new Map(rows.map(record => [record.id, record]));
  const voices = new Map<string, { id: string; thread: string | null }>();
  for (const conversation of audio) {
    const threads = new Set(conversation.record_ids.flatMap(id => lookup.get(id)?.thread ?? []));
    const thread = threads.size === 1 ? [...threads][0]! : null;
    for (const id of conversation.record_ids) voices.set(id, { id: conversation.id, thread });
  }
  const groups: Activity[] = [], open = new Map<string, Activity>();
  for (const row of rows) {
    const voice = voices.get(row.id), thread = voice ? voice.thread : row.thread;
    const kind = thread ? "thread" : voice ? "speech" : SESSION_SOURCES.has(row.source) ? "session"
      : row.chat && !SKELETON_SOURCES.has(row.source) ? "chat" : "misc";
    const key = thread ? `thread:${thread}` : voice ? `speech:${voice.id}`
      : kind === "chat" ? `${row.source}:${chatKey(row.chat!)}` : row.key;
    const gap = kind === "chat" ? CHAT_GAP : kind === "misc" ? MISC_GAP : Infinity;
    let group = open.get(key);
    if (!group || row.start > group.end + gap) {
      group = { id: thread ? key : `${kind}:${row.id}`, label: row.chat ?? row.title,
        start: row.start, end: row.end, records: [], spans: [], kind };
      open.set(key, group); groups.push(group);
    }
    group.records.push(row);
    group.spans.push([row.start, row.end]);
    group.end = Math.max(group.end, row.end);
    if (kind === "misc") group.label = row.title;
  }
  return groups;
}

function reference({ id, at, source, title }: ReviewRecord): DayReference { return { id, at, source, title }; }
const byImportance = (a: { seconds: number; start: number }, b: { seconds: number; start: number }) =>
  b.seconds - a.seconds || a.start - b.start;

export function reviewInput(hub: HubDB, start: number, end: number) {
  const candidates = groupRecords(loadRecords(hub, start, end))
    .map(activity => ({ ...activity, seconds: unionSeconds(activity.spans) }))
    .filter(a => a.kind === "thread" || a.kind === "speech" || a.kind === "session" ||
      (a.kind === "chat" && a.records.length > 1) || a.seconds >= MISC_SECONDS)
    .sort(byImportance).slice(0, MAX_ACTIVITIES);
  return candidates.sort((a, b) => a.start - b.start).map((activity, i) => {
    const refs = activity.records.map(reference);
    return { ...activity, key: `a${i + 1}`, refs,
      evidence: dayEvidence(hub, refs, start, end, Math.max(6, Math.floor(120 / Math.max(1, candidates.length)))) };
  });
}

type ReviewActivity = ReturnType<typeof reviewInput>[number];
export function reviewMaterial(activities: ReviewActivity[]) {
  return activities.filter(a => a.evidence.length).map(a => ({
    key: a.key, kind: a.kind, start: toLocalIso(a.start).slice(11, 16),
    active_minutes: Math.round(a.seconds / 60),
    evidence: a.evidence.map(({ reference: _reference, ...entry }) => entry),
  }));
}

function coverageChapters(spans: Span[]) {
  const segments: Span[] = [];
  for (const [start, end] of spans.filter(([s, e]) => e > s).sort((a, b) => a[0] - b[0])) {
    const last = segments.at(-1);
    if (last && start <= last[1] + MISC_GAP) last[1] = Math.max(last[1], end);
    else segments.push([start, end]);
  }
  return segments;
}
const singleLine = (text: string, limit: number) => {
  const line = text.trim();
  return line && Array.from(line).length <= limit && !/[\r\n]/.test(line) ? line : null;
};

export function composeReview(activities: ReviewActivity[], output: DayOutput, dayStart: number, dayEnd: number, cutoff: string): ReviewDetail {
  const written = new Map(output.items.map(item => [item.activity, item]));
  const result = activities.flatMap(a => {
    const candidate = written.get(a.key);
    const title = candidate && singleLine(candidate.title, 20), description = candidate && singleLine(candidate.description, 160);
    let item: Pick<ReviewItem, "title" | "description" | "evidence">;
    if (candidate && title && description && candidate.refs.length) {
      const references = candidate.refs.map(key => a.evidence.find(entry => entry.key === key)?.reference);
      if (references.some(ref => !ref)) return [];
      const evidence = [...new Map(references.map(ref => [ref!.id, ref!])).values()]
        .sort((x, y) => Date.parse(x.at) - Date.parse(y.at));
      item = { title, description, evidence };
    } else if (a.seconds >= MISC_SECONDS && a.records.every(r => SKELETON_SOURCES.has(r.source))) {
      const browsed = a.records.every(r => r.source === "mac.browser");
      item = { title: terse(a.label, 20), description: browsed ? "在这段时间浏览了网页。" : "在这段时间使用了这个窗口。",
        evidence: a.refs.length === 1 ? a.refs : [a.refs[0]!, a.refs.at(-1)!] };
    } else {
      return [];
    }
    const activity: ReviewItem = {
      id: a.id, title: item.title, description: item.description, t_start: toLocalIso(a.start), t_end: toLocalIso(a.end),
      active_seconds: a.seconds, sources: [...new Set(a.records.map(r => r.source))], evidence: item.evidence,
    };
    return [{ a, activity }];
  });
  const main = output.highlight && result.find(({ a }) => a.key === output.highlight?.activity && a.evidence.length);
  const longest = [...result].sort((a, b) => byImportance(a.a, b.a))[0]?.activity;
  const summary = (main && singleLine(output.highlight!.text, 30)) || longest?.title || null;
  const timeline = result.flatMap(({ a, activity }) => coverageChapters(a.spans).map(([start, end]) => ({
    start: toLocalIso(start).slice(11, 16), end: end === dayEnd ? "24:00" : toLocalIso(end).slice(11, 16), text: activity.title,
    duration: end - start,
  }))).filter(chapter => chapter.start !== chapter.end)
    .sort((a, b) => b.duration - a.duration).slice(0, 12).sort((a, b) => a.start.localeCompare(b.start))
    .map(({ duration: _, ...chapter }) => chapter);
  const record_ids = [...new Set(result.flatMap(({ a }) => a.records.filter(r => Date.parse(r.at) < dayStart).map(r => r.id)))];
  return { summary, timeline, items: result.map(({ activity }) => activity), cutoff, record_ids };
}
