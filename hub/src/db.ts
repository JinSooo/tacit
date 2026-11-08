// 依赖包的 exports 漏了 types 条目；仅类型走文件路径，运行时仍按包名加载。
import type DatabaseTypes from "../../node_modules/better-sqlite3-multiple-ciphers/index.d.ts";
import { createRequire } from "node:module";
const Database: typeof DatabaseTypes = createRequire(import.meta.url)("better-sqlite3-multiple-ciphers");
import { copyFileSync, constants } from "node:fs";
import { dirname, join } from "node:path";
import { distillSchema } from "./distill/schema.ts";
import { DistillStore } from "./distill/store.ts";
import { createHash } from "node:crypto";
import { validateRecord, type RecordV1 } from "../../packages/record/index.ts";
import { redactRecord } from "./redact.ts";

export type StoredRecord = RecordV1 & { t_received: string };
export interface IngestResult { accepted: number; duplicates: number; rejected: { index: number; errors: string[] }[] }
export class InputError extends Error {}

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
function decode(row: Row, body = true): StoredRecord {
  const result: Record<string, unknown> = {};
  for (const field of fields) {
    if (!body && field === "body") continue;
    const value = row[field];
    if (value === null && !["source_ref", "t_end", "corrects"].includes(field)) continue;
    result[field] = jsonFields.has(field) && typeof value === "string" ? JSON.parse(value) : value;
  }
  return result as unknown as StoredRecord;
}

export class HubDB {
  readonly db: DatabaseTypes.Database;
  constructor(file: string, key: string) {
    if (!key) throw new Error("数据库密钥不能为空");
    this.db = new Database(file);
    try {
      this.db.pragma("cipher='sqlcipher'");
      this.db.pragma("legacy=4");
      this.db.pragma(`key='${key.replaceAll("'", "''")}'`);
      this.db.pragma("busy_timeout=5000");
      const version = this.db.pragma("user_version", { simple: true }) as number;
      if (version > 4) throw new Error("数据库版本比当前 hub 新");
      if (version === 1 && file !== ":memory:") {
        try { copyFileSync(file, join(dirname(file), "history.db.bak-v1"), constants.COPYFILE_EXCL); }
        catch (error) { if ((error as NodeJS.ErrnoException).code !== "EEXIST") throw error; }
      }
      this.db.pragma("secure_delete=ON");
      // 不使用 WAL，避免删除后的明文页在额外日志里继续存留。
      this.db.pragma("journal_mode=DELETE");
      // 必须先拿写锁再读取版本，等待另一进程迁移完成后才能决定迁移步骤。
      this.db.transaction(() => {
        const version = this.db.pragma("user_version", { simple: true }) as number;
        if (version > 4) throw new Error("数据库版本比当前 hub 新");
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
      }).immediate();
    } catch (e) { this.db.close(); throw e; }
  }
  close(): void { this.db.close(); }

  ingest(records: unknown[]): IngestResult {
    return this.db.transaction(() => {
      const result: IngestResult = { accepted: 0, duplicates: 0, rejected: [] };
      const exists = this.db.prepare(`SELECT 1 FROM records WHERE id=? OR (source=? AND source_ref=?)
        UNION ALL SELECT 1 FROM tombstones WHERE id=? OR (source=? AND source_ref=?) LIMIT 1`);
      const insert = this.db.prepare(`INSERT INTO records (${fields.map(f => `"${f}"`).join(",")},t_start_ms) VALUES (${[...fields, "t_start_ms"].map(() => "?").join(",")})`);
      const index = this.db.prepare("INSERT INTO records_fts(rowid,title,body) VALUES(?,?,?)");
      records.forEach((raw, i) => {
        const validation = validateRecord(raw);
        if (!validation.ok) { result.rejected.push({ index: i, errors: validation.errors }); return; }
        const r = raw as RecordV1;
        // schema 不表达来源特有的约束，按契约在入库边界补充校验。
        if (["mac.shell", "mac.git", "mac.browser", "claude_code.session", "codex.session"].includes(r.source) && !r.source_ref) {
          result.rejected.push({ index: i, errors: ["/source_ref 重读外部存储的来源必须提供稳定键"] }); return;
        }
        if (r.source === "manual.correction" && !r.corrects) {
          result.rejected.push({ index: i, errors: ["/corrects 修正记录必须指向原记录"] }); return;
        }
        if (!Number.isFinite(Date.parse(r.t_start))) {
          result.rejected.push({ index: i, errors: ["/t_start 无法转换为可排序的时间"] }); return;
        }
        if (exists.get(r.id, r.source, r.source_ref ?? null, r.id, r.source, r.source_ref ?? null)) { result.duplicates++; return; }
        const record: StoredRecord = { ...redactRecord(r), t_received: new Date().toISOString() };
        const values = fields.map(f => {
          const value = record[f];
          return value === undefined ? null : jsonFields.has(f) ? JSON.stringify(value) : value;
        });
        const inserted = insert.run(...values, Date.parse(r.t_start));
        index.run(inserted.lastInsertRowid, bigram(record.title), bigram(record.body));
        result.accepted++;
      });
      return result;
    })();
  }

  list(params: URLSearchParams): { records: Partial<StoredRecord>[]; next_cursor: string | null } {
    const where: string[] = [];
    const args: unknown[] = [];
    for (const field of ["device", "source"]) if (params.has(field)) { where.push(`r.${field}=?`); args.push(params.get(field)); }
    for (const [field, op] of [["from", ">="], ["to", "<="]]) if (params.has(field!)) {
      const time = Date.parse(params.get(field!)!);
      if (!Number.isFinite(time)) throw new InputError(`${field} 必须是有效时间`);
      where.push(`r.t_start_ms ${op} ?`); args.push(time);
    }
    const q = params.get("q")?.trim();
    if (q) {
      if (/^[\u3400-\u9fff\uf900-\ufaff]$/.test(q)) {
        where.push("(r.title LIKE ? ESCAPE '\\' OR r.body LIKE ? ESCAPE '\\')");
        const escaped = q.replace(/[\\%_]/g, "\\$&"); args.push(`%${escaped}%`, `%${escaped}%`);
      } else {
        // 用引号包住整个分词串，保持实验里的短语匹配，避免用户输入成为 FTS 语法。
        const phrase = bigram(q).trim().replace(/\s+/g, " ").replaceAll('"', '""');
        where.push("r.rowid IN (SELECT rowid FROM records_fts WHERE records_fts MATCH ?)"); args.push(`"${phrase}"`);
      }
    }
    const limit = Number(params.get("limit") ?? 50);
    if (!Number.isInteger(limit) || limit < 1 || limit > 500) throw new InputError("limit 必须是 1–500 的整数");
    const cursor = params.get("cursor");
    if (cursor) {
      try {
        const parsed = JSON.parse(Buffer.from(cursor, "base64url").toString("utf8"));
        if (!Array.isArray(parsed) || parsed.length !== 2 || !Number.isSafeInteger(parsed[0]) || typeof parsed[1] !== "string" || !/^[0-9A-HJKMNP-TV-Z]{26}$/.test(parsed[1])) throw new Error();
        where.push("(r.t_start_ms < ? OR (r.t_start_ms = ? AND r.id < ?))"); args.push(parsed[0], parsed[0], parsed[1]);
      } catch { throw new InputError("cursor 无效"); }
    }
    const rows = this.db.prepare<unknown[], Row>(`SELECT r.rowid,r.* FROM records r ${where.length ? "WHERE " + where.join(" AND ") : ""} ORDER BY r.t_start_ms DESC,r.id DESC LIMIT ?`).all(...args, limit + 1);
    const hasMore = rows.length > limit;
    const page = rows.slice(0, limit);
    const last = page.at(-1);
    return {
      records: page.map(row => decode(row, params.get("body") === "1")),
      next_cursor: hasMore && last ? Buffer.from(JSON.stringify([last.t_start_ms, last.id])).toString("base64url") : null,
    };
  }

  get(id: string): (StoredRecord & { corrections: StoredRecord[] }) | null {
    const row = this.db.prepare<[string], Row>("SELECT rowid,* FROM records WHERE id=?").get(id);
    if (!row) return null;
    const corrections = this.db.prepare<[string], Row>("SELECT rowid,* FROM records WHERE corrects=? AND source='manual.correction' ORDER BY t_start_ms,id").all(id).map(r => decode(r));
    return { ...decode(row), corrections };
  }

  delete(id: string): boolean {
    return this.db.transaction(() => {
      const row = this.db.prepare<[string], Row>("SELECT rowid,* FROM records WHERE id=?").get(id);
      if (!row) return false;
      // 修正记录写的是关于原记录的内容，原记录真删时一并删掉，否则内容会残留在修正里。
      const corrections = this.db.prepare<[string], Row>("SELECT rowid,* FROM records WHERE corrects=? AND source='manual.correction'").all(id);
      for (const r of [row, ...corrections]) {
        new DistillStore(this).removeRecord(r.id as string, r.t_start as string);
        const contentHash = createHash("sha256").update(JSON.stringify(decode(r))).digest("hex");
        this.db.prepare("INSERT INTO tombstones(id,source,source_ref,content_hash,deleted_at) VALUES(?,?,?,?,?)").run(r.id, r.source, r.source_ref, contentHash, new Date().toISOString());
        this.db.prepare("DELETE FROM records_fts WHERE rowid=?").run(r.rowid);
        this.db.prepare("DELETE FROM records WHERE id=?").run(r.id);
      }
      return true;
    })();
  }
}
