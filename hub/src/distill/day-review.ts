import { toLocalIso } from "../../../packages/record/index.ts";
import { chatKey } from "../chat.ts";
import { groupConversations } from "../conversations.ts";
import type { HubDB } from "../db.ts";
import { unionSeconds } from "../durations.ts";
import { redactString } from "../redact.ts";
import { readDayEvidence, sampleDayEvidence, SKELETON_SOURCES, type DayReference, type UnnumberedEvidence } from "./day-evidence.ts";
import { frameKey } from "./frames.ts";
import { MAX_REVIEW_SEGMENTS, type DayOutput } from "./prompts.ts";

const MINUTE = 60_000;
const MISC_SECONDS = 5 * 60;
const EVIDENCE_WINDOW = 2 * MINUTE;
const SESSION_SOURCES = new Set(["codex.session", "claude_code.session"]);
const terse = (text: string, max: number) => Array.from(text.replace(/\s+/g, " ").trim()).slice(0, max).join("");

type ReviewRecord = DayReference & {
  start: number; end: number; key: string; thread: string | null; projectId: string | null; session: string | null;
  related?: ReviewRecord[]; app: string | null; chat: string | null; evidence: UnnumberedEvidence[];
};
type Kind = "thread" | "speech" | "chat" | "session" | "misc";
type Span = [number, number];
type Activity = {
  key: string; kind: Kind; projectId: string | null;
  start: number; end: number; records: ReviewRecord[];
};
type Piece = { activity: Activity; start: number; end: number };
type Candidate = Piece & { primary: ReviewRecord[]; seconds: number };
export interface ReviewItem {
  id: string; title: string; description: string; t_start: string; t_end: string;
  active_seconds: number; sources: string[]; evidence: DayReference[];
  apps: { source: string; app: string | null }[]; record_ids: string[]; project_id: string | null;
}
export interface ReviewDetail {
  summary: string | null;
  timeline: { start: string; end: string; text: string }[];
  items: ReviewItem[];
  cutoff: string;
  // 撤下含这些记录的派生文字，包括依据里没直接引用的记录。
  record_ids: string[];
  omitted_record_ids: string[];
}

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

function loadRecords(hub: HubDB, start: number, end: number): ReviewRecord[] {
  type RawRow = {
    id: string; source: string; source_ref: string | null; title: string; t_start: string; t_start_ms: number; t_end: string | null;
    context: string | null; key: string | null; thread_id: string | null; project_id: string | null;
    body: string | null; corrected: number;
  };
  const rows = hub.db.prepare<unknown[], RawRow>(`SELECT r.id,r.source,r.source_ref,r.title,r.t_start,r.t_start_ms,r.t_end,r.context,f.key,a.thread_id,t.project_id,
    CASE WHEN r.source IN ('mac.screen','mac.browser','mac.app') THEN NULL ELSE COALESCE(c.body,r.body) END AS body,
    c.id IS NOT NULL AS corrected
    FROM records r
    LEFT JOIN frame_records fr ON fr.record_id=r.id LEFT JOIN frames f ON f.id=fr.frame_id
    LEFT JOIN assignments a ON a.frame_id=f.id LEFT JOIN threads t ON t.id=a.thread_id
    LEFT JOIN records c ON c.id=(SELECT cc.id FROM records cc WHERE cc.corrects=r.id AND cc.source='manual.correction'
      ORDER BY cc.t_start_ms DESC,cc.id DESC LIMIT 1)
    WHERE r.t_start_ms<? AND (r.t_start_ms>=? OR (r.t_end IS NOT NULL AND julianday(r.t_end)>julianday(?)))
      AND r.sensitivity<>'private' AND COALESCE(c.sensitivity,'normal')<>'private'
      AND (r.source IN ('mac.screen','mac.browser','mac.app','mac.audio','codex.session','claude_code.session','mac.wechat','manual.note')
        OR (r.source NOT IN ('mac.shell','mac.git','mac.file','mac.clipboard','manual.agent','manual.correction')
          AND json_type(r.context,'$.chat')='text' AND json_extract(r.context,'$.extra.from_me') IN (0,1)))
    ORDER BY r.t_start_ms,r.id`).iterate(end, start, new Date(start).toISOString());
  const records: ReviewRecord[] = [];
  for (const row of rows) {
    const context = row.context ? JSON.parse(row.context) as Parameters<typeof frameKey>[0]["context"] : undefined;
    const key = row.key ?? frameKey({ id: row.id, source: row.source, source_ref: row.source_ref, context } as Parameters<typeof frameKey>[0]);
    const title = terse(redactString(row.title).text, 120) || "原始记录";
    const reference = { id: row.id, source: row.source, title, at: row.t_start };
    const evidence = readDayEvidence(reference, { source: row.source, t_start: row.t_start, t_end: row.t_end, context },
      row.body, !!row.corrected, start, end);
    const session = SESSION_SOURCES.has(row.source) && row.source_ref
      ? JSON.stringify([row.source, row.source_ref.split("#", 1)[0]]) : null;
    if (!evidence) continue;
    records.push({
      ...reference,
      start: Math.max(start, row.t_start_ms), end: Math.min(end, Math.max(row.t_start_ms, Date.parse(row.t_end ?? "") || row.t_start_ms)),
      key, thread: row.thread_id, projectId: row.project_id, session, evidence,
      app: context?.app ? redactString(context.app).text : null, chat: context?.chat ? redactString(context.chat).text : null,
    });
  }
  return presenceRecords(records, start, end);
}

/** Imported batches lack individual timestamps. Only surviving user-message anchors support presence.
 * Assistant/goal continuation contributes evidence, never wall-clock duration. */
function presenceRecords(records: ReviewRecord[], dayStart: number, dayEnd: number): ReviewRecord[] {
  const result: ReviewRecord[] = [];
  for (const record of records) {
    if (!SESSION_SOURCES.has(record.source)) { result.push(record); continue; }
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
    const anchors = [...new Set(users.map(e => Date.parse(e.at)))].sort((a,b) => a-b);
    for (const [i, at] of anchors.entries()) {
      const next = anchors[i + 1] ?? Infinity;
      const evidence = record.evidence.filter(e => {
        const time = Date.parse(e.at);
        return i === 0 ? time < next : time >= at && time < next;
      });
      result.push({ ...record, start: Math.max(dayStart, at - EVIDENCE_WINDOW),
        end: Math.min(dayEnd, at + EVIDENCE_WINDOW), evidence });
    }
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
      : kind === "chat" ? `${row.source}:${chatKey(row.chat!)}` : row.key;
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
  const support: Span[] = records.map(r => {
    // 消息没有时长。带时间的聊天事件可支持相邻消息的连续性，界面仍按原始时长计。
    const point = r.end === r.start && r.chat && r.evidence.length;
    return [Math.max(start, r.start - (point ? EVIDENCE_WINDOW : 0)),
      Math.min(end, r.end + (point ? EVIDENCE_WINDOW : 0))];
  });
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
  return { ...piece, primary, seconds: unionSeconds(spans), start: spans[0]![0], end };
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

const eligible = (kind: Kind, count: number, seconds: number) =>
  kind === "thread" || kind === "speech" || kind === "session" || (kind === "chat" && count > 1) || seconds >= MISC_SECONDS;
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

function splitOverlaps(activities: Activity[]): Candidate[] {
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
    if (!eligible(activity.kind, activity.records.length, unionSeconds(spans.map(r => [r.start, r.end])))) continue;
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

  const candidates = pieces.flatMap(candidatesIn).filter(a => eligible(a.activity.kind, a.primary.length, a.seconds));
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

function mergeAdjacent(candidates: Candidate[], gap: number) {
  while (candidates.length > MAX_REVIEW_SEGMENTS) {
    let merge = -1, shortest = Infinity;
    for (let i = 0; i + 1 < candidates.length; i++) {
      const a = candidates[i]!, b = candidates[i + 1]!;
      if (a.activity.key !== b.activity.key || a.seconds + b.seconds >= shortest) continue;
      if (b.start - a.end > gap || !hasCoverage([...a.primary, ...b.primary], a.start, b.end)) continue;
      merge = i; shortest = a.seconds + b.seconds;
    }
    if (merge < 0) break;
    const a = candidates[merge]!, b = candidates[merge + 1]!;
    const activity = { ...a.activity, start: a.start, end: b.end,
      records: [...new Set([...a.primary, ...b.primary])] };
    candidates.splice(merge, 2, makeCandidate({ activity, start: a.start, end: b.end })!);
  }
  return candidates;
}

function limitCandidates(candidates: Candidate[], leadingActivity: string | undefined) {
  if (candidates.length <= MAX_REVIEW_SEGMENTS) return candidates;
  const ranked = [...candidates].sort(byImportance);
  const projects = new Set<string>(), selected = new Set<Candidate>();
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
    if (selected.size === MAX_REVIEW_SEGMENTS) return candidates.filter(c => selected.has(c));
  }
  for (const candidate of ranked) {
    selected.add(candidate);
    if (selected.size === MAX_REVIEW_SEGMENTS) break;
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

export function reviewPlan(hub: HubDB, start: number, end: number, gapMinutes = 30) {
  const rows = loadRecords(hub, start, end);
  const gap = gapMinutes * MINUTE;
  const sessionThreads = new Set(rows.filter(r => SESSION_SOURCES.has(r.source)).flatMap(r => r.thread ?? []));
  const allCandidates = splitOverlaps(groupRecords(rows.filter(r =>
    !SKELETON_SOURCES.has(r.source) || !r.thread || !sessionThreads.has(r.thread)), gap));
  const candidates = allCandidates.filter(a => a.primary.some(r =>
    r.evidence.some(entry => evidenceInPiece(entry, r, a))));
  const candidateCount = allCandidates.length, evidenceCount = candidates.length;
  const activitySeconds = new Map<string, number>();
  for (const c of candidates) activitySeconds.set(c.activity.key, (activitySeconds.get(c.activity.key) ?? 0) + c.seconds);
  const leadingActivity = [...activitySeconds.entries()].sort((a, b) => b[1] - a[1])[0]?.[0];
  mergeAdjacent(candidates, gap);
  const selected = limitCandidates(candidates, leadingActivity);
  const baseLimit = Math.max(4, Math.floor(120 / Math.max(1, selected.length)));
  const extraEvidence = longerConversationBudget(selected);
  const dependencyRecordIds = new Set<string>();
  const recordMembership = (a: Candidate, overlapping: ReviewRecord[]) =>
    overlapping.filter(r => !a.activity.projectId || !r.projectId || r.projectId === a.activity.projectId);
  const segments = selected.map((a, i) => {
    const limit = baseLimit + (extraEvidence.get(a) ?? 0);
    const primary = a.primary[0]!, anchor = primary.id;
    const id = a.start > Date.parse(primary.at) ? `${anchor}:${a.start}` : anchor;
    const overlapping = [...new Set(rows.filter(r => inPiece(r, a))
      .flatMap(r => [r, ...(r.related ?? [])]))].sort((x,y) => Date.parse(x.at)-Date.parse(y.at) || x.id.localeCompare(y.id));
    for (const r of overlapping) dependencyRecordIds.add(r.id);
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
    return { ...a, id, kind: a.activity.kind, key: `a${i + 1}`, records, apps, evidence };
  });
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
      project: a.activity.projectId, active_minutes: Math.round(a.seconds / 60),
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

function modelItem(a: ReviewSegment, candidate: DayOutput["items"][number] | undefined) {
  if (!candidate || candidate.content === "request_only" || candidate.content === "empty") return null;
  const title = singleLine(redactString(candidate.title).text, 20);
  const description = singleLine(redactString(candidate.description).text, 160);
  if (!title || !description || !candidate.refs.length || !isReadableReviewItem({ title, description })) return null;
  const references = candidate.refs.map(key => a.evidence.find(entry => `${a.key}:${entry.key}` === key));
  if (references.some(entry => !entry) || !references.some(entry => entry && !entry.secondary)) return null;
  const evidence = [...new Map(references.map(entry => [entry!.reference.id, entry!.reference])).values()]
    .sort((x, y) => Date.parse(x.at) - Date.parse(y.at));
  return { title, description, evidence };
}

export function composeReview(segments: ReviewSegment[], output: DayOutput, dayEnd: number, cutoff: string,
  omitted: string[], dependencies: string[]): ReviewDetail | null {
  const written = new Map(output.items.map(item => [item.activity, item]));
  const result = segments.flatMap(a => {
    const model = modelItem(a, written.get(a.key));
    if (!model) return [];
    const cited = new Set(model.evidence.map(r => r.id));
    const apps = [...new Map(a.records.filter(r => cited.has(r.id))
      .map(({ source, app }) => [JSON.stringify([source, app]), { source, app }])).values()];
    const segment: ReviewItem = {
      id: a.id, title: model.title, description: model.description, t_start: toLocalIso(a.start), t_end: toLocalIso(a.end),
      active_seconds: a.seconds, sources: [...new Set(apps.map(r => r.source))], evidence: model.evidence,
      apps, record_ids: [...new Set(a.records.map(r => r.id))], project_id: a.activity.projectId,
    };
    return [{ a, segment, model }];
  });
  if (output.items.some(item => item.content !== "request_only" && item.content !== "empty") && !result.length) return null;
  const main = output.highlight && result.find(({ a, model }) => model && a.seconds > 0 && a.key === output.highlight?.activity);
  const projectSeconds = new Map<string, number>();
  for (const { a } of result) {
    const key = a.activity.projectId ?? a.activity.key;
    projectSeconds.set(key, (projectSeconds.get(key) ?? 0) + a.seconds);
  }
  const longest = result.filter(r => r.a.seconds > 0).sort((x,y) =>
    (projectSeconds.get(y.a.activity.projectId ?? y.a.activity.key) ?? 0) -
    (projectSeconds.get(x.a.activity.projectId ?? x.a.activity.key) ?? 0) || byImportance(x.a,y.a))[0]?.segment;
  const summary = (main && singleLine(redactString(output.highlight!.text).text, 30)) || longest?.title || null;
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
