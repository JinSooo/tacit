import { createHash } from "node:crypto";
import { contentRevision, appliedCall, discardedCall } from "../runtime-log.ts";
// 提炼流程：切片 → 归线程 → 线程详细版 → 简略版 → 项目 → 当前状态 → 日记。契约：docs/contracts.md 第 4 节。
// 模型调用都在事务之外；每一步落库用小事务，失败只影响这一步，下一轮再试。
// 日志只写计数，不写任何记录内容或标题。
import type { HubDB } from "../db.ts";
import { chatApp, chatKey, recordChat } from "../chat.ts";
import { ulid, toLocalIso } from "../../../packages/record/index.ts";
import { classifyModelError, type ModelErrorCode } from "../llm/error-category.ts";
import { activeCooldown, ModelCooldown, withModelCooldown } from "./cooldown.ts";
import type { LLMRequest, LLMResult } from "../llm/index.ts";
import { applyTimelineCorrections, DistillStore, timelineCorrectionKey, type Frame, type Thread, type TimelineCorrections } from "./store.ts";
import { persistFrames, visibleFrame } from "./frames.ts";
import { DistillRules, projectByName } from "./rules.ts";
import { DistillRequests, localDayStart, localDateString } from "./requests.ts";
import * as P from "./prompts.ts";
import { digestPieces, digestFrameSize } from "./digest-input.ts";
import { threadRequest, type ThreadModelOutput } from "./thread-request.ts";
import { assignRequest } from "./assign-request.ts";
import { projectRequest, type ProjectModelOutput } from "./project-request.ts";
import { groundedQuote } from "./quotes.ts";
import { gitMaterialKey, materialBody, uniqueMaterials } from "./material.ts";
import { evidenceTime } from "./evidence-time.ts";
import { AUDIO_SOURCES, SKELETON_SOURCES, sourceList } from "../record-sources.ts";
import { notificationsShadowedSince } from "./wechat-duplicates.ts";
import { resolveRepoRoot } from "./repos.ts";
import { readGeneral, readTimelineSettings } from "../general-settings.ts";
import { nowSummary } from "../now-status.ts";
import { composePolish, composeReview, incrementalReview, reviewPlan, reviewMaterial, type ReviewDetail } from "./day-review.ts";
import { redactString } from "../redact.ts";
import { CONVERSATION_GAP_MS, conversationsIn, groupTurns, saveSummary, storedSummary, summaryState, speakerNamer } from "../conversations.ts";

export interface LLM { complete<T>(req: LLMRequest): Promise<LLMResult<T>> }
export interface Deps { db: HubDB; llm: LLM; now?: () => number; log?: (line: string) => void }

/** 事务外等待模型时用户可能删除/修正内容：丢弃旧快照的响应，下一轮重试。 */
async function complete<T>(d: Deps, req: LLMRequest): Promise<LLMResult<T>> {
  const revision = contentRevision(d.db);
  const result = await d.llm.complete<T>({ ...req, prompt: redactString(req.prompt).text, system: redactString(req.system).text, contentRevision: revision });
  if (revision !== contentRevision(d.db)) {
    discardedCall(d.db,result.call_id);
    return { ok: false, error: "unknown", discarded: true, ms: result.ms, call_id: result.call_id };
  }
  return result;
}

const MIN = 60_000, HOUR = 60 * MIN, DAY = 24 * HOUR;
export const LIMITS = {
  assignBatch: 20, assignChars: 24_000, assignExcerpt: 800, assignRecords: 10, assignThreads: 40,
  digestChars: 45_000, threadsPerRound: 12,
  candidateTTL: DAY, newSession: 30 * MIN, pauseAfter: 2 * HOUR,
  // 最近确认完成的线程也给模型选：结束后又聊到它的零星跟进归回去，不再只进日记（2026-11-10 实测：九院线程已完成，后续对话无处可归）。
  // 自动归档（archived）的不放：用户没确认，按规则不再参与。
  assignDoneThreads: 10, assignDoneWindow: 14 * DAY,
  // 门槛（AGENTS.md）：累计 15 分钟或跨两段活动才建线程，不够的只进日记。
  threadMinutes: 15, threadFrames: 2,
  // 对话总结：只看录音保留期内的，每轮最多写几场，单场原文太长时留头尾。
  conversationDays: 7, conversationsPerRound: 4, conversationChars: 24_000,
  // 合并重复线程：每天看一次最近的线程，模型把握不低于 0.8 才并。
  dedupThreads: 60, dedupConfidence: 0.8, dedupEvery: DAY,
};

const pad = (n: number) => String(n).padStart(2, "0");
const clock = (ms: number) => { const d = new Date(ms); return `${pad(d.getMonth() + 1)}-${pad(d.getDate())} ${pad(d.getHours())}:${pad(d.getMinutes())}`; };
const hhmm = (ms: number) => { const d = new Date(ms); return `${pad(d.getHours())}:${pad(d.getMinutes())}`; };
export const localDate = (ms: number) => toLocalIso(ms).slice(0, 10);
export const startOfDay = (ms: number) => { const d = new Date(ms); d.setHours(0, 0, 0, 0); return d.getTime(); };

/** 按条件读片段（避免整表读出后在内存里过滤）。 */
export function loadFrames(store: DistillStore, where: string, ...args: unknown[]): Frame[] {
  return (store.hub.db.prepare(`SELECT * FROM frames ${where}`).all(...args) as (Omit<Frame, "record_ids"> & { record_ids: string })[])
    .map(r => ({ ...r, record_ids: JSON.parse(r.record_ids) as string[] }));
}

interface Candidate { id: string; title: string; frame_ids: string[]; minutes: number; last_ms: number; project_id: string | null }

function markFrameReviewDays(store: DistillStore, frames: Frame[], before: number) {
  if (!frames.length) return;
  const dates = new Set(frames.map(f => localDate(f.t_start_ms)));
  const audio = store.hub.db.prepare(`SELECT DISTINCT r.t_start_ms,r.t_end FROM frame_records fr JOIN records r ON r.id=fr.record_id
    WHERE fr.frame_id IN (SELECT value FROM json_each(?)) AND r.source IN (${sourceList(AUDIO_SOURCES)}) AND r.sensitivity<>'private' AND r.t_end IS NOT NULL`)
    .all(JSON.stringify(frames.map(f => f.id))) as { t_start_ms: number; t_end: string }[];
  for (const record of audio) {
    const day = new Date(startOfDay(record.t_start_ms));
    // 转写的钟点至多从录音开始向后滚动 24 小时。补整理仍以请求的日期范围为准。
    const last = Math.min(Date.parse(record.t_end), record.t_start_ms + DAY, before - 1);
    day.setDate(day.getDate() + 1);
    while (day.getTime() <= last) {
      dates.add(localDate(day.getTime()));
      day.setDate(day.getDate() + 1);
    }
  }
  for (const date of dates) store.upsertDay({ date, needs_regen: 1 });
}

// ---------------- 1. 切片 + 规则归属（确定性，一个事务） ----------------

/** enabledDefault：首次运行时增量处理的起点。用户 2026-11-08 选定\"今天之后\"，CLI 传当天 0 点；测试传 now。 */
export function sliceStep(db: HubDB, backfill = false, now = Date.now(), enabledDefault = now) {
  const store = new DistillStore(db), rules = new DistillRules(store);
  return db.db.transaction(() => {
    // 补处理先前版本已入库但未影响整理的修正，也去掉旧的独立修正片段。
    const correctionCursor = store.getState<number>("correction_rowid") ?? 0;
    const corrections = db.db.prepare("SELECT rowid,id,corrects,t_start FROM records WHERE source='manual.correction' AND rowid>? ORDER BY rowid").all(correctionCursor) as { rowid: number; id: string; corrects: string; t_start: string }[];
    for (const r of corrections) {
      store.removeRecord(r.id, r.t_start);
      store.correctRecord(r.corrects);
    }
    if (corrections.length) store.setState("correction_rowid", corrections.at(-1)!.rowid);
    let cursor = store.getState<number>("cursor_ms");
    if (cursor === null) { cursor = now; store.setState("cursor_ms", cursor); }
    const enabled = store.getState<number>("enabled_ms") ?? enabledDefault;
    store.setState("enabled_ms", enabled);
    for (const id of notificationsShadowedSince(db, store.getState<number>("last_rowid") ?? 0)) store.refreshNotification(id);
    let created = 0, assigned = 0;
    const touched: Frame[] = [];
    if (backfill && !store.getState<boolean>("backfill_done")) {
      const rows = db.db.prepare("SELECT t_start_ms FROM records WHERE t_start_ms<? ORDER BY t_start_ms").all(enabled) as { t_start_ms: number }[];
      for (const start of new Set(rows.map(r => startOfDay(r.t_start_ms)))) {
        const end = new Date(start); end.setDate(end.getDate() + 1);
        const r = persistFrames(db, start - 1, Number.MAX_SAFE_INTEGER, Math.min(end.getTime(), enabled));
        created += r.frames.length; touched.push(...r.frames);
      }
      store.setState("backfill_done", true);
    }
    const result = persistFrames(db, cursor, now);
    created += result.frames.length; touched.push(...result.frames);
    store.setState("cursor_ms", result.cursor_ms);
    markFrameReviewDays(store, touched, now + 1);
    const pending = store.frames().filter(f => f.status === "new").map(f => visibleFrame(db, f)).filter(f => f !== null);
    for (const frame of pending) {
      rules.projectForFrame(frame);
      const r = rules.assign(frame);
      if (r.status === "assigned") { assigned++; touchThread(store, r.thread_id, frame); }
    }
    return { frames: created, assigned, unassigned: pending.length - assigned };
  })();
}

/** 片段归入线程后更新线程的时间统计，并标记需要重新提炼。 */
export function touchThread(store: DistillStore, threadId: string, frame: Frame) {
  const t = store.thread(threadId);
  if (!t) return;
  const newSession = !t.last_ms || frame.t_start_ms - t.last_ms > LIMITS.newSession;
  let project_hint = t.project_hint ?? null;
  if (!project_hint) project_hint = new DistillRules(store).projectForFrame(frame)?.id ?? null;
  store.upsertThread({
    ...t, project_hint,
    status: t.status === "paused" ? "active" : t.status,
    first_ms: Math.min(t.first_ms ?? frame.t_start_ms, frame.t_start_ms),
    last_ms: Math.max(t.last_ms ?? 0, frame.t_end_ms),
    active_minutes: store.activeMinutes(threadId),
    sessions: (t.sessions ?? 0) + (newSession ? 1 : 0),
    needs_regen: 1,
  });
  if (t.project_id) store.hub.db.prepare("UPDATE projects SET needs_regen=1 WHERE id=?").run(t.project_id);
}

// ---------------- 片段给模型看的样子 ----------------

/** 比较用规整键，给模型的名称仍取组内最新记录的原文。 */
function displayFrameKey(store: DistillStore, f: Frame): string {
  if (!f.key.startsWith("chat:")) return f.key;
  const latest = f.record_ids.map(id => store.hub.get(id)).filter(r => r !== null).filter(r => !!recordChat(r))
    .sort((a, b) => Date.parse(b.t_start) - Date.parse(a.t_start) || b.id.localeCompare(a.id))
    .map(r => `chat:${chatApp(r)}:${recordChat(r)}`)
    .find(key => chatKey(key) === chatKey(f.key));
  return latest ?? f.key;
}

export function frameView(store: DistillStore, frame: Frame, opts: { maxRecords: number; excerpt: (source: string) => number; seenMaterials?: Set<string> }): P.FrameView {
  const f = visibleFrame(store.hub, frame) ?? { ...frame, record_ids: [] };
  const projects = store.projects();
  // 保留原活动 ID 供后续查 effective；修正记录本身不能误当成独立活动再被过滤掉。
  const materials = uniqueMaterials(f.record_ids.flatMap(id => {
    const r = store.hub.effective(id);
    return r ? [{ ...r, id }] : [];
  }), repo => resolveRepoRoot(repo, projects) ?? repo, opts.seenMaterials);
  const materialIDs = materials.map(r => r.id);
  // 去重先于抽样，不能让多个 worktree 的副本挤掉独立提交。
  const ids = materialIDs.length <= opts.maxRecords ? materialIDs
    : Array.from({ length: opts.maxRecords }, (_, i) => materialIDs[Math.round(i * (materialIDs.length - 1) / (opts.maxRecords - 1))]!);
  let hidden = 0;
  const conversations = new Set<string>();
  const records: P.FrameView["records"] = ids.flatMap(id => {
    const original = store.hub.get(id);
    if (!original || original.source === "manual.correction") return [];
    const originalEffective = store.hub.effective(id)!;
    // private 记录的标题和正文都不发给模型；同一片段里的其他记录照常发送。
    if (originalEffective.sensitivity === "private") { hidden++; return []; }
    if (SKELETON_SOURCES.has(original.source) && (originalEffective.source !== "manual.correction" || original.source === "android.usage")) {
      // 骨架只提供活动时间和标题，正文留给 History 和主动查询。
      return [{ id, source: original.source, title: originalEffective.title, recorded_at: original.t_start,
        ...(original.t_end ? { recorded_until: original.t_end } : {}), excerpt: "" }];
    }
    const r = { ...originalEffective, body: materialBody(originalEffective) };
    // 对话开头常是寒暄和噪声，总结另附一次，不挤占每条原文的截断预算。
    if (AUDIO_SOURCES.has(original.source)) {
      const at = Date.parse(original.t_start);
      const g = conversationsIn(store.hub, at, at, original.device).find(g => g.record_ids.includes(original.id));
      const s = g && storedSummary(store.hub, g);
      if (s && g) {
        const first = !conversations.has(g.id); conversations.add(g.id);
        return [{ id: r.id, source: r.source, title: `对话：${s.title}`, ...evidenceTime(r), conversation_id: g.id,
          ...(first ? { conversation_summary: { summary: s.summary, points: s.points } } : {}),
          excerpt: P.excerpt(r.body, opts.excerpt(r.source)) }];
      }
    }
    return [{ id: r.id, source: r.source, title: r.title, ...evidenceTime(r), excerpt: P.excerpt(r.body, opts.excerpt(r.source)) }];
  });
  if (hidden) records.push({ id: "", source: "note", title: `（另有 ${hidden} 条私密记录，内容未提供）`, excerpt: "" });
  if (ids.length < materialIDs.length) records.push({ id: "", source: "note", title: `（共 ${materialIDs.length} 条独立材料，只列出 ${ids.length} 条）`, excerpt: "" });
  // 整个片段都是私密记录时才整段隐藏（只给应用和时长）。
  const allPrivate = hidden > 0 && records.every(r => r.source === "note");
  const repos = [...new Set(ids.flatMap(id => { const r = store.hub.get(id); return r?.sensitivity !== "private" && r?.context?.repo ? [r.context.repo] : []; }))];
  return { id: f.id, start: clock(f.t_start_ms), end: clock(f.t_end_ms), key: displayFrameKey(store, f), ...(repos.length ? { repos } : {}), private: allPrivate, records };
}

/** 按字数预算分批，单个片段超预算时自成一批。 */
function batches<T>(items: T[], size: (item: T) => number, budget: number, maxCount: number): T[][] {
  const out: T[][] = []; let cur: T[] = [], used = 0;
  for (const item of items) {
    const n = size(item);
    if (cur.length && (used + n > budget || cur.length >= maxCount)) { out.push(cur); cur = []; used = 0; }
    cur.push(item); used += n;
  }
  if (cur.length) out.push(cur);
  return out;
}

// ---------------- 2. 归线程（minute 档） ----------------

export async function assignStep(d: Deps, store: DistillStore, now: number) {
  const log = d.log ?? (() => {});
  let assigned = 0, created = 0, ignored = 0, calls = 0, failed = 0;
  const previous = store.getState<Candidate[]>("candidates") ?? [];
  let candidates = previous.filter(c => now - c.last_ms < LIMITS.candidateTTL);
  const saveCandidates = () => {
    for (const candidate of candidates) {
      if (candidate.project_id && !store.project(candidate.project_id)) candidate.project_id = null;
    }
    store.setState("candidates", candidates);
  };
  store.hub.db.transaction(() => {
    const live = JSON.stringify(candidates.flatMap(c=>c.frame_ids));
    const expired = JSON.stringify(previous.filter(c=>!candidates.includes(c)).flatMap(c=>c.frame_ids));
    store.hub.db.prepare("UPDATE frames SET status='candidate_expired' WHERE (status='candidate' AND id NOT IN (SELECT value FROM json_each(?))) OR (status='ignored' AND id IN (SELECT value FROM json_each(?)))").run(live,expired);
    store.hub.db.prepare("UPDATE frames SET status='candidate' WHERE status='ignored' AND id IN (SELECT value FROM json_each(?))").run(live);
    saveCandidates();
  })();
  const pending = loadFrames(store, "WHERE status='new' ORDER BY t_start_ms,id")
    .map(f => visibleFrame(store.hub, f)).filter(f => f !== null);
  // 用户说过"不属于"某些线程的片段按拒绝的线程分组单独成批：候选里直接去掉这些线程（只在提示里写不能选，
  // 模型仍会被片段里的字样带回原线程，2026-11-10 实测），片段带上被拒线程的标题，避免另起同名线程。
  const groups = new Map<string, { rejected: string[]; views: { f: Frame; v: P.FrameView }[] }>();
  for (const f of pending) {
    const v = frameView(store, f, { maxRecords: LIMITS.assignRecords, excerpt: () => LIMITS.assignExcerpt });
    const rejected = store.rejectedThreads(f.id).sort();
    const titles = rejected.map(id => store.thread(id)?.title).filter((t): t is string => !!t);
    const key = rejected.join(",");
    if (!groups.has(key)) groups.set(key, { rejected, views: [] });
    groups.get(key)!.views.push({ f, v: titles.length ? { ...v, not_threads: titles } : v });
  }
  for (const group of groups.values()) for (const batch of batches(group.views, x => JSON.stringify(x.v).length, LIMITS.assignChars, LIMITS.assignBatch)) {
    const excluded = new Set(group.rejected);
    const open = (store.hub.db.prepare("SELECT * FROM threads WHERE status IN ('active','paused') ORDER BY last_ms DESC LIMIT ?").all(LIMITS.assignThreads + excluded.size) as (Thread & { project_id: string | null })[])
      .filter(t => !excluded.has(t.id)).slice(0, LIMITS.assignThreads);
    const ended = (store.hub.db.prepare("SELECT * FROM threads WHERE status='done' AND last_ms>? ORDER BY last_ms DESC LIMIT ?").all(now - LIMITS.assignDoneWindow, LIMITS.assignDoneThreads + excluded.size) as (Thread & { project_id: string | null })[])
      .filter(t => !excluded.has(t.id)).slice(0, LIMITS.assignDoneThreads);
    const threads = [...open, ...ended];
    const names = new Map(store.projects().map(p => [p.id, p.name]));
    const choices: P.ThreadView[] = [
      ...threads.map(t => ({ id: t.id, title: t.title, brief: t.brief ?? "", project: t.project_id ? names.get(t.project_id) ?? null : null, status: t.status, last: t.last_ms ? clock(t.last_ms) : "" })),
      ...candidates.map(c => ({ id: `cand:${c.id}`, title: c.title, brief: "", project: c.project_id ? names.get(c.project_id) ?? null : null, status: "candidate", last: clock(c.last_ms) })),
    ];
    calls++;
    const request = assignRequest(batch.map(x => x.v), choices);
    const r = await complete<P.AssignOutput>(d, { tier: "minute", task: "assign", system: P.ASSIGN_SYSTEM, prompt: request.prompt, schema: request.schema, refs: request.refs });
    if (!r.ok) { failed += batch.length; log(JSON.stringify({ step: "assign", ok: false, frames: batch.length, category: classifyModelError(r.error) })); continue; }
    const byFrame = new Map(request.decode(r.data).items.map(i => [i.frame_id, i]));
    const real = new Set(threads.map(t => t.id));
    // 同一批里多个片段提议同一个新标题，或者提议的标题就是已有线程：归到同一条，不重复建。
    const byTitle = new Map(threads.map(t => [t.title, t.id]));
    store.hub.db.transaction(() => {
      for (const { f } of batch) {
        const item = byFrame.get(f.id);
        if (!item) continue; // 模型漏掉的片段保持 new，下一轮再给
        const ignore = () => { store.hub.db.prepare("UPDATE frames SET status='ignored' WHERE id=?").run(f.id); ignored++; };
        if (item.ignore) { ignore(); continue; }
        // 被拒线程不在候选里；模型仍填了它的 id 或提议同名新线程时，不归回去，只进日记。
        const rejectedTitles = new Set(group.rejected.map(id => store.thread(id)?.title));
        if (item.thread_id && excluded.has(item.thread_id) || rejectedTitles.has(item.new_thread_title?.trim())) {
          log(JSON.stringify({ step: "assign", rejected_choice: true, frame: f.id })); ignore(); continue;
        }
        if (item.thread_id && real.has(item.thread_id)) {
          store.assign(f.id, item.thread_id, "llm", item.confidence); touchThread(store, item.thread_id, f); assigned++; continue;
        }
        const title = item.new_thread_title?.trim();
        const existing = title ? byTitle.get(title) : undefined;
        if (existing) { store.assign(f.id, existing, "llm", item.confidence); touchThread(store, existing, f); assigned++; continue; }
        let cand = item.thread_id?.startsWith("cand:") ? candidates.find(c => `cand:${c.id}` === item.thread_id) : undefined;
        if (!cand && title) cand = candidates.find(c => c.title === title);
        if (!cand && !title) { ignore(); continue; }
        // 屏幕、浏览器、应用只是时间骨架（AGENTS.md）：可以并进已有线程或候选，不能单独发起新线程（2026-11-18）。
        if (!cand && skeletonOnly(store, f)) { ignore(); continue; }
        if (!cand) {
          const project = new DistillRules(store).projectForFrame(f);
          cand = { id: ulid(now), title: title!, frame_ids: [], minutes: 0, last_ms: 0, project_id: project?.id ?? null };
          candidates.push(cand);
        }
        cand.frame_ids.push(f.id); cand.minutes = store.frameMinutes(cand.frame_ids); cand.last_ms = Math.max(cand.last_ms, f.t_end_ms);
        // 候选单独计数，不重复送模型；建事项时正式归属，过期后仍保留原因。
        store.hub.db.prepare("UPDATE frames SET status='candidate' WHERE id=?").run(f.id);
        if (cand.minutes >= LIMITS.threadMinutes || cand.frame_ids.length >= LIMITS.threadFrames) {
          const frames = loadFrames(store, `WHERE id IN (${cand.frame_ids.map(() => "?").join(",")}) ORDER BY t_start_ms,id`, ...cand.frame_ids);
          if (frames.length) {
            const id = ulid(now);
            // last_ms 先留空，第一个片段由 touchThread 计为一段会话。
            const projectHint = cand.project_id && store.project(cand.project_id) ? cand.project_id : null;
            store.upsertThread({ id, project_hint: projectHint, status: "active", title: cand.title, first_ms: frames[0]!.t_start_ms, active_minutes: 0, sessions: 0, needs_regen: 1 });
            for (const fr of frames) { store.assign(fr.id, id, "llm", item.confidence); touchThread(store, id, fr); }
            created++; assigned += frames.length; real.add(id); byTitle.set(cand.title, id);
          }
          candidates = candidates.filter(c => c !== cand);
        }
      }
      saveCandidates();
      appliedCall(d.db,r.call_id);
    })();
  }
  return { calls, assigned, created_threads: created, ignored, failed, candidates: candidates.length };
}

function skeletonOnly(store: DistillStore, f: Frame): boolean {
  const sources = f.record_ids.map(id => store.hub.get(id)?.source).filter((s): s is string => !!s);
  return sources.length > 0 && sources.every(s => SKELETON_SOURCES.has(s));
}

// ---------------- 3. 线程详细版 + 简略版 ----------------

function factViews(store: DistillStore, field: "thread_id" | "project_id", id: string): P.FactView[] {
  return store.facts(field, id).map(f => ({ id: f.id, kind: f.kind, text: f.text, origin: f.origin, at: f.valid_at, scope: { thread_id: f.thread_id ?? null, project_id: f.project_id ?? null } }));
}

function threadFrames(store: DistillStore, threadId: string): Frame[] {
  return loadFrames(store, "WHERE id IN (SELECT frame_id FROM assignments WHERE thread_id=?) ORDER BY t_start_ms,id", threadId)
    .map(f => visibleFrame(store.hub, f)).filter(f => f !== null);
}

async function makeBrief(d: Deps, task: string, title: string, detail: unknown): Promise<{ text: string; call_id?: string } | null> {
  const r = await complete<P.BriefOutput>(d, { tier: "minute", task, system: P.BRIEF_SYSTEM, prompt: P.briefPrompt(title, detail), schema: P.BRIEF_SCHEMA });
  return r.ok ? { text: r.data.brief.trim(), call_id: r.call_id } : null;
}

/** 已经提炼进详细版的片段，以及当时这些片段的记录总数（变少说明有记录被删，要整条重建）。 */
interface DigestMark { frames: string[]; records: number; user_facts?: string[]; fact_ids?: string[]; parts?: string[] }

function projectHint(store: DistillStore, thread: Thread): P.ProjectHint {
  const p = thread.project_hint ? store.project(thread.project_hint) : null;
  return p ? { name: p.name, brief: p.brief ?? null } : null;
}

/** 归属更新集中在此处，未来用户手动指定归属可在这里加入优先级判断。 */
function applyClassification(store: DistillStore, id: string, out: P.Classification) {
  const t = store.thread(id)!;
  const projectId = out.domain === "work" && out.in_project && projectHint(store, t) ? t.project_hint! : null;
  store.upsertThread({ ...t, domain: out.domain, project_id: projectId });
  if ((t.project_id ?? null) !== projectId) {
    store.hub.db.prepare("UPDATE facts SET project_id=? WHERE thread_id=?").run(projectId, id);
    for (const pid of new Set([t.project_id, projectId])) if (pid) {
      store.hub.db.prepare("UPDATE projects SET needs_regen=1 WHERE id=?").run(pid);
    }
  }
}

/** 没有新片段的存量线程走轻量判断；有新片段的留给 digest 一起判断。 */
// ---------------- 对话总结（minute 档） ----------------

/** 整理过的原文给模型；太长时留开头三分之二、结尾三分之一。 */
export function conversationTranscript(turns: { at: string; speaker: string; text: string }[], budget = LIMITS.conversationChars): string {
  const text = turns.map(t => `${hhmm(Date.parse(t.at))} ${t.speaker}：${t.text}`).join("\n");
  const cps = Array.from(text);
  if (cps.length <= budget) return text;
  const head = Math.floor(budget * 2 / 3);
  return `${cps.slice(0, head).join("")}\n（中间省略）\n${cps.slice(cps.length - (budget - head)).join("")}`;
}

/** 结束超过 10 分钟（不会再接上新的一段）、还没有总结或组成变了的对话，各写一段总结。私密的不发给模型。 */
export async function conversationStep(d: Deps, now: number) {
  const groups = conversationsIn(d.db, now - LIMITS.conversationDays * DAY, now);
  const namer = speakerNamer(d.db);
  const todo = groups.filter(g => now - g.end_ms >= CONVERSATION_GAP_MS).flatMap(g => {
    const turns = groupTurns(d.db, g, namer());
    return summaryState(g, turns, storedSummary(d.db, g), now) === "waiting" ? [{ g, turns }] : [];
  });
  // 新的先写：刚结束的对话最可能马上被打开看。
  todo.sort((a, b) => b.g.start_ms - a.g.start_ms);
  let calls = 0, done = 0;
  for (const { g, turns } of todo.slice(0, LIMITS.conversationsPerRound)) {
    calls++;
    const r = await complete<P.ConversationOutput>(d, { tier: "minute", task: "conversation_summary", system: P.CONVERSATION_SYSTEM,
      prompt: P.conversationPrompt({ start: clock(g.start_ms), end: clock(g.end_ms), app: g.app }, conversationTranscript(turns)), schema: P.CONVERSATION_SCHEMA });
    if (!r.ok) continue;
    const out = { title: r.data.title.trim(), summary: r.data.summary.trim(), points: r.data.points.map(p => p.trim()).filter(Boolean).slice(0, 5) };
    if (!out.title || !out.summary) { discardedCall(d.db,r.call_id); continue; }
    // 调用期间记录可能被删或者接上了新的一段：组成变了就不写，下一轮重来。
    const current = conversationsIn(d.db, g.start_ms, g.start_ms).find(c => c.id === g.id);
    if (!current || JSON.stringify(current.record_ids) !== JSON.stringify(g.record_ids)
      || JSON.stringify(groupTurns(d.db, current, namer())) !== JSON.stringify(turns)) { discardedCall(d.db,r.call_id); continue; }
    d.db.db.transaction(() => { saveSummary(d.db, g, out); appliedCall(d.db,r.call_id); })(); done++;
  }
  return { calls, done, pending: todo.length - done };
}

/** 没有项目候选的线程按名字找一个候选，交给下一次 classify / digest 判断（见 projectByName）。 */
export function nominateByName(store: DistillStore): number {
  const revision = contentRevision(store.hub);
  const rows = store.hub.db.prepare("SELECT * FROM threads WHERE project_hint IS NULL AND project_id IS NULL AND status IN ('active','paused','done')").all() as Thread[];
  const ignored = store.ignoredProjectKeys(), rules = new DistillRules(store);
  const hasIgnoredKeys = Object.values(ignored).some(keys => keys.length);
  const nominations = rows.flatMap(t => {
    const p = projectByName(store, `${t.title}\n${t.brief ?? ""}`, ignored);
    if (!p || (hasIgnoredKeys && threadFrames(store, t.id).some(frame => rules.hasIgnoredProjectKey(frame, ignored)))) return [];
    return [{ project: p.id, thread: t.id }];
  });
  if (!nominations.length) return 0;
  return store.hub.db.transaction(() => {
    if (revision !== contentRevision(store.hub)) return 0;
    // domain 清空：已提炼过的线程走一次 classify 重新判断是否属于这个项目。
    const nominate = store.hub.db.prepare(`UPDATE threads SET project_hint=?,domain=NULL WHERE id=?
      AND project_hint IS NULL AND project_id IS NULL AND EXISTS (SELECT 1 FROM projects WHERE id=?)`);
    return nominations.reduce((count, { project, thread }) => count + nominate.run(project, thread, project).changes, 0);
  }).immediate();
}

/** 判断规则改过一次：在仓库里做的学习从"生活"改算工作（用户 2026-11-12 确认）。之前判成生活、有候选项目的线程重判一次。 */
const CLASSIFY_RULES_VERSION = 2;
export function reclassifyAfterRuleChange(store: DistillStore): number {
  if ((store.getState<number>("classify_rules") ?? 1) >= CLASSIFY_RULES_VERSION) return 0;
  const n = store.hub.db.prepare("UPDATE threads SET domain=NULL WHERE domain='life' AND project_hint IS NOT NULL").run().changes;
  store.setState("classify_rules", CLASSIFY_RULES_VERSION);
  return n;
}

export async function classifyStep(d: Deps, store: DistillStore) {
  let calls = 0, updated = 0, failed = 0;
  reclassifyAfterRuleChange(store);
  nominateByName(store);
  const rows = store.hub.db.prepare("SELECT id FROM threads WHERE domain IS NULL ORDER BY last_ms DESC,id").all() as { id: string }[];
  for (const { id } of rows) {
    const frames = threadFrames(store, id), mark = store.getState<DigestMark>(`digest:${id}`);
    if (frames.length && (!mark || frames.some(f => !mark.frames.includes(f.id))
      || mark.frames.some(fid => !frames.some(f => f.id === fid))
      || frames.reduce((n, f) => n + f.record_ids.length, 0) < mark.records)) continue;
    if (calls >= LIMITS.threadsPerRound) break;
    calls++;
    try {
      const t = store.thread(id)!;
      const r = await complete<P.Classification>(d, { tier: "minute", task: "classify", system: P.CLASSIFY_SYSTEM,
        prompt: P.classifyPrompt(t, projectHint(store, t)), schema: P.CLASSIFY_SCHEMA });
      if (!r.ok) { failed++; continue; }
      store.hub.db.transaction(() => { applyClassification(store,id,r.data); appliedCall(d.db,r.call_id); })();
      updated++;
    } catch (error) {
      if (error instanceof ModelCooldown) throw error;
      failed++;
    }
  }
  return { calls, updated, failed };
}

/**
 * 选哪些待更新线程重写详细版。all：每小时那轮写全部待更新的（2026-11-20 起当天仍在进行的也写，
 * 让新会话带入和时间线同步）。wanted：每 15 分钟的快轮只处理被打开或被 Agent 读取的。
 */
export type DigestSelect = "all" | "wanted";
export async function digestStep(d: Deps, store: DistillStore, now: number, select: DigestSelect = "all") {
  const log = d.log ?? (() => {});
  let updated = 0, failed = 0, facts = 0, calls = 0, dropped = 0, invalidInference = 0;
  const wanted = store.wantedDigests();
  const pendingRows = store.hub.db.prepare("SELECT id,brief,last_ms FROM threads WHERE needs_regen=1 AND status!='abandoned' ORDER BY last_ms DESC").all() as { id: string; brief: string | null; last_ms: number | null }[];
  const pendingIds = new Set(pendingRows.map(r => r.id));
  const stale = [...wanted].filter(id => !pendingIds.has(id));
  if (stale.length) { for (const id of stale) wanted.delete(id); store.setState("digest_wanted", [...wanted]); }
  const threads = pendingRows
    .filter(r => select === "all" || wanted.has(r.id))
    .sort((x, y) => Number(wanted.has(y.id)) - Number(wanted.has(x.id)))
    .slice(0, LIMITS.threadsPerRound);
  for (const { id } of threads) {
    const revision = contentRevision(d.db);
    const thread = store.thread(id)!;
    const frames = threadFrames(store, id);
    const recordVersions = frames.flatMap(f => f.record_ids).map(id => [id, store.hub.effective(id)?.id]);
    const unchanged = () => recordVersions.every(([id, version]) => store.hub.effective(id!)?.id === version);
    const countOf = (ids: Set<string>) => frames.filter(f => ids.has(f.id)).reduce((n, f) => n + f.record_ids.length, 0);
    if (!frames.length) {
      store.hub.db.transaction(() => {
        if (revision !== contentRevision(d.db)) return;
        store.upsertThread({ ...thread, detail: null, brief: null, needs_regen: 0, updated_at: toLocalIso(now) });
        store.setState(`digest:${id}`, null);
      }).immediate();
      continue;
    }
    const mark = store.getState<DigestMark>(`digest:${id}`);
    const present = new Set(frames.map(f => f.id));
    // 片段或记录被删过就整条线程从头重建，保证删掉的内容不会留在详细版里。
    let rebuild = !mark || mark.frames.some(f => !present.has(f)) || countOf(new Set(mark.frames)) < mark.records;
    const done = new Set(rebuild ? [] : mark!.frames);
    let fresh = frames.filter(f => !done.has(f.id));
    const toPieces = () => {
      const seenMaterials = new Set<string>();
      const freshIDs = new Set(fresh.map(f => f.id)), views: P.FrameView[] = [], projects = store.projects();
      // 续跑时也从已读片段恢复去重集合，不能让同一副本因跨批次重新变成正文。
      for (const f of frames) {
        if (freshIDs.has(f.id)) views.push(frameView(store, f, { maxRecords: Infinity, excerpt: () => Infinity, seenMaterials }));
        else for (const id of f.record_ids) {
          const r = store.hub.effective(id);
          if (!r) continue;
          const key = gitMaterialKey(r, r.context?.repo ? resolveRepoRoot(r.context.repo, projects) ?? r.context.repo : undefined);
          if (key) seenMaterials.add(key);
        }
      }
      return digestPieces(views, LIMITS.digestChars);
    };
    let pieces = toPieces();
    // 部分成功后原记录被删除/移走时，旧分段摘要也必须从头重建。
    if (!rebuild && mark?.parts?.some(key => !pieces.some(p => p.key === key))) {
      rebuild = true; done.clear(); fresh = frames; pieces = toPieces();
    }
    let detail: unknown = rebuild ? { goal: "", progress: "", artifacts: { files: [], urls: [], commands: [], people: [] }, quotes: [] } : thread.detail;
    if (detail && typeof detail === "object" && "quotes" in detail && Array.isArray(detail.quotes)) {
      detail = { ...detail, quotes: detail.quotes.filter(q => typeof q?.text === "string" && typeof q.record_id === "string" && groundedQuote(store.hub.get(q.record_id), q.text)) };
    }
    let title = thread.title, ok = true;
    const presentParts = new Set(pieces.map(p => p.key));
    const doneParts = new Set((rebuild ? [] : mark!.parts ?? []).filter(key => presentParts.has(key)));
    const userFacts = () => store.facts("thread_id", id).filter(f => f.origin === "user").map(f => f.id).sort();
    const factIds = userFacts();
    const currentFacts = () => store.facts("thread_id", id).map(f => f.id).sort();
    const chunks = batches(pieces.filter(p => !doneParts.has(p.key)), x => digestFrameSize(x.v) + 1, LIMITS.digestChars - 1, 50);
    // 用户纠错也使详细版失效；不能在没有新片段时绕过详细版、只改简略版。
    if (!chunks.length && (JSON.stringify(mark?.user_facts ?? []) !== JSON.stringify(factIds)
      || JSON.stringify(mark?.fact_ids ?? currentFacts()) !== JSON.stringify(currentFacts()))) chunks.push([]);
    for (const chunk of chunks) {
      calls++;
      const request = threadRequest({ title, detail }, factViews(store, "thread_id", id), chunk.map(x => x.v), projectHint(store, store.thread(id)!), recordId => store.hub.get(recordId));
      const r = await complete<ThreadModelOutput>(d, { tier: "hour", task: "thread_digest", system: P.THREAD_SYSTEM, prompt: request.prompt, schema: request.schema, refs: request.refs });
      if (!r.ok) { log(JSON.stringify({ step: "digest", ok: false, category: classifyModelError(r.error) })); ok = false; break; }
      if (!unchanged()) { discardedCall(d.db,r.call_id); ok = false; break; }
      const known = new Set(chunk.flatMap(x => x.v.records.map(rec => rec.id)).filter(Boolean));
      const out = request.decode(r.data);
      ok = store.hub.db.transaction(() => {
        if (revision !== contentRevision(d.db)) { discardedCall(d.db, r.call_id); return false; }
        applyClassification(store, id, out);
        const kept = out.new_facts.map(f => {
          const grounded = P.keepGroundedFacts([f], known)[0];
          if (!grounded) { dropped++; return null; }
          // 不把高置信度推测自动改写成“已定”，也不替模型编一个置信度。
          if (f.kind === "inference" && f.confidence >= 0.8) { invalidInference++; return null; }
          return grounded;
        });
        const ids = kept.map(f => {
          if (!f) return null;
          const fid = ulid(now);
          const when = Math.max(...f.evidence.map(e => Date.parse(store.hub.get(e)?.t_start ?? "") || 0));
          store.writeFact({ id: fid, thread_id: id, project_id: store.thread(id)!.project_id ?? null, kind: f.kind, text: f.text, reason: f.reason ?? undefined, evidence: f.evidence, confidence: f.confidence, origin: "llm", valid_at: new Date(when || now).toISOString(), created_at: new Date(now).toISOString() });
          facts++; return fid;
        });
        const valid = new Set(store.facts("thread_id", id).filter(f => f.origin === "llm").map(f => f.id));
        for (const inv of out.invalidate) {
          if (!valid.has(inv.fact_id)) continue; // 用户写的 fact 不在集合里，模型推翻不了
          const by = inv.replaced_by === null ? null : ids[inv.replaced_by] ?? null;
          if (inv.replaced_by !== null && by === null) continue; // 替代事实被过滤时，不能连带作废原事实
          store.hub.db.prepare("UPDATE facts SET invalid_at=?,superseded_by=? WHERE id=? AND invalid_at IS NULL").run(new Date(now).toISOString(), by, inv.fact_id);
        }
        // 只接受原记录中逐字存在的原话；AI 会话必须来自单段用户发言，不能串到 AI 回复。
        const prevQuotes = ((detail as { quotes?: { record_id: string }[] })?.quotes ?? []).map(q => q.record_id);
        const allowed = new Set([...known, ...prevQuotes]);
        detail = { ...out.detail, quotes: out.detail.quotes.filter(q => allowed.has(q.record_id) && groundedQuote(store.hub.get(q.record_id), q.text)) };
        title = out.title.trim() || title;
        store.upsertThread({ ...store.thread(id)!, title, detail });
        for (const piece of chunk) doneParts.add(piece.key);
        for (const frame of fresh) {
          if (pieces.filter(p => p.frameId === frame.id).every(p => doneParts.has(p.key))) done.add(frame.id);
        }
        const partial = pieces.filter(p => !done.has(p.frameId) && doneParts.has(p.key)).map(p => p.key);
        store.setState(`digest:${id}`, { frames: [...done], records: countOf(done), user_facts: factIds, fact_ids: currentFacts(), ...(partial.length ? { parts: partial } : {}) } satisfies DigestMark);
        appliedCall(d.db,r.call_id);
        return true;
      }).immediate();
      if (!ok) break;
    }
    if (!ok || revision !== contentRevision(d.db)) { failed++; log(JSON.stringify({ step: "digest", ok: false })); continue; }
    calls++;
    const brief = await makeBrief(d, "thread_brief", title, detail);
    if (brief === null) { failed++; continue; }
    const applied = store.hub.db.transaction(() => {
      if (revision !== contentRevision(d.db)) { discardedCall(d.db, brief.call_id); return false; }
      store.upsertThread({ ...store.thread(id)!, brief: brief.text, needs_regen: Number(JSON.stringify(userFacts()) !== JSON.stringify(factIds)), updated_at: toLocalIso(now) });
      const projectId = store.thread(id)!.project_id;
      if (projectId) store.hub.db.prepare("UPDATE projects SET needs_regen=1 WHERE id=?").run(projectId);
      appliedCall(d.db,brief.call_id);
      return true;
    }).immediate();
    if (applied) updated++; else failed++;
  }
  return { calls, updated, failed, facts, dropped_ungrounded: dropped, dropped_invalid_inference: invalidInference };
}

// ---------------- 合并重复线程（每天一次） ----------------

/**
 * 同一件事被拆成几条线程时并成一条（2026-11-12 实测：整理启用前的历史时，同一批里给 Familiar 发版、首期 Weekly
 * 各起了两个标题，之后两条各自长大）。只并同一领域、不分属两个项目的；片段最多的那条留下。
 */
export async function dedupStep(d: Deps, store: DistillStore, now: number) {
  const rows = store.hub.db.prepare(`SELECT t.*,(SELECT count(*) FROM assignments a WHERE a.thread_id=t.id) AS frames FROM threads t
    WHERE brief IS NOT NULL AND (status IN ('active','paused') OR (status='done' AND last_ms>?)) ORDER BY last_ms DESC LIMIT ?`).all(now - LIMITS.assignDoneWindow, LIMITS.dedupThreads) as (Thread & { frames: number })[];
  if (rows.length < 2) return { calls: 0, merged: 0, failed: 0 };
  const names = new Map(store.projects().map(p => [p.id, p.name]));
  const views = rows.map(t => ({ id: t.id, title: t.title, brief: t.brief ?? "", project: t.project_id ? names.get(t.project_id) ?? null : null, status: t.status, first: t.first_ms ? clock(t.first_ms) : "", last: t.last_ms ? clock(t.last_ms) : "" }));
  const r = await complete<P.DedupOutput>(d, { tier: "hour", task: "dedupe", system: P.DEDUP_SYSTEM, prompt: P.dedupPrompt(views), schema: P.DEDUP_SCHEMA });
  if (!r.ok) return { calls: 1, merged: 0, failed: 1 };
  const byId = new Map(rows.map(t => [t.id, t]));
  let merged = 0;
  store.hub.db.transaction(() => {
    for (const g of r.data.groups) {
      if (g.confidence < LIMITS.dedupConfidence) continue;
      const members = [...new Set(g.thread_ids)].map(id => byId.get(id)).filter((t): t is Thread & { frames: number } => !!t && !!store.thread(t.id));
      if (members.length < 2) continue;
      if (new Set(members.map(t => t.domain).filter(Boolean)).size > 1) continue;
      if (new Set(members.map(t => t.project_id).filter(Boolean)).size > 1) continue;
      const [target, ...rest] = members.sort((a, b) => b.frames - a.frames || (b.last_ms ?? 0) - (a.last_ms ?? 0));
      for (const t of rest) { store.mergeThreads(t.id, target!.id, new Date(now).toISOString()); merged++; }
    }
    appliedCall(d.db,r.call_id);
  })();
  return { calls: 1, merged, failed: 0 };
}

// ---------------- 4. 项目 ----------------

export async function projectStep(d: Deps, store: DistillStore, now: number) {
  let updated = 0, failed = 0, calls = 0;
  for (const { id } of store.projects()) {
    const revision = contentRevision(d.db), p = store.project(id);
    if (!p || (!p.needs_regen && !store.getState<boolean>(`project_brief:${id}`))) continue;
    // needs_regen 只标记详细版输入失效；简略版失败由独立检查点重试。
    const pendingKey = `project_brief:${id}`;
    let detail = p.detail;
    if (p.needs_regen || detail == null) {
      const threads = store.hub.db.prepare("SELECT * FROM threads WHERE project_id=? AND status!='abandoned' ORDER BY last_ms DESC LIMIT 20").all(p.id) as (Thread & { last_ms: number | null; active_minutes: number | null })[];
      const last = Math.max(0, ...threads.map(t => t.last_ms ?? 0));
      const salience = threads.reduce((s, t) => s + (t.active_minutes ?? 0) * Math.exp(-(now - (t.last_ms ?? 0)) / (7 * DAY)), 0);
      const described = threads.filter(t => t.brief);
      // 没有可用线程时清掉旧摘要，避免已移出的生活内容继续从项目摘要注入。
      if (!described.length) {
        store.hub.db.transaction(() => {
          if (revision !== contentRevision(d.db) || !store.project(id)) return;
          store.setState(pendingKey, null);
          store.upsertProject({ ...store.project(id)!, brief: null, detail: null, last_ms: last || p.last_ms, salience, needs_regen: 0, updated_at: toLocalIso(now) });
        }).immediate();
        continue;
      }
      calls++;
      const views: P.ThreadView[] = described.map(t => ({ id: t.id, title: t.title, brief: t.brief ?? "", project: p.name, status: t.status, last: t.last_ms ? clock(t.last_ms) : "" }));
      const evidenceKey = `project_evidence_at:${id}`;
      const request = projectRequest(store, p.id, p.name, views, store.getState<number>(evidenceKey) ?? now - 3 * DAY);
      const r = await complete<ProjectModelOutput>(d, { tier: "hour", task: "project", system: P.PROJECT_SYSTEM, prompt: request.prompt, schema: request.schema, refs: request.refs });
      if (!r.ok) { failed++; continue; }
      detail = { goal: r.data.goal, status: r.data.status, people: r.data.people };
      const applied = store.hub.db.transaction(() => {
        const current = store.project(id);
        if (!current || revision !== contentRevision(d.db)) { discardedCall(d.db, r.call_id); return false; }
        request.apply(r.data, now);
        store.setState(evidenceKey, now);
        store.upsertProject({ ...current, detail, last_ms: last, salience, needs_regen: 0, updated_at: toLocalIso(now) });
        store.setState(pendingKey, true);
        appliedCall(d.db,r.call_id);
        return true;
      }).immediate();
      if (!applied) { failed++; continue; }
    }
    if (revision !== contentRevision(d.db)) { failed++; continue; }
    calls++;
    const brief = await makeBrief(d, "project_brief", p.name, detail);
    if (brief === null) { failed++; continue; }
    const applied = store.hub.db.transaction(() => {
      const current = store.project(id);
      if (!current || revision !== contentRevision(d.db)) { discardedCall(d.db, brief.call_id); return false; }
      store.upsertProject({ ...current, brief: brief.text, updated_at: toLocalIso(now) });
      store.setState(pendingKey, null);
      appliedCall(d.db,brief.call_id);
      return true;
    }).immediate();
    if (applied) updated++; else failed++;
  }
  return { calls, updated, failed };
}

// ---------------- 5. 当前状态（确定性，不调模型） ----------------

export function nowStep(store: DistillStore, now: number) {
  return store.hub.db.transaction(() => {
    const summary = nowSummary(store, now);
    store.setState("now", summary);
    return { threads: summary.detail.threads.length };
  }).immediate();
}

// ---------------- 6. 线程生命周期 ----------------

function localDayBoundary(ms: number): number {
  const date = new Date(ms);
  date.setHours(0, 0, 0, 0);
  return date.getTime();
}

/** 用记录时间索引跳过同一天的其余记录。最后活动所在日不计入等待天数。 */
function usageDayCutoff(store: DistillStore, now: number, days: number): number | null {
  const latest = store.hub.db.prepare("SELECT MAX(t_start_ms) AS last FROM records WHERE t_start_ms<?");
  let before = now + 1;
  for (let day = 0; day < days; day++) {
    const { last } = latest.get(before) as { last: number | null };
    if (last === null) return null;
    before = localDayBoundary(last);
  }
  return before;
}

export function lifecycleStep(store: DistillStore, now: number) {
  const sql = store.hub.db;
  return sql.transaction(() => {
    const cutoff = usageDayCutoff(store, now, readGeneral(store.hub).archive_days);
    const archived = cutoff === null ? 0 : sql.prepare(`UPDATE threads SET status='archived'
      WHERE status IN ('active','paused') AND last_ms<?`).run(cutoff).changes;
    const expired = sql.prepare(`UPDATE pending SET resolved_at=?,resolution='expired'
      WHERE kind='thread_done' AND resolved_at IS NULL`).run(new Date(now).toISOString()).changes;
    const paused = sql.prepare("UPDATE threads SET status='paused' WHERE status='active' AND last_ms<?")
      .run(now - LIMITS.pauseAfter).changes;
    return { paused, asked: 0, archived, expired };
  })();
}

// ---------------- 7. 日记 ----------------

type DayStepResult = { calls: number; ok: boolean; error?: ModelErrorCode };

export async function dayStep(d: Deps, store: DistillStore, date: string, now: number): Promise<DayStepResult> {
  const start = localDayStart(date);
  if (start === null || start > now) return { calls: 0, ok: false, error: "bad_request" };
  const next = new Date(start);
  next.setDate(next.getDate() + 1);
  const end = Math.min(next.getTime(), now + 1), cutoff = toLocalIso(Math.min(next.getTime(), now));
  const revision = contentRevision(d.db);
  const { segments, omittedRecordIds, dependencyRecordIds } = reviewPlan(d.db, start, end), material = reviewMaterial(segments);
  const failed = (calls: number, discarded = false, error?: ModelErrorCode) => {
    store.hub.db.transaction(() => {
      store.upsertDay({ date, needs_regen: 1 });
      store.setState(`day_failed:${date}`, discarded ? null : true);
    })();
    return { calls, ok: false, ...(error ? { error } : {}) };
  };
  const result = material.length ? await complete<P.DayOutput>(d, { tier: "day", task: "day", system: P.DAY_SYSTEM, timeoutMs: 300_000,
    prompt: P.dayPrompt(date, material, cutoff), schema: P.DAY_SCHEMA, normalizeOutput: P.normalizeDayOutput }) : null;
  const calls = Number(!!result);
  if (result?.ok === false) return result.discarded ? failed(calls, true) : failed(calls, false, classifyModelError(result.error));
  const warnings: string[] = [];
  const detail = composeReview(segments, result?.data ?? { highlight: null, items: [] },
    next.getTime(), cutoff, omittedRecordIds, dependencyRecordIds, activity => warnings.push(activity));
  if (!detail) {
    discardedCall(d.db, result?.call_id);
    return failed(calls, false, "schema_mismatch");
  }
  return store.hub.db.transaction(() => {
    if (revision !== contentRevision(d.db)) {
      discardedCall(d.db, result?.call_id);
      return failed(calls, true);
    }
    store.upsertDay({ date, detail, brief: detail.summary, needs_regen: 0, updated_at: toLocalIso(now) });
    store.setState(`day_failed:${date}`, null);
    if (result?.ok) {
      appliedCall(d.db, result.call_id);
      if (warnings.length) {
        if (result.call_id) d.db.db.prepare("UPDATE runtime_calls SET error='schema_mismatch' WHERE id=? AND content_state='available'").run(result.call_id);
        d.log?.(JSON.stringify({ step: "day", category: "schema_mismatch", count: warnings.length }));
      }
    }
    return { calls, ok: true };
  }).immediate();
}

/** 今天的文本逐段发布。独立保存概述，保证概述失败时段落仍可读。 */
async function todayStep(d: Deps, store: DistillStore, now: number, timing: "fast" | "hourly" | "manual"): Promise<DayStepResult> {
  const date = localDate(now), start = startOfDay(now);
  const { polish, overview } = readTimelineSettings(d.db);
  const previous = (store.day(date)?.detail ?? null) as ReviewDetail | null;
  const plan = incrementalReview(d.db, start, now, previous);
  if (!previous && !plan.pending.length && !plan.omittedIds([], []).length) return { calls: 0, ok: true };

  const revision = contentRevision(d.db);
  const stillCurrent = (expected: ReviewDetail | null) => revision === contentRevision(d.db) &&
    JSON.stringify(store.day(date)?.detail ?? null) === JSON.stringify(expected);
  let calls = 0, error: ModelErrorCode | undefined;
  const mayPolish = polish === "after_segment" || (polish === "hourly" && timing !== "fast");
  const segments = mayPolish ? plan.segments() : [];
  const recent = applyTimelineCorrections(plan.items.slice(-5), store.getState<TimelineCorrections>(timelineCorrectionKey(date)))
    .map(({ title, description }) => ({ title, description }));
  const result = segments.length ? await complete<P.DayOutput>(d, {
    tier: "day", task: "day_polish", system: P.DAY_POLISH_SYSTEM, timeoutMs: 300_000,
    prompt: P.dayPolishPrompt(date, reviewMaterial(segments), recent),
    schema: P.DAY_SCHEMA, normalizeOutput: P.normalizeDayOutput,
  }) : null;
  const warnings: string[] = [];
  const polished = result?.ok ? composePolish(segments, result.data, key => warnings.push(key)) : null;
  if (result) {
    calls++;
    if (!result.ok) error = classifyModelError(result.error);
    else if (!polished) error = "schema_mismatch";
  }
  const completed = polished ? plan.ready.map(entry => entry.snapshot) : [];
  const processed = [...plan.preserved, ...completed];
  const snapshots = [...processed.map(({ pending: _pending, ...entry }) => entry),
    ...plan.pending.map(entry => entry.snapshot).filter(entry => entry.pending && !completed.includes(entry))]
    .sort((a, b) => a.start - b.start);
  const items = [...plan.items, ...(polished ?? [])].sort((a, b) => Date.parse(a.t_start) - Date.parse(b.t_start));
  const detail: ReviewDetail = {
    ...previous, items, summary: previous?.summary ?? null,
    timeline: items.map(item => ({ start: item.t_start.slice(11, 16), end: item.t_end.slice(11, 16), text: item.title }))
      .filter(item => item.start !== item.end),
    cutoff: toLocalIso(Math.max(Date.parse(previous?.cutoff ?? "") || start,
      ...(polished ? plan.ready.map(({ snapshot }) => snapshot.end) : []))),
    omitted_record_ids: plan.omittedIds(items, processed),
    polished_segments: snapshots,
    record_ids: [],
  };
  detail.record_ids = [...new Set([...detail.omitted_record_ids, ...snapshots.flatMap(segment => segment.dependencies)])];

  const saved = d.db.db.transaction(() => {
    if (!stillCurrent(previous)) {
      discardedCall(d.db, result?.call_id);
      return false;
    }
    if (JSON.stringify(previous) !== JSON.stringify(detail) || polished) {
      store.upsertDay({ date, detail, brief: detail.summary, needs_regen: 1,
        ...(polished ? { updated_at: new Date(d.now?.() ?? now).toISOString() } : {}) });
    }
    if (result) {
      store.setState(`day_failed:${date}`, error ? true : null);
      if (polished) {
        appliedCall(d.db, result.call_id);
        if (warnings.length) {
          if (result.call_id) d.db.db.prepare("UPDATE runtime_calls SET error='schema_mismatch' WHERE id=? AND content_state='available'").run(result.call_id);
          d.log?.(JSON.stringify({ step: "day_polish", category: "schema_mismatch", count: warnings.length }));
        }
      } else discardedCall(d.db, result.call_id);
    }
    return true;
  }).immediate();
  if (!saved) return { calls, ok: false, error: "unknown" };

  const overviewDue = overview !== "nightly" && timing !== "fast" &&
    (timing === "manual" || overview === "hourly" || now - (detail.overview_checked_ms ?? 0) >= 3 * HOUR);
  if (overviewDue) {
    const headline = await overviewStep(d, store, date, now, detail, () => stillCurrent(detail));
    calls += headline.calls;
    error ??= headline.error;
  }
  return { calls, ok: !error, ...(error ? { error } : {}) };
}

async function overviewStep(d: Deps, store: DistillStore, date: string, now: number,
  detail: ReviewDetail, stillCurrent: () => boolean): Promise<DayStepResult> {
  const corrections = store.getState<TimelineCorrections>(timelineCorrectionKey(date));
  const projects = new Map<string, string | null>();
  // 带上开始时刻并按时间排：同一件事后来解决了，模型才能分清哪句是最新状态。
  const activities = applyTimelineCorrections(detail.items, corrections).filter(item => item.active_seconds > 0)
    .sort((a, b) => Date.parse(a.t_start) - Date.parse(b.t_start))
    .map(({ t_start, title, description, project_id }) => {
      if (project_id && !projects.has(project_id)) projects.set(project_id, store.project(project_id)?.name ?? null);
      return { start: t_start.slice(11, 16), title, description, project: project_id ? projects.get(project_id) ?? null : null };
    });
  const prompt = P.dayOverviewPrompt(activities);
  const input = createHash("sha256").update(prompt).digest("hex");
  const changed = input !== detail.overview_input;
  const result = changed && activities.length ? await complete<{ summary: string | null }>(d, {
    tier: "day", task: "day_brief", system: P.DAY_OVERVIEW_SYSTEM, timeoutMs: 300_000,
    prompt, schema: P.DAY_OVERVIEW_SCHEMA,
  }) : null;
  if (result?.ok === false) return { calls: 1, ok: false, error: classifyModelError(result.error) };
  const summary = result?.data.summary === null || !result ? null : redactString(result.data.summary).text.trim();
  const sentences = summary?.match(/[。！？!?]+|\.(?=\s|$)/gu)?.length ?? 0;
  if (result && summary !== null && (sentences < 2 || sentences > 4 || Array.from(summary).length > P.MAX_DAY_SUMMARY_CHARS)) {
    discardedCall(d.db, result.call_id);
    return { calls: 1, ok: false, error: "schema_mismatch" };
  }
  const calls = Number(!!result);
  return d.db.db.transaction((): DayStepResult => {
    if (!stillCurrent()) {
      discardedCall(d.db, result?.call_id);
      return { calls, ok: false, error: "unknown" };
    }
    const next = { ...detail, summary: changed ? summary : detail.summary, overview_input: input, overview_checked_ms: now };
    store.upsertDay({ date, detail: next, brief: next.summary, ...(result ? { updated_at: new Date(d.now?.() ?? now).toISOString() } : {}) });
    appliedCall(d.db, result?.call_id);
    return { calls, ok: true };
  }).immediate();
}

// ---------------- 一轮 ----------------

export interface RoundOptions { backfill?: boolean; slow?: boolean; days?: "all" | "past" | "none"; enabledDefault?: number; wantedDigestsOnFast?: boolean }

/** 快步骤每轮都跑；slow=true 时再跑线程、项目和日记。冷却会在下次模型调用前中止这一轮。 */
export async function distillRound(deps: Deps, opts: RoundOptions = {}) {
  const clock = deps.now ?? Date.now, now = clock();
  const store = new DistillStore(deps.db);
  const out: Record<string, unknown> = { at: toLocalIso(now) };
  const d: Deps = { ...deps, llm: withModelCooldown(deps.llm, store, clock) };
  try { await distillRoundInner(d, opts, out, store, now); }
  catch (error) {
    if (!(error instanceof ModelCooldown)) throw error;
    out.stopped = error.kind;
  }
  return out;
}

async function distillRoundInner(d: Deps, opts: RoundOptions, out: Record<string, unknown>, store: DistillStore, now: number) {
  out.slice = sliceStep(d.db, opts.backfill ?? false, now, opts.enabledDefault ?? now);
  const active = activeCooldown(store, now);
  if (active) out.stopped = active.kind;
  else {
    try {
      // 先写对话总结，归线程时给模型看总结而不是转写开头。
      out.conversations = await conversationStep(d, now);
      out.assign = await assignStep(d, store, now);
      out.classify = await classifyStep(d, store);
      if (opts.slow) {
        if (now - (store.getState<number>("dedup_ms") ?? 0) >= LIMITS.dedupEvery) {
          out.dedup = await dedupStep(d, store, now);
          if (!(out.dedup as { failed: number }).failed) store.setState("dedup_ms", now);
        }
        out.digest = await digestStep(d, store, now, "all");
        out.projects = await projectStep(d, store, now);
      } else if (opts.wantedDigestsOnFast && store.wantedDigests().size) {
        out.digest = await digestStep(d, store, now, "wanted");
      }
    } catch (error) {
      if (!(error instanceof ModelCooldown)) throw error;
      out.stopped = error.kind;
    }
  }
  out.lifecycle = lifecycleStep(store, now);
  out.now = nowStep(store, now);
  store.setState("last_round_at", toLocalIso(now));
  if (!out.stopped && opts.slow && opts.days !== "none") {
    const today = localDate(now);
    const days = (d.db.db.prepare("SELECT date FROM days WHERE needs_regen=1 ORDER BY date").all() as { date: string }[])
      .map(r => r.date).filter(date => date < today);
    let calls = 0, done = 0;
    for (const date of days) { const r = await dayStep(d, store, date, now); calls += r.calls; if (r.ok) done++; }
    out.days = { calls, done, pending: days.length - done };
  }
  if (!out.stopped && opts.days === "all") {
    const result = await todayStep(d, store, now, opts.slow ? "hourly" : "fast");
    out.today = { ...result, failed: Number(!result.ok) };
  }
}

/** 按日期范围整理启用前的历史：[from 当天 0 点, to 次日 0 点) 与启用时刻取交集，按天切片。
 * 不看 backfill_done，可以对同一范围重复执行；已进片段的记录由 frame_records 自动排除。范围外不处理。 */
export function backfillRange(db: HubDB, from: string, to: string, opts: { enabledDefault?: number; onProgress?: (done: number, total: number) => void } = {}) {
  const start = localDayStart(from), last = localDayStart(to);
  if (start === null || last === null || start > last) throw new Error("日期范围无效");
  const store = new DistillStore(db);
  const enabled = store.getState<number>("enabled_ms") ?? opts.enabledDefault ?? startOfDay(Date.now());
  store.setState("enabled_ms", enabled);
  const end = new Date(last); end.setDate(end.getDate() + 1);
  const stop = Math.min(end.getTime(), enabled);
  const rows = db.db.prepare("SELECT t_start_ms FROM records WHERE t_start_ms>=? AND t_start_ms<? ORDER BY t_start_ms").all(start, stop) as { t_start_ms: number }[];
  const days = [...new Set(rows.map(r => startOfDay(r.t_start_ms)))];
  let frames = 0;
  opts.onProgress?.(0, days.length);
  days.forEach((day, i) => {
    const next = new Date(day); next.setDate(next.getDate() + 1);
    const r = persistFrames(db, Math.max(day, start) - 1, Number.MAX_SAFE_INTEGER, Math.min(next.getTime(), stop));
    markFrameReviewDays(store, r.frames, stop);
    frames += r.frames.length;
    opts.onProgress?.(i + 1, days.length);
  });
  return { days: days.length, frames };
}

/** 状态写入遇到库忙时，下一次先补写完成或重新排队。 */
export interface LoopState { lastRound: number; enabledDefault: number; unfinished?: { id: string; error?: string; at: number; requeue?: boolean } }
/** 常驻循环的一步：有排队请求就领取执行；否则到时间了跑常规一轮。返回这一步做了什么。 */
export async function distillTick(deps: Deps, state: LoopState, at?: number): Promise<"request" | "round" | "idle"> {
  const clock = deps.now ?? (at === undefined ? Date.now : () => at);
  const now = at ?? clock(), d = { ...deps, now: clock };
  const store = new DistillStore(d.db), requests = new DistillRequests(d.db);
  const log = d.log ?? console.log;
  const settleRequest = () => {
    const pending = state.unfinished;
    if (!pending) return;
    if (pending.requeue) requests.requeue(pending.id);
    else requests.finish(pending.id, pending.error, pending.at);
    state.unfinished = undefined;
  };
  store.setState("heartbeat_at", toLocalIso(now));
  settleRequest();
  const req = activeCooldown(store, now) ? null : requests.claim(now);
  if (req) {
    let error: ModelErrorCode | undefined, requeue = false;
    try {
      // 打开时间线排的当天补整理：排队后常规轮次已经写过今天，就不再重写一遍。
      const today = localDate(now);
      if (req.kind === "regen_days" && req.from === today && req.to === today && !requests.regenProgress(req.id)
          && (Date.parse(store.day(today)?.updated_at ?? "") || 0) >= Date.parse(req.created_at)) {
        log(JSON.stringify({ request: req.id, regen_days: { days: 0, calls: 0, skipped: "fresh" } }));
      } else if (req.kind === "regen_days") {
        let checkpoint = requests.regenProgress(req.id);
        if (!checkpoint) {
          const start = localDayStart(req.from!), last = localDayStart(req.to!);
          if (start === null || last === null || start > last) throw new Error("日期范围无效");
          const end = new Date(last); end.setDate(end.getDate() + 1);
          const rows = d.db.db.prepare("SELECT t_start_ms FROM records WHERE t_start_ms>=? AND t_start_ms<? ORDER BY t_start_ms").all(start, end.getTime()) as { t_start_ms: number }[];
          const dates = [...new Set(rows.map(r => localDateString(r.t_start_ms)))];
          checkpoint = { dates };
          d.db.db.transaction(() => {
            for (const date of dates) store.upsertDay({ date, needs_regen: 1 });
            requests.saveRegenProgress(req.id, 0, { dates });
          })();
        }
        const work = { ...d, llm: withModelCooldown(d.llm, store, clock) };
        const { dates } = checkpoint;
        let calls = 0;
        for (let i = req.progress?.done ?? 0; i < dates.length; i++) {
          const date = dates[i]!;
          try {
            const at = clock();
            const result = date === localDate(at)
              ? await todayStep(work, store, at, "manual")
              : await dayStep(work, store, date, at);
            calls += result.calls;
            if (!result.ok) checkpoint.error ??= result.error ?? "unknown";
          } catch (cause) {
            if (cause instanceof ModelCooldown) throw cause;
            store.upsertDay({ date, needs_regen: 1 });
            checkpoint.error ??= classifyModelError(cause);
          }
          requests.saveRegenProgress(req.id, i + 1, checkpoint);
        }
        error = checkpoint.error;
        log(JSON.stringify({ request: req.id, regen_days: { days: dates.length, calls, ...(error ? { error } : {}) } }));
      } else if (req.kind === "backfill") {
        if (!req.progress || req.progress.done < req.progress.total) {
          const r = backfillRange(d.db, req.from!, req.to!, { enabledDefault: state.enabledDefault, onProgress: (done, total) => requests.progress(req.id, done, total) });
          log(JSON.stringify({ request: req.id, backfill: r }));
        }
        // 切好的片段接着归线程、写线程和日记；一轮处理不完的由后续常规轮次继续。
        const result = await distillRound(d, { slow: true, days: "all", enabledDefault: state.enabledDefault });
        log(JSON.stringify(result));
        requeue = Boolean(result.stopped);
      } else requeue = await regularRound(d, state);
    } catch (cause) {
      if (cause instanceof ModelCooldown) {
        requeue = true;
        log(JSON.stringify({ request: req.id, stopped: cause.kind }));
      } else {
        error = classifyModelError(cause);
        log(JSON.stringify({ request: req.id, error }));
      }
    }
    state.unfinished = { id: req.id, error, at: clock(), ...(requeue ? { requeue } : {}) };
    settleRequest();
    return "request";
  }
  if (now - state.lastRound < 15 * MIN) return "idle";
  try { await regularRound(d, state); }
  catch (error) { log(JSON.stringify({ error: classifyModelError(error) })); }
  return "round";
}

async function regularRound(d: Deps, state: LoopState) {
  const store = new DistillStore(d.db), log = d.log ?? console.log;
  const now = d.now?.() ?? Date.now();
  // 失败也算跑过一轮，避免出错时每 5 秒重试一次。
  state.lastRound = now;
  // 只有一个整点钟：快步骤每 15 分钟；到点后按顺序写事项、项目、当天概述与过往日期的日记。
  const slowDue = now - (store.getState<number>("slow_ms") ?? 0) >= HOUR;
  const result = await distillRound(d, { slow: slowDue, days: "all", enabledDefault: state.enabledDefault, wantedDigestsOnFast: true });
  log(JSON.stringify(result));
  if (result.stopped) return true;
  const failed = Object.values(result).some(v => v && typeof v === "object" && "failed" in v && Number(v.failed) > 0)
    || Number((result.days as { pending?: number } | undefined)?.pending ?? 0) > 0;
  // 失败的慢速整理在下一轮（15 分钟）重试；不能把失败当完成再等整整一小时。
  if (slowDue && !failed) store.setState("slow_ms", now);
  return false;
}

export async function runDistill({ db, llm, once, backfill, range, log = console.log, pollMs = 5000 }: { db: HubDB; llm: LLM; once: boolean; backfill: boolean; range?: { from: string; to: string }; log?: (line: string) => void; pollMs?: number }) {
  const store = new DistillStore(db);
  refreshDerivedState(store);
  const d: Deps = { db, llm, log };
  const enabledDefault = startOfDay(Date.now());
  if (range) log(JSON.stringify(backfillRange(db, range.from, range.to, { enabledDefault })));
  if (once || backfill) { log(JSON.stringify(await distillRound(d, { backfill: backfill && !range, slow: true, days: "all", enabledDefault }))); if (once) return; }
  new DistillRequests(db).recoverInterrupted();
  // 长任务（一轮可能几分钟）期间也写心跳，状态页据此判断提炼进程是否还活着。
  const beat = setInterval(() => { try { store.setState("heartbeat_at", toLocalIso(Date.now())); } catch { /* 库忙时下一次再写 */ } }, 30_000);
  const state: LoopState = { lastRound: 0, enabledDefault };
  try {
    for (;;) {
      // 刚执行完请求时立刻再看一次队列；空闲时每 pollMs 看一次，常规轮次仍按 15 分钟。
      if (await tickSafely(d, state) !== "request") await new Promise(r => setTimeout(r, pollMs));
    }
  } finally { clearInterval(beat); }
}

/** 一次性使旧算法的派生结果失效；保留详细版和增量检查点，由现有有界队列重写。 */
export function refreshDerivedState(store: DistillStore, now = Date.now()) {
  const key = "derived_correctness_v1";
  return store.hub.db.transaction(() => {
    if (store.getState<boolean>(key)) return false;
    const rows = store.hub.db.prepare("SELECT id FROM threads").all() as { id: string }[];
    const update = store.hub.db.prepare("UPDATE threads SET active_minutes=?,needs_regen=1 WHERE id=?");
    for (const { id } of rows) update.run(store.activeMinutes(id), id);
    store.hub.db.prepare("UPDATE days SET needs_regen=1").run();
    // 项目详细版没有受计时影响，简略版直接从现有详细版重写，不重放历史记录。
    for (const p of store.projects()) if (p.detail != null) store.setState(`project_brief:${p.id}`, true);
    store.setState("slow_ms", null); store.setState("today_ms", null);
    nowStep(store, now);
    store.setState(key, true);
    return true;
  })();
}

/**
 * 库被 hub 连续写入（例如导入全部历史）时，心跳和领取请求可能等锁超时；
 * 这只是这一次没轮上，下一次再试，不能让常驻进程退出。其他错误照旧抛出。
 */
export async function tickSafely(d: Deps, state: LoopState, now?: number): Promise<"request" | "round" | "idle" | "busy"> {
  try { return await distillTick(d, state, now); }
  catch (e) {
    if ((e as { code?: unknown })?.code !== "SQLITE_BUSY") throw e;
    (d.log ?? console.log)(JSON.stringify({ step: "storage_busy", error: "unknown" }));
    return "busy";
  }
}
