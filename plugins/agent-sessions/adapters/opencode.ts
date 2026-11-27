import { Database } from "bun:sqlite";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { pathToFileURL } from "node:url";
import { capturePrefix } from "../../../packages/record/capture-prefix.ts";
import { cleanUserText } from "../filters.ts";
import { ignored, unknown, type Json, type Parsed } from "../session-events.ts";
import type { DatabaseSessionAdapter } from "./types.ts";

interface MessageRow {
  id: string;
  session_id: string;
  directory: string;
  session_updated: number;
  created: number;
  updated: number;
  data: string;
}

interface PartRow { type: string | null; text: string | null; synthetic: number | null; ignored: number | null }

const ignoredParts = new Set([
  "reasoning", "tool", "file", "compaction", "subtask", "agent", "step-start",
  "step-finish", "snapshot", "patch", "retry",
]);
const TEXT_LIMIT = 150_064;

function parse(row: MessageRow, parts: () => Iterable<PartRow>): Parsed | null {
  let data: Json | null;
  try { data = JSON.parse(row.data); } catch { return unknown; }
  const role = data?.role;
  if (role !== "user" && role !== "assistant") return unknown;
  if (data!.summary === true || data!.agent === "compaction" || data!.mode === "compaction") return ignored;
  if (role === "assistant" && !Number.isFinite(data!.time?.completed)) return null;
  // time_created 是上游逐条写入的 Unix 毫秒，与 data.time.created 一致。
  if (!Number.isFinite(row.created)) return unknown;
  const texts: string[] = [];
  let recognized = true;
  let hasParts = false;
  for (const part of parts()) {
    hasParts = true;
    if (role === "user" && part.type === "compaction") return ignored;
    if (ignoredParts.has(part.type ?? "") || part.synthetic === 1 || part.ignored === 1) continue;
    if (part.type !== "text" || typeof part.text !== "string") { recognized = false; continue; }
    const prefix = capturePrefix(part.text, TEXT_LIMIT, part.text.length > TEXT_LIMIT);
    const text = cleanUserText(prefix.length < part.text.length ? prefix + "…[已截断]" : prefix);
    if (text) texts.push(text);
  }
  if (role === "user" && !hasParts) return null;
  return { recognized, message: texts.length ? { role, time: row.created, text: texts.join("\n") } : undefined };
}

function readOnlyURI(file: string): string | null {
  const uri = pathToFileURL(file);
  uri.search = "mode=ro";
  const header = Buffer.alloc(20);
  const fd = fs.openSync(file, "r");
  try { fs.readSync(fd, header, 0, header.length, 0); } finally { fs.closeSync(fd); }
  if (header[18] !== 2 && header[19] !== 2) return uri.href;

  const wal = fs.statSync(file + "-wal", { throwIfNoEntry: false });
  if (wal && fs.existsSync(file + "-shm")) return uri.href;
  // 只读 SQLite 也可能创建 WAL sidecar。没有待写回的 WAL 时直接读已写回的库。
  if (wal && wal.size > 0) return null;
  uri.searchParams.set("immutable", "1");
  return uri.href;
}

export const opencode: DatabaseSessionAdapter = {
  id: "opencode",
  database({ opencodeDir }) {
    const override = opencodeDir ?? process.env.RA_OPENCODE_DIR;
    const dataHome = process.env.XDG_DATA_HOME || path.join(process.env.OPENCODE_TEST_HOME || os.homedir(), ".local", "share");
    const root = override ?? process.env.OPENCODE_DATA_DIR ?? path.join(dataHome, "opencode");
    const filename = (override === undefined && process.env.OPENCODE_DB) || "opencode.db";
    if (filename === ":memory:") return null;
    return path.isAbsolute(filename) ? filename : path.resolve(root, filename);
  },
  readDatabase(file, previous, floor, rescan) {
    let db: Database | undefined;
    try {
      const stat = fs.statSync(file, { throwIfNoEntry: false });
      if (!stat?.isFile()) return null;
      const uri = readOnlyURI(file);
      if (!uri) return null;
      db = new Database(uri, { readonly: true });
      db.exec("BEGIN");
      const identity = `${stat.dev}:${stat.ino}`;
      const old = previous?.identity === identity ? previous : undefined;
      const since = Math.max(floor, rescan ? floor : old?.updated ?? floor);
      let updated = Math.max(since, old?.updated ?? since);
      const boundary = new Set(old?.updated === updated ? old.boundary : []);
      const rows: NonNullable<ReturnType<DatabaseSessionAdapter["readDatabase"]>>["rows"] = [];
      const messages = db.query<MessageRow, [number, number, number]>(`
        WITH changed AS (
          SELECT id FROM message WHERE time_updated >= ?
          UNION
          SELECT message_id FROM part WHERE time_updated >= ?
        )
        SELECT m.id, m.session_id, m.time_created AS created, m.data,
          s.directory, s.time_updated AS session_updated,
          max(m.time_updated, coalesce((SELECT max(p.time_updated) FROM part p WHERE p.message_id = m.id), 0)) AS updated
        FROM changed c JOIN message m ON m.id = c.id JOIN session s ON s.id = m.session_id
        WHERE s.parent_id IS NULL AND m.time_created >= ?
        ORDER BY updated, m.id
      `);
      const parts = db.query<PartRow, [string]>(`
        SELECT
          json_extract(data, '$.type') AS type,
          CASE WHEN json_extract(data, '$.type') = 'text' THEN substr(json_extract(data, '$.text'), 1, ${TEXT_LIMIT + 1}) END AS text,
          json_type(data, '$.synthetic') = 'true' AS synthetic,
          json_type(data, '$.ignored') = 'true' AS ignored
        FROM (SELECT id, CASE WHEN json_valid(data) THEN data END AS data FROM part WHERE message_id = ?)
        ORDER BY id
      `);
      for (const row of messages.iterate(since, since, floor)) {
        if (!rescan && row.updated === updated && boundary.has(row.id)) continue;
        if (row.updated > updated) {
          updated = row.updated;
          boundary.clear();
        }
        const result = parse(row, () => parts.iterate(row.id));
        if (!result) continue;
        if (row.updated === updated) boundary.add(row.id);
        rows.push({ sessionId: row.session_id, cwd: row.directory, mtime: Math.max(row.session_updated, row.updated), result });
      }
      return { progress: { identity, updated, boundary: [...boundary] }, rows };
    } catch {
      // 锁住、正在恢复或无法打开的库留给下一轮，原游标保持不动。
      return null;
    } finally {
      db?.close();
    }
  },
};
