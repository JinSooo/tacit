import type { HubDB } from "./db.ts";
import { InputError } from "./db.ts";

/**
 * 对话（mac.audio）给人看的样子：一场对话常被静音切成几条记录，按规则合成一组；
 * 转写原文按人合并、去掉识别噪声；每组另存一段模型写的总结。记录本身不改（AGENTS.md）。
 */

export const conversationSchema = `
CREATE TABLE IF NOT EXISTS conversation_summaries(id TEXT PRIMARY KEY,record_ids TEXT NOT NULL,title TEXT NOT NULL,summary TEXT NOT NULL,points TEXT NOT NULL,created_at TEXT NOT NULL);
PRAGMA user_version=7;
`;
/** 转写里每句是谁、是不是扬声器声音：采集端按新规则重认后另存，记录本身不改（AGENTS.md：归属关系另存一张表）。at 是正文里的 HH:MM:SS。 */
export const lineSchema = `
CREATE TABLE IF NOT EXISTS conversation_lines(conversation_ref TEXT NOT NULL,at TEXT NOT NULL,speaker_id TEXT,hidden INTEGER NOT NULL DEFAULT 0,PRIMARY KEY(conversation_ref,at));
PRAGMA user_version=8;
`;

/** 采集端重认的结果整段替换。同一秒有两段时，以认出了人、不是扬声器声音的为准。 */
export function saveLines(db: HubDB, ref: string, lines: { at: string; speaker_id: string | null; hidden: boolean }[]) {
  db.db.prepare("DELETE FROM conversation_lines WHERE conversation_ref=?").run(ref);
  const best = new Map<string, { speaker_id: string | null; hidden: boolean }>();
  for (const l of lines) {
    const prev = best.get(l.at);
    const score = (x: { speaker_id: string | null; hidden: boolean }) => (x.hidden ? 0 : 2) + (x.speaker_id ? 1 : 0);
    if (!prev || score(l) > score(prev)) best.set(l.at, l);
  }
  const insert = db.db.prepare("INSERT INTO conversation_lines VALUES(?,?,?,?)");
  for (const [at, l] of best) insert.run(ref, at, l.speaker_id, Number(l.hidden));
  // 认人变了，这段对话的总结按新的写法重写。
  for (const r of db.db.prepare("SELECT id FROM records WHERE source='mac.audio' AND source_ref=?").all(ref) as { id: string }[]) removeSummariesOf(db, r.id);
  return best.size;
}

/** 相邻两条对话记录间隔不超过它，且同在一个会议软件里（或都不在会议里），算同一场对话。 */
export const CONVERSATION_GAP_MS = 10 * 60_000;
/** 转写整理后不到这么多字的不总结，看原文就够了。 */
export const SUMMARY_MIN_CHARS = 200;

export interface AudioRow { id: string; start_ms: number; end_ms: number; app: string | null; private: boolean }
export interface ConversationGroup { id: string; record_ids: string[]; start_ms: number; end_ms: number; app: string | null; private: boolean }

/** rows 不要求有序。开会时同一个会议软件里的连成一场；不开会的按间隔连；开会和不开会的不连在一起。 */
export function groupConversations(rows: AudioRow[]): ConversationGroup[] {
  const sorted = rows.slice().sort((a, b) => a.start_ms - b.start_ms || a.id.localeCompare(b.id));
  const out: ConversationGroup[] = [];
  for (const r of sorted) {
    const g = out.at(-1);
    if (g && g.app === r.app && r.start_ms - g.end_ms <= CONVERSATION_GAP_MS) {
      g.record_ids.push(r.id); g.end_ms = Math.max(g.end_ms, r.end_ms); g.private ||= r.private;
    } else out.push({ id: r.id, record_ids: [r.id], start_ms: r.start_ms, end_ms: r.end_ms, app: r.app, private: r.private });
  }
  return out;
}

export interface Line { at_ms: number; label: string; text: string; clock?: string; speaker_id?: string | null }

/** 采集端写的正文每行是"[HH:MM:SS] 说话人：内容"，时间是本地钟点；跨过午夜的行算到第二天。 */
export function parseTranscript(body: string, t_start: string): Line[] {
  const m = /^(\d{4}-\d\d-\d\d)T(\d\d:\d\d:\d\d)(?:\.\d+)?(Z|[+-]\d\d:\d\d)$/.exec(t_start);
  const start = Date.parse(t_start);
  const out: Line[] = [];
  for (const raw of body.split("\n")) {
    const line = /^\[(\d\d:\d\d:\d\d)\]\s*([^：]+)：(.*)$/.exec(raw.trim());
    if (!line) continue;
    let at = m ? Date.parse(`${m[1]}T${line[1]}${m[3]}`) : start;
    if (Number.isFinite(start) && at < start - 60_000) at += 86_400_000;
    out.push({ at_ms: Number.isFinite(at) ? at : start, label: line[2]!.trim(), text: line[3]!.trim(), clock: line[1]! });
  }
  return out;
}

const FILLER = /^(嗯|啊|哦|噢|呃|额|唉|哎|诶|欸|嘿|喂|哈|呀|yeah|yes|yep|oh|ok|okay|hello|hi|hey|wei|uh|um|hmm|mm|bye)+$/i;
/** 识别噪声：语气词、一两个字的碎片、夹在中文里的假名（背景声被认成日语）。 */
export function isNoise(text: string): boolean {
  const t = text.replace(/[\s\p{P}\p{S}]/gu, "");
  if (t.length <= 2) return true;
  if (FILLER.test(t)) return true;
  // 中文对话里单独冒出的一个短英文词（"The."），多半是背景声被认成了英文。
  if (/^[A-Za-z]{1,5}$/.test(t)) return true;
  return /[\p{Script=Hiragana}\p{Script=Katakana}]/u.test(t) && t.replace(/[\p{Script=Hiragana}\p{Script=Katakana}ー]/gu, "").length <= 3;
}

export interface Turn { at: string; speaker: string; text: string }

/** 去噪、去掉两路录到的同一句（回声），同一个人一分钟内接着说的合成一段。name 把转写时的标签换成现在的叫法。 */
export function readableTurns(lines: Line[], name: (label: string, speakerId?: string | null) => string): Turn[] {
  const kept: (Line & { speaker: string })[] = [];
  const norm = (s: string) => s.replace(/[\s\p{P}\p{S}]/gu, "");
  for (const l of lines.slice().sort((a, b) => a.at_ms - b.at_ms)) {
    if (isNoise(l.text)) continue;
    const n = norm(l.text);
    if (kept.some(k => l.at_ms - k.at_ms <= 10_000 && norm(k.text) === n)) continue;
    kept.push({ ...l, speaker: name(l.label, l.speaker_id) });
  }
  const out: (Turn & { last: number })[] = [];
  for (const k of kept) {
    const prev = out.at(-1);
    if (prev && prev.speaker === k.speaker && k.at_ms - prev.last <= 60_000) {
      prev.text += /[。！？!?…,，、；;：:]$/.test(prev.text) ? k.text : `，${k.text}`;
      prev.last = k.at_ms;
    } else out.push({ at: new Date(k.at_ms).toISOString(), speaker: k.speaker, text: k.text, last: k.at_ms });
  }
  return out.map(({ last: _, ...t }) => t);
}

interface SpeakerRow { id: string; label: string; name: string | null; is_me: number; status: string; merged_into: string | null }

/**
 * 转写时写进正文的是当时的叫法：确认过的名字、"我"、还没确认的编号或"未知说话人"。
 * 编号按现在的状态换：已确认的换成名字，被并走的跟到并入的那个人，其余按出场顺序叫"对方 1""对方 2"。
 */
export function speakerNamer(db: HubDB): () => (label: string, speakerId?: string | null) => string {
  const rows = db.db.prepare("SELECT id,label,name,is_me,status,merged_into FROM speakers").all() as SpeakerRow[];
  const byLabel = new Map(rows.map(r => [r.label, r])), byId = new Map(rows.map(r => [r.id, r]));
  const resolve = (r: SpeakerRow): SpeakerRow => {
    for (let i = 0; i < 10 && r.status === "merged" && r.merged_into && byId.has(r.merged_into); i++) r = byId.get(r.merged_into)!;
    return r;
  };
  return () => {
    const others = new Map<string, string>();
    const other = (key: string) => { if (!others.has(key)) others.set(key, `对方 ${others.size + 1}`); return others.get(key)!; };
    return (label: string, speakerId?: string | null) => {
      const byIdRow = speakerId ? byId.get(speakerId) : undefined;
      if (byIdRow) {
        const r = resolve(byIdRow);
        if (r.is_me) return "我";
        if (r.name && r.status === "confirmed") return r.name;
        return other(r.id);
      }
      if (label === "我") return "我";
      if (label === "未知说话人") return "其他人";
      const row = byLabel.get(label);
      // 说话人已被删掉（例如对话删除时）只剩编号：同样按"对方"编号，确认过的名字原样保留。
      if (!row) return /^说话人 [A-Z]+$/.test(label) ? other(label) : label;
      const r = resolve(row);
      if (r.is_me) return "我";
      if (r.name && r.status === "confirmed") return r.name;
      return other(r.id);
    };
  };
}

interface RecordRow { id: string; t_start: string; t_start_ms: number; t_end: string | null; context: string | null; sensitivity: string; body: string }

function appOf(context: string | null): string | null {
  if (!context) return null;
  try { const app = (JSON.parse(context) as { app?: unknown }).app; return typeof app === "string" && app ? app : null; } catch { return null; }
}
function audioRows(db: HubDB, from: number, to: number): RecordRow[] {
  return db.db.prepare("SELECT id,t_start,t_start_ms,t_end,context,sensitivity,body FROM records WHERE source='mac.audio' AND t_start_ms>=? AND t_start_ms<=? ORDER BY t_start_ms,id").all(from, to) as RecordRow[];
}
const toAudio = (r: RecordRow): AudioRow => ({ id: r.id, start_ms: r.t_start_ms, end_ms: Math.max(r.t_start_ms, r.t_end ? Date.parse(r.t_end) || r.t_start_ms : r.t_start_ms), app: appOf(r.context), private: r.sensitivity === "private" });

/** 范围内的对话分组。范围两头各多读一段，免得把跨边界的一场切开。 */
export function conversationsIn(db: HubDB, from: number, to: number): ConversationGroup[] {
  const pad = 4 * 3600_000;
  return groupConversations(audioRows(db, from - pad, to + pad).map(r => toAudio({ ...r, sensitivity: db.effective(r.id)?.sensitivity ?? r.sensitivity }))).filter(g => g.end_ms >= from && g.start_ms <= to);
}

/** 用户写的修正优先于转写原文。 */
function bodyOf(db: HubDB, r: RecordRow): string {
  const c = db.db.prepare("SELECT body FROM records WHERE corrects=? AND source='manual.correction' ORDER BY t_start_ms DESC,id DESC LIMIT 1").get(r.id) as { body: string } | undefined;
  return c?.body ?? r.body;
}

export function groupTurns(db: HubDB, g: ConversationGroup, namer = speakerNamer(db)()): Turn[] {
  const rows = g.record_ids.map(id => db.db.prepare("SELECT id,source_ref,t_start,t_start_ms,t_end,context,sensitivity,body FROM records WHERE id=?").get(id) as (RecordRow & { source_ref: string | null }) | undefined).filter((r): r is RecordRow & { source_ref: string | null } => !!r);
  return readableTurns(rows.flatMap(r => {
    const overrides = new Map((db.db.prepare("SELECT at,speaker_id,hidden FROM conversation_lines WHERE conversation_ref=?").all(r.source_ref ?? "") as { at: string; speaker_id: string | null; hidden: number }[]).map(o => [o.at, o]));
    return parseTranscript(bodyOf(db, r), r.t_start).flatMap(l => {
      const o = l.clock ? overrides.get(l.clock) : undefined;
      if (o?.hidden) return [];
      return [o?.speaker_id ? { ...l, speaker_id: o.speaker_id } : l];
    });
  }), namer);
}

export interface Summary { title: string; summary: string; points: string[] }
interface SummaryRow { id: string; record_ids: string; title: string; summary: string; points: string }

/** 记录组成和存的时候一样才算数；对话后来又接上了新的一段，总结要重写。 */
export function storedSummary(db: HubDB, g: ConversationGroup): Summary | null {
  const row = db.db.prepare("SELECT * FROM conversation_summaries WHERE id=?").get(g.id) as SummaryRow | undefined;
  if (!row || row.record_ids !== JSON.stringify(g.record_ids)) return null;
  return { title: row.title, summary: row.summary, points: JSON.parse(row.points) as string[] };
}
export function saveSummary(db: HubDB, g: ConversationGroup, s: Summary, at = new Date().toISOString()) {
  db.db.prepare("INSERT INTO conversation_summaries VALUES(?,?,?,?,?,?) ON CONFLICT(id) DO UPDATE SET record_ids=excluded.record_ids,title=excluded.title,summary=excluded.summary,points=excluded.points,created_at=excluded.created_at")
    .run(g.id, JSON.stringify(g.record_ids), s.title, s.summary, JSON.stringify(s.points), at);
}
/** 真删记录时连带删掉引用它的总结，下一轮按剩下的记录重写。 */
export function removeSummariesOf(db: HubDB, recordId: string | string[]) {
  const ids = JSON.stringify(Array.isArray(recordId) ? recordId : [recordId]);
  db.db.prepare("DELETE FROM conversation_summaries WHERE EXISTS(SELECT 1 FROM json_each(record_ids) WHERE value IN (SELECT value FROM json_each(?)))").run(ids);
}

export type SummaryState = "ready" | "waiting" | "short" | "private";
export function summaryState(g: ConversationGroup, turns: Turn[], summary: Summary | null, now = Date.now()): SummaryState {
  if (summary) return "ready";
  if (g.private) return "private";
  if (turns.reduce((n, t) => n + t.text.length, 0) < SUMMARY_MIN_CHARS) return "short";
  return "waiting";
}

/** 查看界面打开一条对话记录时用：它所在的整场对话、整理过的原文和总结。 */
export function conversationDetail(db: HubDB, recordId: string, now = Date.now()) {
  const r = db.db.prepare("SELECT t_start_ms FROM records WHERE id=? AND source='mac.audio'").get(recordId) as { t_start_ms: number } | undefined;
  if (!r) throw new InputError("不是对话记录");
  const g = conversationsIn(db, r.t_start_ms, r.t_start_ms).find(g => g.record_ids.includes(recordId))!;
  const turns = groupTurns(db, g);
  const summary = storedSummary(db, g);
  // 原文：每条记录现在的正文（有修正时用修正），给"查看原文"用。
  const records = g.record_ids.flatMap(id => {
    const row = db.db.prepare("SELECT id,t_start,t_start_ms,t_end,context,sensitivity,body FROM records WHERE id=?").get(id) as RecordRow | undefined;
    return row ? [{ id: row.id, t_start: row.t_start, t_end: row.t_end, body: bodyOf(db, row) }] : [];
  });
  return { id: g.id, record_ids: g.record_ids, start: new Date(g.start_ms).toISOString(), end: new Date(g.end_ms).toISOString(), app: g.app,
    state: summaryState(g, turns, summary, now), title: summary?.title ?? null, summary: summary?.summary ?? null, points: summary?.points ?? [], turns, records };
}

/** 列表用：每场对话的组成和标题（有总结时）。 */
export function conversationList(db: HubDB, from: number, to: number) {
  return conversationsIn(db, from, to).map(g => ({ id: g.id, record_ids: g.record_ids, start_ms: g.start_ms, end_ms: g.end_ms, app: g.app, title: storedSummary(db, g)?.title ?? null }));
}
