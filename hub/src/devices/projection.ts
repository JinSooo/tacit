import { createHash } from "node:crypto";
import { AgentReads } from "../agent.ts";
import { conversationDetail } from "../conversations.ts";
import { InputError, recordListCursor, type HubDB, type StoredRecord } from "../db.ts";
import type { DraftItem, ReviewDetail, ReviewItem } from "../distill/day-review.ts";
import { localDateString } from "../distill/requests.ts";
import { DistillStore, type Project, type Thread } from "../distill/store.ts";
import { historySegments } from "../history.ts";
import { currentNow, emptyNowBrief, nowSummary, pendingBrief } from "../now-status.ts";
import { activeDaysInMonth, timelineDays, timelineRecord } from "../timeline.ts";
import { base64url, object, WireError } from "./envelope.ts";
import { directProjectionBytes, projectionHead, type ChangeRow, type ProjectionKind } from "./projection-store.ts";

const validID = /^[0-9A-HJKMNP-TV-Z]{26}$/;
const dayMs = 86_400_000;
const bytes = (value: unknown) => Buffer.byteLength(JSON.stringify(value));
const fits = (body: object, max: number) => bytes({ status: 200, body }) <= max;
const text = (value: unknown) => typeof value === "string" ? value : undefined;
const strings = (value: unknown) => Array.isArray(value) ? value.filter((v): v is string => typeof v === "string") : undefined;
const encode = (data: unknown) => Buffer.from(JSON.stringify(data)).toString("base64url");

export function integer(value: unknown, min: number, max: number, name: string): number {
  if (typeof value !== "number" || !Number.isSafeInteger(value) || value < min || value > max) throw new InputError(`${name} 无效`);
  return value;
}

function recordID(value: unknown) {
  if (typeof value !== "string" || !validID.test(value)) throw new InputError("记录 ID 无效");
  return value;
}

function parameters(body: Record<string, unknown>, fields: string[]) {
  const params = new URLSearchParams();
  for (const key of fields) {
    const v = body[key];
    if (v === undefined) continue;
    if ((typeof v !== "string" && typeof v !== "number" && typeof v !== "boolean") || String(v).length > 4096) {
      throw new InputError(`${key} 无效`);
    }
    params.set(key, key === "body" && typeof v === "boolean" ? String(Number(v)) : String(v));
  }
  return params;
}

// Fail closed on missing ancestry, cycles and any private original or latest correction.
const publicRecord = `NOT EXISTS (
  WITH RECURSIVE lineage(id,sensitivity,source,corrects) AS (
    SELECT r.id,r.sensitivity,r.source,r.corrects
    UNION
    SELECT p.id,p.sensitivity,p.source,p.corrects FROM lineage l JOIN records p ON p.id=l.corrects
    WHERE l.source='manual.correction'
  )
  SELECT 1 WHERE NOT EXISTS(SELECT 1 FROM lineage WHERE source<>'manual.correction')
  UNION ALL
  SELECT 1 FROM lineage l WHERE l.sensitivity='private' OR
    (SELECT c.sensitivity FROM records c WHERE c.corrects=l.id AND c.source='manual.correction'
      ORDER BY c.t_start_ms DESC,c.id DESC LIMIT 1)='private'
)`;

export interface Change {
  seq: number; op: "upsert" | "delete"; kind: ProjectionKind; id: string; rev: number;
  data?: object; truncated?: true;
}
export interface ProjectionPage {
  epoch: number; reset: boolean; changes: Change[]; cursor: number; more: boolean; server_time: string;
}
type Visibility = "public" | "mixed" | "hidden";
type StoredDay = { detail: ReviewDetail | null };

export class Projection {
  private readonly store: DistillStore;
  private readonly sql: HubDB["db"];
  private readonly visibility = new Map<string, boolean>();
  private readonly threadVisibility = new Map<string, Visibility>();
  private readonly projects = new Map<string, ReturnType<Projection["buildProjectData"]>>();
  private readonly dayInputs = new Map<string, ReviewDetail | null>();

  constructor(private readonly hub: HubDB, private readonly clock: number) {
    this.store = new DistillStore(hub);
    this.sql = hub.db;
  }

  private public(id: string) {
    const seen = this.visibility.get(id);
    if (seen !== undefined) return seen;
    const allowed = !!this.sql.prepare(`SELECT 1 FROM records r WHERE r.id=? AND ${publicRecord}`).get(id);
    this.visibility.set(id, allowed);
    return allowed;
  }

  private publicEvidence(ids: string[]) {
    return ids.length > 0 && ids.every(id => this.public(id));
  }

  private facts(field: "thread_id" | "project_id", id: string) {
    return this.store.facts(field, id).filter(fact => this.publicEvidence(fact.evidence));
  }

  private threadAccess(id: string): Visibility {
    const seen = this.threadVisibility.get(id);
    if (seen) return seen;
    // Digest may retain input from an earlier frame and from facts later superseded.
    const rows = this.sql.prepare<[string, string, string, string], { id: string }>(`
      SELECT fr.record_id AS id FROM assignments a JOIN frame_records fr ON fr.frame_id=a.frame_id WHERE a.thread_id=?
      UNION SELECT e.value FROM facts f JOIN json_each(f.evidence) e WHERE f.thread_id=?
      UNION SELECT fr.record_id FROM distill_state s JOIN json_each(s.v,'$.frames') f
        JOIN frame_records fr ON fr.frame_id=f.value WHERE s.k='digest:' || ?
      UNION SELECT json_extract(q.value,'$.record_id') FROM threads t JOIN json_each(t.detail,'$.quotes') q WHERE t.id=?`).all(id, id, id, id);
    const publicCount = rows.filter(row => this.public(row.id)).length;
    const access = publicCount === 0 ? "hidden" : publicCount === rows.length ? "public" : "mixed";
    this.threadVisibility.set(id, access);
    return access;
  }

  private threadData(id: string) {
    const thread = this.store.thread(id);
    const access = this.threadAccess(id);
    if (!thread || access === "hidden") return null;
    const { project_id, status, domain, title, brief, first_ms, last_ms, active_minutes, sessions, needs_regen, updated_at } = thread;
    return { id, project_id, status, domain, title: access === "public" ? title : "事项",
      brief: access === "public" ? brief : null, detail: access === "public" ? this.threadDetail(thread) : null,
      first_ms: access === "public" ? first_ms : null, last_ms: access === "public" ? last_ms : null,
      active_minutes: access === "public" ? active_minutes : null, sessions: access === "public" ? sessions : null,
      needs_regen, updated_at, facts: this.facts("thread_id", id) };
  }

  private threadDetail(thread: Thread) {
    const detail = object(thread.detail);
    if (!detail) return null;
    const goal = text(detail.goal), progress = text(detail.progress);
    const a = object(detail.artifacts) ?? {};
    const artifacts = { files: strings(a.files), urls: strings(a.urls), commands: strings(a.commands), people: strings(a.people) };
    const quotes = Array.isArray(detail.quotes) ? detail.quotes.flatMap(raw => {
      const q = object(raw);
      return q && typeof q.record_id === "string" && typeof q.text === "string" && this.public(q.record_id) ? [{ record_id: q.record_id, text: q.text }] : [];
    }) : [];
    return { goal, progress, artifacts, quotes };
  }

  private projectKeys(p: Project) {
    const { repos, hosts, chats, remotes } = p.keys as Project["keys"] & { remotes?: string[] };
    return { repos: strings(repos) ?? [], hosts: strings(hosts) ?? [], chats: strings(chats) ?? [], remotes: strings(remotes) };
  }

  private projectData(id: string) {
    if (!this.projects.has(id)) this.projects.set(id, this.buildProjectData(id));
    return this.projects.get(id) ?? null;
  }

  private buildProjectData(id: string) {
    const project = this.store.project(id);
    if (!project) return null;
    const threadIds = this.sql.prepare<[string], { id: string }>("SELECT id FROM threads WHERE project_id=?").all(id);
    const access = threadIds.map(row => this.threadAccess(row.id));
    const facts = this.facts("project_id", id);
    if (access.length && access.every(value => value === "hidden") && !facts.length && !project.confirmed) return null;
    // Project text may have read both an unsafe thread summary and project-level facts.
    const safe = access.length > 0 && access.every(value => value === "public") &&
      this.sql.prepare<[string], { evidence: string }>("SELECT evidence FROM facts WHERE project_id=?")
        .all(id).every(row => this.publicEvidence(JSON.parse(row.evidence) as string[]));
    const { name, confirmed, brief, salience, last_ms, needs_regen, updated_at } = project;
    const detail = safe && object(project.detail);
    return { id, name: safe || confirmed ? name : "项目", confirmed,
      keys: safe || confirmed ? this.projectKeys(project) : { repos: [], hosts: [], chats: [] },
      brief: safe ? brief : null, detail: detail ? { goal: text(detail.goal), status: text(detail.status), people: strings(detail.people) } : null,
      salience: safe ? salience : null, last_ms: safe ? last_ms : null,
      thread_count: access.filter(value => value !== "hidden").length, needs_regen, updated_at, facts };
  }

  private projectContext(id: string) {
    const p = this.store.project(id), safe = this.projectData(id);
    if (!p || !safe) return null;
    const cached = this.sql.prepare<[string], { payload: string; updated_at: string }>(
      "SELECT payload,updated_at FROM project_context_cache WHERE project_id=?").get(id);
    const computed = Date.parse(cached?.updated_at ?? "");
    if (cached && this.clock >= computed && this.clock - computed < 60_000) {
      const value = JSON.parse(cached.payload) as { thread_ids: string[] };
      if (value.thread_ids.every(thread => this.threadAccess(thread) === "public")) return value;
    }
    const context = new AgentReads(this.hub).projectContext({ ...p, name: safe.name }, {
      thread: thread => this.threadAccess(thread.id) === "public",
      openFacts: thread => this.facts("thread_id", thread).filter(f => f.kind === "open").reverse().slice(0, 2).map(f => f.text),
      now: this.clock,
    });
    const threads = context.threads.map(({ id, project_id, status, domain, title, brief, first_ms, last_ms,
      active_minutes, sessions, needs_regen, updated_at, open }) => ({
      id, project_id, status, domain, title, brief, first_ms, last_ms, active_minutes, sessions, needs_regen, updated_at, open,
    }));
    const computed_at = this.serverTime();
    // Ignored paths can originate in a private or removed project. Only expose paths on this visible project.
    const ignored = new Set(this.store.ignoredProjectKeys().repos);
    const value = { ...context.value, name: safe.name, keys: safe.keys, ignored_repos: safe.keys.repos.filter(path => ignored.has(path)),
      thread_ids: context.ids, threads, computed_at, needs_regen: p.needs_regen };
    this.sql.prepare("INSERT OR REPLACE INTO project_context_cache(project_id,payload,updated_at) VALUES (?,?,?)")
      .run(id, JSON.stringify(value), computed_at);
    return value;
  }

  private inputs(date: string) {
    if (!this.dayInputs.has(date)) this.dayInputs.set(date, (this.store.day(date) as StoredDay | null)?.detail ?? null);
    return this.dayInputs.get(date) ?? null;
  }

  private dayItem(date: string, item: ReviewItem) {
    const ids = [...(item.record_ids ?? []), ...(item.evidence ?? []).map(ref => ref.id)];
    const day = this.inputs(date);
    const segment = day?.polished_segments?.find(segment => segment.id === item.id);
    const deps = segment?.model_dependencies ?? (day?.polished_segments
      ? day.polished_segments.flatMap(segment => segment.dependencies) : day?.record_ids ?? []);
    return !!item.evidence?.length && this.publicEvidence([...ids, ...deps]);
  }

  private cleanItem(item: ReviewItem | DraftItem) {
    const { id, title, t_start, t_end, active_seconds, sources, apps, record_ids, project_id } = item;
    const thread = (item as DraftItem).thread_id;
    const fields = { id, title, t_start, t_end, active_seconds, sources, apps: apps?.map(({ source, app }) => ({ source, app })),
      record_ids, project_id: project_id && this.projectData(project_id) ? project_id : null,
      ...(thread && this.threadAccess(thread) !== "hidden" ? { thread_id: thread } : {}) };
    return "excerpt" in item ? { ...fields, excerpt: item.excerpt } : { ...fields, description: item.description,
      evidence: item.evidence.map(({ id, at, source, title }) => ({ id, at, source, title })) };
  }

  private dayData(date: string) {
    const row = this.store.dayView(date, { now: this.clock });
    if (!row) return null;
    const original = this.inputs(date);
    const visible = (row.detail?.items ?? []) as ReviewItem[];
    const items = visible.filter(item => this.dayItem(date, item)).map(item => this.cleanItem(item));
    const drafts = ((row.drafts ?? []) as DraftItem[]).filter(item => this.publicEvidence(item.record_ids)).map(item => this.cleanItem(item));
    // The overview is generated from the whole review, not just the references it quotes.
    const safe = items.length === visible.length && this.publicEvidence(original?.polished_segments?.flatMap(segment => segment.model_dependencies ?? segment.dependencies) ?? original?.record_ids ?? []);
    const summary = safe ? row.detail?.summary ?? null : null;
    return { date, brief: safe ? row.brief ?? null : null, detail: row.detail ? {
      summary, cutoff: row.detail.cutoff, items,
      omitted_count: ((row.detail.omitted_record_ids ?? []) as string[]).filter(id => this.public(id)).length,
      // 只下推公开记录的 ID（不含正文），查看端据此给详细档标“未入时间线”。
      omitted_record_ids: ((row.detail.omitted_record_ids ?? []) as string[]).filter(id => this.public(id)),
    } : null, needs_regen: row.needs_regen ?? 0, failed: !!row.failed, updated_at: row.updated_at ?? null,
    ...(date === localDateString(this.clock) ? { drafts } : {}) };
  }

  private nowData() {
    const rows = nowSummary(this.store, this.clock, id => this.threadAccess(id) === "public").detail.threads;
    const threads = rows.map(row => {
      const thread = this.store.thread(row.thread_id)!;
      const project = thread.project_id ? this.projectData(thread.project_id) : null;
      return { ...row, project: project?.name ?? null };
    });
    const first = threads[0], local = currentNow(this.hub, this.clock);
    if (!first) {
      // 没有公开的活跃事项时，照样下推“待整理 / 整理失败”这类状态（AGENTS：此刻要显示整理失败或有新活动待整理）。
      // 只用固定文案，不带 currentNow 可能来自私密事项的缓存摘要。
      if (!local?.feedback && local?.brief !== pendingBrief) return null;
      return { brief: local.brief === pendingBrief ? pendingBrief : emptyNowBrief, detail: { threads: [] }, updated_at: null, feedback: local.feedback ?? null };
    }
    const brief = first.project && !first.brief.includes(first.project) ? `${first.project}：${first.brief}` : first.brief;
    return { brief, detail: { threads }, updated_at: this.store.thread(first.thread_id)?.updated_at ?? null, feedback: local?.feedback ?? null };
  }

  private entity(kind: ProjectionKind, id: string): object | null {
    switch (kind) {
      case "day": return this.dayData(id);
      case "project": return this.projectData(id);
      case "thread": return this.threadData(id);
      case "project_context": return this.projectContext(id);
      case "now": return this.nowData();
      case "record_gone": return null;
    }
  }

  private serverTime() { return new Date(this.clock).toISOString(); }

  pull(device: string, body: Record<string, unknown>, max = directProjectionBytes, contextOnly = false): ProjectionPage {
    const cursor = integer(body.cursor, 0, Number.MAX_SAFE_INTEGER, "cursor");
    const head = projectionHead(this.sql);
    const epoch = body.epoch === undefined && cursor === 0 ? head.epoch : integer(body.epoch, 1, Number.MAX_SAFE_INTEGER, "epoch");
    const limit = integer(body.limit ?? 50, 1, 200, "limit");
    const window = integer(body.window_days ?? 90, 1, 365, "window_days");
    if (epoch !== head.epoch || cursor > head.seq || (cursor > 0 && cursor < head.floor)) {
      return { epoch: head.epoch, reset: true, changes: [], cursor: 0, more: true, server_time: this.serverTime() };
    }
    if (cursor === 0) {
      const oldest = new Date(this.clock);
      oldest.setDate(oldest.getDate() - window + 1);
      this.sql.prepare("UPDATE devices SET projection_window_from=?,projection_window_until=? WHERE id=?")
        .run(localDateString(+oldest), head.seq, device);
    }
    const state = this.sql.prepare<[string], { projection_window_from: string | null; projection_window_until: number | null }>(
      "SELECT projection_window_from,projection_window_until FROM devices WHERE id=?").get(device);
    const rows = this.sql.prepare<[number, number], ChangeRow>(
      `SELECT * FROM projection_changes WHERE seq>? ${contextOnly ? "AND kind='project_context'" : ""} ORDER BY seq LIMIT ?`)
      .all(cursor, limit + 1);
    const page: ProjectionPage = { epoch, reset: false, changes: [], cursor, more: false, server_time: this.serverTime() };
    let total = 0;
    for (const row of rows.slice(0, limit)) {
      if (row.kind === "day" && state?.projection_window_from && row.seq <= (state.projection_window_until ?? 0) &&
        row.entity_id < state.projection_window_from) { page.cursor = row.seq; continue; }
      const data = row.op === "upsert" ? this.entity(row.kind, row.entity_id) : null;
      const change: Change = { seq: row.seq, rev: row.rev, kind: row.kind, id: row.entity_id,
        op: data ? "upsert" : "delete", ...(data ? { data } : {}) };
      const budget = max - 1024; // Leave room for page and unsolicited delta envelopes.
      if (data && bytes(change) > budget) this.compact(change, budget);
      const size = bytes(change) + 1;
      if (total + size > budget) { page.more = true; return page; }
      page.changes.push(change);
      page.cursor = row.seq;
      total += size;
    }
    page.more = rows.length > limit;
    if (!page.more) page.cursor = head.seq;
    return page;
  }

  // Atomic cache rows cannot be split; drop optional detail on a single pathological entity.
  private compact(change: Change, budget: number) {
    const data = change.data as Record<string, unknown>;
    change.truncated = true;
    const detail = object(data.detail);
    for (const field of ["facts", "drafts", "detail", "keys", "text", "threads", "thread_ids"] as const) {
      if (bytes(change) <= budget) return;
      if (field === "detail" && change.kind === "day" && Array.isArray(detail?.items)) {
        let items = detail.items;
        while (items.length && bytes(change) > budget) {
          items = items.slice(0, Math.floor(items.length / 2));
          detail.items = items;
        }
      } else delete data[field];
    }
    if (bytes(change) > budget) {
      change.op = "delete";
      delete change.data;
    }
  }

  ack(device: string, body: Record<string, unknown>) {
    const { epoch, seq, floor } = projectionHead(this.sql);
    const cursor = integer(body.cursor, 0, seq, "cursor");
    if (integer(body.epoch, 1, Number.MAX_SAFE_INTEGER, "epoch") !== epoch || (cursor > 0 && cursor < floor)) {
      throw new WireError(409, "同步窗口已重置，请重新拉取");
    }
    this.sql.prepare(`UPDATE devices SET projection_cursor=CASE WHEN projection_epoch=? THEN MAX(projection_cursor,?) ELSE ? END,
      projection_epoch=? WHERE id=?`).run(epoch, cursor, cursor, epoch, device);
    return { ok: true };
  }

  read(op: string, body: Record<string, unknown>, max: number, includePrivate = false): object {
    const allowedItem = (date: string, item: ReviewItem) => this.dayItem(date, item);
    let result: object;
    switch (op) {
      case "records.get": return this.recordsGet(body, max, includePrivate);
      case "records.list": return this.recordsList(body, max, includePrivate);
      case "history.segments": {
        const history = historySegments(this.hub, parameters(body, ["from", "to", "device"]), includePrivate ? undefined : id => this.public(id));
        if (includePrivate) { result = history; break; }
        for (const segment of history.segments) {
          const thread = segment.thread;
          if (thread && this.threadAccess(thread.id) !== "public") segment.thread = null;
          else if (thread?.project_id) thread.project_name = this.projectData(thread.project_id)?.name ?? null;
        }
        const conversations = history.conversations.filter(group => this.publicEvidence(group.record_ids));
        result = { segments: history.segments, conversations };
        break;
      }
      case "conversations.detail": {
        const id = recordID(body.record_id);
        if (!includePrivate && !this.public(id)) throw new WireError(404, "内容不存在");
        const detail = conversationDetail(this.hub, id, this.clock);
        if (!includePrivate && !this.publicEvidence(detail.record_ids)) throw new WireError(404, "内容不存在");
        result = detail;
        break;
      }
      case "timeline.query": {
        const params = parameters(body, ["project_id", "thread_id", "q", "before", "limit"]);
        const page = timelineDays(this.hub, params, allowedItem);
        const days: typeof page.days = [];
        for (const day of page.days) {
          const clean = { date: day.date, items: day.items.map(item => this.cleanItem(item)) };
          if (!fits({ days: [...days, clean], next_cursor: day.date }, max)) {
            if (!days.length) throw new WireError(413, "单日时间线超过响应上限");
            return { days, next_cursor: days.at(-1)!.date };
          }
          days.push(clean as typeof day);
        }
        result = { days, next_cursor: page.next_cursor };
        break;
      }
      case "timeline.locate": {
        const id = recordID(body.record_id);
        const located = (includePrivate || this.public(id)) && timelineRecord(this.hub, id, allowedItem);
        if (!located) throw new WireError(404, "内容不存在");
        result = located;
        break;
      }
      case "days.active": {
        if (typeof body.month !== "string") throw new InputError("month 必须是 YYYY-MM");
        result = activeDaysInMonth(this.hub, body.month, includePrivate ? undefined : {
          dayItem: allowedItem,
          daySummaryVisible: (_date, detail, visibleItems, readableItems) =>
            visibleItems.length === readableItems.length && this.publicEvidence(
              detail.polished_segments?.flatMap(segment => segment.model_dependencies ?? segment.dependencies) ?? detail.record_ids ?? [],
            ),
          recordFilter: publicRecord,
        });
        break;
      }
      default: throw new InputError("设备操作无效");
    }
    if (!fits(result, max)) throw new WireError(413, "响应过大，请缩小查询范围或直接读取录音记录");
    return result;
  }

  private recordsList(body: Record<string, unknown>, max: number, includePrivate: boolean) {
    const p = parameters(body, ["from", "to", "device", "source", "q", "limit", "cursor", "body"]);
    const list = this.hub.list(p, { recordFilter: includePrivate ? "" : publicRecord });
    const records: Partial<StoredRecord>[] = [];
    let used = 0;
    const budget = max - 1024;
    for (const row of list.records) {
      const { media: _media, ...record } = row;
      let candidate = record;
      if (bytes(record) + 1 > budget) {
        const { body: _body, ...metadata } = record;
        candidate = { ...metadata, ...{ body_truncated: true } };
        if (bytes(candidate) + 1 > budget) throw new WireError(413, "记录元数据超过响应上限");
      }
      const size = bytes(candidate) + 1;
      if (used + size > budget) {
        const last = records.at(-1)!;
        return { records, next_cursor: recordListCursor(Date.parse(last.t_start!), last.id!) };
      }
      records.push(candidate);
      used += size;
    }
    return { ...list, records };
  }

  private recordsGet(body: Record<string, unknown>, max: number, includePrivate: boolean) {
    if (!Array.isArray(body.ids) || !body.ids.length || body.ids.length > 50) throw new InputError("ids 必须是 1–50 个记录 ID");
    const ids = [...new Set(body.ids.map(recordID))];
    const corrections = body.include_corrections === true;
    const missing: string[] = [];
    const records: object[] = [];
    let used = 0;
    const budget = max - 2048; // Up to 50 missing IDs, plus the wrapper and cursor.
    const key = createHash("sha256").update(JSON.stringify(includePrivate ? [ids, corrections, true] : [ids, corrections])).digest("base64url");
    const revision = this.store.getState<number>("content_revision") ?? 0;
    let index = 0, part = 0, offset = 0;
    const cursor = (i: number, p: number, at: number) => encode([key, revision, i, p, at]);
    if (body.cursor !== undefined) {
      let decoded: unknown;
      try { decoded = JSON.parse(base64url(body.cursor)?.toString("utf8") ?? ""); } catch { throw new InputError("cursor 无效"); }
      if (!Array.isArray(decoded) || decoded.length !== 5 || decoded[0] !== key) throw new InputError("cursor 无效");
      if (decoded[1] !== revision) throw new WireError(409, "记录已修正或删除，请从第一页重新读取");
      index = integer(decoded[2], 0, ids.length - 1, "cursor");
      part = integer(decoded[3], 0, Number.MAX_SAFE_INTEGER, "cursor");
      offset = integer(decoded[4], 0, Number.MAX_SAFE_INTEGER, "cursor");
    }
    for (; index < ids.length; index++, part = 0, offset = 0) {
      const id = ids[index]!, record = this.hub.get(id);
      if (!record) { missing.push(id); continue; }
      const versions = (includePrivate || this.public(id)) && corrections ? [record, ...record.corrections] : [record];
      if (part >= versions.length) throw new InputError("cursor 无效");
      for (; part < versions.length; part++, offset = 0) {
        const entry = versions[part]!;
        const visible = includePrivate || this.public(entry.id);
        const { id: version, device, source, kind, t_start, t_end, title, source_ref, context, people, capture, sensitivity, redactions, corrects, t_received } = entry;
        const meta = visible ? { id: version, device, source, kind, t_start, t_end, title, source_ref, context, people, capture, sensitivity, redactions, corrects, t_received, schema: entry.schema }
          : { id: version, redacted_private: true };
        const points = visible ? Array.from(entry.body) : [];
        if (offset > points.length) throw new InputError("cursor 超出原文范围");
        const value = (end: number) => {
          const page = visible ? { ...meta, body: points.slice(offset, end).join(""),
            body_range: { start: offset, end, total: points.length } } : meta;
          return part === 0 ? page : { id, corrections: [page] };
        };
        const next = (end: number) => end < points.length ? cursor(index, part, end) : part + 1 < versions.length ?
          cursor(index, part + 1, 0) : index + 1 < ids.length ? cursor(index + 1, 0, 0) : null;
        const minimum = Math.min(offset + 1, points.length);
        const room = (end: number) => {
          const serialized = JSON.stringify(value(end));
          return serialized.length <= 38_000 && used + Buffer.byteLength(serialized) + 1 <= budget;
        };
        if (!room(minimum)) {
          if (!records.length && !missing.length) throw new WireError(413, "记录元数据超过响应上限");
          return { records, missing, next_cursor: cursor(index, part, offset) };
        }
        let low = minimum, high = Math.min(points.length, offset + 38_000);
        while (low < high) {
          const middle = Math.ceil((low + high) / 2);
          // The 38,000 ceiling counts serialized UTF-16 code units, as Agent raw pages do.
          if (room(middle)) low = middle;
          else high = middle - 1;
        }
        const row = value(low);
        records.push(row);
        used += bytes(row) + 1;
        if (low < points.length) return { records, missing, next_cursor: next(low) };
      }
    }
    return { records, missing, next_cursor: null };
  }
}
