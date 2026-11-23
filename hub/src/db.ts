// 依赖包的 exports 漏了 types 条目；仅类型走文件路径，运行时仍按包名加载。
import type DatabaseTypes from "../../node_modules/better-sqlite3-multiple-ciphers/index.d.ts";
import { createRequire } from "node:module";
const Database: typeof DatabaseTypes = createRequire(import.meta.url)("better-sqlite3-multiple-ciphers");
import { copyFileSync, constants, chmodSync, unlinkSync, openSync, closeSync, fsyncSync, readdirSync, lstatSync, renameSync, rmSync } from "node:fs";
import { basename, dirname, join } from "node:path";
import { AudioStore, audioSchema } from "./audio.ts";
import { distillSchema, usageTaskSchema } from "./distill/schema.ts";
import { requestsSchema, regenDaysRequestsSchema } from "./distill/requests.ts";
import { conversationSchema, lineSchema } from "./conversations.ts";
import { DistillStore } from "./distill/store.ts";
import { createHash } from "node:crypto";
import { validateRecord, type RecordV1 } from "../../packages/record/index.ts";
import { redactRecord } from "./redact.ts";
import { SKELETON_SOURCES, sourceList } from "./record-sources.ts";
import { registerAgentAudit, stopAgentAudit } from "./agent-audit.ts";
import { relaySchema } from "./devices/relay-store.ts";
import { deviceSchema } from "./devices/store.ts";
import { runtimeSchema, expireSnapshots, eraseSnapshots, sanitizeStoredModelErrors } from "./runtime-log.ts";

export type StoredRecord = RecordV1 & { t_received: string };
export interface IngestResult { accepted: number; duplicates: number; rejected: { index: number; errors: string[] }[] }
export class InputError extends Error {}

function setCipher(db: DatabaseTypes.Database, key: string): void {
  db.pragma("cipher='sqlcipher'");
  db.pragma("legacy=4");
  db.pragma(`key='${key.replaceAll("'", "''")}'`);
}

function validMigrationBackup(file: string, backup: string, key: string, version: number): boolean {
  let stat;
  try { stat = lstatSync(backup); }
  catch (e) { if ((e as NodeJS.ErrnoException).code === "ENOENT") return false; throw e; }
  if (!stat.isFile()) throw new Error("迁移备份路径无效");
  if (stat.size !== lstatSync(file).size) return false;
  let db: DatabaseTypes.Database | undefined;
  try {
    db = new Database(backup, { readonly: true, fileMustExist: true });
    setCipher(db, key);
    return db.pragma("user_version", { simple: true }) === version
      && db.pragma("integrity_check", { simple: true }) === "ok";
  } catch { return false; }
  finally { db?.close(); }
}

/** 持有源库写锁并且尚未修改迁移页。临时文件可以在中断后安全重建。 */
function ensureMigrationBackup(file: string, key: string, version: number): void {
  const backup = `${file}.migration-v${version}.bak`, temp = `${backup}.tmp`;
  rmSync(temp, { force: true });
  if (validMigrationBackup(file, backup, key, version)) { chmodSync(backup, 0o600); return; }
  try {
    copyFileSync(file, temp, constants.COPYFILE_EXCL);
    chmodSync(temp, 0o600);
    const fd = openSync(temp, "r");
    try { fsyncSync(fd); } finally { closeSync(fd); }
    renameSync(temp, backup);
    const dir = openSync(dirname(file), "r");
    try { fsyncSync(dir); } finally { closeSync(dir); }
  } finally { rmSync(temp, { force: true }); }
}

/** 与存储实验一致：中文重叠两字，非中文原样交给 unicode61。 */
export function bigram(text: string): string {
  return text.replace(/[\u3400-\u9fff\uf900-\ufaff]+/g, run => {
    if (run.length === 1) return ` ${run} `;
    const out = [];
    for (let i = 0; i < run.length - 1; i++) out.push(run.slice(i, i + 2));
    return ` ${out.join(" ")} `;
  });
}

const fields = ["id", "schema", "device", "source", "source_ref", "kind", "t_start", "t_end", "context", "people", "title", "body", "media", "capture", "sensitivity", "redactions", "corrects", "t_received"] as const;
const jsonFields = new Set(["context", "people", "media", "capture"]);
type Row = { rowid: number; t_start_ms: number } & Record<string, unknown>;
function decode(row: Row, body: boolean, received: false): RecordV1;
function decode(row: Row, body?: boolean): StoredRecord;
function decode(row: Row, body = true, received = true): RecordV1 {
  const result: Record<string, unknown> = {};
  for (const field of fields) {
    if ((!body && field === "body") || (!received && field === "t_received")) continue;
    const value = row[field];
    if (value === null && !["source_ref", "t_end", "corrects"].includes(field)) continue;
    result[field] = jsonFields.has(field) && typeof value === "string" ? JSON.parse(value) : value;
  }
  return result as unknown as StoredRecord;
}

export class HubDB {
  readonly db: DatabaseTypes.Database;
  private snapshotTimer?: ReturnType<typeof setInterval>;
  constructor(file: string, key: string) {
    if (!key) throw new Error("数据库密钥不能为空");
    this.db = new Database(file);
    let migrating = false;
    try {
      if (file !== ":memory:") chmodSync(file, 0o600);
      setCipher(this.db, key);
      this.db.pragma("busy_timeout=5000");
      const version = this.db.pragma("user_version", { simple: true }) as number;
      if (version > 14) throw new Error("数据库版本比当前 hub 新");
      this.db.pragma("secure_delete=ON");
      // 保留回滚日志模式；加密 WAL 也可能保留已删除内容的旧加密页。
      this.db.pragma("journal_mode=DELETE");
      // 必须先拿写锁再读取版本，等待另一进程迁移完成后才能决定迁移步骤。
      this.db.transaction(() => {
        const version = this.db.pragma("user_version", { simple: true }) as number;
        if (version > 14) throw new Error("数据库版本比当前 hub 新");
        migrating = version < 14;
        if (version > 0 && migrating && file !== ":memory:") ensureMigrationBackup(file, key, version);
        if (version === 0) {
          this.db.exec(`
            CREATE TABLE records (
              id TEXT NOT NULL UNIQUE, schema INTEGER NOT NULL, device TEXT NOT NULL,
              source TEXT NOT NULL, source_ref TEXT, kind TEXT NOT NULL,
              t_start TEXT NOT NULL, t_end TEXT, context TEXT, people TEXT,
              title TEXT NOT NULL, body TEXT NOT NULL, media TEXT, capture TEXT NOT NULL,
              sensitivity TEXT NOT NULL, redactions INTEGER NOT NULL, corrects TEXT,
              t_received TEXT NOT NULL, t_start_ms INTEGER NOT NULL,
              UNIQUE(source, source_ref)
            );
            CREATE INDEX records_time ON records(t_start_ms DESC, id DESC);
            CREATE INDEX records_corrects ON records(corrects);
            CREATE TABLE tombstones (
              id TEXT PRIMARY KEY, source TEXT NOT NULL, source_ref TEXT,
              content_hash TEXT NOT NULL, deleted_at TEXT NOT NULL,
              UNIQUE(source, source_ref)
            );
            CREATE VIRTUAL TABLE records_fts USING fts5(title, body, tokenize='unicode61');
            INSERT INTO records_fts(records_fts, rank) VALUES('secure-delete', 1);
          `);
          this.db.exec(distillSchema);
        }
        if (version === 1) this.db.exec(distillSchema);
        new DistillStore(this).ensureFrameRecords();
        if (version < 3) {
          this.db.exec(`CREATE TABLE agent_reads(
            id TEXT PRIMARY KEY, at TEXT, tool TEXT, kind TEXT, args TEXT,
            result_ids TEXT, bytes INTEGER, ok INTEGER
          );
          CREATE INDEX agent_reads_time ON agent_reads(at DESC,id DESC);
          CREATE INDEX agent_reads_tool_time ON agent_reads(tool,at DESC,id DESC);
          PRAGMA user_version=3;`);
        }
        if (version < 4) {
          this.db.exec(`ALTER TABLE threads ADD COLUMN domain TEXT CHECK(domain IN ('work','life'));
            ALTER TABLE threads ADD COLUMN project_hint TEXT;
            UPDATE threads SET project_hint=project_id;
            PRAGMA user_version=4;`);
        }
        if (version < 5) this.db.exec(audioSchema);
        if (version < 6) this.db.exec(requestsSchema);
        if (version < 7) this.db.exec(conversationSchema);
        if (version < 8) this.db.exec(lineSchema);
        if (version < 9) {
          const columns = this.db.pragma("table_info(llm_usage)") as { name: string }[];
          if (!columns.some(c => c.name === "task")) this.db.exec(usageTaskSchema);
          this.db.pragma("user_version=9");
        }
        if (version < 10) {
          const columns = this.db.pragma("table_info(speakers)") as { name: string }[];
          if (!columns.some(c => c.name === "mic")) this.db.exec("ALTER TABLE speakers ADD COLUMN mic INTEGER NOT NULL DEFAULT 0;");
          this.db.exec("UPDATE speakers SET mic=1 WHERE id IN (SELECT speaker_id FROM voice_embeddings WHERE track='mic');");
          this.db.pragma("user_version=10");
        }
        if (version < 11) this.db.exec(runtimeSchema);
        if (version < 12) this.db.exec(regenDaysRequestsSchema);
        if (version < 13) this.db.exec(deviceSchema);
        if (version < 14) this.db.exec(relaySchema);
      }).immediate();
      migrating = false;
      const backups = file === ":memory:" ? [] : readdirSync(dirname(file)).filter(name =>
        name.startsWith(`${basename(file)}.migration-v`) && /^(?:[1-9]|1[0-3])\.bak$/.test(name.slice(`${basename(file)}.migration-v`.length)));
      if (backups.length) {
        if (this.db.pragma("integrity_check", { simple: true }) !== "ok") throw new Error("迁移后完整性检查失败，已保留备份");
        for (const backup of backups) {
          const path = join(dirname(file), backup);
          try {
            if (!lstatSync(path).isFile()) throw new Error("迁移备份路径无效");
            unlinkSync(path);
          } catch (e) {
            // 另一个进程可能已通过完整性检查并清理了同一份备份。
            if ((e as NodeJS.ErrnoException).code !== "ENOENT") throw e;
          }
        }
      }
      registerAgentAudit(this, key);
      sanitizeStoredModelErrors(this);
      expireSnapshots(this);
      this.snapshotTimer = setInterval(() => {
        try { expireSnapshots(this); } catch { console.error(JSON.stringify({ location: "runtime.expire", category: "storage" })); }
      }, 30 * 60_000);
      this.snapshotTimer.unref();
    } catch (e) {
      this.db.close();
      if (migrating) throw Object.assign(new Error("数据库迁移失败，已保留可用的备份", { cause: e }), { code: "db_migration_failed" });
      throw e;
    }
  }
  close(): void { clearInterval(this.snapshotTimer); if (this.db.open) { stopAgentAudit(this); this.db.close(); } }

  ingest(records: unknown[], device?: string): IngestResult {
    return this.db.transaction(() => {
      const result: IngestResult = { accepted: 0, duplicates: 0, rejected: [] };
      const exists = this.db.prepare(`SELECT 1 FROM records WHERE id=? OR (source=? AND source_ref=?)
        UNION ALL SELECT 1 FROM tombstones WHERE id=? OR (source=? AND source_ref=?) LIMIT 1`);
      const insert = this.db.prepare(`INSERT INTO records (${fields.map(f => `"${f}"`).join(",")},t_start_ms) VALUES (${[...fields, "t_start_ms"].map(() => "?").join(",")})`);
      const index = this.db.prepare("INSERT INTO records_fts(rowid,title,body) VALUES(?,?,?)");
      const owner = this.db.prepare("SELECT 1 FROM records WHERE id=? AND device=?");
      const correction = this.db.prepare(`
        INSERT INTO device_changes(device,kind,record_id,created_at)
        SELECT r.device,'correction',?,? FROM records r JOIN devices d ON d.id=r.device WHERE r.id=?
      `);
      records.forEach((raw, i) => {
        const validation = validateRecord(raw);
        if (!validation.ok) { result.rejected.push({ index: i, errors: validation.errors }); return; }
        const r = raw as RecordV1;
        if (device !== undefined) {
          const errors = [];
          if (r.device !== device) errors.push("/device 必须与配对设备一致");
          if (r.source === "manual.correction") {
            if (!r.corrects || !owner.get(r.corrects, device)) errors.push("/corrects 必须指向本设备的记录");
          } else if (r.source !== "manual.note" && !r.source.startsWith("android.")) {
            errors.push("/source 不支持此设备来源");
          }
          if (errors.length) { result.rejected.push({ index: i, errors }); return; }
        }
        // schema 不表达来源特有的约束，按契约在入库边界补充校验。
        if (["mac.browser", "claude_code.session", "codex.session"].includes(r.source) && !r.source_ref) {
          result.rejected.push({ index: i, errors: ["/source_ref 重读外部存储的来源必须提供稳定键"] }); return;
        }
        if (r.source === "manual.correction" && !r.corrects) {
          result.rejected.push({ index: i, errors: ["/corrects 修正记录必须指向原记录"] }); return;
        }
        if (!Number.isFinite(Date.parse(r.t_start))) {
          result.rejected.push({ index: i, errors: ["/t_start 无法转换为可排序的时间"] }); return;
        }
        if (exists.get(r.id, r.source, r.source_ref ?? null, r.id, r.source, r.source_ref ?? null)) { result.duplicates++; return; }
        if (device !== undefined && r.source === "android.audio" && r.source_ref) {
          try { new AudioStore(this).assertDeviceConversation(r.source_ref, device); }
          catch (error) {
            if (!(error instanceof InputError)) throw error;
            result.rejected.push({ index: i, errors: [`/source_ref ${error.message}`] });
            return;
          }
        }
        const record: StoredRecord = { ...redactRecord(r), t_received: new Date().toISOString() };
        const values = fields.map(f => {
          const value = record[f];
          return value === undefined ? null : jsonFields.has(f) ? JSON.stringify(value) : value;
        });
        const inserted = insert.run(...values, Date.parse(r.t_start));
        index.run(inserted.lastInsertRowid, bigram(record.title), bigram(record.body));
        if (record.source === "manual.correction" && record.corrects) {
          correction.run(record.id, record.t_received, record.corrects);
          new DistillStore(this).correctRecord(record.corrects);
        }
        result.accepted++;
      });
      return result;
    })();
  }

  list(params: URLSearchParams, { collapseScreenMatches = false, prioritizeContent = false } = {}): { records: Partial<StoredRecord>[]; next_cursor: string | null } {
    const where: string[] = [];
    const args: unknown[] = [];
    for (const field of ["device", "source"]) if (params.has(field)) { where.push(`r.${field}=?`); args.push(params.get(field)); }
    for (const [field, op] of [["from", ">="], ["to", "<="]]) if (params.has(field!)) {
      const time = Date.parse(params.get(field!)!);
      if (!Number.isFinite(time)) throw new InputError(`${field} 必须是有效时间`);
      where.push(`r.t_start_ms ${op} ?`); args.push(time);
    }
    const q = params.get("q")?.trim();
    for (const term of q?.split(/\s+/).filter(Boolean) ?? []) {
      if (/^[\u3400-\u9fff\uf900-\ufaff]$/.test(term)) {
        where.push("(r.title LIKE ? ESCAPE '\\' OR r.body LIKE ? ESCAPE '\\')");
        const escaped = term.replace(/[\\%_]/g, "\\$&"); args.push(`%${escaped}%`, `%${escaped}%`);
      } else {
        // 词内保持短语，词间 AND；引用输入避免 FTS 语法注入。
        const phrase = bigram(term).trim().replace(/\s+/g, " ").replaceAll('"', '""');
        where.push("r.rowid IN (SELECT rowid FROM records_fts WHERE records_fts MATCH ?)"); args.push(`"${phrase}"`);
      }
    }
    const limit = Number(params.get("limit") ?? 50);
    if (!Number.isInteger(limit) || limit < 1 || limit > 500) throw new InputError("limit 必须是 1–500 的整数");
    const cursor = params.get("cursor");
    // Agent 独立使用 [来源层, 时间, id]；普通列表仍使用 [时间, id]。
    const tierSql = `CASE WHEN r.source IN (${sourceList(SKELETON_SOURCES)}) THEN 1 ELSE 0 END`;
    const tierOf = (row: Row) => SKELETON_SOURCES.has(String(row.source)) ? 1 : 0;
    let position: [number, string] | undefined;
    let cursorTier = 0;
    if (cursor) {
      try {
        if (prioritizeContent && (!/^[A-Za-z0-9_-]+$/.test(cursor) || Buffer.from(cursor, "base64url").toString("base64url") !== cursor)) throw new Error();
        let parsed = JSON.parse(Buffer.from(cursor, "base64url").toString("utf8"));
        if (prioritizeContent) {
          if (!Array.isArray(parsed) || parsed.length !== 3 || ![0, 1].includes(parsed[0])) throw new Error();
          cursorTier = parsed[0];
          parsed = parsed.slice(1);
        }
        if (!Array.isArray(parsed) || parsed.length !== 2 || !Number.isSafeInteger(parsed[0]) || typeof parsed[1] !== "string" || !/^[0-9A-HJKMNP-TV-Z]{26}$/.test(parsed[1])) throw new Error();
        position = [parsed[0], parsed[1]];
      } catch { throw new InputError("cursor 无效"); }
    }
    if (position && !collapseScreenMatches) {
      const after = "(r.t_start_ms < ? OR (r.t_start_ms = ? AND r.id < ?))";
      where.push(prioritizeContent ? `(${tierSql}>? OR (${tierSql}=? AND ${after}))` : after);
      if (prioritizeContent) args.push(cursorTier, cursorTier);
      args.push(position[0], position[0], position[1]);
    }
    const sql = `SELECT r.rowid,r.* FROM records r ${where.length ? "WHERE " + where.join(" AND ") : ""} ORDER BY ${prioritizeContent ? tierSql + " ASC," : ""}r.t_start_ms DESC,r.id DESC`;
    let rows: Row[];
    if (collapseScreenMatches) {
      rows = [];
      const seen = new Set<string>();
      // 只读到够填满本页。经过游标前的匹配时也记下代表，下一页不会补出已折叠的旧片段。
      for (const row of this.db.prepare<unknown[], Row>(sql).iterate(...args)) {
        if (row.source === "mac.screen") {
          const context = typeof row.context === "string" ? JSON.parse(row.context) as RecordV1["context"] : null;
          const key = JSON.stringify([row.device, row.title, context?.app, context?.window, context?.url, row.sensitivity === "private"]);
          if (seen.has(key)) continue;
          seen.add(key);
        }
        if (position) {
          const tier = prioritizeContent ? tierOf(row) : 0;
          if (tier < cursorTier || tier === cursorTier && (row.t_start_ms > position[0] || (row.t_start_ms === position[0] && String(row.id) >= position[1]))) continue;
        }
        rows.push(row);
        if (rows.length > limit) break;
      }
    } else {
      rows = this.db.prepare<unknown[], Row>(`${sql} LIMIT ?`).all(...args, limit + 1);
    }
    const hasMore = rows.length > limit;
    const page = rows.slice(0, limit);
    const last = page.at(-1);
    return {
      records: page.map(row => decode(row, params.get("body") === "1")),
      next_cursor: hasMore && last ? Buffer.from(JSON.stringify(prioritizeContent ? [tierOf(last), last.t_start_ms, last.id] : [last.t_start_ms, last.id])).toString("base64url") : null,
    };
  }

  get(id: string): (StoredRecord & { corrections: StoredRecord[] }) | null {
    const row = this.db.prepare<[string], Row>("SELECT rowid,* FROM records WHERE id=?").get(id);
    if (!row) return null;
    const corrections = this.db.prepare<[string], Row>("SELECT rowid,* FROM records WHERE corrects=? AND source='manual.correction' ORDER BY t_start_ms,id").all(id).map(r => decode(r));
    return { ...decode(row), corrections };
  }

  /** 整理只读最新修正；保留原活动上下文，证据指向实际提供正文的修正记录。 */
  effective(id: string): StoredRecord | null {
    const original = this.get(id);
    if (!original) return null;
    const latest = original.corrections.at(-1);
    if (!latest) return original;
    return { ...original, ...latest, context: original.context,
      sensitivity: original.sensitivity === "private" || latest.sensitivity === "private" ? "private" : latest.sensitivity };
  }

  deviceChanges(device: string, cursor: number) {
    const pageSize = 200;
    const rows = this.db.prepare<[string, number, number], Row & {
      seq: number; change_kind: "delete" | "correction"; record_id: string; change_source: string; change_ref: string | null;
    }>(`
      SELECT r.*, c.seq, c.kind AS change_kind, c.record_id, c.source AS change_source, c.source_ref AS change_ref
      FROM device_changes c LEFT JOIN records r ON c.kind='correction' AND r.id=c.record_id
      WHERE c.device=? AND c.seq>? ORDER BY c.seq LIMIT ?
    `).all(device, cursor, pageSize + 1);
    const more = rows.length > pageSize;
    if (more) rows.pop();
    type Change =
      | { seq: number; kind: "delete"; id: string; source: string; source_ref: string | null }
      | { seq: number; kind: "correction"; record: RecordV1 };
    const changes = rows.flatMap<Change>(row => {
      if (row.change_kind === "delete") {
        return [{ seq: row.seq, kind: row.change_kind, id: row.record_id, source: row.change_source, source_ref: row.change_ref }];
      }
      if (!row.id) return [];
      return [{ seq: row.seq, kind: row.change_kind, record: decode(row, true, false) }];
    });
    return { changes, cursor: rows.at(-1)?.seq ?? cursor, more };
  }

  delete(id: string): boolean { return this.deleteMany([id]) > 0; }

  /** 有界批次共享一次引用清理和事务，包含原记录的所有修正。 */
  deleteMany(ids: string[], device?: string): number {
    return this.db.transaction(() => {
      const input = JSON.stringify([...new Set(ids)]);
      const rows = this.db.prepare<[string, string | null, string | null], Row>(`
        WITH targets AS (
          SELECT id FROM records WHERE id IN (SELECT value FROM json_each(?)) AND (? IS NULL OR device=?)
        )
        SELECT rowid,* FROM records WHERE id IN targets OR (source='manual.correction' AND corrects IN targets)
      `).all(input, device ?? null, device ?? null);
      if (device !== undefined) {
        // 设备删的记录可能还在信箱里没送到（经信箱投出后，手机回家直连发了删除）。
        // 先留一个不含内容的墓碑，那封旧信之后到达时按重复处理，删掉的不会复活。
        this.db.prepare(`INSERT INTO tombstones(id,source,source_ref,content_hash,deleted_at)
          SELECT value,'device.deleted',NULL,'',? FROM json_each(?)
          WHERE value NOT IN (SELECT id FROM records) AND value NOT IN (SELECT id FROM tombstones)`)
          .run(new Date().toISOString(), input);
      }
      if (!rows.length) return 0;
      eraseSnapshots(this);
      // 还没投出去的信箱回执可能带着被删内容（对话总结、修正记录），同事务清掉；
      // 设备收不到回复会在 24 小时后换新 nonce 重发。配对回执不含记录内容，保留。
      this.db.prepare(`DELETE FROM relay_receipts WHERE NOT EXISTS (
        SELECT 1 FROM relay_mailboxes b WHERE b.space=relay_receipts.space AND b.up=relay_receipts.up AND b.state='pair_reply')`).run();
      const store = new DistillStore(this);
      store.removeRecords(rows.map(r => ({ id: r.id as string, time: r.t_start as string })));
      const deleted = new Set(rows.map(r => r.id));
      const corrected = new Set<string>();
      const tombstone = this.db.prepare("INSERT INTO tombstones(id,source,source_ref,content_hash,deleted_at) VALUES(?,?,?,?,?)");
      const fts = this.db.prepare("DELETE FROM records_fts WHERE rowid=?"), record = this.db.prepare("DELETE FROM records WHERE id=?");
      const at = new Date().toISOString();
      const change = this.db.prepare(`
        INSERT INTO device_changes(device,kind,record_id,source,source_ref,created_at)
        SELECT d.id,'delete',?,?,?,? FROM devices d
        WHERE d.id=? OR d.id=(SELECT device FROM records WHERE id=?)
      `);
      // 原记录仍在时查修正的接收方，批量删除的顺序不会影响下发。
      for (const r of rows) change.run(r.id, r.source, r.source_ref, at, r.device,
        r.source === "manual.correction" ? r.corrects : null);
      for (const r of rows) {
        const contentHash = createHash("sha256").update(JSON.stringify(decode(r))).digest("hex");
        tombstone.run(r.id,r.source,r.source_ref,contentHash,at); fts.run(r.rowid); record.run(r.id);
        if (r.corrects && !deleted.has(r.corrects)) corrected.add(r.corrects as string);
      }
      for (const id of corrected) store.correctRecord(id);
      return rows.length;
    })();
  }
}
