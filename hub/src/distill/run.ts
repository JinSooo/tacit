// 提炼流程：切片 → 归线程 → 线程详细版 → 简略版 → 项目 → 当前状态 → 日记。契约：docs/contracts.md 第 4 节。
// 模型调用都在事务之外；每一步落库用小事务，失败只影响这一步，下一轮再试。
// 日志只写计数，不写任何记录内容或标题。
import type { HubDB } from "../db.ts";
import { ulid, toLocalIso } from "../../../packages/record/index.ts";
import type { LLMRequest, LLMResult } from "../llm/index.ts";
import { DistillStore, type Frame, type Thread } from "./store.ts";
import { persistFrames } from "./frames.ts";
import { DistillRules } from "./rules.ts";
import { DistillRequests, localDayStart } from "./requests.ts";
import * as P from "./prompts.ts";
import { readGeneral } from "../general-settings.ts";
import { CONVERSATION_GAP_MS, conversationsIn, groupTurns, saveSummary, storedSummary, summaryState, speakerNamer } from "../conversations.ts";

export interface LLM { complete<T>(req: LLMRequest): Promise<LLMResult<T>> }
export interface Deps { db: HubDB; llm: LLM; now?: () => number; log?: (line: string) => void }

const MIN = 60_000, HOUR = 60 * MIN, DAY = 24 * HOUR;
export const LIMITS = {
  assignBatch: 20, assignChars: 24_000, assignExcerpt: 240, assignRecords: 10, assignThreads: 40,
  digestChars: 45_000, sessionExcerpt: 3_000, otherExcerpt: 800, digestRecords: 40, threadsPerRound: 12,
  candidateTTL: DAY, newSession: 30 * MIN, pauseAfter: 2 * HOUR,
  // 最近确认完成的线程也给模型选：结束后又聊到它的零星跟进归回去，不再只进日记（2026-11-10 实测：九院线程已完成，后续对话无处可归）。
  // 自动归档（archived）的不放：用户没确认，按规则不再参与。
  assignDoneThreads: 10, assignDoneWindow: 14 * DAY,
  // 门槛（AGENTS.md）：累计 15 分钟或跨两段活动才建线程，不够的只进日记。
  threadMinutes: 15, threadFrames: 2,
  // 对话总结：只看录音保留期内的，每轮最多写几场，单场原文太长时留头尾。
  conversationDays: 7, conversationsPerRound: 4, conversationChars: 24_000,
};

const pad = (n: number) => String(n).padStart(2, "0");
const clock = (ms: number) => { const d = new Date(ms); return `${pad(d.getMonth() + 1)}-${pad(d.getDate())} ${pad(d.getHours())}:${pad(d.getMinutes())}`; };
const hhmm = (ms: number) => { const d = new Date(ms); return `${pad(d.getHours())}:${pad(d.getMinutes())}`; };
export const localDate = (ms: number) => toLocalIso(ms).slice(0, 10);
export const startOfDay = (ms: number) => { const d = new Date(ms); d.setHours(0, 0, 0, 0); return d.getTime(); };
const minutesOf = (f: Frame) => Math.max(0, (f.t_end_ms - f.t_start_ms) / MIN);
const isSession = (source: string) => source === "claude_code.session" || source === "codex.session";

/** 按条件读片段（避免整表读出后在内存里过滤）。 */
export function loadFrames(store: DistillStore, where: string, ...args: unknown[]): Frame[] {
  return (store.hub.db.prepare(`SELECT * FROM frames ${where}`).all(...args) as (Omit<Frame, "record_ids"> & { record_ids: string })[])
    .map(r => ({ ...r, record_ids: JSON.parse(r.record_ids) as string[] }));
}

interface Candidate { id: string; title: string; frame_ids: string[]; minutes: number; last_ms: number; project_id: string | null }

// ---------------- 1. 切片 + 规则归属（确定性，一个事务） ----------------

/** enabledDefault：首次运行时增量处理的起点。用户 2026-11-08 选定\"今天之后\"，CLI 传当天 0 点；测试传 now。 */
export function sliceStep(db: HubDB, backfill = false, now = Date.now(), enabledDefault = now) {
  const store = new DistillStore(db), rules = new DistillRules(store);
  return db.db.transaction(() => {
    let cursor = store.getState<number>("cursor_ms");
    if (cursor === null) { cursor = now; store.setState("cursor_ms", cursor); }
    const enabled = store.getState<number>("enabled_ms") ?? enabledDefault;
    store.setState("enabled_ms", enabled);
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
    for (const f of touched) store.upsertDay({ date: localDate(f.t_start_ms), needs_regen: 1 });
    for (const frame of store.frames().filter(f => f.status === "new")) {
      if (frame.key.startsWith("repo:")) rules.projectForRepo(frame.key.slice(5));
      const r = rules.assign(frame);
      if (r.status === "assigned") { assigned++; touchThread(store, r.thread_id, frame); }
    }
    return { frames: created, assigned, unassigned: store.frames().filter(f => f.status === "new").length };
  })();
}

/** 片段归入线程后更新线程的时间统计，并标记需要重新提炼。 */
export function touchThread(store: DistillStore, threadId: string, frame: Frame) {
  const t = store.thread(threadId);
  if (!t) return;
  const newSession = !t.last_ms || frame.t_start_ms - t.last_ms > LIMITS.newSession;
  let project_hint = t.project_hint ?? null;
  if (!project_hint && frame.key.startsWith("repo:")) project_hint = new DistillRules(store).projectForRepo(frame.key.slice(5))?.id ?? null;
  store.upsertThread({
    ...t, project_hint,
    status: t.status === "paused" ? "active" : t.status,
    first_ms: Math.min(t.first_ms ?? frame.t_start_ms, frame.t_start_ms),
    last_ms: Math.max(t.last_ms ?? 0, frame.t_end_ms),
    active_minutes: (t.active_minutes ?? 0) + Math.round(minutesOf(frame)),
    sessions: (t.sessions ?? 0) + (newSession ? 1 : 0),
    needs_regen: 1,
  });
  if (t.project_id) store.hub.db.prepare("UPDATE projects SET needs_regen=1 WHERE id=?").run(t.project_id);
}

// ---------------- 片段给模型看的样子 ----------------

export function frameView(store: DistillStore, f: Frame, opts: { maxRecords: number; excerpt: (source: string) => number }): P.FrameView {
  const ids = f.record_ids.length <= opts.maxRecords ? f.record_ids
    : Array.from({ length: opts.maxRecords }, (_, i) => f.record_ids[Math.round(i * (f.record_ids.length - 1) / (opts.maxRecords - 1))]!);
  let hidden = 0;
  const records = ids.flatMap(id => {
    const r = store.hub.get(id);
    if (!r) return [];
    // private 记录的标题和正文都不发给模型；同一片段里的其他记录照常发送。
    if (r.sensitivity === "private") { hidden++; return []; }
    return [{ id: r.id, source: r.source, title: r.title, excerpt: P.excerpt(r.body, opts.excerpt(r.source)) }];
  });
  if (hidden) records.push({ id: "", source: "note", title: `（另有 ${hidden} 条私密记录，内容未提供）`, excerpt: "" });
  if (ids.length < f.record_ids.length) records.push({ id: "", source: "note", title: `（共 ${f.record_ids.length} 条，只列出 ${ids.length} 条）`, excerpt: "" });
  // 整个片段都是私密记录时才整段隐藏（只给应用和时长）。
  const allPrivate = hidden > 0 && records.every(r => r.source === "note");
  return { id: f.id, start: clock(f.t_start_ms), end: clock(f.t_end_ms), key: f.key, private: allPrivate, records };
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
  let candidates = (store.getState<Candidate[]>("candidates") ?? []).filter(c => now - c.last_ms < LIMITS.candidateTTL);
  const pending = loadFrames(store, "WHERE status='new' ORDER BY t_start_ms,id");
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
  outer: for (const group of groups.values()) for (const batch of batches(group.views, x => JSON.stringify(x.v).length, LIMITS.assignChars, LIMITS.assignBatch)) {
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
    const r = await d.llm.complete<P.AssignOutput>({ tier: "minute", system: P.ASSIGN_SYSTEM, prompt: P.assignPrompt(batch.map(x => x.v), choices), schema: P.ASSIGN_SCHEMA });
    if (!r.ok) { failed += batch.length; log(JSON.stringify({ step: "assign", ok: false, frames: batch.length })); break outer; }
    const byFrame = new Map(r.data.items.map(i => [i.frame_id, i]));
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
        if (!cand) {
          const project = f.key.startsWith("repo:") ? new DistillRules(store).projectForRepo(f.key.slice(5)) : null;
          cand = { id: ulid(now), title: title!, frame_ids: [], minutes: 0, last_ms: 0, project_id: project?.id ?? null };
          candidates.push(cand);
        }
        cand.frame_ids.push(f.id); cand.minutes += minutesOf(f); cand.last_ms = Math.max(cand.last_ms, f.t_end_ms);
        // 候选期间片段标为 ignored，不会被重复发给模型；建线程时再正式归属。
        store.hub.db.prepare("UPDATE frames SET status='ignored' WHERE id=?").run(f.id);
        if (cand.minutes >= LIMITS.threadMinutes || cand.frame_ids.length >= LIMITS.threadFrames) {
          const frames = loadFrames(store, `WHERE id IN (${cand.frame_ids.map(() => "?").join(",")}) ORDER BY t_start_ms,id`, ...cand.frame_ids);
          if (frames.length) {
            const id = ulid(now);
            // last_ms 先留空，第一个片段由 touchThread 计为一段会话。
            store.upsertThread({ id, project_hint: cand.project_id, status: "active", title: cand.title, first_ms: frames[0]!.t_start_ms, active_minutes: 0, sessions: 0, needs_regen: 1 });
            for (const fr of frames) { store.assign(fr.id, id, "llm", item.confidence); touchThread(store, id, fr); }
            created++; assigned += frames.length; real.add(id); byTitle.set(cand.title, id);
          }
          candidates = candidates.filter(c => c !== cand);
        }
      }
      store.setState("candidates", candidates);
    })();
  }
  store.setState("candidates", candidates);
  return { calls, assigned, created_threads: created, ignored, failed, candidates: candidates.length };
}

// ---------------- 3. 线程详细版 + 简略版 ----------------

function factViews(store: DistillStore, field: "thread_id" | "project_id", id: string): P.FactView[] {
  return store.facts(field, id).map(f => ({ id: f.id, kind: f.kind, text: f.text, origin: f.origin }));
}

function threadFrames(store: DistillStore, threadId: string): Frame[] {
  return loadFrames(store, "WHERE id IN (SELECT frame_id FROM assignments WHERE thread_id=?) ORDER BY t_start_ms,id", threadId);
}

async function makeBrief(d: Deps, title: string, detail: unknown, facts: P.FactView[]): Promise<string | null> {
  const r = await d.llm.complete<P.BriefOutput>({ tier: "minute", system: P.BRIEF_SYSTEM, prompt: P.briefPrompt(title, detail, facts), schema: P.BRIEF_SCHEMA });
  return r.ok ? r.data.brief.trim() : null;
}

/** 已经提炼进详细版的片段，以及当时这些片段的记录总数（变少说明有记录被删，要整条重建）。 */
interface DigestMark { frames: string[]; records: number }

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
    const r = await d.llm.complete<P.ConversationOutput>({ tier: "minute", system: P.CONVERSATION_SYSTEM,
      prompt: P.conversationPrompt({ start: clock(g.start_ms), end: clock(g.end_ms), app: g.app }, conversationTranscript(turns)), schema: P.CONVERSATION_SCHEMA });
    if (!r.ok) continue;
    const out = { title: r.data.title.trim(), summary: r.data.summary.trim(), points: r.data.points.map(p => p.trim()).filter(Boolean).slice(0, 5) };
    if (!out.title || !out.summary) continue;
    // 调用期间记录可能被删或者接上了新的一段：组成变了就不写，下一轮重来。
    const current = conversationsIn(d.db, g.start_ms, g.start_ms).find(c => c.id === g.id);
    if (!current || JSON.stringify(current.record_ids) !== JSON.stringify(g.record_ids)) continue;
    saveSummary(d.db, g, out); done++;
  }
  return { calls, done, pending: todo.length - done };
}

export async function classifyStep(d: Deps, store: DistillStore) {
  let calls = 0, updated = 0, failed = 0;
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
      const r = await d.llm.complete<P.Classification>({ tier: "minute", system: P.CLASSIFY_SYSTEM,
        prompt: P.classifyPrompt(t, projectHint(store, t)), schema: P.CLASSIFY_SCHEMA });
      if (!r.ok) { failed++; continue; }
      store.hub.db.transaction(() => applyClassification(store, id, r.data))();
      updated++;
    } catch { failed++; }
  }
  return { calls, updated, failed };
}

export async function digestStep(d: Deps, store: DistillStore, now: number) {
  const log = d.log ?? (() => {});
  let updated = 0, failed = 0, facts = 0, calls = 0, dropped = 0;
  const threads = store.hub.db.prepare("SELECT id FROM threads WHERE needs_regen=1 AND status!='abandoned' ORDER BY last_ms DESC LIMIT ?").all(LIMITS.threadsPerRound) as { id: string }[];
  for (const { id } of threads) {
    const thread = store.thread(id)!;
    const frames = threadFrames(store, id);
    const countOf = (ids: Set<string>) => frames.filter(f => ids.has(f.id)).reduce((n, f) => n + f.record_ids.length, 0);
    if (!frames.length) {
      store.upsertThread({ ...thread, detail: null, brief: null, needs_regen: 0, updated_at: toLocalIso(now) });
      store.setState(`digest:${id}`, null); continue;
    }
    const mark = store.getState<DigestMark>(`digest:${id}`);
    const present = new Set(frames.map(f => f.id));
    // 片段或记录被删过就整条线程从头重建，保证删掉的内容不会留在详细版里。
    const rebuild = !mark || mark.frames.some(f => !present.has(f)) || countOf(new Set(mark.frames)) < mark.records;
    const done = new Set(rebuild ? [] : mark!.frames);
    const fresh = frames.filter(f => !done.has(f.id));
    let detail: unknown = rebuild ? { goal: "", progress: "", artifacts: { files: [], urls: [], commands: [], people: [] }, quotes: [] } : thread.detail;
    let title = thread.title, ok = true, doneHint = false;
    const views = fresh.map(f => ({ f, v: frameView(store, f, { maxRecords: LIMITS.digestRecords, excerpt: s => isSession(s) ? LIMITS.sessionExcerpt : LIMITS.otherExcerpt }) }));
    for (const chunk of batches(views, x => JSON.stringify(x.v).length, LIMITS.digestChars, 50)) {
      calls++;
      const r = await d.llm.complete<P.ThreadOutput>({ tier: "hour", system: P.THREAD_SYSTEM, prompt: P.threadPrompt({ title, detail }, factViews(store, "thread_id", id), chunk.map(x => x.v), projectHint(store, store.thread(id)!)), schema: P.THREAD_SCHEMA });
      if (!r.ok) { ok = false; break; }
      const known = new Set(chunk.flatMap(x => x.v.records.map(rec => rec.id)).filter(Boolean));
      const out = r.data;
      store.hub.db.transaction(() => {
        applyClassification(store, id, out);
        const kept = out.new_facts.map(f => P.keepGroundedFacts([f], known)[0] ?? null);
        dropped += kept.filter(k => !k).length;
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
          store.hub.db.prepare("UPDATE facts SET invalid_at=?,superseded_by=? WHERE id=? AND invalid_at IS NULL").run(new Date(now).toISOString(), by, inv.fact_id);
        }
        // 原话只保留能对上本批或之前已有记录的，避免编造。
        const prevQuotes = ((detail as { quotes?: { record_id: string }[] })?.quotes ?? []).map(q => q.record_id);
        const allowed = new Set([...known, ...prevQuotes]);
        detail = { ...out.detail, quotes: out.detail.quotes.filter(q => allowed.has(q.record_id) && !!store.hub.get(q.record_id)) };
        title = out.title.trim() || title;
        if (out.status_hint === "done_candidate") doneHint = true;
        store.upsertThread({ ...store.thread(id)!, title, detail });
        for (const x of chunk) done.add(x.f.id);
        store.setState(`digest:${id}`, { frames: [...done], records: countOf(done) } satisfies DigestMark);
      })();
    }
    if (!ok) { failed++; log(JSON.stringify({ step: "digest", ok: false })); continue; }
    calls++;
    const brief = await makeBrief(d, title, detail, factViews(store, "thread_id", id));
    if (brief === null) { failed++; continue; }
    store.hub.db.transaction(() => {
      store.upsertThread({ ...store.thread(id)!, brief, needs_regen: 0, updated_at: toLocalIso(now) });
      const projectId = store.thread(id)!.project_id;
      if (projectId) store.hub.db.prepare("UPDATE projects SET needs_regen=1 WHERE id=?").run(projectId);
      if (doneHint) askDone(store, id, now);
    })();
    updated++;
  }
  return { calls, updated, failed, facts, dropped_ungrounded: dropped };
}

/** 放进待确认问\"做完了吗\"；同一线程有未处理的、或在最后活动之后已经问过的，不再问。 */
function askDone(store: DistillStore, threadId: string, now: number) {
  const t = store.thread(threadId);
  if (!t || t.status === "done" || t.status === "abandoned" || t.status === "archived") return;
  const asked = (store.hub.db.prepare("SELECT created_at,resolved_at FROM pending WHERE kind='thread_done' AND json_extract(payload,'$.thread_id')=?").all(threadId) as { created_at: string; resolved_at: string | null }[])
    .some(p => !p.resolved_at || Date.parse(p.created_at) >= (t.last_ms ?? 0));
  if (!asked) store.createPending({ id: ulid(now), kind: "thread_done", payload: { thread_id: threadId }, created_at: new Date(now).toISOString() });
}

// ---------------- 4. 项目 ----------------

export async function projectStep(d: Deps, store: DistillStore, now: number) {
  let updated = 0, failed = 0, calls = 0;
  for (const p of store.projects().filter(p => p.needs_regen)) {
    const threads = store.hub.db.prepare("SELECT * FROM threads WHERE project_id=? AND status!='abandoned' ORDER BY last_ms DESC LIMIT 20").all(p.id) as (Thread & { last_ms: number | null; active_minutes: number | null })[];
    const last = Math.max(0, ...threads.map(t => t.last_ms ?? 0));
    const salience = threads.reduce((s, t) => s + (t.active_minutes ?? 0) * Math.exp(-(now - (t.last_ms ?? 0)) / (7 * DAY)), 0);
    const described = threads.filter(t => t.brief);
    // 没有可用线程时清掉旧摘要，避免已移出的生活内容继续从项目摘要注入。
    if (!described.length) { store.upsertProject({ ...p, brief: null, detail: null, last_ms: last || p.last_ms, salience, needs_regen: 0, updated_at: toLocalIso(now) }); continue; }
    calls++;
    const views: P.ThreadView[] = described.map(t => ({ id: t.id, title: t.title, brief: t.brief ?? "", project: p.name, status: t.status, last: t.last_ms ? clock(t.last_ms) : "" }));
    const r = await d.llm.complete<P.ProjectOutput>({ tier: "hour", system: P.PROJECT_SYSTEM, prompt: P.projectPrompt(p.name, views, factViews(store, "project_id", p.id)), schema: P.PROJECT_SCHEMA });
    if (!r.ok) { failed++; continue; }
    calls++;
    const brief = await makeBrief(d, p.name, r.data, factViews(store, "project_id", p.id));
    if (brief === null) { failed++; continue; }
    store.upsertProject({ ...store.project(p.id)!, detail: r.data, brief, last_ms: last, salience, needs_regen: 0, updated_at: toLocalIso(now) });
    updated++;
  }
  return { calls, updated, failed };
}

// ---------------- 5. 当前状态（确定性，不调模型） ----------------

export function nowStep(store: DistillStore, now: number) {
  // 线程 2 小时不动就转为暂停，但"现在"仍应显示最近在做的事，所以 24 小时内暂停的也算。
  const threads = store.hub.db.prepare("SELECT * FROM threads WHERE status IN ('active','paused') AND last_ms>? AND brief IS NOT NULL ORDER BY last_ms DESC LIMIT 5").all(now - DAY) as (Thread & { last_ms: number })[];
  const names = new Map(store.projects().map(p => [p.id, p.name]));
  const items = threads.map(t => ({ thread_id: t.id, title: t.title, brief: t.brief, project: t.project_id ? names.get(t.project_id) ?? null : null, last: toLocalIso(t.last_ms) }));
  const top = items[0];
  // 简略版本身已说清在做什么，只在它没提到项目名时补上项目名。
  const brief = top ? (top.project && !top.brief!.includes(top.project) ? `${top.project}：${top.brief}` : top.brief!) : "最近 24 小时没有活跃的线程。";
  store.setState("now", { brief, detail: { threads: items }, updated_at: toLocalIso(now) });
  return { threads: items.length };
}

// ---------------- 6. 线程生命周期 ----------------

/** 多久问"做完了吗"、问后多久归档由通用设置决定（默认 3 天、7 天），每轮现读。 */
export function lifecycleStep(store: DistillStore, now: number) {
  const settings = readGeneral(store.hub);
  const askDoneAfter = settings.ask_done_days * DAY, archiveAfter = settings.archive_days * DAY;
  return store.hub.db.transaction(() => {
    let archived = 0;
    const expired = (store.hub.db.prepare("SELECT id,payload,created_at FROM pending WHERE kind='thread_done' AND resolved_at IS NULL").all() as { id: string; payload: string; created_at: string }[])
      // RFC 3339 可以带不同时区，比较时间戳而非字符串。
      .filter(p => Date.parse(p.created_at) < now - archiveAfter);
    for (const p of expired) {
      const payload = JSON.parse(p.payload) as { thread_id?: string };
      archived += store.hub.db.prepare("UPDATE threads SET status='archived' WHERE id=? AND status IN ('active','paused')").run(payload.thread_id ?? null).changes;
      store.hub.db.prepare("UPDATE pending SET resolved_at=?,resolution='expired' WHERE id=?").run(new Date(now).toISOString(), p.id);
    }
    const paused = store.hub.db.prepare("UPDATE threads SET status='paused' WHERE status='active' AND last_ms<?").run(now - LIMITS.pauseAfter).changes;
    const stale = store.hub.db.prepare("SELECT id FROM threads WHERE status IN ('active','paused') AND last_ms<?").all(now - askDoneAfter) as { id: string }[];
    for (const t of stale) askDone(store, t.id, now);
    return { paused, asked: stale.length, archived };
  })();
}

// ---------------- 7. 日记 ----------------

export async function dayStep(d: Deps, store: DistillStore, date: string, now: number) {
  const start = new Date(`${date}T00:00:00`).getTime(), end = start + DAY;
  const frames = loadFrames(store, "WHERE t_start_ms>=? AND t_start_ms<? ORDER BY t_start_ms,id", start, end);
  if (!frames.length) { store.upsertDay({ date, needs_regen: 0, updated_at: toLocalIso(now) }); return { calls: 0, ok: true }; }
  const owner = new Map((store.hub.db.prepare("SELECT frame_id,thread_id FROM assignments").all() as { frame_id: string; thread_id: string }[]).map(r => [r.frame_id, r.thread_id]));
  const blocks: P.DayBlock[] = [];
  for (const f of frames) {
    const t = owner.get(f.id) ? store.thread(owner.get(f.id)!) : null;
    const label = t ? t.title : f.key.replace(/^(app|host|repo|chat):/, "");
    const prev = blocks.at(-1);
    if (prev && prev.label === label && Date.parse(`${date}T${prev.end}:00`) + 15 * MIN >= f.t_start_ms) {
      prev.end = hhmm(f.t_end_ms); prev.minutes += Math.round(minutesOf(f)); continue;
    }
    blocks.push({ start: hhmm(f.t_start_ms), end: hhmm(f.t_end_ms), minutes: Math.round(minutesOf(f)), label, brief: t?.brief ?? null, kind: t ? "thread" : "misc" });
  }
  const r = await d.llm.complete<P.DayOutput>({ tier: "day", system: P.DAY_SYSTEM, prompt: P.dayPrompt(date, blocks.slice(0, 300)), schema: P.DAY_SCHEMA });
  if (!r.ok) return { calls: 1, ok: false };
  const brief = await makeBrief(d, date, r.data, []);
  if (brief === null) return { calls: 2, ok: false };
  store.upsertDay({ date, brief, detail: r.data, needs_regen: 0, updated_at: toLocalIso(now) });
  return { calls: 2, ok: true };
}

// ---------------- 一轮 ----------------

export interface RoundOptions { backfill?: boolean; slow?: boolean; days?: "all" | "past" | "none"; enabledDefault?: number }

/** 快步骤（切片、归线程、当前状态、生命周期）每轮都跑；slow=true 时再跑线程、项目和日记。 */
/** 额度、频率限制类错误：本轮剩下的调用直接跳过，不再继续消耗。 */
export const QUOTA_ERROR = /limit|quota|rate.?limit|usage|exceeded|429|额度|限额/i;
export function withBreaker(llm: LLM, onTrip: (error: string) => void): LLM {
  let tripped: string | null = null;
  return {
    async complete<T>(req: LLMRequest): Promise<LLMResult<T>> {
      if (tripped) return { ok: false, error: `本轮已停止调用：${tripped}`, ms: 0 };
      const r = await llm.complete<T>(req);
      if (!r.ok && QUOTA_ERROR.test(r.error)) { tripped = r.error.slice(0, 200); onTrip(tripped); }
      return r;
    },
  };
}

export async function distillRound(deps: Deps, opts: RoundOptions = {}) {
  let stopped: string | null = null;
  const d: Deps = { ...deps, llm: withBreaker(deps.llm, e => { stopped = e; }) };
  const out = await distillRoundInner(d, opts);
  if (stopped) out.stopped = stopped;
  return out;
}

async function distillRoundInner(d: Deps, opts: RoundOptions) {
  const now = d.now?.() ?? Date.now();
  const store = new DistillStore(d.db);
  const out: Record<string, unknown> = { at: toLocalIso(now) };
  out.slice = sliceStep(d.db, opts.backfill ?? false, now, opts.enabledDefault ?? now);
  out.assign = await assignStep(d, store, now);
  out.classify = await classifyStep(d, store);
  out.conversations = await conversationStep(d, now);
  if (opts.slow) {
    out.digest = await digestStep(d, store, now);
    out.projects = await projectStep(d, store, now);
  }
  out.lifecycle = lifecycleStep(store, now);
  out.now = nowStep(store, now);
  if (opts.slow && opts.days !== "none") {
    const today = localDate(now);
    const days = (d.db.db.prepare("SELECT date FROM days WHERE needs_regen=1 ORDER BY date").all() as { date: string }[])
      .map(r => r.date).filter(date => opts.days === "all" || date < today);
    let calls = 0, done = 0;
    for (const date of days) { const r = await dayStep(d, store, date, now); calls += r.calls; if (r.ok) done++; }
    out.days = { calls, done, pending: days.length - done };
  }
  return out;
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
    for (const f of r.frames) store.upsertDay({ date: localDate(f.t_start_ms), needs_regen: 1 });
    frames += r.frames.length;
    opts.onProgress?.(i + 1, days.length);
  });
  return { days: days.length, frames };
}

/** 常驻循环的一步：有排队请求就领取执行；否则到时间了跑常规一轮。返回这一步做了什么。 */
export interface LoopState { lastRound: number; enabledDefault: number }
export async function distillTick(d: Deps, state: LoopState, now = d.now?.() ?? Date.now()): Promise<"request" | "round" | "idle"> {
  const store = new DistillStore(d.db), requests = new DistillRequests(d.db);
  const log = d.log ?? console.log;
  store.setState("heartbeat_at", toLocalIso(now));
  const req = requests.claim(now);
  if (req) {
    try {
      if (req.kind === "backfill") {
        const r = backfillRange(d.db, req.from!, req.to!, { enabledDefault: state.enabledDefault, onProgress: (done, total) => requests.progress(req.id, done, total) });
        log(JSON.stringify({ request: req.id, backfill: r }));
        // 切好的片段接着归线程、写线程和日记；一轮处理不完的由后续常规轮次继续。
        log(JSON.stringify(await distillRound(d, { slow: true, days: "all", enabledDefault: state.enabledDefault })));
      } else await regularRound(d, state);
      requests.finish(req.id);
    } catch (e) {
      const error = e instanceof Error ? e.message.slice(0, 200) : "提炼失败";
      requests.finish(req.id, error);
      log(JSON.stringify({ request: req.id, error }));
    }
    return "request";
  }
  if (now - state.lastRound < 15 * MIN) return "idle";
  try { await regularRound(d, state); }
  catch (e) { log(JSON.stringify({ error: e instanceof Error ? e.message.slice(0, 200) : "提炼失败" })); }
  return "round";
}

async function regularRound(d: Deps, state: LoopState) {
  const store = new DistillStore(d.db), log = d.log ?? console.log;
  const now = d.now?.() ?? Date.now();
  // 失败也算跑过一轮，避免出错时每 5 秒重试一次。
  state.lastRound = now;
  const slowDue = now - (store.getState<number>("slow_ms") ?? 0) >= HOUR;
  // 当天的日记每 3 小时刷新一次；过去的日子有变化就在每小时那轮重写。
  const todayDue = now - (store.getState<number>("today_ms") ?? 0) >= 3 * HOUR;
  log(JSON.stringify(await distillRound(d, { slow: slowDue, days: todayDue ? "all" : "past", enabledDefault: state.enabledDefault })));
  if (slowDue) store.setState("slow_ms", now);
  if (slowDue && todayDue) store.setState("today_ms", now);
}

export async function runDistill({ db, llm, once, backfill, range, log = console.log, pollMs = 5000 }: { db: HubDB; llm: LLM; once: boolean; backfill: boolean; range?: { from: string; to: string }; log?: (line: string) => void; pollMs?: number }) {
  const store = new DistillStore(db);
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
      if (await distillTick(d, state) !== "request") await new Promise(r => setTimeout(r, pollMs));
    }
  } finally { clearInterval(beat); }
}
