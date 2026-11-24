import { createHash, randomUUID } from "node:crypto";
import { validateRecord, type RecordV1 } from "../../../packages/record/index.ts";
import type { HubDB } from "../db.ts";
import { localDateString, localDayStart } from "../distill/requests.ts";
import { redactString } from "../redact.ts";
import { deviceID, object } from "./envelope.ts";
import { auditSecurity } from "../security-audit.ts";

const correctionSource = "manual.correction";
const idPattern = /^[0-9A-HJKMNP-TV-Z]{26}$/;
const snapshotPattern = /^[a-f0-9]{64}$/;
const sessionPattern = /^[a-f0-9]{8}-(?:[a-f0-9]{4}-){3}[a-f0-9]{12}$/;
const hour = 3_600_000;
const pageSize = 200;
const statuses = ["added", "exists", "deleted", "conflict", "rejected"] as const;
type ItemStatus = typeof statuses[number];
type ItemError = "invalid_record" | "out_of_scope" | "private_record" | "media_not_allowed" |
  "device_collision" | "correction_target" | "unsafe_source_ref" | "record_conflict";
type Item = { id: string | null; status: ItemStatus; remote_id?: string; code?: ItemError };
type Counts = Record<ItemStatus, number>;
type SQL = HubDB["db"];
type Session = { id: string; hub_id: string; snapshot_id: string; identities: string; expires_ms: number; finished_at: string | null; queued_days: number };
export type HistoricalIdentity = { device: string; kind: "mac" | "agent"; sources: string[] };

/** 所有记录删除和私密变更共用同一个持久水位。撤下事件只含来源 ID 和类型。 */
export const historyImportSchema = `
CREATE TABLE IF NOT EXISTS history_import_sessions (
  id TEXT PRIMARY KEY, actor TEXT NOT NULL, hub_id TEXT NOT NULL, snapshot_id TEXT NOT NULL,
  identities TEXT NOT NULL, started_at TEXT NOT NULL, expires_ms INTEGER NOT NULL, finished_at TEXT,
  queued_days INTEGER NOT NULL DEFAULT 0, UNIQUE(actor,hub_id,snapshot_id)
);
CREATE TABLE IF NOT EXISTS history_import_batches (
  session_id TEXT NOT NULL, batch_number INTEGER NOT NULL, fingerprint TEXT NOT NULL,
  receipt TEXT NOT NULL, added INTEGER NOT NULL, existing INTEGER NOT NULL, deleted INTEGER NOT NULL,
  conflicts INTEGER NOT NULL, rejected INTEGER NOT NULL, committed_at TEXT NOT NULL,
  PRIMARY KEY(session_id,batch_number)
);
CREATE TABLE IF NOT EXISTS history_import_ids (
  session_id TEXT NOT NULL, source_id TEXT NOT NULL, remote_id TEXT NOT NULL, PRIMARY KEY(session_id,source_id)
);
CREATE INDEX IF NOT EXISTS history_import_remote_id ON history_import_ids(remote_id);
CREATE TABLE IF NOT EXISTS history_import_changes (
  seq INTEGER PRIMARY KEY AUTOINCREMENT, session_id TEXT NOT NULL, id TEXT NOT NULL,
  kind TEXT NOT NULL CHECK(kind IN ('deleted','private')), UNIQUE(session_id,id,kind)
);
CREATE INDEX IF NOT EXISTS history_import_change_cursor ON history_import_changes(session_id,seq);
CREATE TABLE IF NOT EXISTS history_import_days (date TEXT PRIMARY KEY);
CREATE TRIGGER IF NOT EXISTS history_import_deleted AFTER DELETE ON records BEGIN
  INSERT INTO history_import_changes(session_id,id,kind)
  SELECT session_id,source_id,'deleted' FROM history_import_ids WHERE remote_id=OLD.id
  ON CONFLICT(session_id,id,kind) DO NOTHING;
END;
${["INSERT", "UPDATE OF sensitivity"].map((event, i) => `
CREATE TRIGGER IF NOT EXISTS history_import_private_${i} AFTER ${event} ON records WHEN NEW.sensitivity='private' BEGIN
  INSERT INTO history_import_changes(session_id,id,kind)
  SELECT session_id,source_id,'private' FROM history_import_ids WHERE remote_id IN (
    WITH RECURSIVE ancestors(id) AS (
      SELECT NEW.id UNION SELECT r.corrects FROM records r JOIN ancestors a ON r.id=a.id
      WHERE r.source='manual.correction' AND r.corrects IS NOT NULL
    ), chain(id) AS (
      SELECT id FROM ancestors UNION SELECT r.id FROM records r JOIN chain c ON r.corrects=c.id WHERE r.source='manual.correction'
    ) SELECT id FROM chain
  )
  ON CONFLICT(session_id,id,kind) DO NOTHING;
END;`).join("\n")}
PRAGMA user_version=19;
`;

export function historicalSource(kind: HistoricalIdentity["kind"], source: string, device: string) {
  if (source.length > 128) return false;
  if (kind === "agent") return source === "manual.agent" || source === correctionSource;
  if (source === "manual.agent") return device === "mac";
  return source === "manual.note" || source === correctionSource || source === "codex.session" || source === "claude_code.session" ||
    /^(?:mac|plugin\.ext_[a-z0-9_]+)\.[a-z0-9_]+(?:\.[a-z0-9_]+)*$/.test(source) ||
    /^plugin\.ext_[a-z0-9_]+$/.test(source);
}

/** 事务里重查，包括已撤销的目标端身份。 */
function destinationIdentity(sql: SQL, device: string) {
  return sql.prepare("SELECT 1 FROM devices WHERE id=? UNION ALL SELECT 1 FROM issued_device_ids WHERE id=? LIMIT 1").get(device, device);
}

function identityScope(raw: unknown): HistoricalIdentity[] | null {
  if (!Array.isArray(raw) || raw.length > 64) return null;
  const result: HistoricalIdentity[] = [];
  const seen = new Set<string>();
  for (const value of raw) {
    const item = object(value), device = item?.device, kind = item?.kind, sources = item?.sources;
    if (typeof device !== "string" || (kind !== "mac" && kind !== "agent") || seen.has(device) ||
        !(device === "mac" ? kind === "mac" : deviceID.test(device) && device.startsWith(kind + "-")) ||
        !Array.isArray(sources) || sources.length > 256 ||
        !sources.every(s => typeof s === "string" && historicalSource(kind, s, device))) return null;
    seen.add(device);
    result.push({ device, kind, sources: [...new Set<string>(sources)].sort() });
  }
  return result.sort((a, b) => a.device.localeCompare(b.device));
}

function sortKeys(value: unknown): unknown {
  if (Array.isArray(value)) return value.map(sortKeys);
  const item = object(value);
  return item ? Object.fromEntries(Object.keys(item).sort().map(k => [k, sortKeys(item[k])])) : value;
}

function comparable(record: RecordV1) {
  const { id, source_ref, t_end, corrects, redactions, ...contents } = record;
  return JSON.stringify(sortKeys({ ...contents, source_ref: source_ref ?? null, t_end: t_end ?? null,
    corrects: corrects ?? null, redactions: redactions ?? 0 }));
}

const ok = (body: object) => ({ status: 200, body });
const fail = (status: number, code: string) => ({ status, body: { error: code } });

class HistoryImport {
  constructor(private hub: HubDB, private actor: string, private hubID: string, private now: number) {}
  private get sql() { return this.hub.db; }

  begin(body: Record<string, unknown>) {
    if (body.hub_id !== this.hubID) return fail(409, "hub_mismatch");
    const identities = identityScope(body.identities);
    if (typeof body.snapshot_id !== "string" || !snapshotPattern.test(body.snapshot_id) || !identities) return fail(400, "invalid_scope");
    const scope = JSON.stringify(identities);
    const previous = this.sql.prepare<[string, string, string], Session>(
      "SELECT * FROM history_import_sessions WHERE actor=? AND hub_id=? AND snapshot_id=?").get(this.actor, this.hubID, body.snapshot_id);
    if (previous && scope !== previous.identities) return fail(409, "scope_changed");
    if (identities.some(i => destinationIdentity(this.sql, i.device))) return fail(403, "device_collision");
    const expires = this.now + 24 * hour;
    if (previous) {
      if (!previous.finished_at && previous.expires_ms <= this.now) {
        this.sql.prepare("UPDATE history_import_sessions SET expires_ms=? WHERE id=?").run(expires, previous.id);
        previous.expires_ms = expires;
      }
      return ok(this.progress(previous));
    }
    const id = randomUUID();
    this.sql.prepare("INSERT INTO history_import_sessions(id,actor,hub_id,snapshot_id,identities,started_at,expires_ms) VALUES(?,?,?,?,?,?,?)")
      .run(id, this.actor, this.hubID, body.snapshot_id, scope, new Date(this.now).toISOString(), expires);
    return ok(this.progress({ id, hub_id: this.hubID, snapshot_id: body.snapshot_id, identities: scope,
      expires_ms: expires, finished_at: null, queued_days: 0 }));
  }

  run(op: string, body: Record<string, unknown>) {
    const result = this.dispatch(op, body);
    this.audit(op, result);
    return result;
  }

  /** 导入绕开普通采集的设备归属检查，开始、完成、失败和批内越界拒收都单独留安全审计（只记类别与计数）。 */
  private audit(op: string, result: { status: number; body: object }) {
    const error = (result.body as { error?: unknown }).error;
    const event = (code: string, ok: boolean, target?: string) =>
      auditSecurity(this.sql, "history.import", { actor: this.actor, code, ok, target, now: this.now });
    if (typeof error === "string") return event(`${op.slice(15)}:${error}`, false);
    const session = (result.body as { session_id?: unknown }).session_id;
    const target = typeof session === "string" ? session : undefined;
    if (op === "history.import.begin" || op === "history.import.finish") return event(op.slice(15), true, target);
    if (op !== "history.import.batch") return;
    const items = (result.body as { items?: { code?: string }[] }).items ?? [];
    for (const code of ["device_collision", "out_of_scope", "private_record", "unsafe_source_ref"]) {
      const n = items.filter(i => i.code === code).length;
      if (n) event(`batch:${code}:${n}`, false, target);
    }
  }

  private dispatch(op: string, body: Record<string, unknown>) {
    if (op === "history.import.begin") return this.begin(body);
    if (typeof body.session_id !== "string" || !sessionPattern.test(body.session_id)) return fail(400, "invalid_session");
    const withdrawalRead = body.withdrawal_only === true && (op === "history.import.changes" || op === "history.import.verify");
    const session = this.sql.prepare<[string, string, string, number], Session>(`
      SELECT s.* FROM history_import_sessions s WHERE s.id=? AND s.hub_id=?
        AND (s.actor=? OR ?=1)`).get(body.session_id, this.hubID, this.actor, Number(withdrawalRead));
    if (!session) return fail(404, "session_unknown");
    switch (op) {
      case "history.import.batch": return this.batch(session, body);
      case "history.import.status": return ok(this.progress(session));
      case "history.import.finish": return this.finish(session);
      case "history.import.changes": return this.changes(session.id, body.after);
      case "history.import.verify": return this.verify(session.id, body.ids);
      default: return fail(400, "invalid_operation");
    }
  }

  private progress(session: Session) {
    const totals = this.sql.prepare<[string], Counts & { confirmed_batches: number; confirmed_records: number }>(`
      SELECT COUNT(*) confirmed_batches, COALESCE(SUM(added+existing+deleted+conflicts+rejected),0) confirmed_records,
        COALESCE(SUM(added),0) added, COALESCE(SUM(existing),0) "exists", COALESCE(SUM(deleted),0) deleted,
        COALESCE(SUM(conflicts),0) conflict, COALESCE(SUM(rejected),0) rejected
      FROM history_import_batches WHERE session_id=?`).get(session.id)!;
    const { confirmed_batches, confirmed_records, ...counts } = totals;
    return { session_id: session.id, hub_id: session.hub_id, snapshot_id: session.snapshot_id, confirmed_batches,
      confirmed_records, next_batch_number: confirmed_batches + 1, counts,
      expires_at: new Date(session.expires_ms).toISOString(), finished_at: session.finished_at, queued_days: session.queued_days };
  }

  private batch(session: Session, body: Record<string, unknown>) {
    const number = body.batch_number, records = body.records;
    if (typeof number !== "number" || !Number.isSafeInteger(number) || number < 1 ||
        !Array.isArray(records) || records.length > pageSize ||
        (records.length === 0 ? body.seal_empty !== true : body.seal_empty !== undefined)) return fail(400, "invalid_batch");
    let fingerprint: string;
    try { fingerprint = createHash("sha256").update(JSON.stringify(sortKeys(records))).digest("hex"); }
    catch (error) {
      if (error instanceof RangeError) return fail(400, "invalid_batch");
      throw error;
    }
    const existing = this.sql.prepare<[string, number], { fingerprint: string; receipt: string }>(
      "SELECT fingerprint,receipt FROM history_import_batches WHERE session_id=? AND batch_number=?").get(session.id, number);
    if (existing) return existing.fingerprint === fingerprint ? ok(JSON.parse(existing.receipt)) : fail(409, "batch_changed");
    if (session.finished_at) return fail(409, "session_finished");
    if (session.expires_ms <= this.now) return fail(403, "authorization_expired");
    const last = this.sql.prepare<[string], { n: number }>(
      "SELECT COALESCE(MAX(batch_number),0) n FROM history_import_batches WHERE session_id=?").get(session.id)!.n;
    if (number !== last + 1) return fail(409, "batch_out_of_order");

    const ids = new Set<string>();
    const privateIDs = new Set<string>();
    let corrections = false;
    const correctionTargets = new Map<string, string>();
    for (const raw of records) {
      const row = object(raw);
      if (row?.source === correctionSource) corrections = true;
      else if (corrections) return fail(400, "originals_first");
      if (typeof row?.id !== "string" || !idPattern.test(row.id)) continue;
      if (ids.has(row.id)) return fail(400, "duplicate_batch_id");
      ids.add(row.id);
      if (row.sensitivity === "private") privateIDs.add(row.id);
      if (row.source === correctionSource && typeof row.corrects === "string" && idPattern.test(row.corrects)) {
        correctionTargets.set(row.id, row.corrects);
      }
    }
    for (const id of privateIDs) {
      const target = correctionTargets.get(id);
      if (target) privateIDs.add(target);
    }
    for (const [id, target] of correctionTargets) {
      if (privateIDs.has(target)) privateIDs.add(id);
    }

    const scope = new Map((JSON.parse(session.identities) as HistoricalIdentity[]).map(i => [i.device, i.sources]));
    const byId = this.sql.prepare("SELECT id FROM records WHERE id=?");
    const byKey = this.sql.prepare("SELECT id FROM records WHERE source=? AND source_ref=?");
    const mapped = this.sql.prepare<[string, string], { remote_id: string }>(
      "SELECT remote_id FROM history_import_ids WHERE session_id=? AND source_id=?");
    const map = this.sql.prepare("INSERT OR IGNORE INTO history_import_ids VALUES(?,?,?)");
    const tombstone = this.sql.prepare<[string, string, string | null], { id: string }>(
      "SELECT id FROM tombstones WHERE id=? UNION ALL SELECT id FROM tombstones WHERE source=? AND source_ref=? LIMIT 1");
    const deleted = this.sql.prepare("INSERT OR IGNORE INTO history_import_changes(session_id,id,kind) VALUES(?,?,'deleted')");
    const items = records.map((raw): Item => {
      const inputId = object(raw)?.id;
      const id = typeof inputId === "string" && idPattern.test(inputId) ? inputId : null;
      const reject = (code: ItemError): Item => ({ id, status: "rejected", code });
      const conflict = (): Item => ({ id, status: "conflict", code: "record_conflict" });
      if (!validateRecord(raw).ok) return reject("invalid_record");
      let record = raw as RecordV1;
      if (!scope.get(record.device)?.includes(record.source)) return reject("out_of_scope");
      if (destinationIdentity(this.sql, record.device)) return reject("device_collision");
      if (privateIDs.has(record.id) || (record.corrects && privateIDs.has(record.corrects))) return reject("private_record");
      if (record.media != null || record.context?.url?.trim().match(/^file:/i)) return reject("media_not_allowed");
      if (localDayStart(localDateString(Date.parse(record.t_start))) === null ||
          (["mac.browser", "claude_code.session", "codex.session"].includes(record.source) && !record.source_ref)) return reject("invalid_record");
      const previous = mapped.get(session.id, record.id);
      const removed = tombstone.get(record.id, record.source, record.source_ref ?? null);
      if (removed) {
        if (!previous || previous.remote_id === removed.id) {
          map.run(session.id, record.id, removed.id);
          deleted.run(session.id, record.id);
        }
        return { id, status: "deleted" };
      }
      if (record.source_ref && (record.source_ref.startsWith("history-private:") || redactString(record.source_ref).count)) return reject("unsafe_source_ref");

      if (record.source === correctionSource) {
        const target = record.corrects ? mapped.get(session.id, record.corrects) : undefined;
        const original = target && this.hub.get(target.remote_id);
        if (!original || original.source === correctionSource || this.isPrivate(original.id)) return reject("correction_target");
        record = { ...record, corrects: original.id };
      } else if (record.corrects) return reject("invalid_record");

      const idMatch = (byId.get(record.id) as { id: string } | undefined)?.id;
      const keyMatch = record.source_ref == null ? undefined : (byKey.get(record.source, record.source_ref) as { id: string } | undefined)?.id;
      if (idMatch && keyMatch && idMatch !== keyMatch) return conflict();
      const found = idMatch ?? keyMatch;
      if (previous && previous.remote_id !== found) {
        return byId.get(previous.remote_id) ? conflict() : { id, status: "deleted" };
      }
      if (found) {
        const { corrections: _, t_received: __, ...stored } = this.hub.get(found)!;
        if (this.isPrivate(found) || comparable(stored) !== comparable(record)) return conflict();
        map.run(session.id, record.id, found);
        return { id, status: "exists", remote_id: found };
      }
      if (this.hub.ingest([record]).accepted !== 1) throw new Error("history_import_insert_invariant");
      map.run(session.id, record.id, record.id);
      return { id, status: "added", remote_id: record.id };
    });
    const counts = Object.fromEntries(statuses.map(status => [status, 0])) as Counts;
    for (const item of items) counts[item.status]++;
    const receipt = { session_id: session.id, batch_number: number, items, counts };
    this.sql.prepare("INSERT INTO history_import_batches VALUES(?,?,?,?,?,?,?,?,?,?)")
      .run(session.id, number, fingerprint, JSON.stringify(receipt), counts.added, counts.exists, counts.deleted, counts.conflict, counts.rejected,
        new Date(this.now).toISOString());
    return ok(receipt);
  }

  private isPrivate(id: string) {
    return !!this.sql.prepare(`
      WITH RECURSIVE ancestors(id) AS (
        SELECT ? UNION SELECT r.corrects FROM records r JOIN ancestors a ON r.id=a.id WHERE r.source='manual.correction' AND r.corrects IS NOT NULL
      ), chain(id) AS (
        SELECT id FROM ancestors UNION SELECT r.id FROM records r JOIN chain c ON r.corrects=c.id WHERE r.source='manual.correction'
      ) SELECT 1 FROM records r JOIN chain c ON c.id=r.id WHERE r.sensitivity='private' LIMIT 1`).get(id);
  }

  private finish(session: Session) {
    if (session.finished_at) return ok(this.progress(session));
    if (session.expires_ms <= this.now) return fail(403, "authorization_expired");
    const dates = new Set<string>();
    const records = this.sql.prepare<[string], { t_start_ms: number; t_end: string | null; target_ms: number | null; target_end: string | null }>(`
      SELECT DISTINCT r.t_start_ms,r.t_end,t.t_start_ms target_ms,t.t_end target_end FROM history_import_ids m JOIN records r ON r.id=m.remote_id
      LEFT JOIN records t ON t.id=r.corrects WHERE m.session_id=?
         AND NOT EXISTS(SELECT 1 FROM history_import_changes c WHERE c.session_id=m.session_id AND c.id=m.source_id)`).iterate(session.id);
    const addDates = (start: number, end: string | null) => {
      dates.add(localDateString(start));
      if (!end) return;
      // 日期整理最多向前回看 48 小时以找到跨午夜的活动。
      const cutoff = Math.min(Date.parse(end) - 1, start + 48 * hour), day = new Date(start);
      day.setHours(0, 0, 0, 0);
      day.setDate(day.getDate() + 1);
      while (+day <= cutoff) {
        dates.add(localDateString(+day));
        day.setDate(day.getDate() + 1);
      }
    };
    for (const row of records) {
      addDates(row.t_start_ms, row.t_end);
      if (row.target_ms !== null) addDates(row.target_ms, row.target_end);
    }
    const enqueue = this.sql.prepare("INSERT OR IGNORE INTO history_import_days VALUES(?)");
    const valid = [...dates].filter(date => /^\d{4}-\d{2}-\d{2}$/.test(date) && localDayStart(date) !== null);
    for (const date of valid) enqueue.run(date);
    session.finished_at = new Date(this.now).toISOString();
    session.queued_days = valid.length;
    this.sql.prepare("UPDATE history_import_sessions SET finished_at=?,queued_days=? WHERE id=?")
      .run(session.finished_at, session.queued_days, session.id);
    return ok(this.progress(session));
  }

  private changes(session: string, after: unknown) {
    if (typeof after !== "number" || !Number.isSafeInteger(after) || after < 0) return fail(400, "invalid_cursor");
    const head = this.sql.prepare<[string], { n: number }>(
      "SELECT COALESCE(MAX(seq),0) n FROM history_import_changes WHERE session_id=?").get(session)!.n;
    if (after > head) return fail(409, "cursor_unknown");
    const rows = this.sql.prepare<[string, number, number], { seq: number; id: string; kind: "deleted" | "private" }>(
      "SELECT seq,id,kind FROM history_import_changes WHERE session_id=? AND seq>? ORDER BY seq LIMIT ?"
    ).all(session, after, pageSize + 1);
    const more = rows.length > pageSize;
    if (more) rows.pop();
    return ok({ changes: rows.map(({ id, kind }) => ({ id, kind })), cursor: rows.at(-1)?.seq ?? after, more });
  }

  private verify(session: string, ids: unknown) {
    if (!Array.isArray(ids) || ids.length < 1 || ids.length > pageSize ||
        !ids.every(id => typeof id === "string" && idPattern.test(id))) return fail(400, "invalid_ids");
    const find = this.sql.prepare<[string, string], { present: number; deleted: number; private: number }>(`
      SELECT r.id IS NOT NULL present,
        EXISTS(SELECT 1 FROM history_import_changes c WHERE c.session_id=m.session_id AND c.id=m.source_id AND c.kind='deleted') deleted,
        EXISTS(SELECT 1 FROM history_import_changes c WHERE c.session_id=m.session_id AND c.id=m.source_id AND c.kind='private') private
      FROM history_import_ids m LEFT JOIN records r ON r.id=m.remote_id WHERE m.session_id=? AND m.source_id=?`);
    return ok({ items: ids.map((id: string) => {
      const row = find.get(session, id);
      return { id, status: row?.deleted ? "deleted" : row?.private ? "private" : row?.present ? "present" : "unknown" };
    }) });
  }
}

export function historyImport(hub: HubDB, actor: string, hubID: string, now: number, op: string, body: Record<string, unknown>) {
  return hub.db.transaction(() => new HistoryImport(hub, actor, hubID, now).run(op, body)).immediate();
}
