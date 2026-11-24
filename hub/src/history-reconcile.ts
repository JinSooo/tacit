import { lstatSync } from "node:fs";
import { join } from "node:path";
import { parseArgs } from "node:util";
import { HubDB } from "./db.ts";
import { keychainStore } from "./secrets/keychain.ts";

type Change = { id: string; kind: "deleted" | "private" };
type Item = { id: string; status: "applied" | "already" | "missing" };
const idPattern = /^[0-9A-HJKMNP-TV-Z]{26}$/;

class ReconcileError extends Error {}

function page(input: string): Change[] {
  try {
    const value = JSON.parse(input);
    if (Object.keys(value).length === 1 && Array.isArray(value.changes) &&
        value.changes.length >= 1 && value.changes.length <= 200 &&
        value.changes.every((row: Change) => row != null && Object.keys(row).length === 2 &&
          typeof row.id === "string" && idPattern.test(row.id) && (row.kind === "deleted" || row.kind === "private"))) {
      return value.changes;
    }
  } catch { /* Invalid JSON and malformed pages share one error category. */ }
  throw new ReconcileError("invalid_changes");
}

export function reconcileHistory(file: string, key: string, changes: Change[]): { items: Item[] } {
  if (!lstatSync(file, { throwIfNoEntry: false })?.isFile()) throw new ReconcileError("history_reconcile_missing");
  for (const suffix of ["-wal", "-shm", "-journal"]) {
    if (lstatSync(file + suffix, { throwIfNoEntry: false })) throw new ReconcileError("snapshot_not_frozen");
  }
  let hub: HubDB;
  try { hub = new HubDB(file, key, { fileMustExist: true, frozen: true }); }
  catch (error) {
    if (error instanceof Error && error.message === "snapshot_schema_unsupported") {
      throw new ReconcileError(error.message);
    }
    throw error;
  }
  try {
    const tombstone = hub.db.prepare("SELECT 1 FROM tombstones WHERE id=?");
    const present = hub.db.prepare("SELECT 1 FROM records WHERE id=?");
    const root = hub.db.prepare<[string], { id: string }>(`
      WITH RECURSIVE ancestors(id, source, corrects) AS (
        SELECT id,source,corrects FROM records WHERE id=?
        UNION
        SELECT r.id,r.source,r.corrects FROM records r JOIN ancestors a ON r.id=a.corrects
        WHERE a.source='manual.correction'
      ) SELECT id FROM ancestors WHERE source!='manual.correction'`);
    // Older preview builds used a copy without provenance. Match only the
    // exact fields that their private-copy operation derived from the correction.
    const legacyCopies = hub.db.prepare<[string], { id: string; corrects: string }>(`
      WITH RECURSIVE targets(id) AS (
        SELECT id FROM records WHERE id=?
        UNION
        SELECT r.id FROM records r JOIN targets t ON r.corrects=t.id WHERE r.source='manual.correction'
      )
      SELECT copy.id,copy.corrects FROM records old JOIN targets ON old.id=targets.id
      JOIN records copy ON copy.corrects=old.corrects AND copy.id!=old.id
      WHERE old.source='manual.correction' AND copy.source='manual.correction'
        AND copy.sensitivity='private' AND copy.source_ref IS NULL AND copy.device=old.device
        AND copy.kind='event' AND copy.capture='{"method":"manual"}' AND copy.t_end IS NULL
        AND copy.context IS NULL AND copy.people IS NULL AND copy.media IS NULL
        AND copy.t_start_ms>old.t_start_ms
        AND copy.title=substr(old.title,1,200) AND copy.body=substr(old.body,1,200000)`);
    return hub.db.transaction(() => ({
      items: changes.map(({ id, kind }): Item => {
        if (kind === "deleted") {
          if (present.get(id)) {
            const legacy = legacyCopies.all(id);
            hub.deleteMany([id, ...legacy.map(copy => copy.id)]);
            for (const target of new Set(legacy.map(copy => copy.corrects))) {
              const remaining = hub.effective(target);
              if (remaining && remaining.sensitivity !== "private") hub.withdrawHistoryPrivacy(target, remaining);
            }
            return { id, status: "applied" };
          }
          return { id, status: tombstone.get(id) ? "already" : "missing" };
        }
        const original = root.get(id)?.id;
        const current = original ? hub.effective(original) : null;
        if (!current) return { id, status: "missing" };
        if (current.sensitivity === "private") return { id, status: "already" };
        hub.withdrawHistoryPrivacy(original!, current);
        return { id, status: "applied" };
      }),
    })).immediate();
  } finally {
    hub.close();
  }
}

async function readInput() {
  const chunks: Uint8Array[] = [];
  let bytes = 0;
  for await (const chunk of Bun.stdin.stream()) {
    bytes += chunk.byteLength;
    if (bytes > 32 * 1024) throw new ReconcileError("invalid_changes");
    chunks.push(chunk);
  }
  return Buffer.concat(chunks).toString("utf8");
}

export async function runHistoryReconcile(
  argv: string[],
  readKey = () => keychainStore().read("db-key"),
  input = readInput,
  output = console.log,
) {
  let directory: string | undefined;
  try { directory = parseArgs({ args: argv, options: { "data-dir": { type: "string" } } }).values["data-dir"]; }
  catch { throw new ReconcileError("invalid_arguments"); }
  if (!directory) throw new ReconcileError("history_reconcile_requires_data_dir");
  const changes = page(await input());
  let key: string | null;
  try { key = readKey(); }
  catch { throw new ReconcileError("history_reconcile_key_unavailable"); }
  if (!key) throw new ReconcileError("history_reconcile_key_unavailable");
  output(JSON.stringify(reconcileHistory(join(directory, "history.db"), key, changes)));
}

export async function historyReconcileCommand(argv: string[]) {
  try { await runHistoryReconcile(argv); }
  catch (error) {
    process.stderr.write((error instanceof ReconcileError ? error.message : "history_reconcile_failed") + "\n");
    process.exitCode = 1;
  }
}
