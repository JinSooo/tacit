import { toLocalIso } from "../../../packages/record/index.ts";
import { chatKey } from "../chat.ts";
import { groupConversations } from "../conversations.ts";
import type { HubDB } from "../db.ts";
import { unionSeconds } from "../durations.ts";
import { redactString } from "../redact.ts";
import { dayDisplayName, readDayEvidence, sampleDayEvidence, SKELETON_SOURCES, type DayReference, type UnnumberedEvidence } from "./day-evidence.ts";
import { excludedSession, requestOnly } from "./session-purpose.ts";
import { frameKey } from "./frames.ts";
import { MAX_DAY_SUMMARY_CHARS, MAX_REVIEW_CANDIDATES, MAX_REVIEW_SEGMENTS, type DayOutput } from "./prompts.ts";

const MINUTE = 60_000;
const MISC_SECONDS = 5 * 60;
const EVIDENCE_WINDOW = 2 * MINUTE;
const SESSION_SOURCES = new Set(["codex.session", "claude_code.session"]);
// 跨进窗口的记录最早从窗口前多久开始：录音、AI 会话批次都不超过 24 小时，留一倍余量；否则按结束时间找跨界记录要扫全部历史。
const LONGEST_RECORD = 48 * 60 * MINUTE;
const terse = (text: string, max: number) => Array.from(text.replace(/\s+/g, " ").trim()).slice(0, max).join("");

type ReviewRecord = DayReference & {
  start: number; end: number; lastActivity: number; key: string; thread: string | null; projectId: string | null; session: string | null;
  projectName: string | null;
  related?: ReviewRecord[]; app: string | null; chat: string | null; evidence: UnnumberedEvidence[];
};
type Kind = "thread" | "speech" | "chat" | "session" | "misc";
type Span = [number, number];
type Activity = {
  key: string; kind: Kind; projectId: string | null;
  start: number; end: number; records: ReviewRecord[];
};
type Piece = { activity: Activity; start: number; end: number };
type Candidate = Piece & { primary: ReviewRecord[]; seconds: number; spans: Span[] };
export interface ReviewItem {
  id: string; title: string; description: string; t_start: string; t_end: string;
  active_seconds: number; sources: string[]; evidence: DayReference[];
  apps: { source: string; app: string | null }[]; record_ids: string[]; project_id: string | null;
}
export type DraftItem = Omit<ReviewItem, "description" | "evidence"> & { excerpt: string; thread_id?: string };
export interface ReviewDetail {
  summary: string | null;
  timeline: { start: string; end: string; text: string }[];
  items: ReviewItem[];
  cutoff: string;
  // 撤下含这些记录的派生文字，包括依据里没直接引用的记录。
  record_ids: string[];
  omitted_record_ids: string[];
  polished_segments?: PolishedSegment[];
  overview_input?: string;
  overview_checked_ms?: number;
}

type PolishedSegment = {
  id: string; anchor: string; start: number; end: number;
  record_ids: string[]; dependencies: string[]; pending?: true;
};

// 采集成功不等于有值得阅读的内容。旧回顾在读取时也使用同一个筛选规则。
const CAPTURE_ONLY = new Set([
  "有 Codex 会话记录", "有 Claude Code 会话记录", "有浏览记录", "有前台窗口记录",
  "有应用使用记录", "有录音记录", "写了一条记录", "有聊天消息",
]);
export function isReadableReviewItem(item: { title?: unknown; description?: unknown }) {
  if (typeof item.title !== "string" || typeof item.description !== "string") return false;
  const text = item.description.trim().replace(/[。.!！]+$/u, "");
  return !!item.title.trim() && !!text && !CAPTURE_ONLY.has(text);
}

type DraftWindow = { cutoff?: number; covered: ReadonlySet<string>; includeRelated?: boolean };

function loadRecords(hub: HubDB, start: number, end: number, draft?: DraftWindow): ReviewRecord[] {
  type RawRow = {
    id: string; source: string; source_ref: string | null; title: string; t_start: string; t_start_ms: number; t_end: string | null;
    context: string | null; key: string | null; thread_id: string | null; project_id: string | null; project_name: string | null;
    body: string | null; corrected: number;
  };
  const cutoff = draft?.cutoff;
  const queryStart = cutoff === undefined ? start : Math.max(start, cutoff);
  const rows = hub.db.prepare<unknown[], RawRow>(`SELECT r.id,r.source,r.source_ref,r.title,r.t_start,r.t_start_ms,r.t_end,r.context,f.key,a.thread_id,t.project_id,p.name AS project_name,
    CASE WHEN r.source IN ('mac.screen','mac.browser','mac.app') THEN NULL ELSE COALESCE(c.body,r.body) END AS body,
    c.id IS NOT NULL AS corrected
    FROM records r
    LEFT JOIN frame_records fr ON fr.record_id=r.id LEFT JOIN frames f ON f.id=fr.frame_id
    LEFT JOIN assignments a ON a.frame_id=f.id LEFT JOIN threads t ON t.id=a.thread_id
    LEFT JOIN projects p ON p.id=t.project_id
    LEFT JOIN records c ON c.id=(SELECT cc.id FROM records cc WHERE cc.corrects=r.id AND cc.source='manual.correction'
      ORDER BY cc.t_start_ms DESC,cc.id DESC LIMIT 1)
    WHERE r.t_start_ms<? AND r.t_start_ms>=? AND (r.t_start_ms>=? OR (r.t_end IS NOT NULL AND julianday(r.t_end)>julianday(?)))
      AND r.sensitivity<>'private' AND COALESCE(c.sensitivity,'normal')<>'private'
      AND (r.source IN ('mac.screen','mac.browser','mac.app','mac.audio','codex.session','claude_code.session','mac.wechat','manual.note')
        OR (r.source NOT IN ('mac.shell','mac.git','mac.file','mac.clipboard','manual.agent','manual.correction')
          AND json_type(r.context,'$.chat')='text' AND json_extract(r.context,'$.extra.from_me') IN (0,1)))
    ORDER BY r.t_start_ms,r.id`).iterate(end, queryStart - LONGEST_RECORD, queryStart, new Date(queryStart).toISOString());
  const records: ReviewRecord[] = [];
  const excluded = new Set<string>();
  const windowStart = Math.max(start, cutoff ?? start);
  const evidenceStart = cutoff === undefined ? start : Math.max(start, cutoff + 1);
  for (const row of rows) {
    const context = row.context ? JSON.parse(row.context) as Parameters<typeof frameKey>[0]["context"] : undefined;
    const isSession = SESSION_SOURCES.has(row.source);
    const session = isSession && row.source_ref
      ? JSON.stringify([row.source, row.source_ref.split("#", 1)[0]]) : null;
    if (isSession && excludedSession(row.body ?? "", context)) excluded.add(session ?? row.id);
    const finish = Math.max(row.t_start_ms, Date.parse(row.t_end ?? "") || row.t_start_ms);
    if (cutoff !== undefined && (finish <= cutoff ||
      (row.t_start_ms >= cutoff && draft?.covered.has(row.id)))) continue;
    const key = row.key ?? frameKey({ id: row.id, source: row.source, source_ref: row.source_ref, context } as Parameters<typeof frameKey>[0]);
    const title = terse(redactString(row.title).text, 120) || "原始记录";
    const reference = { id: row.id, source: row.source, title, at: row.t_start };
    const evidence = readDayEvidence(reference, { source: row.source, t_start: row.t_start, t_end: row.t_end, context },
      row.body, !!row.corrected, evidenceStart, end);
    if (!evidence) continue;
    if (draft && !SKELETON_SOURCES.has(row.source) &&
      (!evidence.length || (isSession && !draft.includeRelated && !evidence.some(entry => entry.role === "user")))) continue;
    records.push({
      ...reference,
      start: Math.max(windowStart, row.t_start_ms), end: Math.min(end, finish),
      key, lastActivity: Math.min(end, finish), thread: row.thread_id, projectId: row.project_id, projectName: row.project_name, session, evidence,
      app: context?.app ? redactString(context.app).text : null, chat: context?.chat ? redactString(context.chat).text : null,
    });
  }
  // 草稿只读截止之后的记录；评测或发布检查的标记可能只在截止前的批次里，只为截止后出现的会话补查。
  if (queryStart > start) {
    const earlier = hub.db.prepare<[string, string, string, string, number, number], { body: string | null; context: string | null }>(`
      SELECT body,context FROM records WHERE source=? AND (source_ref=? OR substr(source_ref,1,length(?))=?)
        AND t_start_ms>=? AND t_start_ms<?`);
    for (const key of new Set(records.flatMap(r => r.session ? [r.session] : []))) {
      if (excluded.has(key)) continue;
      const [source, ref] = JSON.parse(key) as [string, string], prefix = `${ref}#`;
      for (const row of earlier.iterate(source, ref, prefix, prefix, start, queryStart)) {
        if (excludedSession(row.body ?? "", row.context ? JSON.parse(row.context) : undefined)) { excluded.add(key); break; }
      }
    }
  }
  const present = presenceRecords(records.filter(r => !excluded.has(r.session ?? r.id)), windowStart, end);
  return draft?.includeRelated ? present.filter(record => !record.key.startsWith("autonomous:")) : present;
}

/** 批次只有首末时刻：按实际跨度计，每条真实输入最多支持 30 分钟。 */
function presenceRecords(records: ReviewRecord[], dayStart: number, dayEnd: number): ReviewRecord[] {
  const result: ReviewRecord[] = [];
  for (const record of records) {
    if (!SESSION_SOURCES.has(record.source)) {
      // 聊天点先扩为在场窗口，统一用于裁决、覆盖率、排序与最终计时。
      const point = record.chat && !SKELETON_SOURCES.has(record.source) && record.source !== "mac.audio" && record.start === record.end;
      result.push(point ? { ...record, start: Math.max(dayStart, record.start - EVIDENCE_WINDOW),
        end: Math.min(dayEnd, record.end + EVIDENCE_WINDOW) } : record);
      continue;
    }
    const users = record.evidence.filter(e => e.role === "user");
    if (!users.length) {
      const initiator = result.findLast(r => SESSION_SOURCES.has(r.source) &&
        r.evidence.some(e => e.role === "user") &&
        (r.session && r.session === record.session || r.thread && r.thread === record.thread));
      if (initiator) {
        initiator.evidence.push(...record.evidence);
        (initiator.related ??= []).push(record);
      } else result.push({ ...record, key: `autonomous:${record.id}`, end: record.start });
      continue;
    }
    // within_batch 没有逐条时刻，不把占位 at 当成输入时刻。已知末条输入可支持末端的零时长点。
    const spans: Span[] = record.end - record.start <= users.length * 30 * MINUTE
      ? [[record.start, record.end]] : [];
    for (const user of spans.length ? [] : users) {
      const at = user.position === "within_batch" ? record.start : Math.max(record.start, Date.parse(user.at));
      const last = spans.at(-1);
      if (last && at <= last[1]) last[1] = Math.min(record.end, last[1] + 30 * MINUTE);
      else spans.push([at, Math.min(record.end, at + 30 * MINUTE)]);
    }
    for (const [start, end] of spans) result.push({ ...record,
      start: Math.max(dayStart, start), end: Math.min(dayEnd, end) });
  }
  return result.sort((a,b) => a.start-b.start);
}

function groupRecords(rows: ReviewRecord[], gap: number): Activity[] {
  const audio = groupConversations(rows.filter(r => r.source === "mac.audio")
    .map(r => ({ id: r.id, start_ms: r.start, end_ms: r.end, app: r.app, private: false })));
  const lookup = new Map(rows.map(record => [record.id, record]));
  const voices = new Map<string, { id: string; thread: string | null }>();
  for (const conversation of audio) {
    const threads = new Set(conversation.record_ids.flatMap(id => lookup.get(id)?.thread ?? []));
    const thread = threads.size === 1 ? [...threads][0]! : null;
    for (const id of conversation.record_ids) voices.set(id, { id: conversation.id, thread });
  }
  const projects = new Map(rows.flatMap(r => r.thread ? [[r.thread, r.projectId] as const] : []));
  const groups: Activity[] = [], open = new Map<string, Activity>();
  for (const row of rows) {
    const voice = voices.get(row.id), thread = voice ? voice.thread : row.thread;
    const kind = thread ? "thread" : voice ? "speech" : SESSION_SOURCES.has(row.source) ? "session"
      : row.chat && !SKELETON_SOURCES.has(row.source) ? "chat" : "misc";
    const key = row.key.startsWith("autonomous:") ? row.key : thread ? `thread:${thread}` : voice ? `speech:${voice.id}`
      : kind === "chat" ? `${row.source}:${chatKey(row.chat!)}`
      : kind === "session" ? (row.session ? `session:${row.session}` : `record:${row.id}`) : row.key;
    let group = open.get(key);
    if (!group || (row.start > group.end && (row.start > group.end + gap ||
      !hasCoverage([...group.records, row], group.start, row.end)))) {
      group = { key, kind, projectId: thread ? projects.get(thread) ?? null : null, start: row.start, end: row.end, records: [] };
      open.set(key, group); groups.push(group);
    }
    group.records.push(row);
    group.end = Math.max(group.end, row.end);
  }
  return groups;
}

function hasCoverage(records: ReviewRecord[], start: number, end: number) {
  if (end === start) return true;
  const support: Span[] = records.map(r => [Math.max(start, r.start), Math.min(end, r.end)]);
  return unionSeconds(support) * 1000 >= 0.6 * (end - start);
}

function inPiece(record: ReviewRecord, { activity, start, end }: Piece) {
  if (record.start !== record.end) return start === end
    ? record.start <= start && start < record.end
    : record.start < end && record.end > start;
  const at = record.start;
  if (start === end) return at === start;
  return start <= at && (at < end || (at === end && end === activity.end && activity.records.includes(record)));
}

function makeCandidate(piece: Piece): Candidate | null {
  const primary = piece.activity.records.filter(r => inPiece(r, piece));
  if (!primary.length) return null;
  const spans: Span[] = primary.map(r => [Math.max(r.start, piece.start), Math.min(r.end, piece.end)]);
  const end = spans.reduce((latest, s) => Math.max(latest, s[1]), piece.start);
  return { ...piece, primary, spans, seconds: unionSeconds(spans), start: spans[0]![0], end };
}

function candidatesIn(piece: Piece): Candidate[] {
  const whole = makeCandidate(piece);
  if (!whole) return [];
  if (hasCoverage(whole.primary, whole.start, whole.end)) return [whole];
  // 优先级裁决可能剪掉先前支撑时间空档的实录，剪完后按剩余的覆盖率重新分段。
  const groups: Activity[] = [];
  for (const r of whole.primary) {
    const start = Math.max(r.start, whole.start), end = Math.min(r.end, whole.end);
    const last = groups.at(-1);
    if (!last || start > last.end && !hasCoverage([...last.records, r], last.start, end)) {
      groups.push({ ...piece.activity, records: [r], start, end });
    } else {
      last.records.push(r);
      last.end = Math.max(last.end, end);
    }
  }
  return groups.flatMap(activity => {
    const candidate = makeCandidate({ activity, start: activity.start, end: activity.end });
    return candidate ? [candidate] : [];
  });
}

const eligible = (kind: Kind, records: ReviewRecord[], seconds: number) =>
  kind === "thread" || kind === "speech" || kind === "session" || (kind === "chat" && records.length > 1) || seconds >= MISC_SECONDS;
const byImportance = (a: { seconds: number; start: number }, b: { seconds: number; start: number }) =>
  b.seconds - a.seconds || a.start - b.start;

function rankWindows(r: ReviewRecord, activity: Activity): { span: Span; rank: number }[] {
  if (SKELETON_SOURCES.has(r.source)) return [{ span: [r.start, r.end], rank: 0 }];
  if (SESSION_SOURCES.has(r.source)) {
    // r 已裁成用户在场窗口；机器产出只提供文字依据。
    const windows: { span: Span; rank: number }[] = [
      { span: [r.start, r.end], rank: r.evidence.some(e => e.role === "assistant") ? 1 : 0 },
    ];
    if (r.evidence.some(e => e.role === "user")) windows.push(
      { span: [r.start, Math.min(r.end, r.start + EVIDENCE_WINDOW)], rank: 3 },
      { span: [Math.max(r.start, r.end - EVIDENCE_WINDOW), r.end], rank: 3 },
    );
    return windows;
  }
  const start = r.start === r.end ? activity.start : r.start;
  const end = r.start === r.end ? activity.end : r.end;
  return [{ span: [r.start, r.end], rank: 0 }, ...r.evidence.map(e => {
    const at = Date.parse(e.at);
    const span: Span = [Math.max(start, at - EVIDENCE_WINDOW), Math.min(end, at + EVIDENCE_WINDOW)];
    return { span, rank: e.role === "user" ? 3 : 2 };
  })];
}

function eventRank(r: ReviewRecord) { return r.evidence.some(e => e.role === "user") ? 3 : r.evidence.length ? 2 : 0; }

function splitOverlaps(activities: Activity[], accepts = eligible): Candidate[] {
  type Changes = { starts: Activity[]; ends: Activity[]; coverage: { activity: Activity; rank: number; delta: number }[] };
  const events = new Map<number, Changes>();
  const change = (at: number) => {
    let event = events.get(at);
    if (!event) { event = { starts: [], ends: [], coverage: [] }; events.set(at, event); }
    return event;
  };
  const points: Activity[] = [];
  for (const activity of activities) {
    const spans = activity.records.filter(r => r.end > r.start);
    if (!accepts(activity.kind, activity.records, unionSeconds(spans.map(r => [r.start, r.end])))) continue;
    if (activity.start === activity.end) { points.push(activity); continue; }
    change(activity.start).starts.push(activity);
    change(activity.end).ends.push(activity);
    for (const r of activity.records) {
      for (const { span: [from, to], rank } of rankWindows(r, activity)) {
        if (to <= from) continue;
        change(from).coverage.push({ activity, rank, delta: 1 });
        change(to).coverage.push({ activity, rank, delta: -1 });
      }
    }
  }

  const active = new Map<Activity, number[]>(), pieces: Piece[] = [];
  const boundaries = [...events.keys()].sort((a, b) => a - b);
  for (const [i, start] of boundaries.entries()) {
    const end = boundaries[i + 1];
    if (end === undefined) break;
    const { starts, ends, coverage } = events.get(start)!;
    for (const a of ends) active.delete(a);
    for (const a of starts) active.set(a, [0, 0, 0, 0]);
    for (const c of coverage) {
      const counts = active.get(c.activity);
      if (counts) counts[c.rank] = counts[c.rank]! + c.delta;
    }
    let winner: Activity | undefined, best = -2;
    const last = pieces.at(-1), incumbent = last?.end === start ? last.activity : undefined;
    for (const [a, counts] of active) {
      // 并行活动意图相同，保留较早开始的当前段，避免同级短活动反复打断正文。
      const score = counts.findLastIndex(n => n > 0);
      const preferred = a === incumbent || winner !== incumbent && winner &&
        (a.start < winner.start || (a.start === winner.start && a.key < winner.key));
      if (score > best || (score === best && preferred)) {
        winner = a; best = score;
      }
    }
    if (!winner) continue;
    if (last?.activity === winner && last.end === start) last.end = end;
    else pieces.push({ activity: winner, start, end });
  }

  const candidates = pieces.flatMap(candidatesIn).filter(a => accepts(a.activity.kind, a.primary, a.seconds));
  // 瞬时事件落在可见段内时作为来源和原文归入该段，否则同一时刻保留意图最强的事件。
  points.sort((a, b) => a.start - b.start || eventRank(b.records[0]!) - eventRank(a.records[0]!) || a.key.localeCompare(b.key));
  const covered = candidates.slice();
  let i = 0, lastPoint: number | undefined;
  for (const a of points) {
    while (covered[i] && covered[i]!.end <= a.start) i++;
    if (a.start === lastPoint || (covered[i] && covered[i]!.start <= a.start)) continue;
    candidates.push(makeCandidate({ activity: a, start: a.start, end: a.end })!);
    lastPoint = a.start;
  }
  return candidates.sort((a, b) => a.start - b.start);
}

function sameActivity(a: Candidate, b: Candidate) {
  return a.activity.key === b.activity.key && ["thread", "session", "chat"].includes(a.activity.kind);
}

function canMerge(a: Candidate, b: Candidate, gap: number) {
  return sameActivity(a, b) && b.start - a.end <= gap &&
    unionSeconds([...a.spans, ...b.spans]) * 1000 >= 0.6 * (b.end - a.start);
}

function mergedCandidate(a: Candidate, b: Candidate): Candidate {
  const primary = [...new Set([...a.primary, ...b.primary])], spans = [...a.spans, ...b.spans];
  return { ...a, end: b.end, primary, spans, seconds: unionSeconds(spans),
    activity: { ...a.activity, start: a.start, end: b.end, records: primary } };
}

function mergeAdjacent(candidates: Candidate[], gap: number) {
  // 每次优先合并最短的一对，合并后重新检查两侧，直到没有合规的相邻段。
  for (;;) {
    let merge = -1, shortest = Infinity;
    for (let i = 0; i + 1 < candidates.length; i++) {
      const a = candidates[i]!, b = candidates[i + 1]!;
      if (a.seconds + b.seconds >= shortest || !canMerge(a, b, gap)) continue;
      merge = i; shortest = a.seconds + b.seconds;
    }
    if (merge < 0) break;
    candidates.splice(merge, 2, mergedCandidate(candidates[merge]!, candidates[merge + 1]!));
  }
  return candidates;
}

function mergedDescription(preferred: string, other: string) {
  const sentences = (text: string) => text.split(/(?<=[。！？!?])|(?<=\.)\s+/u).map(s => s.trim()).filter(Boolean);
  return (preferred === other ? sentences(preferred).slice(0, 2)
    : [sentences(preferred)[0], sentences(other)[0]]).filter(Boolean).join(" ");
}

function limitCandidates<T extends Candidate>(candidates: T[], leadingActivity: string | undefined, limit = MAX_REVIEW_CANDIDATES) {
  if (candidates.length <= limit) return candidates;
  const ranked = [...candidates].sort(byImportance);
  const projects = new Set<string>(), selected = new Set<T>();
  for (const seed of [ranked[0], ranked.find(c => c.activity.key === leadingActivity)]) {
    if (!seed) continue;
    selected.add(seed);
    if (seed.activity.projectId) projects.add(seed.activity.projectId);
  }
  for (const candidate of ranked) {
    const project = candidate.activity.projectId;
    if (!project || projects.has(project)) continue;
    projects.add(project);
    selected.add(candidate);
    if (selected.size === limit) return candidates.filter(c => selected.has(c));
  }
  for (const candidate of ranked) {
    selected.add(candidate);
    if (selected.size === limit) break;
  }
  return candidates.filter(c => selected.has(c));
}

function evidenceInPiece(entry: UnnumberedEvidence, record: ReviewRecord, segment: Candidate) {
  const at = Date.parse(entry.at), { start, end } = segment;
  if (SESSION_SOURCES.has(record.source)) return true;
  if (entry.position === "within_batch" && (record.start < start || record.end > end)) return false;
  // 末消息正好等于切分点时只归给结束在该处的一段，下一段使用自己的开始依据。
  if (entry.position === "last" && record.start !== record.end) return at > start && at <= end;
  return at >= start && (at < end || (at === end && record.start === record.end && segment.primary.includes(record)));
}

function longerConversationBudget(segments: Candidate[]) {
  const extras = new Map<Candidate, number>();
  let available = 24;
  for (const a of [...segments].sort(byImportance)) {
    if (!available || a.seconds < 20 * 60) break;
    const hasConversation = a.primary.some(r => r.source === "mac.audio" || r.evidence.some(e => e.role === "other"));
    if (!hasConversation) continue;
    const bonus = Math.min(available, a.seconds >= 40 * 60 ? 4 : 2);
    extras.set(a, bonus);
    available -= bonus;
  }
  return extras;
}

function cutCandidates(rows: ReviewRecord[], gap: number, accepts = eligible) {
  const sessionThreads = new Set(rows.filter(r => SESSION_SOURCES.has(r.source)).flatMap(r => r.thread ?? []));
  return splitOverlaps(groupRecords(rows.filter(r =>
    !SKELETON_SOURCES.has(r.source) || !r.thread || !sessionThreads.has(r.thread)), gap), accepts);
}

function segmentId(a: Candidate) {
  const anchor = a.primary[0]!;
  return a.start > Date.parse(anchor.at) ? `${anchor.id}:${a.start}` : anchor.id;
}

function recordMembership(a: Candidate, overlapping: ReviewRecord[]) {
  return overlapping.filter(r => !a.activity.projectId || !r.projectId || r.projectId === a.activity.projectId);
}

function overlappingRecords(rows: ReviewRecord[], candidate: Candidate) {
  return [...new Set(rows.filter(r => inPiece(r, candidate)).flatMap(r => [r, ...(r.related ?? [])]))]
    .sort((x,y) => Date.parse(x.at)-Date.parse(y.at) || x.id.localeCompare(y.id));
}

function reviewSegments(rows: ReviewRecord[], selected: Candidate[], evidenceLimit?: number) {
  const projectNames = new Map(rows.flatMap(r => r.projectId && r.projectName ? [[r.projectId, r.projectName] as const] : []));
  const baseLimit = evidenceLimit ?? Math.max(4, Math.floor(120 / Math.max(1, selected.length)));
  const extraEvidence = longerConversationBudget(selected);
  return selected.map((a, i) => {
    const limit = baseLimit + (extraEvidence.get(a) ?? 0);
    const overlapping = overlappingRecords(rows, a);
    const apps = [...new Map(overlapping.map(({ source, app }) => [JSON.stringify([source, app]), { source, app }])).values()];
    const records = recordMembership(a, overlapping);
    const primaryIds = new Set(a.primary.map(r => r.id));
    const entries = [...new Map(records.flatMap(r => r.evidence.filter(entry => evidenceInPiece(entry, r, a))).map(e => [JSON.stringify([e.reference.id,e.at,e.role,e.text]),e])).values()];
    const direct = entries.filter(e => primaryIds.has(e.reference.id) || a.primary.some(r => r.related?.some(related => related.id === e.reference.id)));
    const directEntries = new Set(direct);
    const secondary = direct.length ? sampleDayEvidence(entries.filter(e => !directEntries.has(e)),
      Math.min(2, Math.floor(limit / 3))).map(e => ({ ...e, secondary: true as const })) : [];
    const evidence = [...sampleDayEvidence(direct, limit - secondary.length), ...secondary]
      .sort((a, b) => Date.parse(a.at) - Date.parse(b.at))
      .map((e, index) => ({ ...e, key: `r${index + 1}` }));
    const projectName = a.activity.projectId ? projectNames.get(a.activity.projectId) : undefined;
    return { ...a, id: segmentId(a), dependencies: [...new Set(overlapping.map(r => r.id))], kind: a.activity.kind, key: `a${i + 1}`, projectName, records, apps, evidence };
  });
}

export function reviewPlan(hub: HubDB, start: number, end: number, gapMinutes = 30) {
  const rows = loadRecords(hub, start, end);
  const gap = gapMinutes * MINUTE;
  const allCandidates = cutCandidates(rows, gap);
  const candidates = allCandidates.filter(a => a.primary.some(r =>
    r.evidence.some(entry => evidenceInPiece(entry, r, a))));
  const candidateCount = allCandidates.length, evidenceCount = candidates.length;
  const activitySeconds = new Map<string, number>();
  for (const c of candidates) activitySeconds.set(c.activity.key, (activitySeconds.get(c.activity.key) ?? 0) + c.seconds);
  const leadingActivity = [...activitySeconds.entries()].sort((a, b) => b[1] - a[1])[0]?.[0];
  mergeAdjacent(candidates, gap);
  const selected = limitCandidates(candidates, leadingActivity);
  const segments = reviewSegments(rows, selected);
  const dependencyRecordIds = new Set(segments.flatMap(segment => segment.dependencies));
  const selectedSet = new Set(selected), visibleIds = new Set(segments.flatMap(s => s.records.map(r => r.id)));
  const withoutEvidence = allCandidates.filter(a => !a.primary.some(r =>
    r.evidence.some(entry => evidenceInPiece(entry, r, a))));
  const omitted = [...withoutEvidence, ...candidates.filter(a => !selectedSet.has(a))]
    .sort((a, b) => a.start - b.start);
  const omittedRecordIds = [...new Set([...rows.filter(r => !visibleIds.has(r.id)).map(r => r.id), ...omitted.flatMap(a => recordMembership(a, rows.filter(r => inPiece(r, a)))
    .flatMap(r => visibleIds.has(r.id) ? [] : [r.id]))])];
  return {
    segments, omittedRecordIds, dependencyRecordIds: [...dependencyRecordIds],
    diagnostics: { candidateCount, mergedCount: evidenceCount - candidates.length, omittedCount: omitted.length,
      longestActivityRetained: !leadingActivity || selected.some(c => c.activity.key === leadingActivity),
      fallbackCount: segments.filter(s => !s.evidence.length).length },
  };
}

const draftSpeech = (entry: UnnumberedEvidence) => entry.role !== "assistant" && !requestOnly(entry.text);

const SEGMENT_QUIET_MS = 30 * MINUTE;
const POLISH_EVIDENCE_PER_SEGMENT = 6;

function draftCandidates(rows: ReviewRecord[]) {
  // 单条实质聊天或手记也可实时显示，无需等到模型整理的候选门槛。
  const candidates = cutCandidates(rows, SEGMENT_QUIET_MS, (_kind, records) =>
    records.some(r => r.evidence.some(draftSpeech))).filter(a => a.primary.some(r =>
      r.evidence.some(e => draftSpeech(e) && evidenceInPiece(e, r, a))));
  return mergeAdjacent(candidates, SEGMENT_QUIET_MS);
}

function draftItem(a: Candidate, id: string, recordIds: string[]): DraftItem {
  const speaking = a.primary.flatMap(r => {
    const entries = r.evidence.filter(e => draftSpeech(e) && evidenceInPiece(e, r, a));
    return entries.length ? [{ record: r, entries }] : [];
  });
  const primary = speaking[0]!.record;
  const entries = speaking.flatMap(s => s.entries);
  const quote = entries.find(e => e.role === "user") ?? entries[0]!;
  const sentence = redactString(quote.text).text.split(/(?<=[。！？!?])|(?<=\.)\s+|\r?\n/u, 1)[0]!;
  const apps = [...new Map(speaking.map(({ record: { source, app } }) =>
    [JSON.stringify([source, app]), { source, app }])).values()];
  const threads = new Set(speaking.flatMap(({ record }) => record.thread ?? []));
  const title = primary.source === "mac.audio" ? "一场对话"
    : primary.chat || (SESSION_SOURCES.has(primary.source) ? primary.title : primary.app || primary.title);
  return {
    id, t_start: toLocalIso(a.start), t_end: toLocalIso(a.end), active_seconds: a.seconds,
    title, excerpt: terse(sentence, 60), sources: [...new Set(apps.map(app => app.source))], apps,
    record_ids: recordIds, project_id: a.activity.projectId,
    ...(threads.size === 1 ? { thread_id: [...threads][0]! } : {}),
  };
}

export function dayDrafts(hub: HubDB, start: number, end: number, window: DraftWindow): DraftItem[] {
  if (window.cutoff !== undefined && window.cutoff >= end - 1) return [];
  const rows = loadRecords(hub, start, end, { ...window, includeRelated: window.cutoff === undefined });
  return draftCandidates(rows).map(a => {
    const overlapping = rows.filter(r => inPiece(r, a)).flatMap(r => [r, ...(r.related ?? [])]);
    return draftItem(a, segmentId(a), [...new Set(recordMembership(a, overlapping).map(r => r.id))]);
  });
}

const sameIds = (a: string[], b: string[]) => a.length === b.length && a.every(id => b.includes(id));

/** Cut the full day locally. Only pending, quiet candidates get evidence numbered for the model. */
export function incrementalReview(hub: HubDB, start: number, now: number, detail: ReviewDetail | null) {
  const rows = loadRecords(hub, start, now + 1, { covered: new Set(), includeRelated: true });
  const previous = detail?.polished_segments ?? (detail?.items ?? []).filter(item => Array.isArray(item.record_ids))
    .map(item => ({
      id: item.id, anchor: item.id, start: Date.parse(item.t_start), end: Date.parse(item.t_end),
      record_ids: item.record_ids, dependencies: item.record_ids,
    } satisfies PolishedSegment));
  const candidates = draftCandidates(rows).map(candidate => {
    const overlapping = overlappingRecords(rows, candidate);
    const anchor = segmentId(candidate);
    const snapshot: PolishedSegment = {
      id: anchor, anchor, start: candidate.start, end: candidate.end,
      record_ids: [...new Set(recordMembership(candidate, overlapping).map(r => r.id))],
      dependencies: [...new Set(overlapping.map(r => r.id))],
    };
    return { candidate, snapshot };
  });
  // Exact anchors win even when a late record splits a segment. Otherwise preserve the
  // old ID on the first overlapping piece with surviving members (including a deleted anchor).
  const matched = new Map<PolishedSegment, PolishedSegment>(), unused = new Set(previous);
  const byId = new Map(previous.map(entry => [entry.id, entry]));
  const byAnchor = new Map(previous.map(entry => [entry.anchor, entry]));
  for (const index of [byId, byAnchor]) {
    for (const { snapshot } of candidates) {
      const old = index.get(snapshot.anchor);
      if (old && unused.has(old) && !matched.has(snapshot)) {
        matched.set(snapshot, old);
        unused.delete(old);
      }
    }
  }
  for (const { snapshot } of candidates) {
    if (matched.has(snapshot)) continue;
    const old = [...unused].find(entry => entry.start <= snapshot.end && entry.end >= snapshot.start &&
      entry.record_ids.some(id => snapshot.record_ids.includes(id)));
    if (old) { matched.set(snapshot, old); unused.delete(old); }
  }

  const preserved: PolishedSegment[] = [], pending: typeof candidates = [];
  const projects = new Map<string, string | null>();
  const legacyOmitted = new Set(detail?.polished_segments ? [] : detail?.omitted_record_ids);
  for (const entry of candidates) {
    const { snapshot } = entry, old = matched.get(snapshot);
    if (old) snapshot.id = old.id;
    if ((old && !old.pending && old.start === snapshot.start && old.end === snapshot.end &&
      sameIds(old.record_ids, snapshot.record_ids) && sameIds(old.dependencies, snapshot.dependencies)) ||
      (!old && snapshot.record_ids.every(id => legacyOmitted.has(id)))) {
      preserved.push(snapshot);
      projects.set(snapshot.id, entry.candidate.activity.projectId);
    } else {
      if (old) snapshot.pending = true;
      pending.push(entry);
    }
  }
  const keep = new Set(preserved.map(segment => segment.id));
  const items = (detail?.items ?? []).filter(item => keep.has(item.id)).map(item => {
    const project_id = projects.get(item.id) ?? null;
    return project_id === item.project_id ? item : { ...item, project_id };
  });
  const covered = new Set(candidates.flatMap(({ snapshot }) => snapshot.record_ids));
  const otherIds = hub.db.prepare<[number, number], { id: string }>(
    "SELECT id FROM records WHERE t_start_ms>=? AND t_start_ms<? ORDER BY t_start_ms,id"
  ).all(start, now + 1).map(row => row.id).filter(id => !covered.has(id));
  const omittedIds = (items: ReviewItem[], snapshots: PolishedSegment[]) => {
    const visible = new Set([...items.flatMap(item => item.record_ids), ...pending
      .filter(({ snapshot }) => !snapshots.includes(snapshot)).flatMap(({ snapshot }) => snapshot.record_ids)]);
    return [...new Set([...otherIds, ...snapshots.flatMap(segment => segment.record_ids)])].filter(id => !visible.has(id));
  };
  const quietBefore = now - SEGMENT_QUIET_MS;
  const ready = pending.filter(({ candidate }) => candidate.primary.every(record =>
    record.lastActivity < quietBefore && (record.related ?? []).every(related => related.lastActivity < quietBefore)))
    .slice(0, MAX_REVIEW_CANDIDATES);

  return {
    items, ready, preserved, pending, omittedIds,
    drafts: () => pending.map(({ candidate, snapshot }) => draftItem(candidate, snapshot.id, snapshot.record_ids)),
    segments: () => reviewSegments(rows, ready.map(entry => entry.candidate), POLISH_EVIDENCE_PER_SEGMENT)
      .map((segment, index) => ({ ...segment, id: ready[index]!.snapshot.id })),
  };
}

export function reviewInput(hub: HubDB, start: number, end: number, gapMinutes = 30) {
  return reviewPlan(hub, start, end, gapMinutes).segments;
}

type ReviewSegment = ReturnType<typeof reviewInput>[number];
export function reviewMaterial(segments: ReviewSegment[]) {
  const previous = new Map<string, string>();
  return segments.filter(a => a.evidence.length).map(a => {
    const continues = previous.get(a.activity.key);
    previous.set(a.activity.key, a.key);
    return {
      key: a.key, kind: a.kind, start: toLocalIso(a.start).slice(11, 16), continues,
      project: dayDisplayName(a.projectName, MAX_DAY_SUMMARY_CHARS) ?? null, active_minutes: Math.round(a.seconds / 60),
      summary_eligible: a.seconds > 0,
      evidence: a.evidence.map(({ reference: _reference, position, ...entry }) =>
        ({ ...entry, key: `${a.key}:${entry.key}`, ...(position === "within_batch" ? { at: undefined } : {}) })),
    };
  });
}

const singleLine = (text: string, limit: number) => {
  const line = text.trim();
  return line && Array.from(line).length <= limit && !/[\r\n]/.test(line) ? line : null;
};

function summaryLine(text: string): string {
  const line = redactString(text).text.replace(/\s*[\r\n\u2028\u2029]+\s*/gu, " ").trim();
  const characters = Array.from(line);
  if (characters.length <= MAX_DAY_SUMMARY_CHARS) return line;
  const prefix = characters.slice(0, MAX_DAY_SUMMARY_CHARS);
  const lastSentence = prefix.findLastIndex((char, index) =>
    /[。！？!?]/u.test(char) || char === "." && /\s/u.test(characters[index + 1] ?? ""));
  return prefix.slice(0, lastSentence === -1 ? prefix.length : lastSentence + 1).join("").trimEnd();
}

function modelItem(a: ReviewSegment, candidate: DayOutput["items"][number] | undefined) {
  if (a.evidence.length && a.evidence.every(e => e.role === "user" && requestOnly(e.text))) return null;
  if (!candidate) return null;
  const title = singleLine(redactString(candidate.title).text, 20);
  const description = singleLine(redactString(candidate.description).text, 160);
  if (!title || !description || !candidate.refs.length || !isReadableReviewItem({ title, description })) return null;
  // 个别引用编号写坏时只丢那个引用；没有一条可用的直接依据才整段不收。
  const references = candidate.refs.flatMap(key => a.evidence.find(entry => `${a.key}:${entry.key}` === key) ?? []);
  if (!references.some(entry => !entry.secondary)) return null;
  const evidence = [...new Map(references.map(entry => [entry.reference.id, entry.reference])).values()]
    .sort((x, y) => Date.parse(x.at) - Date.parse(y.at));
  return { title, description, evidence };
}

function reviewResults(segments: ReviewSegment[], output: DayOutput, warn: (activity: string) => void) {
  const written = new Map(output.items.map(item => [item.activity, item]));
  const omissions = new Map((output.omissions ?? []).map(item => [item.activity, item]));
  const result = segments.flatMap(a => {
    const item = written.get(a.key), omission = omissions.get(a.key);
    const excluded = !item || item.content === "request_only" || item.content === "empty";
    if (excluded && omission && ["request_only", "empty", "excluded_session"].includes(omission.reason)) return [];
    // 未说明、未知理由或旧 content 标签均不能静默丢弃。有文字则按结果校验，否则报警并保留原文。
    if (excluded) warn(a.key);
    const model = modelItem(a, item ?? (omission ? { ...omission, content: "result" } : undefined));
    if (!model) return [];
    const cited = new Set(model.evidence.map(r => r.id));
    const apps = [...new Map(a.records.filter(r => cited.has(r.id))
      .map(({ source, app }) => [JSON.stringify([source, app]), { source, app }])).values()];
    const segment: ReviewItem = {
      id: a.id, title: model.title, description: model.description, t_start: toLocalIso(a.start), t_end: toLocalIso(a.end),
      active_seconds: a.seconds, sources: [...new Set(apps.map(r => r.source))], evidence: model.evidence,
      apps, record_ids: [...new Set(a.records.map(r => r.id))], project_id: a.activity.projectId,
    };
    return [{ a, segment, summaryKeys: !excluded && a.seconds > 0 ? [a.key] : [] }];
  });
  if (output.items.some(item => item.content !== "request_only" && item.content !== "empty") && !result.length) return null;
  return result;
}

export function composePolish(segments: ReviewSegment[], output: DayOutput, warn: (activity: string) => void) {
  return reviewResults(segments, output, warn)?.map(({ segment }) => segment) ?? null;
}

export function composeReview(segments: ReviewSegment[], output: DayOutput, dayEnd: number, cutoff: string,
  omitted: string[], dependencies: string[], warn: (activity: string) => void = () => {}): ReviewDetail | null {
  let result = reviewResults(segments, output, warn);
  if (!result) return null;
  // 模型省略中间候选后可能产生新的相邻段；同事项按相同规则兜底，不凭项目猜事项。
  for (let i = 0; i + 1 < result.length;) {
    const x = result[i]!, y = result[i + 1]!;
    if (!canMerge(x.a, y.a, 30 * MINUTE)) { i++; continue; }
    const preferred = x.a.seconds >= y.a.seconds ? x.segment : y.segment;
    const other = preferred === x.segment ? y.segment : x.segment;
    x.a = { ...x.a, ...mergedCandidate(x.a, y.a) };
    const apps = [...new Map([...x.segment.apps, ...y.segment.apps].map(a => [JSON.stringify(a), a])).values()];
    x.segment = { ...x.segment, title: preferred.title,
      description: mergedDescription(preferred.description, other.description),
      t_end: y.segment.t_end, active_seconds: x.a.seconds, apps,
      sources: [...new Set([...x.segment.sources, ...y.segment.sources])],
      record_ids: [...new Set([...x.segment.record_ids, ...y.segment.record_ids])],
      evidence: [...new Map([...x.segment.evidence, ...y.segment.evidence].map(e => [e.id, e])).values()] };
    x.summaryKeys.push(...y.summaryKeys);
    result.splice(i + 1, 1);
    // 合并后的覆盖率可能让前一对也满足条件。
    i = Math.max(0, i - 1);
  }
  const activitySeconds = new Map<string, number>();
  for (const { a } of result) activitySeconds.set(a.activity.key, (activitySeconds.get(a.activity.key) ?? 0) + a.seconds);
  const leadingActivity = [...activitySeconds.entries()].sort((a,b) => b[1]-a[1])[0]?.[0];
  const selected = new Set(limitCandidates(result.map(r => ({ ...r.a, result: r })), leadingActivity, MAX_REVIEW_SEGMENTS).map(r => r.result));
  result = result.filter(r => selected.has(r));
  const highlight = output.highlight;
  const refs = !highlight ? [] : "activities" in highlight ? highlight.activities : [highlight.activity];
  const main = result.some(({ summaryKeys }) => summaryKeys.some(key => refs.includes(key)));
  const projectSeconds = new Map<string, number>();
  for (const { a } of result) {
    const key = a.activity.projectId ?? a.activity.key;
    projectSeconds.set(key, (projectSeconds.get(key) ?? 0) + a.seconds);
  }
  const longest = result.filter(r => r.a.seconds > 0).sort((x,y) =>
    (projectSeconds.get(y.a.activity.projectId ?? y.a.activity.key) ?? 0) -
    (projectSeconds.get(x.a.activity.projectId ?? x.a.activity.key) ?? 0) || byImportance(x.a,y.a))[0]?.segment;
  const summary = (main && highlight && summaryLine(highlight.text)) || longest?.title || null;
  const timeline = result.map(({ a, segment }) => ({
    start: toLocalIso(a.start).slice(11, 16), end: a.end === dayEnd ? "24:00" : toLocalIso(a.end).slice(11, 16), text: segment.title,
  })).filter(chapter => chapter.start !== chapter.end);
  const items = result.map(({ segment }) => segment);
  const visible = new Set(items.flatMap(item => item.record_ids));
  const omitted_record_ids = [...new Set([...omitted, ...segments.flatMap(a => a.records.map(r => r.id))])]
    .filter(id => !visible.has(id));
  const record_ids = [...new Set([...dependencies, ...omitted_record_ids])];
  return { summary, timeline, items, cutoff, record_ids, omitted_record_ids };
}
