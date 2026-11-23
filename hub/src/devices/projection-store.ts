import type { HubDB } from "../db.ts";

type SQL = HubDB["db"];
export const relayProjectionBytes = 640 * 1024;
export const directProjectionBytes = 4 * 1024 * 1024;
export const projectionKinds = ["day", "project", "thread", "project_context", "now", "record_gone"] as const;
export type ProjectionKind = typeof projectionKinds[number];
export interface ChangeRow { seq: number; kind: ProjectionKind; entity_id: string; rev: number; op: "upsert" | "delete"; urgent: number }

const at = "strftime('%Y-%m-%dT%H:%M:%fZ','now')";
const urgent = "EXISTS (SELECT 1 FROM distill_state WHERE k='projection_withdrawal')";
const enqueue = (kind: ProjectionKind, id: string, op = "'upsert'", from = "", where = "1", urgentWhen = urgent) => `
  INSERT INTO projection_changes(kind,entity_id,op,urgent,created_at)
  SELECT '${kind}',${id},${op},
    (${urgentWhen}),${at}
  ${from} WHERE (${id}) IS NOT NULL AND (${where})
  ON CONFLICT(kind,entity_id) DO UPDATE SET seq=excluded.seq,op=excluded.op,urgent=excluded.urgent,
    urgent_seq=CASE WHEN excluded.urgent=1 THEN excluded.seq ELSE projection_changes.urgent_seq END,
    created_at=excluded.created_at;`;

const project = (id: string, op?: string) => enqueue("project", id, op) + context(id, op);
const context = (id: string, op?: string) =>
  `DELETE FROM project_context_cache WHERE project_id=${id};` + enqueue("project_context", id, op);
const now = enqueue("now", "'current'");
const thread = (id: string) => enqueue("thread", id) + project(`(SELECT project_id FROM threads WHERE id=${id})`) + now;
const day = (date: string) => enqueue("day", date);
const trigger = (name: string, event: string, table: string, body: string, when = "1") =>
  `CREATE TRIGGER projection_${name} AFTER ${event} ON ${table} WHEN ${when} BEGIN ${body} END;`;
const stateTrigger = (event: "INSERT" | "UPDATE" | "DELETE") => {
  const row = event === "DELETE" ? "OLD" : "NEW";
  const key = `${row}.k`;
  return trigger("state_" + event, event, "distill_state", enqueue("now", "'current'", "'upsert'", "", `${key}='now'`) +
    enqueue("day", `substr(${key},instr(${key},':')+1)`, "'upsert'", "", `${key} LIKE 'timeline_corrections:%' OR ${key} LIKE 'day_failed:%'`,
      `(${urgent}) OR ${key} LIKE 'timeline_corrections:%'`) +
    `DELETE FROM project_context_cache WHERE ${key} IN ('general_settings','ignored_project_keys');` +
    enqueue("project_context", "p.id", "'upsert'", "FROM projects p", `${key} IN ('general_settings','ignored_project_keys')`),
    `${key}='now' OR ${key} IN ('general_settings','ignored_project_keys') OR ${key} LIKE 'timeline_corrections:%' OR ${key} LIKE 'day_failed:%'`);
};

export const projectionSchema = `
ALTER TABLE devices ADD COLUMN viewer INTEGER NOT NULL DEFAULT 0 CHECK(viewer IN (0,1));
ALTER TABLE devices ADD COLUMN projection_cursor INTEGER NOT NULL DEFAULT 0;
ALTER TABLE devices ADD COLUMN projection_epoch INTEGER NOT NULL DEFAULT 0;
ALTER TABLE devices ADD COLUMN projection_window_from TEXT;
ALTER TABLE devices ADD COLUMN projection_window_until INTEGER;
ALTER TABLE relay_mailboxes ADD COLUMN push_msg_id TEXT;
ALTER TABLE relay_mailboxes ADD COLUMN push_seq INTEGER;
ALTER TABLE relay_mailboxes ADD COLUMN push_epoch INTEGER;
ALTER TABLE relay_mailboxes ADD COLUMN push_at INTEGER;
ALTER TABLE relay_mailboxes ADD COLUMN push_kind TEXT;
ALTER TABLE relay_mailboxes ADD COLUMN projection_purged_epoch INTEGER;
CREATE TABLE projection_changes (
  seq INTEGER PRIMARY KEY AUTOINCREMENT,
  kind TEXT NOT NULL CHECK(kind IN ('day','project','thread','project_context','now','record_gone')),
  entity_id TEXT NOT NULL,
  op TEXT NOT NULL CHECK(op IN ('upsert','delete')),
  rev INTEGER GENERATED ALWAYS AS (seq) VIRTUAL,
  urgent INTEGER NOT NULL DEFAULT 0,
  urgent_seq INTEGER NOT NULL DEFAULT 0,
  created_at TEXT NOT NULL,
  UNIQUE(kind,entity_id)
);
CREATE INDEX projection_urgent ON projection_changes(urgent_seq) WHERE urgent_seq>0;
CREATE TRIGGER projection_insert_urgent AFTER INSERT ON projection_changes WHEN NEW.urgent=1 BEGIN
  UPDATE projection_changes SET urgent_seq=NEW.seq WHERE seq=NEW.seq;
END;
CREATE TABLE relay_projection_replies (
  space TEXT NOT NULL, up TEXT NOT NULL, id TEXT NOT NULL, seq INTEGER NOT NULL, epoch INTEGER NOT NULL, created_at INTEGER NOT NULL,
  PRIMARY KEY(space,up,id)
);
CREATE INDEX relay_projection_reply_age ON relay_projection_replies(created_at);
CREATE TABLE project_context_cache (project_id TEXT PRIMARY KEY, payload TEXT NOT NULL, updated_at TEXT NOT NULL);
INSERT INTO distill_state(k,v) VALUES ('projection_epoch','1');
${enqueue("day", "d.date", "'upsert'", "FROM days d")}
${enqueue("project", "p.id", "'upsert'", "FROM projects p")}
${enqueue("project_context", "p.id", "'upsert'", "FROM projects p")}
${enqueue("thread", "t.id", "'upsert'", "FROM threads t")}
${now}
${trigger("day_insert", "INSERT", "days", day("NEW.date"))}
${trigger("day_update", "UPDATE", "days", day("NEW.date"))}
${trigger("day_delete", "DELETE", "days", enqueue("day", "OLD.date", "'delete'", "", "1", "1"))}
${trigger("project_insert", "INSERT", "projects", project("NEW.id"))}
${trigger("project_update", "UPDATE", "projects", project("NEW.id") + now)}
${trigger("project_delete", "DELETE", "projects", project("OLD.id", "'delete'") + now)}
${trigger("thread_insert", "INSERT", "threads", thread("NEW.id"))}
${trigger("thread_update", "UPDATE", "threads", thread("NEW.id") + project("OLD.project_id"), "OLD.project_id IS NOT NEW.project_id")}
${trigger("thread_same_project", "UPDATE", "threads", thread("NEW.id"), "OLD.project_id IS NEW.project_id")}
${trigger("thread_delete", "DELETE", "threads", enqueue("thread", "OLD.id", "'delete'", "", "1", "1") + project("OLD.project_id") + now)}
${trigger("assign_insert", "INSERT", "assignments", thread("NEW.thread_id"))}
${trigger("assign_update", "UPDATE", "assignments", thread("NEW.thread_id") + thread("OLD.thread_id"), "NEW.thread_id IS NOT OLD.thread_id")}
${trigger("assign_delete", "DELETE", "assignments", thread("OLD.thread_id"))}
${trigger("fact_insert", "INSERT", "facts", thread("NEW.thread_id") + project("NEW.project_id"))}
${trigger("fact_update", "UPDATE", "facts", thread("NEW.thread_id") + project("NEW.project_id") +
  thread("OLD.thread_id") + project("OLD.project_id"))}
${trigger("fact_delete", "DELETE", "facts", thread("OLD.thread_id") + project("OLD.project_id"))}
${["INSERT", "UPDATE", "DELETE"].map(event => stateTrigger(event as "INSERT" | "UPDATE" | "DELETE")).join("\n")}
${trigger("record_delete", "DELETE", "records", enqueue("record_gone", "OLD.id", "'delete'", "", "1", "1"))}
PRAGMA user_version=15;
`;

/** The marker and affected rows share the enclosing write transaction. */
export function projectionWithdrawal<T>(sql: SQL, write: () => T): T {
  return sql.transaction(() => {
    const outermost = sql.prepare("INSERT OR IGNORE INTO distill_state(k,v) VALUES ('projection_withdrawal','1')").run().changes > 0;
    const before = outermost && projectionHead(sql).urgent;
    const result = write();
    if (outermost) {
      sql.prepare("DELETE FROM distill_state WHERE k='projection_withdrawal'").run();
      if (before !== projectionHead(sql).urgent) sql.prepare(`DELETE FROM relay_receipts WHERE NOT EXISTS (
        SELECT 1 FROM relay_mailboxes b WHERE b.space=relay_receipts.space AND b.up=relay_receipts.up AND b.state='pair_reply')`).run();
    }
    return result;
  }).immediate();
}

export function touchProjectionDay(sql: SQL, date: string) {
  sql.prepare(enqueue("day", "@date")).run({ date });
}

export function withdrawProjectionRecord(sql: SQL, id: string) {
  sql.prepare(enqueue("record_gone", "@id", "'delete'", "", "1", "1")).run({ id });
}

export function scheduleProjectionDraft(sql: SQL, due: number) {
  sql.prepare("INSERT OR IGNORE INTO distill_state(k,v) VALUES ('projection_draft_due',?)").run(String(due));
}

export function flushProjectionDraft(sql: SQL, time: number, date: string) {
  if (!sql.prepare("SELECT 1 FROM distill_state WHERE k='projection_draft_due' AND CAST(v AS INTEGER)<=?").get(time)) return;
  sql.transaction(() => {
    if (sql.prepare("DELETE FROM distill_state WHERE k='projection_draft_due' AND CAST(v AS INTEGER)<=?").run(time).changes) {
      touchProjectionDay(sql, date);
      // 新记录可能让“此刻”变成“有新活动待整理”，一起重算。
      sql.prepare(now).run();
    }
  }).immediate();
}

export function projectionHead(sql: SQL) {
  return sql.prepare<[], { epoch: number; seq: number; urgent: number; floor: number }>(`SELECT
    CAST((SELECT v FROM distill_state WHERE k='projection_epoch') AS INTEGER) AS epoch,
    COALESCE((SELECT seq FROM sqlite_sequence WHERE name='projection_changes'),0) AS seq,
    COALESCE((SELECT MAX(urgent_seq) FROM projection_changes WHERE urgent_seq>0),0) AS urgent,
    COALESCE(CAST((SELECT v FROM distill_state WHERE k='projection_floor_seq') AS INTEGER),0) AS floor`).get()!;
}

/** A restore/rebuild discards client cursors while retaining the current entity index. */
export function resetProjection(sql: SQL, minimumEpoch = 1) {
  sql.transaction(() => {
    sql.prepare("UPDATE distill_state SET v=MAX(CAST(v AS INTEGER)+1,?) WHERE k='projection_epoch'").run(minimumEpoch);
    sql.prepare("DELETE FROM project_context_cache").run();
    sql.prepare("UPDATE devices SET projection_window_from=NULL, projection_window_until=NULL WHERE role IN ('view','admin')").run();
    if (minimumEpoch > 1) {
      sql.prepare(`INSERT INTO distill_state(k,v) SELECT 'projection_relay_purge_epoch',v FROM distill_state WHERE k='projection_epoch'
        ON CONFLICT(k) DO UPDATE SET v=excluded.v`).run();
      sql.prepare(`DELETE FROM relay_receipts WHERE EXISTS (SELECT 1 FROM relay_mailboxes b JOIN devices d ON d.id=b.device
        WHERE b.space=relay_receipts.space AND b.up=relay_receipts.up AND b.state='active' AND d.role IN ('view','admin'))`).run();
    }
  }).immediate();
}

export function pruneProjection(sql: SQL, clock: number) {
  const cutoff = new Date(clock - 30 * 86_400_000).toISOString();
  sql.transaction(() => {
    const { epoch, seq } = projectionHead(sql);
    const min = sql.prepare<[number], { cursor: number | null }>(`SELECT MIN(projection_cursor) AS cursor
      FROM devices WHERE role IN ('view','admin') AND projection_epoch=?`).get(epoch)!.cursor;
    if (sql.prepare("SELECT 1 FROM devices WHERE role IN ('view','admin') AND projection_epoch<>? LIMIT 1").get(epoch)) return;
    const deleted = sql.prepare<[number, string], { seq: number }>(
      "DELETE FROM projection_changes WHERE op='delete' AND seq<=? AND created_at<=? RETURNING seq").all(min ?? seq, cutoff);
    if (!deleted.length) return;
    const floor = deleted.reduce((max, row) => Math.max(max, row.seq), projectionHead(sql).floor);
    sql.prepare("INSERT INTO distill_state(k,v) VALUES ('projection_floor_seq',?) ON CONFLICT(k) DO UPDATE SET v=excluded.v").run(String(floor));
    resetProjection(sql);
  }).immediate();
}
