import { createHash } from "node:crypto";
import { constants, copyFileSync, lstatSync, mkdtempSync, rmSync, statSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { parseArgs } from "node:util";
import { decode, openHistoryReadOnly } from "./db.ts";
import { historicalSource, type HistoricalIdentity } from "./devices/history-import.ts";
import { deviceID } from "./devices/envelope.ts";
import { keychainStore } from "./secrets/keychain.ts";

type Cursor = [snapshot: string, phase: 0 | 1, rowid: number];

function exportError(code: string) {
  return Object.assign(new Error(code), { code });
}

function snapshotID(file: string): string {
  // 中枢库固定 journal_mode=DELETE；出现任何 WAL 边车（含 0 字节）都说明不是冻结的中枢库。
  for (const suffix of ["-wal", "-shm"]) {
    if (statSync(file + suffix, { throwIfNoEntry: false })) throw exportError("snapshot_not_frozen");
  }
  if (statSync(file + "-journal", { throwIfNoEntry: false })?.size) throw exportError("snapshot_not_frozen");
  const stat = statSync(file, { bigint: true });
  if (!stat.isFile()) throw exportError("snapshot_not_frozen");
  return createHash("sha256").update([stat.dev, stat.ino, stat.size, stat.mtimeNs, stat.ctimeNs].join(":")).digest("hex");
}

function readCursor(encoded: string | undefined, snapshot: string): Cursor {
  if (encoded === undefined) return [snapshot, 0, 0];
  let cursor: unknown;
  try {
    if (!/^[A-Za-z0-9_-]{1,200}$/.test(encoded)) throw new Error();
    cursor = JSON.parse(Buffer.from(encoded, "base64url").toString("utf8"));
  } catch { throw exportError("invalid_cursor"); }
  if (!Array.isArray(cursor) || cursor.length !== 3 || typeof cursor[0] !== "string" ||
      !/^[a-f0-9]{64}$/.test(cursor[0]) || (cursor[1] !== 0 && cursor[1] !== 1) ||
      !Number.isSafeInteger(cursor[2]) || cursor[2] < 1) throw exportError("invalid_cursor");
  if (cursor[0] !== snapshot) throw exportError("snapshot_changed");
  return cursor as Cursor;
}

const exportable = `
WITH RECURSIVE private_ancestors(id) AS (
  SELECT id FROM records WHERE sensitivity='private'
  UNION SELECT r.corrects FROM records r JOIN private_ancestors p ON p.id=r.id
    WHERE r.source='manual.correction' AND r.corrects IS NOT NULL
), private_chain(id) AS (
  SELECT id FROM private_ancestors
  UNION SELECT r.id FROM records r JOIN private_chain p ON r.corrects=p.id WHERE r.source='manual.correction'
), owned AS (
  SELECT r.id,r.source,r.corrects,r.rowid AS export_rowid FROM records r
  WHERE r.rowid<=? AND EXISTS(SELECT 1 FROM json_each(?) i
    WHERE json_extract(i.value,'$.device')=r.device AND r.source IN (SELECT value FROM json_each(i.value,'$.sources')))
), eligible AS (
  SELECT r.export_rowid, r.id, r.source='manual.correction' AS phase FROM owned r
  LEFT JOIN owned target ON r.source='manual.correction' AND r.corrects=target.id
  WHERE r.id NOT IN private_chain AND (
    (r.source<>'manual.correction' AND r.corrects IS NULL) OR
    (target.source<>'manual.correction' AND target.corrects IS NULL AND target.id NOT IN private_chain)
  )
)`;

function exportScope(db: ReturnType<typeof openHistoryReadOnly>) {
  const hasLocalOnly = (db.pragma("table_info(devices)") as { name: string }[]).some(c => c.name === "local_only");
  const kinds = new Map<string, HistoricalIdentity["kind"]>([["mac", "mac"]]);
  if (hasLocalOnly) {
    for (const { id, platform } of db.prepare<[], { id: string; platform: string }>(
      "SELECT id,platform FROM devices WHERE local_only=1 AND ((platform='mac' AND role='admin') OR (platform='agent' AND role='agent'))"
    ).all()) {
      if (deviceID.test(id) && (platform === "mac" || platform === "agent") && id.startsWith(platform + "-")) kinds.set(id, platform);
    }
  }
  const identities = new Map<string, HistoricalIdentity>();
  for (const { device, source } of db.prepare<[string], { device: string; source: string }>(
    "SELECT DISTINCT device,source FROM records WHERE device IN (SELECT value FROM json_each(?)) ORDER BY device,source"
  ).iterate(JSON.stringify([...kinds.keys()]))) {
    const kind = kinds.get(device)!;
    if (!historicalSource(kind, source, device)) continue;
    if (!identities.has(device)) identities.set(device, { device, kind, sources: [] });
    identities.get(device)!.sources.push(source);
  }
  const scope = [...identities.values()];
  const max = db.prepare<[], { max: number | null }>("SELECT MAX(rowid) max FROM records").get()!.max ?? 0;
  const args = [max, JSON.stringify(scope)] as const;
  const totals = db.prepare<[number, string], { total: number; private_count: number }>(exportable + `
    SELECT (SELECT COUNT(*) FROM eligible) total,
      (SELECT COUNT(*) FROM owned WHERE id IN private_chain) private_count`).get(...args)!;
  return { scope, args, totals };
}

/** Count the current committed view without reading record bodies or requiring a frozen file. */
export function previewHistoryExport(file: string, key: string) {
  const preview = (path: string, exclusive = false) => {
    const db = openHistoryReadOnly(path, key);
    try {
      db.pragma("temp_store=MEMORY");
      db.pragma("busy_timeout=3000");
      if (exclusive) db.pragma("locking_mode=EXCLUSIVE");
      return db.transaction(() => exportScope(db).totals)();
    } finally { db.close(); }
  };
  const stat = (suffix: string) => lstatSync(file + suffix, { bigint: true, throwIfNoEntry: false });
  if (!stat("-shm") && !stat("-wal")) {
    try { return preview(file, true); }
    catch (error) {
      // A closed WAL can require an exclusive lock unavailable on a read-only descriptor.
      if (!String((error as { code?: string }).code).startsWith("SQLITE_IOERR")) throw error;
    }
  }

  // Keep SQLite's WAL index and any recovery I/O inside a private directory.
  // Copy ciphertext only, and reject a concurrent change to either source file.
  const main = stat(""), wal = stat("-wal");
  if (!main?.isFile() || wal && !wal.isFile() || stat("-journal")) throw exportError("snapshot_changed");
  const unchanged = (before: ReturnType<typeof stat>, suffix: string) => {
    const after = stat(suffix);
    return !before ? !after : after?.isFile() && before.ino === after.ino && before.dev === after.dev &&
      before.size === after.size && before.mtimeNs === after.mtimeNs && before.ctimeNs === after.ctimeNs;
  };
  const dir = mkdtempSync(join(tmpdir(), "tacit-history-preview-"));
  try {
    const copy = join(dir, "history.db");
    copyFileSync(file, copy, constants.COPYFILE_EXCL);
    if (wal) copyFileSync(file + "-wal", copy + "-wal", constants.COPYFILE_EXCL);
    if (!unchanged(main, "") || !unchanged(wal, "-wal") || stat("-journal")) throw exportError("snapshot_changed");
    return preview(copy);
  } finally { rmSync(dir, { recursive: true, force: true }); }
}

export function exportHistory(file: string, key: string, after?: string, limit = 100) {
  if (!Number.isInteger(limit) || limit < 1 || limit > 200) throw exportError("invalid_limit");
  const snapshot = snapshotID(file), cursor = readCursor(after, snapshot);
  const db = openHistoryReadOnly(file, key);
  try {
    db.pragma("temp_store=MEMORY");
    const result = db.transaction(() => {
      const { scope, args, totals } = exportScope(db);
      const rows = db.prepare<[number, string, number, number, number, number], Parameters<typeof decode>[0] & { export_rowid: number; phase: 0 | 1 }>(exportable + `
        SELECT r.*,e.export_rowid,e.phase FROM (
          SELECT * FROM eligible WHERE phase>? OR (phase=? AND export_rowid>?) ORDER BY phase,export_rowid LIMIT ?
        ) e JOIN records r ON r.rowid=e.export_rowid ORDER BY e.phase,e.export_rowid`
      ).all(...args, cursor[1], cursor[1], cursor[2], limit + 1);
      const more = rows.length > limit;
      if (more) rows.pop();
      const last = rows.at(-1);
      const next_cursor = more && last ? Buffer.from(JSON.stringify([snapshot, last.phase, last.export_rowid])).toString("base64url") : null;
      const records = rows.map(row => {
        const { media: _, ...record } = decode(row, true, false);
        if (record.context?.url?.trim().match(/^file:/i)) delete record.context.url;
        return record;
      });
      return { snapshot_id: snapshot, identities: scope, records, next_cursor, ...totals };
    })();
    if (snapshotID(file) !== snapshot) throw exportError("snapshot_changed");
    return result;
  } finally {
    // 中枢库固定 journal_mode=DELETE，且导出前 Mac 已停掉本机后台、冻结旧库。若遇到 WAL 模式的库，
    // 只读打开可能建出 -wal/-shm，随后 snapshotID 报 snapshot_not_frozen；不按路径删边车，免得误删并发连接的文件。
    db.close();
  }
}

export function runHistoryExport(argv: string[], readKey = () => keychainStore().read("db-key"), output = console.log) {
  const { values } = parseArgs({ args: argv, options: {
    "data-dir": { type: "string" }, preview: { type: "boolean" }, after: { type: "string" }, limit: { type: "string" },
  } });
  if (!values["data-dir"]) throw exportError("history_export_requires_data_dir");
  if (values.preview && (values.after !== undefined || values.limit !== undefined)) throw exportError("invalid_preview_options");
  const key = readKey();
  if (!key) throw exportError("history_export_key_unavailable");
  const file = join(values["data-dir"], "history.db");
  output(JSON.stringify(values.preview ? previewHistoryExport(file, key) : exportHistory(file, key, values.after,
    values.limit === undefined ? undefined : Number(values.limit))));
}
