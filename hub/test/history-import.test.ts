import { expect, test } from "bun:test";
import { existsSync, readFileSync, readdirSync, writeFileSync } from "node:fs";
import { HubDB, openHistoryReadOnly } from "../src/db.ts";
import { historyImport } from "../src/devices/history-import.ts";
import { exportHistory, previewHistoryExport, runHistoryExport } from "../src/history-export.ts";
import { distillRound } from "../src/distill/run.ts";
import { localDateString } from "../src/distill/requests.ts";
import { DistillStore } from "../src/distill/store.ts";
import { updateGeneral } from "../src/general-settings.ts";
import { fixture, setup } from "./helpers.ts";

const snapshot_id = "a".repeat(64), hub_id = "fixture", now = Date.parse("2026-11-24T00:00:00Z");
const identities = [{ device: "mac", kind: "mac", sources: ["mac.screen", "mac.audio", "manual.note", "manual.correction"] }];
const begin = { hub_id, snapshot_id, identities };

function importFixture(db: HubDB) {
  const send = (op: string, body: object, actor = "fixture-admin", at = now) =>
    historyImport(db, actor, hub_id, at, "history.import." + op, body as Record<string, unknown>);
  const started = send("begin", begin);
  expect(started.status).toBe(200);
  const session_id = (started.body as { session_id: string }).session_id;
  const batch = (batch_number: number, records: unknown[]) => send("batch", { session_id, batch_number, records });
  return { send, batch, session_id };
}

test("v18 加密库迁移到 v19，保留原文、墓碑和完整性", () => {
  const ctx = setup();
  try {
    const live = fixture(), erased = fixture();
    ctx.db.ingest([live, erased]);
    ctx.db.delete(erased.id);
    ctx.db.db.exec(`
      DROP TRIGGER history_import_deleted; DROP TRIGGER history_import_private_0; DROP TRIGGER history_import_private_1;
      DROP TABLE history_import_sessions; DROP TABLE history_import_batches; DROP TABLE history_import_ids;
      DROP TABLE history_import_changes; DROP TABLE history_import_days; PRAGMA user_version=18;
    `);
    ctx.db.close();
    const upgraded = new HubDB(ctx.file, ctx.config.dbKey);
    try {
      expect(upgraded.db.pragma("user_version", { simple: true })).toBe(19);
      expect(upgraded.db.pragma("integrity_check", { simple: true })).toBe("ok");
      expect(upgraded.get(live.id)?.body).toBe(live.body);
      expect(upgraded.db.prepare("SELECT id FROM tombstones").get()).toEqual({ id: erased.id });
      expect(existsSync(ctx.file + ".migration-v18.bak")).toBe(false);
      expect(importFixture(upgraded).batch(1, [fixture()]).status).toBe(200);
    } finally { upgraded.close(); }
  } finally { ctx.cleanup(); }
});

test("批次回执可重放，墓碑与冲突不覆盖，等价原记录映射后才接修正", () => {
  const ctx = setup();
  try {
    const erased = fixture({ source_ref: "gone-anchor" });
    const stored = fixture({ source_ref: "existing-anchor" });
    const conflict = fixture({ source_ref: "different-anchor" });
    ctx.db.ingest([erased, stored, conflict]);
    ctx.db.delete(erased.id);
    const imported = fixture({ body: "示例花园记录" });
    const alias = { ...stored, id: fixture().id };
    const byKey = { ...erased, id: fixture().id };
    const byID = { ...erased, source_ref: "changed-anchor" };
    const changed = { ...conflict, id: fixture().id, body: "不同内容" };
    const correction = fixture({ source: "manual.correction", corrects: alias.id, title: "示例花园更正" });
    const orphan = fixture({ source: "manual.correction", corrects: fixture().id });
    const records = [imported, alias, byKey, byID, changed, correction, orphan];
    const { batch, send, session_id } = importFixture(ctx.db);
    const first = batch(1, records);
    expect(first).toEqual({ status: 200, body: {
      session_id, batch_number: 1, counts: { added: 2, exists: 1, deleted: 2, conflict: 1, rejected: 1 },
      items: [
        { id: imported.id, status: "added", remote_id: imported.id },
        { id: alias.id, status: "exists", remote_id: stored.id },
        { id: byKey.id, status: "deleted" }, { id: byID.id, status: "deleted" },
        { id: changed.id, status: "conflict", code: "record_conflict" },
        { id: correction.id, status: "added", remote_id: correction.id },
        { id: orphan.id, status: "rejected", code: "correction_target" },
      ],
    } });
    expect(batch(1, records.map(r => Object.fromEntries(Object.entries(r).reverse())))).toEqual(first);
    expect(batch(1, [{ ...imported, body: "变了" }])).toEqual({ status: 409, body: { error: "batch_changed" } });
    expect(send("status", { session_id }, "another-admin")).toEqual({ status: 404, body: { error: "session_unknown" } });
    expect(ctx.db.get(imported.id)?.body).toBe(imported.body);
    expect(ctx.db.get(stored.id)?.corrections.map(r => r.id)).toEqual([correction.id]);
    expect(ctx.db.get(byKey.id)).toBeNull();
    expect(ctx.db.get(byID.id)).toBeNull();
    expect(ctx.db.get(conflict.id)?.body).toBe(conflict.body);
    expect(ctx.db.get(changed.id)).toBeNull();
    expect(JSON.stringify(ctx.db.db.prepare("SELECT receipt FROM history_import_batches").all())).not.toContain(imported.body);
    expect(send("status", { session_id }).body).toMatchObject({
      confirmed_batches: 1, confirmed_records: 7, next_batch_number: 2, finished_at: null,
    });
  } finally { ctx.cleanup(); }
});

test("同批私密链不入库，已导入 ID 在真删与私密修正后可按水位和全量对账", () => {
  const ctx = setup();
  try {
    const { batch, session_id, send } = importFixture(ctx.db);
    const removed = fixture(), stored = fixture({ source_ref: "mapped" }), privateRoot = fixture();
    ctx.db.ingest([stored]);
    const alias = { ...stored, id: fixture().id };
    const fix = fixture({ source: "manual.correction", corrects: alias.id });
    const blocked = fixture({ source: "manual.correction", corrects: privateRoot.id, sensitivity: "private" });
    const accepted = batch(1, [removed, alias, privateRoot, fix, blocked]);
    expect(accepted.body).toMatchObject({ counts: { added: 2, exists: 1, rejected: 2 } });
    expect(ctx.db.get(privateRoot.id)).toBeNull();
    expect(ctx.db.get(blocked.id)).toBeNull();
    expect(send("changes", { session_id, after: 0 }).body).toEqual({ changes: [], cursor: 0, more: false });

    ctx.db.delete(removed.id);
    const first = send("changes", { session_id, after: 0 }).body as { changes: unknown[]; cursor: number; more: boolean };
    expect(first).toEqual({ changes: [{ id: removed.id, kind: "deleted" }], cursor: expect.any(Number), more: false });
    const privateEdit = fixture({ source: "manual.correction", corrects: stored.id, sensitivity: "private", body: "不返回的虚构正文" });
    expect(ctx.db.ingest([privateEdit]).accepted).toBe(1);
    const second = send("changes", { session_id, after: first.cursor }).body as typeof first;
    expect(second.changes).toHaveLength(2);
    expect(second.changes).toContainEqual({ id: alias.id, kind: "private" });
    expect(second.changes).toContainEqual({ id: fix.id, kind: "private" });
    expect(second.cursor).toBeGreaterThan(first.cursor);
    expect(send("verify", { session_id, ids: [alias.id, removed.id, fix.id, privateRoot.id] }).body).toEqual({
      items: [{ id: alias.id, status: "private" }, { id: removed.id, status: "deleted" }, { id: fix.id, status: "private" },
        { id: privateRoot.id, status: "unknown" }],
    });
    expect(send("changes", { session_id, after: second.cursor }).body).toEqual({ changes: [], cursor: second.cursor, more: false });
    expect(send("changes", { session_id, after: second.cursor + 1 }).status).toBe(409);
  } finally { ctx.cleanup(); }
});

test("finish 幂等安排启用前日期，后台切片并尊重每日模型上限", async () => {
  const ctx = setup();
  try {
    const { batch, session_id, send } = importFixture(ctx.db);
    const store = new DistillStore(ctx.db);
    store.setState("enabled_ms", now);
    const imported = fixture();
    expect(batch(1, [imported]).status).toBe(200);
    const date = localDateString(Date.parse(imported.t_start));
    expect(ctx.db.db.prepare("SELECT * FROM history_import_days").all()).toEqual([]);
    const finished = send("finish", { session_id });
    expect(finished.body).toMatchObject({ queued_days: 1, finished_at: new Date(now).toISOString() });
    expect(send("finish", { session_id })).toEqual(finished);
    expect(ctx.db.db.prepare("SELECT date FROM history_import_days").all()).toEqual([{ date }]);
    expect(batch(2, [fixture()]).status).toBe(409);

    updateGeneral(ctx.db, { daily_token_limit: 1 });
    ctx.db.db.exec(`INSERT INTO llm_usage(id,at,tier,provider,model,input_tokens,output_tokens,ms,ok,error,task)
      VALUES('fixture','2026-11-24T00:00:00Z','day','mock','mock',1,1,0,1,NULL,'day')`);
    let calls = 0;
    const result = await distillRound({ db: ctx.db, now: () => now, llm: { async complete() { calls++; throw new Error("unexpected call"); } } },
      { slow: true, days: "all" });
    expect(result.stopped).toBe("budget");
    expect(calls).toBe(0);
    expect(ctx.db.db.prepare("SELECT record_id FROM frame_records").all()).toEqual([{ record_id: imported.id }]);
    expect(store.day(date)?.needs_regen).toBe(1);
    expect(ctx.db.db.prepare("SELECT * FROM history_import_days").all()).toEqual([]);
  } finally { ctx.cleanup(); }
});

test("冻结库只读分页，排除私密整链、孤儿修正和其它设备，不导媒体", () => {
  const ctx = setup();
  try {
    const local = "mac-aaaaaaaa", agent = "agent-bbbbbbbb", foreign = "mac-cccccccc";
    const ins = ctx.db.db.prepare("INSERT INTO devices(id,name,platform,public_key,paired_at,last_seen,role,local_only) VALUES(?,?,?,?,?,?,?,?)");
    ins.run(local, "fixture", "mac", Buffer.alloc(32, 1), "", "", "admin", 1);
    ins.run(agent, "fixture", "agent", Buffer.alloc(32, 2), "", "", "agent", 1);
    ins.run(foreign, "fixture", "mac", Buffer.alloc(32, 3), "", "", "admin", 0);
    const original = fixture({ source: "mac.audio", device: local, context: { url: "file:///example.wav" }, media: [{ kind: "audio", path: "/example.wav" }] });
    const fix = fixture({ source: "manual.correction", corrects: original.id });
    const note = fixture({ source: "manual.agent", device: agent, source_ref: "fixture-note" });
    const secret = fixture({ body: "私密样例原文不可导出" }), sibling = fixture({ source: "manual.correction", corrects: secret.id });
    const secretEdit = fixture({ source: "manual.correction", corrects: sibling.id, sensitivity: "private" });
    const orphan = fixture({ source: "manual.correction", corrects: fixture().id });
    ctx.db.ingest([original, fix, note, secret, sibling, secretEdit, orphan,
      fixture({ device: foreign }), fixture({ device: "android-aaaaaaaa", source: "android.audio" })]);
    ctx.db.close();

    const bytes = readFileSync(ctx.file), files = readdirSync(ctx.dir);
    const readOnly = openHistoryReadOnly(ctx.file, ctx.config.dbKey);
    try { expect(() => readOnly.exec("DELETE FROM records")).toThrow(); }
    finally { readOnly.close(); }
    const page = exportHistory(ctx.file, ctx.config.dbKey, undefined, 1);
    expect(page).toMatchObject({ total: 3, private_count: 3, records: [{ id: original.id, device: local }] });
    expect(page.records[0]).not.toHaveProperty("media");
    expect(page.records[0]?.context?.url).toBeUndefined();
    expect(page.next_cursor).not.toBeNull();
    const second = exportHistory(ctx.file, ctx.config.dbKey, page.next_cursor!, 1);
    const third = exportHistory(ctx.file, ctx.config.dbKey, second.next_cursor!, 1);
    expect(second).toMatchObject({ snapshot_id: page.snapshot_id, records: [{ id: note.id, device: agent }] });
    expect(third).toMatchObject({ snapshot_id: page.snapshot_id, records: [{ id: fix.id, corrects: original.id }], next_cursor: null });
    let output = "";
    runHistoryExport(["--data-dir", ctx.dir, "--limit", "1"], () => ctx.config.dbKey, line => { output = line; });
    expect(JSON.parse(output)).toEqual(page);
    expect(output).not.toContain(ctx.config.dbKey);
    expect(readdirSync(ctx.dir)).toEqual(files);
    expect(readFileSync(ctx.file)).toEqual(bytes);
    const writer = new HubDB(ctx.file, ctx.config.dbKey);
    try { writer.ingest([fixture()]); } finally { writer.close(); }
    expect(() => exportHistory(ctx.file, ctx.config.dbKey, page.next_cursor!)).toThrow("snapshot_changed");
    writeFileSync(ctx.file + "-journal", Buffer.from("pending"));
    expect(() => exportHistory(ctx.file, ctx.config.dbKey)).toThrow("snapshot_not_frozen");
  } finally { ctx.cleanup(); }
});

test("在线历史预览只按导出口径计数，不需要冻结数据库", () => {
  const ctx = setup();
  try {
    const original = fixture();
    const privateRecord = fixture({ sensitivity: "private" });
    ctx.db.db.pragma("journal_mode=WAL");
    ctx.db.ingest([original, privateRecord, fixture({ source: "manual.correction", corrects: privateRecord.id }),
      fixture({ device: "android-aaaaaaaa", source: "android.audio" })]);
    const before = readFileSync(ctx.file);
    const result = { total: 1, private_count: 2 };
    expect(previewHistoryExport(ctx.file, ctx.config.dbKey)).toEqual(result);
    let output = "";
    runHistoryExport(["--preview", "--data-dir", ctx.dir], () => ctx.config.dbKey, line => { output = line; });
    expect(JSON.parse(output)).toEqual(result);
    expect(readFileSync(ctx.file)).toEqual(before);
    expect(() => exportHistory(ctx.file, ctx.config.dbKey)).toThrow("snapshot_not_frozen");
    expect(() => previewHistoryExport(ctx.file + ".missing", ctx.config.dbKey)).toThrow();
    expect(() => previewHistoryExport(ctx.file, "wrong-fixture-key")).toThrow();
    ctx.db.db.pragma("journal_mode=DELETE");
    ctx.db.close();
    expect(exportHistory(ctx.file, ctx.config.dbKey)).toMatchObject(result);
  } finally { ctx.cleanup(); }
});

// 2026-11-24 第 1 轮审查回归：未来结束时刻、非法日期、附件、审计与 WAL 边车。
test("过去导入日一次出队，非法日期不入队，附件与空 WAL 边车被拒，导入留安全审计", async () => {
  const ctx = setup();
  try {
    const { batch, session_id, send } = importFixture(ctx.db);
    new DistillStore(ctx.db).setState("enabled_ms", now);
    const lingering = fixture({ t_start: "2026-11-20T10:00:00Z", t_end: "2026-11-30T10:00:00Z" });
    const farFuture = fixture({ t_start: "9999-12-31T10:00:00Z", t_end: "9999-12-31T23:59:00Z" });
    const spaced = fixture({ context: { url: " file:///example.wav" } }), empty = fixture({ media: [] });
    const reply = batch(1, [lingering, farFuture, spaced, empty]).body as { items: { status: string; code?: string }[] };
    expect(reply.items.map(i => i.code ?? i.status)).toEqual(["added", "added", "media_not_allowed", "media_not_allowed"]);
    send("batch", { session_id, batch_number: 2, records: [fixture({ device: "mac-zzzzzzzz" })] });
    send("finish", { session_id });
    const queued = (ctx.db.db.prepare("SELECT date FROM history_import_days").all() as { date: string }[]).map(r => r.date);
    expect(queued.every(d => /^\d{4}-\d{2}-\d{2}$/.test(d))).toBe(true);
    const ctxLlm = { db: ctx.db, now: () => now, llm: { async complete(): Promise<never> { throw new Error("offline"); } } };
    await distillRound(ctxLlm, { slow: true, days: "all" }).catch(() => {});
    const remaining = ctx.db.db.prepare("SELECT date FROM history_import_days WHERE date<=?").all(localDateString(now));
    expect(remaining).toEqual([]);
    const audit = (ctx.db.db.prepare("SELECT detail_code, ok FROM security_audit WHERE action='history.import' ORDER BY rowid").all() as { detail_code: string; ok: number }[]);
    expect(audit.map(a => a.detail_code)).toEqual(expect.arrayContaining(["begin", "batch:out_of_scope:1", "finish"]));
    ctx.db.close();
    writeFileSync(ctx.file + "-wal", Buffer.alloc(0));
    expect(() => exportHistory(ctx.file, ctx.config.dbKey)).toThrow("snapshot_not_frozen");
  } finally { ctx.cleanup(); }
});

// 2026-11-24 第 2 轮审查回归：旧代码留下的非法队列日直接丢弃；WAL 模式库导出失败后目录保持原样。
test("非法队列日不进 days，WAL 库导出报错", async () => {
  const ctx = setup();
  try {
    ctx.db.db.prepare("INSERT INTO history_import_days VALUES(?)").run("10000-01-01");
    ctx.db.db.prepare("INSERT INTO history_import_days VALUES(?)").run("2026-02-30x");
    const llm = { async complete(): Promise<never> { throw new Error("offline"); } };
    await distillRound({ db: ctx.db, now: () => now, llm }, { slow: true, days: "all" }).catch(() => {});
    expect(ctx.db.db.prepare("SELECT * FROM history_import_days").all()).toEqual([]);
    expect(new DistillStore(ctx.db).day("10000-01-01")).toBeFalsy();
    ctx.db.db.pragma("journal_mode=WAL");
    ctx.db.close();
    expect(() => exportHistory(ctx.file, ctx.config.dbKey)).toThrow("snapshot_not_frozen");
  } finally { ctx.cleanup(); }
});

// 2026-11-24 第 3 轮审查回归：跨午夜的导入录音，两天都要排上整理。
test("跨午夜的导入录音在一个窗口里切片，两天都标重整并出队", async () => {
  const ctx = setup();
  try {
    const { batch, session_id, send } = importFixture(ctx.db);
    new DistillStore(ctx.db).setState("enabled_ms", now);
    const start = new Date(2026, 10, 20, 23, 58), end = new Date(2026, 10, 21, 0, 6);
    const audio = fixture({ source: "mac.audio", t_start: start.toISOString(), t_end: end.toISOString(), body: "合成跨午夜对话转写" });
    expect((batch(1, [audio]).body as { items: { status: string }[] }).items[0]?.status).toBe("added");
    send("finish", { session_id });
    const days = [localDateString(+start), localDateString(+end)];
    expect((ctx.db.db.prepare("SELECT date FROM history_import_days ORDER BY date").all() as { date: string }[]).map(r => r.date)).toEqual(days);
    const llm = { async complete(): Promise<never> { throw new Error("offline"); } };
    await distillRound({ db: ctx.db, now: () => now, llm }, { slow: false }).catch(() => {});
    const store = new DistillStore(ctx.db);
    for (const day of days) expect(store.day(day)?.needs_regen).toBe(1);
    expect(ctx.db.db.prepare("SELECT * FROM history_import_days").all()).toEqual([]);
  } finally { ctx.cleanup(); }
});

test("a closed WAL preview does not create a shared-memory sidecar", () => {
  const ctx = setup();
  try {
    ctx.db.db.pragma("journal_mode=WAL");
    ctx.db.ingest([fixture()]);
    ctx.db.close();
    const before = readdirSync(ctx.dir);
    expect(before).not.toContain("history.db-shm");
    expect(previewHistoryExport(ctx.file, ctx.config.dbKey)).toEqual({ total: 1, private_count: 0 });
    expect(readdirSync(ctx.dir)).toEqual(before);
  } finally { ctx.cleanup(); }
});

test("replacement Mac can read an old session's private and deletion mappings without acquiring its write authority", () => {
  const ctx = setup();
  try {
    const { send, batch, session_id } = importFixture(ctx.db);
    const record = fixture();
    expect(batch(1, [record]).status).toBe(200);
    const actor = "fixture-new-admin", body = { session_id, ids: [record.id] };
    expect(send("verify", body, actor).status).toBe(404);
    expect(ctx.db.ingest([fixture({ source: "manual.correction", corrects: record.id, sensitivity: "private" })]).accepted).toBe(1);
    const withdrawal = { ...body, withdrawal_only: true };
    expect(send("verify", withdrawal, actor).body).toEqual({ items: [{ id: record.id, status: "private" }] });
    expect(send("batch", { ...withdrawal, batch_number: 2, records: [fixture()] }, actor).status).toBe(404);
    expect(send("finish", withdrawal, actor).status).toBe(404);
    expect(ctx.db.delete(record.id)).toBe(true);
    expect(send("verify", withdrawal, actor).body).toEqual({ items: [{ id: record.id, status: "deleted" }] });
    expect(send("changes", { ...withdrawal, after: 0 }, actor).body).toMatchObject({
      changes: [{ id: record.id, kind: "private" }, { id: record.id, kind: "deleted" }],
    });
  } finally { ctx.cleanup(); }
});

test("an empty batch fence makes an unconfirmed larger upload ineligible to commit later", () => {
  const ctx = setup();
  try {
    const { send, batch, session_id } = importFixture(ctx.db);
    const record = fixture();
    expect(batch(1, []).status).toBe(400);
    const fence = { session_id, batch_number: 1, records: [], seal_empty: true };
    expect(send("batch", fence).body).toMatchObject({ items: [], counts: {
      added: 0, exists: 0, deleted: 0, conflict: 0, rejected: 0,
    } });
    expect(send("batch", fence).status).toBe(200);
    expect(batch(1, [record])).toEqual({ status: 409, body: { error: "batch_changed" } });
    expect(ctx.db.get(record.id)).toBeNull();
  } finally { ctx.cleanup(); }
});
