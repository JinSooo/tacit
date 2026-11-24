import { expect, test } from "bun:test";
import { spawnSync } from "node:child_process";
import { chmodSync, lstatSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { HubDB, openHistoryReadOnly } from "../src/db.ts";
import { exportHistory } from "../src/history-export.ts";
import { reconcileHistory, runHistoryReconcile } from "../src/history-reconcile.ts";
import { fixture, setup } from "./helpers.ts";

test("frozen reconciliation deletes, retains the current private body, and replays idempotently", async () => {
  const ctx = setup();
  try {
    const removed = fixture({ body: "Synthetic deletion text", source_ref: "synthetic-delete-key" });
    const kept = fixture({ body: "Synthetic original text", source_ref: "synthetic-private-key" });
    const latest = fixture({ source: "manual.correction", corrects: kept.id, body: "Synthetic revised text", title: "Synthetic new title" });
    const unknown = fixture().id;
    expect(ctx.db.ingest([removed, kept, latest]).accepted).toBe(3);
    ctx.db.db.prepare(`INSERT INTO runtime_calls (id,at,at_ms,kind,revision,request_json,response_text)
      VALUES ('synthetic','2026-11-24',?, 'model',0,'synthetic request','synthetic response')`).run(Date.now());
    const before = ctx.db.effective(kept.id);
    ctx.db.close();

    const changes = [{ id: removed.id, kind: "deleted" }, { id: kept.id, kind: "private" },
      { id: unknown, kind: "private" }, { id: unknown, kind: "deleted" }];
    const run = async () => {
      const output: string[] = [];
      await runHistoryReconcile(["--data-dir", ctx.dir], () => ctx.config.dbKey,
        async () => JSON.stringify({ changes }), line => output.push(line));
      expect(output).toHaveLength(1);
      const text = output[0]!;
      for (const value of [removed.body, kept.body, latest.body, latest.title, kept.source_ref, ctx.config.dbKey]) {
        expect(text).not.toContain(value!);
      }
      return JSON.parse(text);
    };
    expect(await run()).toEqual({ items: changes.map(({ id }, i) => ({ id, status: i < 2 ? "applied" : "missing" })) });
    expect(await run()).toEqual({ items: changes.map(({ id }, i) => ({ id, status: i < 2 ? "already" : "missing" })) });
    const backup = new HubDB(ctx.file, ctx.config.dbKey);
    try {
      expect(backup.get(removed.id)).toBeNull();
      expect(backup.list(new URLSearchParams({ q: removed.body })).records).toHaveLength(0);
      expect(backup.db.prepare("SELECT content_state,request_json,response_text FROM runtime_calls WHERE id='synthetic'").get())
        .toEqual({ content_state: "deleted", request_json: null, response_text: null });
      expect(backup.get(kept.id)?.body).toBe(kept.body);
      expect(backup.effective(kept.id)).toMatchObject({ title: before?.title, body: before?.body, sensitivity: "private" });
      expect(backup.get(kept.id)?.corrections).toHaveLength(2);
    } finally { backup.close(); }
    expect(exportHistory(ctx.file, ctx.config.dbKey)).toMatchObject({ records: [], private_count: 3 });
  } finally { ctx.cleanup(); }
});

test("frozen reconciliation rejects sidecars and malformed pages before writes", async () => {
  const ctx = setup();
  try {
    const original = fixture();
    ctx.db.ingest([original]);
    ctx.db.close();
    const bytes = readFileSync(ctx.file);
    const run = (changes: unknown) => runHistoryReconcile(["--data-dir", ctx.dir], () => ctx.config.dbKey,
      async () => JSON.stringify({ changes }), () => { throw Error("unexpected output"); });
    await expect(run([{ id: "bad", kind: "deleted" }])).rejects.toThrow("invalid_changes");
    writeFileSync(ctx.file + "-wal", "");
    await expect(run([{ id: original.id, kind: "deleted" }])).rejects.toThrow("snapshot_not_frozen");
    expect(readFileSync(ctx.file)).toEqual(bytes);
  } finally { ctx.cleanup(); }
});

test("a later withdrawal deletes nested private copies, and a failed page rolls back", async () => {
  const ctx = setup();
  try {
    const original = fixture(), correction = fixture({ source: "manual.correction", corrects: original.id });
    const other = fixture();
    expect(ctx.db.ingest([original, correction, other]).accepted).toBe(3);
    ctx.db.db.exec(`CREATE TRIGGER fixture_failure BEFORE INSERT ON records
      WHEN NEW.sensitivity='private' AND NEW.corrects='${other.id}' BEGIN SELECT RAISE(ABORT, 'fixture'); END;`);
    ctx.db.close();
    const run = (changes: {id: string, kind: string}[]) => runHistoryReconcile(["--data-dir", ctx.dir], () => ctx.config.dbKey,
      async () => JSON.stringify({ changes }), () => {});
    await expect(run([{ id: original.id, kind: "deleted" }, { id: other.id, kind: "private" }])).rejects.toThrow();
    expect(reconcileHistory(ctx.file, ctx.config.dbKey, [
      { id: correction.id, kind: "private" }, { id: original.id, kind: "private" },
    ])).toEqual({ items: [{ id: correction.id, status: "applied" }, { id: original.id, status: "already" }] });
    const backup = new HubDB(ctx.file, ctx.config.dbKey);
    const legacyCopy = fixture({ source: "manual.correction", corrects: correction.id, sensitivity: "private", body: "synthetic-fossil" });
    try {
      expect(backup.effective(original.id)).toMatchObject({ sensitivity: "private", body: correction.body });
      expect(backup.get(original.id)?.corrections).toHaveLength(2);
      expect(backup.get(correction.id)?.corrections).toHaveLength(0);
      expect(backup.db.prepare("SELECT 1 FROM tombstones WHERE id=?").get(original.id)).toBeUndefined();
      expect(backup.ingest([legacyCopy]).accepted).toBe(1);
      expect(backup.delete(original.id)).toBe(true);
    } finally { backup.close(); }
    const final = new HubDB(ctx.file, ctx.config.dbKey);
    try {
      expect(final.get(original.id)).toBeNull();
      expect(final.get(correction.id)).toBeNull();
      expect(final.get(legacyCopy.id)).toBeNull();
      expect(final.list(new URLSearchParams({ q: "synthetic-fossil" })).records).toEqual([]);
      expect(final.db.prepare("SELECT 1 FROM tombstones WHERE id=?").get(legacyCopy.id)).not.toBeUndefined();
    } finally { final.close(); }
  } finally { ctx.cleanup(); }
});

test("reconcile CLI reports only its error category for malformed input", () => {
  const ctx = setup();
  try {
    const result = spawnSync(process.execPath, [new URL("../src/cli.ts", import.meta.url).pathname, "history-reconcile",
      "--data-dir", ctx.dir], { input: "synthetic-text", encoding: "utf8" });
    expect(result.status).toBe(1);
    expect(result.stdout).toBe("");
    expect(result.stderr).toBe("invalid_changes\n");
  } finally { ctx.cleanup(); }
});

test("a no-op reconciliation leaves frozen file metadata and unrelated maintenance data alone", () => {
  const ctx = setup();
  try {
    ctx.db.db.exec(`INSERT INTO runtime_calls (id,at,at_ms,kind,revision,request_json,response_text)
      VALUES ('old','2000-01-01',0,'model',0,'synthetic request','synthetic response');
      INSERT INTO security_audit(id,at,action,ok) VALUES ('old','2000-01-01','fixture',1);`);
    ctx.db.close();
    const audit = ctx.file + ".audit-pending";
    const previousBackup = ctx.file + ".migration-v18.bak";
    mkdirSync(audit);
    writeFileSync(join(audit, "synthetic.enc"), "synthetic invalid pending entry");
    writeFileSync(previousBackup, "retained backup");
    chmodSync(ctx.file, 0o640);
    const before = lstatSync(ctx.file, { bigint: true });
    const snapshot = exportHistory(ctx.file, ctx.config.dbKey).snapshot_id;
    const unknown = fixture().id;

    expect(reconcileHistory(ctx.file, ctx.config.dbKey, [
      { id: unknown, kind: "private" }, { id: unknown, kind: "deleted" },
    ])).toEqual({ items: [{ id: unknown, status: "missing" }, { id: unknown, status: "missing" }] });

    const after = lstatSync(ctx.file, { bigint: true });
    expect([after.mode, after.ctimeNs, after.mtimeNs]).toEqual([before.mode, before.ctimeNs, before.mtimeNs]);
    expect(exportHistory(ctx.file, ctx.config.dbKey).snapshot_id).toBe(snapshot);
    expect(readFileSync(join(audit, "synthetic.enc"), "utf8")).toBe("synthetic invalid pending entry");
    expect(readFileSync(previousBackup, "utf8")).toBe("retained backup");
    const frozen = openHistoryReadOnly(ctx.file, ctx.config.dbKey);
    try {
      expect(frozen.prepare("SELECT response_text FROM runtime_calls WHERE id='old'").get()).toEqual({ response_text: "synthetic response" });
      expect(frozen.prepare("SELECT id FROM security_audit WHERE id='old'").get()).toEqual({ id: "old" });
    } finally { frozen.close(); }
  } finally { ctx.cleanup(); }
});

test("privacy withdrawal preserves all text that expanded during redaction", () => {
  const ctx = setup();
  try {
    const padding = "🧪";
    const suffix = " 密码:1234";
    const record = fixture({
      title: padding.repeat(200 - suffix.length) + suffix,
      body: padding.repeat(200_000 - suffix.length) + suffix,
    });
    expect(ctx.db.ingest([record]).accepted).toBe(1);
    const original = ctx.db.get(record.id)!;
    expect(Array.from(original.title).length).toBeGreaterThan(200);
    expect(Array.from(original.body).length).toBeGreaterThan(200_000);
    ctx.db.close();
    const apply = () => reconcileHistory(ctx.file, ctx.config.dbKey, [{ id: record.id, kind: "private" }]);
    expect(apply()).toEqual({ items: [{ id: record.id, status: "applied" }] });
    expect(apply()).toEqual({ items: [{ id: record.id, status: "already" }] });
    const restored = new HubDB(ctx.file, ctx.config.dbKey);
    try {
      expect(restored.effective(record.id)).toMatchObject({
        sensitivity: "private", title: original.title, body: original.body,
      });
    } finally { restored.close(); }
  } finally { ctx.cleanup(); }
});

test("deleting a single correction erases its private copy and leaves the root private", () => {
  const ctx = setup();
  try {
    const root = fixture({ body: "remaining synthetic body" });
    const revised = fixture({ source: "manual.correction", corrects: root.id, body: "sensitive synthetic copy" });
    expect(ctx.db.ingest([root, revised]).accepted).toBe(2);
    ctx.db.close();
    reconcileHistory(ctx.file, ctx.config.dbKey, [{ id: root.id, kind: "private" }]);
    reconcileHistory(ctx.file, ctx.config.dbKey, [{ id: revised.id, kind: "deleted" }]);
    const backup = new HubDB(ctx.file, ctx.config.dbKey);
    try {
      expect(backup.effective(root.id)).toMatchObject({ body: root.body, sensitivity: "private" });
      expect(backup.db.prepare("SELECT count(*) AS count FROM records WHERE body=?").get(revised.body)).toEqual({ count: 0 });
      expect(backup.db.prepare("SELECT count(*) AS count FROM records_fts WHERE records_fts MATCH 'sensitive'").get()).toEqual({ count: 0 });
    } finally { backup.close(); }
  } finally { ctx.cleanup(); }
});

test("a sealed older schema is left byte-for-byte unchanged", () => {
  const ctx = setup();
  try {
    ctx.db.db.pragma("user_version=18");
    ctx.db.close();
    const bytes = readFileSync(ctx.file);
    expect(() => reconcileHistory(ctx.file, ctx.config.dbKey, [{ id: fixture().id, kind: "deleted" }]))
      .toThrow("snapshot_schema_unsupported");
    expect(readFileSync(ctx.file)).toEqual(bytes);
    expect(lstatSync(ctx.file + ".migration-v18.bak", { throwIfNoEntry: false })).toBeUndefined();
  } finally { ctx.cleanup(); }
});

test("deletion recognizes a private copy written by an older preview without provenance", () => {
  const ctx = setup();
  try {
    const root = fixture({ body: "remaining synthetic body" });
    const revised = fixture({ source: "manual.correction", corrects: root.id, body: "legacy private copy probe" });
    const copy = fixture({ source: "manual.correction", corrects: root.id, kind: "event",
      sensitivity: "private", capture: { method: "manual" }, title: revised.title, body: revised.body,
      t_start: new Date(Date.parse(revised.t_start) + 5_000).toISOString() });
    expect(ctx.db.ingest([root, revised, copy]).accepted).toBe(3);
    ctx.db.close();
    reconcileHistory(ctx.file, ctx.config.dbKey, [{ id: revised.id, kind: "deleted" }]);
    const backup = new HubDB(ctx.file, ctx.config.dbKey);
    try {
      expect(backup.get(copy.id)).toBeNull();
      expect(backup.effective(root.id)).toMatchObject({ body: root.body, sensitivity: "private" });
    } finally { backup.close(); }
  } finally { ctx.cleanup(); }
});
