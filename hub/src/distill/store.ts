import { tryWriteWithoutWaiting } from "../db-busy.ts";
import { chatKey } from "../chat.ts";
import { AudioStore } from "../audio.ts";
import { removeSummariesOf } from "../conversations.ts";
import { frameRecordsSchema, frameRejectionsSchema } from "./schema.ts";
import { HubDB, InputError } from "../db.ts";
import { ulid, toLocalIso } from "../../../packages/record/index.ts";
import { recordSpans, unionSeconds } from "../durations.ts";
import { isReadableReviewItem, type ReviewItem } from "./day-review.ts";

export interface Frame { id: string; t_start_ms: number; t_end_ms: number; key: string; record_ids: string[]; chars: number; private: number; status: "new" | "assigned" | "ignored" | "candidate" | "candidate_expired" }
export interface ProjectKeys { repos: string[]; hosts: string[]; chats: string[] }
export interface Project { id: string; name: string; confirmed?: number; keys: ProjectKeys; brief?: string | null; detail?: unknown; salience?: number; last_ms?: number; needs_regen?: number; updated_at?: string }
export interface Thread { id: string; domain?: "work" | "life" | null; project_hint?: string | null; project_id?: string | null; status: "active" | "paused" | "done" | "abandoned" | "archived"; title: string; brief?: string | null; detail?: unknown; first_ms?: number; last_ms?: number; active_minutes?: number; sessions?: number; needs_regen?: number; updated_at?: string }
export interface Fact { id: string; thread_id?: string | null; project_id?: string | null; kind: "decision" | "rejected" | "open" | "next" | "inference"; text: string; reason?: string; evidence: string[]; confidence?: number; origin: "llm" | "user"; valid_at: string; invalid_at?: string | null; superseded_by?: string | null; created_at: string }
export interface Pending { id: string; kind: "project" | "merge" | "thread_done" | "voice"; payload: Record<string, unknown>; created_at: string; resolved_at?: string | null; resolution?: string | null }
type TimelineFields = "apps" | "record_ids" | "project_id";
export type StoredReviewItem = Omit<ReviewItem, TimelineFields> & Partial<Pick<ReviewItem, TimelineFields>>;
type TimelineCorrection = { record_ids: string[]; description: string };
export type TimelineCorrections = Record<string, TimelineCorrection>;
export const timelineCorrectionKey = (date: string) => `timeline_corrections:${date}`;

export function isTimelineItem(item: StoredReviewItem): item is ReviewItem {
  return Array.isArray(item.record_ids);
}

export function applyTimelineCorrections(items: StoredReviewItem[], corrections: TimelineCorrections | null) {
  if (!corrections) return items;
  return items.map(item => {
    const correction = Object.hasOwn(corrections, item.id) ? corrections[item.id] : undefined;
    if (!correction || !isTimelineItem(item)) return item;
    const members = new Set(item.record_ids);
    // 新记录可并入原段。旧段被拆成别的活动时，不把原修正套到剩余的一部分。
    return correction.record_ids.every(id => members.has(id)) ? { ...item, description: correction.description } : item;
  });
}
type Row = Record<string, any>;
const jsonColumns = new Set(["record_ids", "keys", "detail", "evidence", "payload"]);
function decode<T>(row: Row): T {
  return Object.fromEntries(Object.entries(row).map(([k,v]) => [k, jsonColumns.has(k) && v !== null ? JSON.parse(v) : v])) as T;
}

export class DistillStore {
  constructor(readonly hub: HubDB) {}
  private get sql() { return this.hub.db; }
  private put(table: string, key: string, value: object) {
    const entries = Object.entries(value).filter(([,v]) => v !== undefined);
    const names = entries.map(([k]) => `"${k}"`);
    this.sql.prepare(`INSERT INTO ${table} (${names}) VALUES (${names.map(() => "?")}) ON CONFLICT(${key}) DO UPDATE SET ${names.filter(n => n !== `"${key}"`).map(n => `${n}=excluded.${n}`)}`).run(...entries.map(([k,v]) => jsonColumns.has(k) && v !== null ? JSON.stringify(v) : v));
  }
  /** 兼容开发期已经升级到 v2、但尚无归属索引的库。 */
  ensureFrameRecords() {
    this.sql.transaction(() => {
      const exists = this.sql.prepare("SELECT 1 FROM sqlite_master WHERE type='table' AND name='frame_records'").get();
      this.sql.exec(frameRecordsSchema);
      this.sql.exec(frameRejectionsSchema);
      if (!exists) {
        const insert = this.sql.prepare("INSERT INTO frame_records(record_id,frame_id) VALUES(?,?)");
        for (const frame of this.frames()) for (const id of frame.record_ids) insert.run(id,frame.id);
      }
    })();
  }
  frames(): Frame[] { return this.sql.prepare("SELECT * FROM frames ORDER BY t_start_ms,id").all().map(r => decode<Frame>(r as Row)); }
  createFrame(frame: Frame) {
    if (!frame.record_ids.length || new Set(frame.record_ids).size !== frame.record_ids.length) throw new InputError("片段记录不能为空或重复");
    this.sql.transaction(() => {
      for (const id of frame.record_ids) {
        if (!this.hub.get(id)) throw new InputError("片段引用的记录不存在");
        if (this.sql.prepare("SELECT 1 FROM frame_records WHERE record_id=?").get(id)) throw new InputError("记录已有片段");
      }
      if (this.sql.prepare("SELECT 1 FROM frames WHERE id=?").get(frame.id)) throw new InputError("片段已存在");
      this.put("frames", "id", frame);
      const insert = this.sql.prepare("INSERT INTO frame_records(record_id,frame_id) VALUES(?,?)");
      for (const id of frame.record_ids) insert.run(id,frame.id);
    })();
  }
  assign(frameId: string, threadId: string, method: "rule" | "llm" | "user", confidence: number) {
    this.sql.transaction(() => {
      if (!this.thread(threadId) || !this.sql.prepare("SELECT 1 FROM frames WHERE id=?").get(frameId)) throw new InputError("线程或片段不存在");
      this.put("assignments", "frame_id", { frame_id: frameId, thread_id: threadId, method, confidence });
      this.sql.prepare("UPDATE frames SET status='assigned' WHERE id=?").run(frameId);
    })();
  }
  upsertThread(thread: Thread) { this.put("threads", "id", thread); }
  upsertProject(project: Project) { this.put("projects", "id", project); }
  ignoredProjectKeys(): ProjectKeys {
    return this.getState<ProjectKeys>("ignored_project_keys") ?? { repos: [], hosts: [], chats: [] };
  }
  upsertDay(day: { date: string; brief?: string | null; detail?: unknown; needs_regen?: number; updated_at?: string }) { this.put("days", "date", day); }
  projects(): Project[] { return this.sql.prepare("SELECT * FROM projects ORDER BY last_ms DESC,id DESC").all().map(r => decode<Project>(r as Row)); }
  projectSummaries() {
    return this.sql.prepare("SELECT p.*,(SELECT count(*) FROM threads t WHERE t.project_id=p.id) AS thread_count FROM projects p ORDER BY p.last_ms DESC,p.id DESC").all().map(r => {
      const project = decode<Row>(r as Row); delete project.detail; return project;
    });
  }
  project(id: string): Project | null { const r = this.sql.prepare("SELECT * FROM projects WHERE id=?").get(id); return r ? decode(r as Row) : null; }
  thread(id: string): Thread | null { const r = this.sql.prepare("SELECT * FROM threads WHERE id=?").get(id); return r ? decode(r as Row) : null; }
  day(date: string): Row | null { const r = this.sql.prepare("SELECT * FROM days WHERE date=?").get(date); return r ? decode(r as Row) : null; }
  /** 给人看的投影。按引用原文的现有归属串联事项，不按相似标题猜测。 */
  readingItems(items: StoredReviewItem[]) {
    const readable = items.filter(item => isReadableReviewItem(item) && Array.isArray(item.evidence));
    const ids = [...new Set(readable.flatMap(item => item.evidence.map(ref => ref.id)))];
    const rows = this.sql.prepare<[string], { id: string; source: string; app: string | null; thread_id: string | null; project_id: string | null }>(`
      SELECT r.id,r.source,json_extract(r.context,'$.app') app,a.thread_id,t.project_id FROM records r
      LEFT JOIN frame_records fr ON fr.record_id=r.id
      LEFT JOIN assignments a ON a.frame_id=fr.frame_id LEFT JOIN threads t ON t.id=a.thread_id
      WHERE r.id IN (SELECT value FROM json_each(?))`).all(JSON.stringify(ids));
    const records = new Map(rows.map(row => [row.id, row]));
    return readable.map(item => {
      const cited = item.evidence.map(ref => records.get(ref.id));
      const assigned = cited.filter((row): row is NonNullable<typeof row> => !!row?.thread_id);
      const threads = new Set(assigned.map(row => row.thread_id));
      const thread = threads.size === 1 && assigned.every(row => row.project_id === item.project_id)
        ? assigned[0]!.thread_id : null;
      const apps = [...new Map(item.evidence.map(ref => {
        const row = records.get(ref.id), source = ref.source, app = row?.app ?? null;
        return [JSON.stringify([source, app]), { source, app }];
      })).values()];
      return { ...item, ...(thread ? { thread_id: thread } : {}),
        ...(apps.length ? { apps, sources: [...new Set(apps.map(app => app.source))] } : {}) };
    });
  }
  dayView(date: string, { agent = false } = {}): Row | null {
    const row = this.day(date);
    if (!row) return null;
    // 旧库仍可读取日期和时间条，接口只返回当前契约里的字段。
    const { summary, timeline, items, cutoff, omitted_record_ids } = row.detail ?? {};
    const adjusted = Array.isArray(items) ? applyTimelineCorrections(items, this.getState<TimelineCorrections>(timelineCorrectionKey(date))) : undefined;
    const reading = !agent && adjusted ? this.readingItems(adjusted) : undefined;
    const visible = agent ? adjusted?.map(item => {
      if (!isTimelineItem(item)) return item;
      const { apps: _apps, record_ids: _ids, project_id: _project, ...existing } = item;
      return existing;
    }) : reading;
    const visibleIds = new Set(reading?.flatMap(item => item.record_ids ?? []) ?? []);
    const hiddenIds = !agent ? adjusted?.filter(item => !reading?.some(shown => shown.id === item.id))
      .flatMap(item => item.record_ids ?? []) ?? [] : [];
    const omitted = [...new Set([...(omitted_record_ids ?? []), ...hiddenIds])].filter(id => !visibleIds.has(id));
    const hiddenHeading = !agent && adjusted?.some(item => !isReadableReviewItem(item) && summary === item.title);
    const leading = reading && [...reading].sort((a, b) => b.active_seconds - a.active_seconds)[0];
    const heading = !agent && adjusted?.length && !visible?.length ? null : hiddenHeading ? leading?.title ?? null : summary;
    const chapters = !agent && adjusted?.every(isTimelineItem) ? reading?.map(item => ({
      start: item.t_start.slice(11, 16), end: item.t_end.slice(0, 10) > date ? "24:00" : item.t_end.slice(11, 16), text: item.title,
    })).filter(item => item.start !== item.end) : timeline;
    return { ...row, ...(!agent && Array.isArray(items) ? { brief: heading ?? null } : {}), detail: row.detail ? { summary: heading, timeline: chapters, items: visible, cutoff,
      ...(!agent && (Array.isArray(omitted_record_ids) || hiddenIds.length) ? { omitted_record_ids: omitted } : {}) } : null,
      ...(this.getState<boolean>(`day_failed:${date}`) ? { failed: true } : {}) };
  }
  facts(field: "thread_id" | "project_id", id: string): Fact[] { return this.sql.prepare(`SELECT * FROM facts WHERE ${field}=? AND invalid_at IS NULL ORDER BY created_at,id`).all(id).map(r => decode<Fact>(r as Row)); }
  writeFact(fact: Fact, supersedes?: string) {
    this.sql.transaction(() => {
      if (!fact.evidence.length || fact.evidence.some(id => !this.hub.get(id))) throw new InputError("事实需要至少一条存在的证据");
      if (fact.thread_id && !this.thread(fact.thread_id) || fact.project_id && !this.project(fact.project_id)) throw new InputError("事实归属不存在");
      this.sql.prepare(`INSERT INTO facts(id,thread_id,project_id,kind,text,reason,evidence,confidence,origin,valid_at,created_at) VALUES(?,?,?,?,?,?,?,?,?,?,?)`).run(fact.id,fact.thread_id ?? null,fact.project_id ?? null,fact.kind,fact.text,fact.reason ?? null,JSON.stringify(fact.evidence),fact.confidence ?? null,fact.origin,fact.valid_at,fact.created_at);
      if (supersedes) this.invalidateFact(supersedes, fact.id, fact.origin, fact.valid_at);
      if (fact.origin === "user") {
        this.sql.prepare("UPDATE threads SET needs_regen=1 WHERE id=?").run(fact.thread_id ?? null);
        this.sql.prepare("UPDATE projects SET needs_regen=1 WHERE id=? OR id=(SELECT project_id FROM threads WHERE id=?)").run(fact.project_id ?? null, fact.thread_id ?? null);
      }
    })();
  }
  activeMinutes(threadId: string): number {
    const frames = (this.sql.prepare("SELECT frame_id FROM assignments WHERE thread_id=?").all(threadId) as { frame_id: string }[]).map(r => r.frame_id);
    return this.frameMinutes(frames);
  }
  frameMinutes(frames: string[]): number {
    const ids = (this.sql.prepare("SELECT record_id FROM frame_records WHERE frame_id IN (SELECT value FROM json_each(?))").all(JSON.stringify(frames)) as { record_id: string }[]).map(r => r.record_id);
    return Math.round(unionSeconds(recordSpans(this.hub, ids)) / 60);
  }
  /** 用户说过不属于的线程，整理时不能再把这个片段归进去。 */
  rejectedThreads(frameId: string): string[] {
    return (this.sql.prepare("SELECT thread_id FROM frame_rejections WHERE frame_id=?").all(frameId) as Row[]).map(r => r.thread_id);
  }
  /**
   * 用户说这条事实不属于它所在的线程（而不是文案写错）：证据所在、分给这条线程的片段退回未分配，
   * 记下不能再分回来，下一轮由模型重新归属；作废这条事实，以及证据全落在这些片段上的自动推断。
   * 用户自己写的其他事实不动。线程、所属项目和涉及的日期标记重新整理。
   */
  detachFact(id: string, at = new Date().toISOString()): { frames: number; facts: number } {
    return this.sql.transaction(() => {
      const fact = this.sql.prepare("SELECT * FROM facts WHERE id=? AND invalid_at IS NULL").get(id) as Row | undefined;
      if (!fact) throw new InputError("事实不存在或已失效");
      const threadId = fact.thread_id as string | null;
      if (!threadId) throw new InputError("这条事实没有挂在线程上");
      const evidence = JSON.parse(fact.evidence) as string[];
      const frames = this.sql.prepare(`SELECT DISTINCT f.* FROM frame_records r JOIN frames f ON f.id=r.frame_id JOIN assignments a ON a.frame_id=f.id
        WHERE a.thread_id=? AND r.record_id IN (${evidence.map(() => "?").join(",")})`).all(threadId, ...evidence).map(r => decode<Frame>(r as Row));
      const moved = new Set(frames.flatMap(f => f.record_ids));
      for (const f of frames) this.unassign(f, threadId, at);
      const invalidate = this.sql.prepare("UPDATE facts SET invalid_at=? WHERE id=? AND invalid_at IS NULL");
      invalidate.run(at, id);
      let count = 1;
      for (const other of this.facts("thread_id", threadId)) {
        if (other.origin === "llm" && other.evidence.length && other.evidence.every(e => moved.has(e))) { invalidate.run(at, other.id); count++; }
      }
      this.sql.prepare("UPDATE threads SET needs_regen=1 WHERE id=?").run(threadId);
      this.sql.prepare("UPDATE projects SET needs_regen=1 WHERE id=(SELECT project_id FROM threads WHERE id=?)").run(threadId);
      if (fact.project_id) this.sql.prepare("UPDATE projects SET needs_regen=1 WHERE id=?").run(fact.project_id);
      return { frames: frames.length, facts: count };
    })();
  }
  /** 片段退回未分配，记下不能再分回这条线程，下一轮由模型重新归属。调用方负责事务和线程重新整理。 */
  private unassign(f: Frame, threadId: string, at: string) {
    this.sql.prepare("DELETE FROM assignments WHERE frame_id=?").run(f.id);
    this.sql.prepare("UPDATE threads SET active_minutes=? WHERE id=?").run(this.activeMinutes(threadId), threadId);
    this.sql.prepare("UPDATE frames SET status='new' WHERE id=?").run(f.id);
    this.sql.prepare("INSERT OR IGNORE INTO frame_rejections(frame_id,thread_id,at) VALUES(?,?,?)").run(f.id, threadId, at);
    this.sql.prepare("UPDATE days SET needs_regen=1 WHERE date=?").run(toLocalIso(f.t_start_ms).slice(0,10));
  }
  /**
   * 一条记录所在的片段不属于它现在的线程（没有事实可以挂"不属于这里"时用）：同 detachFact 的移出规则，
   * 证据全在这个片段上的自动推断一并作废。
   */
  detachRecord(recordId: string, at = new Date().toISOString()): { frames: number; facts: number; thread: string | null } {
    return this.sql.transaction(() => {
      const row = this.sql.prepare("SELECT f.*,a.thread_id FROM frame_records r JOIN frames f ON f.id=r.frame_id JOIN assignments a ON a.frame_id=f.id WHERE r.record_id=?").get(recordId) as Row | undefined;
      if (!row) return { frames: 0, facts: 0, thread: null };
      const threadId = row.thread_id as string, f = decode<Frame>(row);
      this.unassign(f, threadId, at);
      const moved = new Set(f.record_ids);
      let count = 0;
      for (const other of this.facts("thread_id", threadId)) {
        if (other.origin === "llm" && other.evidence.length && other.evidence.every(e => moved.has(e))) { this.sql.prepare("UPDATE facts SET invalid_at=? WHERE id=? AND invalid_at IS NULL").run(at, other.id); count++; }
      }
      this.sql.prepare("UPDATE threads SET needs_regen=1 WHERE id=?").run(threadId);
      this.sql.prepare("UPDATE projects SET needs_regen=1 WHERE id=(SELECT project_id FROM threads WHERE id=?)").run(threadId);
      return { frames: 1, facts: count, thread: threadId };
    })();
  }
  invalidateFact(id: string, replacement: string, origin: "llm" | "user", at = new Date().toISOString()) {
    const fact = this.sql.prepare("SELECT origin FROM facts WHERE id=? AND invalid_at IS NULL").get(id) as Row | undefined;
    if (!fact || fact.origin === "user" && origin !== "user") throw new InputError("事实不存在、已失效或不允许推翻用户事实");
    this.sql.prepare("UPDATE facts SET invalid_at=?,superseded_by=? WHERE id=?").run(at,replacement,id);
  }
  private mergeDismissed(a: string, b: string): boolean {
    const pair = [a,b].sort();
    return (this.getState<string[][]>("merge_dismissed") ?? []).some(p => p[0] === pair[0] && p[1] === pair[1]);
  }
  createPending(p: Pending) {
    if (p.kind === "merge" && this.mergeDismissed(String(p.payload.a),String(p.payload.b))) return;
    this.put("pending", "id", p);
  }
  pending(): Pending[] {
    const { result, marks } = this.sql.transaction(() => {
      const result: Pending[] = [];
      const marks: { id: string; resolution: string }[] = [];
      const rows = this.sql.prepare("SELECT * FROM pending WHERE resolved_at IS NULL ORDER BY created_at,id").all();
      for (const row of rows) {
        const p = decode<Pending>(row as Row);
        let stale = false, dismissed = false;
        if (p.kind === "voice") {
          const payload = new AudioStore(this.hub).pendingPayload(String(p.payload.speaker_id ?? ""));
          if (!payload) stale = true;
          else p.payload = payload;
        } else if (p.kind === "project") {
          const project = this.project(String(p.payload.project_id ?? p.payload.id ?? ""));
          if (!project) stale = true;
          else p.payload = { ...p.payload,name: project.name,keys: project.keys,threads: this.sql.prepare("SELECT id,title,brief FROM threads WHERE project_id=? ORDER BY last_ms DESC,id DESC LIMIT 5").all(project.id) };
        } else if (p.kind === "thread_done") {
          const thread = this.thread(String(p.payload.thread_id ?? p.payload.id ?? ""));
          if (!thread) stale = true;
          else p.payload = { ...p.payload,title: thread.title,brief: thread.brief };
        } else {
          const a = this.project(String(p.payload.a ?? "")), b = this.project(String(p.payload.b ?? ""));
          if (!a || !b) stale = true;
          else {
            dismissed = this.mergeDismissed(a.id,b.id);
            p.payload = { ...p.payload,a_name: a.name,b_name: b.name };
          }
        }
        if (stale || dismissed) marks.push({ id: p.id, resolution: stale ? "stale" : "keep" });
        else result.push(p);
      }
      return { result, marks };
    })();
    if (marks.length) tryWriteWithoutWaiting(this.hub, () => {
      const update = this.sql.prepare("UPDATE pending SET resolved_at=?,resolution=? WHERE id=? AND resolved_at IS NULL");
      for (const mark of marks) update.run(new Date().toISOString(), mark.resolution, mark.id);
    });
    return result;
  }
  getState<T>(key: string): T | null { const row = this.sql.prepare("SELECT v FROM distill_state WHERE k=?").get(key) as Row | undefined; return row ? JSON.parse(row.v) : null; }
  setState(key: string, value: unknown) { this.sql.prepare("INSERT INTO distill_state VALUES(?,?) ON CONFLICT(k) DO UPDATE SET v=excluded.v").run(key,JSON.stringify(value)); }
  writeUsage(usage: { id?: string; at?: string; tier: string; task?: string | null; provider: string; model: string; input_chars?: number; output_chars?: number; input_tokens?: number; output_tokens?: number; ms: number; ok: number; error?: string }) { this.put("llm_usage", "id", { id: ulid(), at: new Date().toISOString(), ...usage }); }
  threads(params: URLSearchParams) {
    const limit = Number(params.get("limit") ?? 50);
    if (!Number.isInteger(limit) || limit < 1 || limit > 500) throw new InputError("limit 必须是 1–500 的整数");
    const where: string[] = [], args: unknown[] = [];
    for (const [param,col] of [["status","status"],["project","project_id"]]) if (params.has(param)) { where.push(`${col}=?`); args.push(params.get(param)); }
    if (params.has("cursor")) {
      try {
        const c = JSON.parse(Buffer.from(params.get("cursor")!,"base64url").toString());
        if (!Array.isArray(c) || c.length !== 2 || !Number.isSafeInteger(c[0]) || typeof c[1] !== "string") throw new Error();
        where.push("(COALESCE(last_ms,0) < ? OR (COALESCE(last_ms,0)=? AND id<?))"); args.push(c[0],c[0],c[1]);
      } catch { throw new InputError("cursor 无效"); }
    }
    const rows = this.sql.prepare(`SELECT * FROM threads ${where.length ? "WHERE " + where.join(" AND ") : ""} ORDER BY COALESCE(last_ms,0) DESC,id DESC LIMIT ?`).all(...args,limit+1) as Row[];
    const page = rows.slice(0,limit), last = page.at(-1);
    return { threads: page.map(r => { const t = decode<Row>(r); delete t.detail; return t; }), next_cursor: rows.length > limit && last ? Buffer.from(JSON.stringify([last.last_ms ?? 0,last.id])).toString("base64url") : null };
  }
  view(kind: "threads" | "projects", id: string, level: string) {
    if (!["brief","detail","evidence"].includes(level)) throw new InputError("level 无效");
    const entity = kind === "threads" ? this.thread(id) : this.project(id);
    if (!entity) return null;
    const result: Row = { ...entity };
    if (level === "brief") { delete result.detail; return result; }
    result.facts = this.facts(kind === "threads" ? "thread_id" : "project_id",id);
    if (level === "evidence") {
      const supports = new Set<string>(result.facts.flatMap((f: Fact) => f.evidence));
      const ids = new Set(supports);
      const threads = kind === "threads" ? [id] : (this.sql.prepare("SELECT id FROM threads WHERE project_id=?").all(id) as Row[]).map(t => t.id);
      for (const tid of threads) for (const row of this.sql.prepare("SELECT f.record_ids FROM frames f JOIN assignments a ON a.frame_id=f.id WHERE a.thread_id=?").all(tid) as Row[]) for (const rid of JSON.parse(row.record_ids)) ids.add(rid);
      const visit = (value: unknown): void => { if (!value || typeof value !== "object") return; for (const [k,v] of Object.entries(value)) { if (k === "record_id" && typeof v === "string") { ids.add(v); supports.add(v); } else visit(v); } };
      visit(result.detail);
      result.records = [...ids].flatMap(rid => { const r = this.sql.prepare("SELECT id,title,t_start,source FROM records WHERE id=?").get(rid); return r ? [{ ...r, relation: supports.has(rid) ? "support" : "activity" }] : []; });
    }
    return result;
  }
  /**
   * 重复的线程并成一条（design.md 4 节"合并重复线程"）：片段、事实、"不属于这里"的记录都转到 target，
   * source 未处理的"做完了吗"关掉；状态取最近活动的那条。target 整条重写详细版。
   * 旧 id 留跳转，AI 工具拿旧 id 也能查到。调用方负责事务。
   */
  mergeThreads(source: string, target: string, at = new Date().toISOString()) {
    const a = this.thread(source), b = this.thread(target);
    if (!a || !b || source === target) throw new InputError("线程合并目标无效");
    const later = (a.last_ms ?? 0) > (b.last_ms ?? 0) ? a : b;
    this.sql.prepare("UPDATE assignments SET thread_id=? WHERE thread_id=?").run(target, source);
    this.sql.prepare("UPDATE facts SET thread_id=?,project_id=? WHERE thread_id=?").run(target, b.project_id ?? null, source);
    this.sql.prepare("INSERT OR IGNORE INTO frame_rejections(frame_id,thread_id,at) SELECT frame_id,?,at FROM frame_rejections WHERE thread_id=?").run(target, source);
    this.sql.prepare("DELETE FROM frame_rejections WHERE thread_id=?").run(source);
    this.sql.prepare("UPDATE pending SET resolved_at=?,resolution='merged' WHERE kind='thread_done' AND resolved_at IS NULL AND json_extract(payload,'$.thread_id')=?").run(at, source);
    const firsts = [a.first_ms, b.first_ms].filter((n): n is number => n != null), lasts = [a.last_ms, b.last_ms].filter((n): n is number => n != null);
    this.upsertThread({ ...b, status: later.status, project_hint: b.project_hint ?? a.project_hint ?? null,
      first_ms: firsts.length ? Math.min(...firsts) : undefined, last_ms: lasts.length ? Math.max(...lasts) : undefined,
      active_minutes: this.activeMinutes(target), sessions: (a.sessions ?? 0) + (b.sessions ?? 0), needs_regen: 1 });
    for (const pid of new Set([a.project_id, b.project_id])) if (pid) this.sql.prepare("UPDATE projects SET needs_regen=1 WHERE id=?").run(pid);
    this.sql.prepare("DELETE FROM distill_state WHERE k IN (?,?)").run(`digest:${source}`, `digest:${target}`);
    // 已经并进 source 的旧 id 也改指 target。
    for (const row of this.sql.prepare("SELECT k FROM distill_state WHERE k LIKE 'thread_redirect:%' AND v=?").all(JSON.stringify(source)) as Row[]) this.setState(row.k, target);
    this.setState(`thread_redirect:${source}`, target);
    this.sql.prepare("DELETE FROM threads WHERE id=?").run(source);
  }
  /** 并掉的线程的旧 id 指向现在的线程；不是并掉的原样返回。 */
  threadId(id: string): string { return this.thread(id) ? id : this.getState<string>(`thread_redirect:${id}`) ?? id; }
  private mergeProjects(source: string, target: string) {
    const project = this.project(source), dest = this.project(target);
    if (!project || !dest || source === target) throw new InputError("合并目标无效");
    const keys = { ...dest.keys };
    for (const k of ["repos","hosts","chats"] as const) {
      const values = [...keys[k], ...project.keys[k]];
      keys[k] = k === "chats" ? [...new Map(values.map(value => [chatKey(value), value])).values()] : [...new Set(values)];
    }
    this.upsertProject({ ...dest, keys, needs_regen: 1 });
    this.sql.prepare("UPDATE threads SET project_id=?,needs_regen=1 WHERE project_id=?").run(dest.id,source);
    this.sql.prepare("UPDATE threads SET project_hint=? WHERE project_hint=?").run(dest.id,source);
    this.sql.prepare("UPDATE facts SET project_id=? WHERE project_id=?").run(dest.id,source);
    this.sql.prepare("DELETE FROM projects WHERE id=?").run(source);
  }
  removeProject(id: string): boolean {
    return this.sql.transaction(() => {
      const project = this.project(id);
      if (!project) return false;
      const ignored = this.ignoredProjectKeys();
      for (const key of ["repos", "hosts", "chats"] as const) {
        ignored[key] = [...new Set([...ignored[key], ...project.keys[key]])];
      }
      this.setState("ignored_project_keys", ignored);
      const threads = this.sql.prepare<[string, string], { id: string }>(`
        SELECT id FROM threads WHERE project_id=? OR project_hint=?`).all(id, id);
      this.clearDerived(new Set(threads.map(thread => thread.id)), new Set([id]), [],
        { pendingResolution: "project_removed", clearThreadDays: false });
      // 时间线段的文字不随项目归属变化，只摘掉段上的项目标注，不让整天重新整理。
      this.sql.prepare(`UPDATE days SET detail=json_set(detail,'$.items',(
          SELECT json_group_array(CASE WHEN json_extract(item.value,'$.project_id')=? THEN json_set(item.value,'$.project_id',json('null')) ELSE json(item.value) END)
          FROM json_each(days.detail,'$.items') item))
        WHERE EXISTS (SELECT 1 FROM json_each(days.detail,'$.items') item WHERE json_extract(item.value,'$.project_id')=?)`).run(id, id);
      const candidates = this.getState<{ project_id: string | null }[]>("candidates");
      if (candidates?.some(candidate => candidate.project_id === id)) {
        this.setState("candidates", candidates.map(candidate => candidate.project_id === id ? { ...candidate, project_id: null } : candidate));
      }
      this.sql.prepare("UPDATE threads SET project_id=NULL WHERE project_id=?").run(id);
      this.sql.prepare("UPDATE threads SET project_hint=NULL WHERE project_hint=?").run(id);
      this.sql.prepare("UPDATE facts SET project_id=NULL WHERE project_id=?").run(id);
      this.sql.prepare("DELETE FROM projects WHERE id=?").run(id);
      return true;
    }).immediate();
  }
  resolvePending(id: string, action: string, name?: string, target?: string) {
    this.sql.transaction(() => {
      const p = this.pending().find(p => p.id === id);
      if (!p) throw new InputError("待确认项不存在或已处理");
      if (p.kind === "voice") {
        new AudioStore(this.hub).resolve(String(p.payload.speaker_id),action,name,target);
      } else if (p.kind === "merge") {
        const a = String(p.payload.a), b = String(p.payload.b);
        if (action === "merge") this.mergeProjects(a,b);
        else if (action === "keep") {
          const pairs = this.getState<string[][]>("merge_dismissed") ?? [];
          if (!this.mergeDismissed(a,b)) pairs.push([a,b].sort());
          this.setState("merge_dismissed",pairs);
        } else throw new InputError("合并操作无效");
      } else if (p.kind === "project") {
        const pid = String(p.payload.project_id ?? p.payload.id ?? "");
        const project = this.project(pid);
        if (!project) throw new InputError("项目不存在");
        if (action === "confirm") this.upsertProject({ ...project, confirmed: 1 });
        else if (action === "rename") {
          if (!name?.trim()) throw new InputError("需要项目名");
          this.upsertProject({ ...project, name: name.trim(), confirmed: 1 });
        } else if (action === "merge_into") {
          if (!target) throw new InputError("需要合并目标");
          this.mergeProjects(pid,target);
        } else if (action === "ignore") {
          this.removeProject(pid);
        } else throw new InputError("项目操作无效");
      } else {
        const status = ({ done: "done", continue: "active", abandon: "abandoned" } as const)[action as "done"];
        const thread = this.thread(String(p.payload.thread_id ?? p.payload.id ?? ""));
        if (!status || !thread) throw new InputError("线程操作无效");
        this.upsertThread({ ...thread, status });
      }
      this.sql.prepare("UPDATE pending SET resolved_at=?,resolution=? WHERE id=?").run(new Date().toISOString(),action,id);
    }).immediate();
  }
  /** 删除/修正立即撤下派生文字；模型调用中的旧快照也不能再写回来。 */
  clearDerived(threads: Set<string>, projects: Set<string>, times: string[],
    { preserveResolvedPending = false, pendingResolution, clearThreadDays = true }:
      { preserveResolvedPending?: boolean; pendingResolution?: string; clearThreadDays?: boolean } = {}) {
    const pendingProjects = pendingResolution ? new Set(projects) : projects;
    this.setState("content_revision", (this.getState<number>("content_revision") ?? 0) + 1);
    for (const id of threads) {
      const t = this.thread(id);
      if (t?.project_id) projects.add(t.project_id);
      // 删除原文或改归属时，清理事项覆盖日期，而不只清理被删记录当天。
      if (clearThreadDays && t?.first_ms != null && t?.last_ms != null) this.sql.prepare("UPDATE days SET brief=NULL,detail=NULL,needs_regen=1,updated_at=NULL WHERE date BETWEEN date(? / 1000.0,'unixepoch','localtime') AND date(? / 1000.0,'unixepoch','localtime')").run(t.first_ms,t.last_ms);
      this.sql.prepare("UPDATE threads SET title='正在重新整理',brief=NULL,detail=NULL,needs_regen=1,updated_at=NULL WHERE id=?").run(id);
      this.setState(`digest:${id}`, null);
    }
    for (const id of projects) {
      this.sql.prepare("UPDATE projects SET brief=NULL,detail=NULL,needs_regen=1,updated_at=NULL WHERE id=?").run(id);
      this.setState(`project_brief:${id}`, null);
    }
    for (const time of new Set(times)) this.sql.prepare("UPDATE days SET brief=NULL,detail=NULL,needs_regen=1,updated_at=NULL WHERE date=date(?,'localtime')").run(time);
    this.setState("now", null);
    const affected = new Set([...threads, ...pendingProjects]);
    const references = (v: unknown): boolean => typeof v === "string" ? affected.has(v)
      : Array.isArray(v) ? v.some(references) : !!v && typeof v === "object" && Object.values(v).some(references);
    const close = pendingResolution && this.sql.prepare("UPDATE pending SET resolved_at=?,resolution=? WHERE id=? AND resolved_at IS NULL");
    const at = new Date().toISOString();
    for (const row of this.sql.prepare("SELECT id,payload,resolved_at FROM pending").all() as Row[]) {
      if (!references(JSON.parse(row.payload))) continue;
      if (close) close.run(at, pendingResolution, row.id);
      else if (!preserveResolvedPending || !row.resolved_at) this.sql.prepare("DELETE FROM pending WHERE id=?").run(row.id);
    }
  }

  /** 引用可来自同一录音的另一自然日，直接按依据 ID 撤下涉及的回顾。 */
  private clearReviewEvidence(recordIds: string[]) {
    this.sql.prepare(`WITH removed(id) AS (SELECT value FROM json_each(?))
      UPDATE days SET brief=NULL,detail=NULL,needs_regen=1,updated_at=NULL WHERE
        EXISTS (SELECT 1 FROM json_tree(days.detail) ref JOIN removed ON removed.id=ref.value WHERE ref.key='id')
        OR EXISTS (SELECT 1 FROM json_each(days.detail,'$.record_ids') ref JOIN removed ON removed.id=ref.value)
        OR EXISTS (SELECT 1 FROM json_each(days.detail,'$.items') item
          JOIN json_each(item.value,'$.record_ids') ref JOIN removed ON removed.id=ref.value)`).run(JSON.stringify(recordIds));
  }

  private clearTimelineCorrections(recordIds: string[]) {
    const rows = this.sql.prepare(`SELECT k,v FROM distill_state WHERE k LIKE 'timeline_corrections:%' AND EXISTS (
      SELECT 1 FROM json_each(distill_state.v) correction JOIN json_each(correction.value,'$.record_ids') record
        WHERE record.value IN (SELECT value FROM json_each(?)))`).all(JSON.stringify(recordIds)) as { k: string; v: string }[];
    const affected = new Set(recordIds);
    for (const { k, v } of rows) {
      const remaining = Object.entries(JSON.parse(v) as TimelineCorrections)
        .filter(([, correction]) => !correction.record_ids.some(id => affected.has(id)));
      if (remaining.length) this.setState(k, Object.fromEntries(remaining));
      else this.sql.prepare("DELETE FROM distill_state WHERE k=?").run(k);
    }
  }

  /** 修正不另起一段活动；已有整理必须回到原活动，用新正文重建。 */
  correctRecord(id: string) {
    const original = this.hub.get(id);
    if (!original) return;
    const ids = [id, ...original.corrections.map(r => r.id)];
    const placeholders = ids.map(() => "?").join(",");
    const affected = this.sql.prepare(`SELECT DISTINCT a.thread_id FROM assignments a JOIN frame_records r ON r.frame_id=a.frame_id WHERE r.record_id IN (${placeholders})
      UNION SELECT thread_id FROM facts WHERE thread_id IS NOT NULL AND EXISTS(SELECT 1 FROM json_each(facts.evidence) WHERE value IN (${placeholders}))`).all(...ids, ...ids) as { thread_id: string }[];
    this.sql.prepare(`UPDATE facts SET invalid_at=? WHERE origin='llm' AND invalid_at IS NULL AND EXISTS(SELECT 1 FROM json_each(facts.evidence) WHERE value IN (${placeholders}))`).run(new Date().toISOString(), ...ids);
    this.clearReviewEvidence(ids);
    if (original.sensitivity === "private" || original.corrections.at(-1)?.sensitivity === "private") this.clearTimelineCorrections(ids);
    this.clearDerived(new Set(affected.map(r => r.thread_id)), new Set(), [original.t_start]);
    removeSummariesOf(this.hub, id);
    this.sql.prepare("UPDATE days SET needs_regen=1 WHERE date=date(?, 'localtime')").run(original.t_start);
  }

  removeRecord(id: string, time: string) { this.removeRecords([{id,time}]); }

  removeRecords(records: { id: string; time: string }[]) {
    const removed = new Set(records.map(r => r.id)), input = JSON.stringify([...removed]);
    for (const {id} of records) {
      const record = this.hub.get(id);
      if (record?.source === "mac.audio" && record.source_ref) new AudioStore(this.hub).removeConversation(record.source_ref,record.device);
    }
    removeSummariesOf(this.hub, [...removed]);
    const affected = new Set<string>(), projects = new Set<string>(), changedFrames = new Set<string>();
    for (const row of this.sql.prepare(`SELECT DISTINCT f.*,a.thread_id FROM frame_records r JOIN frames f ON f.id=r.frame_id
      LEFT JOIN assignments a ON a.frame_id=f.id WHERE r.record_id IN (SELECT value FROM json_each(?))`).all(input) as Row[]) {
      changedFrames.add(row.id);
      if (row.thread_id) affected.add(row.thread_id);
      const ids = (JSON.parse(row.record_ids) as string[]).filter(r => !removed.has(r));
      if (!ids.length) {
        this.sql.prepare("DELETE FROM assignments WHERE frame_id=?").run(row.id);
        this.sql.prepare("DELETE FROM frame_rejections WHERE frame_id=?").run(row.id);
        this.sql.prepare("DELETE FROM frames WHERE id=?").run(row.id);
      } else {
        const kept = ids.map(r => this.hub.get(r)!);
        this.sql.prepare("UPDATE frames SET record_ids=?,chars=?,private=?,t_start_ms=?,t_end_ms=? WHERE id=?").run(JSON.stringify(ids),kept.reduce((n,r) => n+r.body.length,0),Number(kept.some(r => r.sensitivity === "private")),Math.min(...kept.map(r => Date.parse(r.t_start))),Math.max(...kept.map(r => Date.parse(r.t_end ?? r.t_start))),row.id);
      }
    }
    this.sql.prepare("DELETE FROM frame_records WHERE record_id IN (SELECT value FROM json_each(?))").run(input);
    // 每个批次只扫描一次全部原话和事实，关联文字在同一事务内立即撤下。
    for (const table of ["threads","projects"]) {
      for (const row of this.sql.prepare(`SELECT id,detail FROM ${table} WHERE detail IS NOT NULL`).all() as Row[]) {
        const detail = decode<Row>(row).detail;
        if (Array.isArray(detail?.quotes) && detail.quotes.some((q: Row) => removed.has(q?.record_id))) {
          if (table === "threads") affected.add(row.id); else projects.add(row.id);
        }
      }
    }
    const facts = this.sql.prepare("SELECT * FROM facts WHERE EXISTS(SELECT 1 FROM json_each(facts.evidence) WHERE value IN (SELECT value FROM json_each(?)))").all(input) as Row[];
    for (const f of facts) {
      if (f.thread_id) affected.add(f.thread_id);
      if (f.project_id) projects.add(f.project_id);
      this.sql.prepare("DELETE FROM facts WHERE id=?").run(f.id);
    }
    for (const tid of affected) this.sql.prepare("UPDATE threads SET active_minutes=? WHERE id=?").run(this.activeMinutes(tid),tid);
    this.clearReviewEvidence([...removed]);
    this.clearTimelineCorrections([...removed]);
    this.clearDerived(affected, projects, records.map(r=>r.time));
    const candidates = this.getState<{ frame_ids: string[] }[]>("candidates");
    if (candidates) this.setState("candidates", candidates.filter(c => !c.frame_ids.some(id => changedFrames.has(id))));
  }
}
