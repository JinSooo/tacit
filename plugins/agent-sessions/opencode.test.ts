import { expect, test } from "bun:test";
import { Database } from "bun:sqlite";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import type { RecordV1 } from "../../packages/record/index.ts";
import { collect, type State } from "./main.ts";

const base = Date.parse("2026-11-27T02:00:00Z");
const at = (minute: number) => base + minute * 60_000;
const cwd = "/synthetic/demo";

function setup() {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "ra-opencode-test-"));
  const file = path.join(root, "opencode.db");
  const claudeDir = path.join(root, "claude");
  const run = async (state?: State, minute = 30) => {
    const records: RecordV1[] = [];
    const warnings: string[] = [];
    const next = await collect({
      device: "test", now: at(minute), state, opencodeDir: root, claudeDir, codexDir: root,
      antigravityDir: root, geminiDir: root, qwenDir: root,
      onRecord: record => { records.push(record); }, onWarning: warning => { warnings.push(warning); },
    });
    return { records, warnings, state: next };
  };
  const database = (wal: boolean) => {
    const db = new Database(file);
    db.exec(`
      PRAGMA journal_mode = ${wal ? "WAL" : "DELETE"};
      PRAGMA wal_autocheckpoint = 0;
      CREATE TABLE session (id TEXT PRIMARY KEY, parent_id TEXT, directory TEXT, time_updated INTEGER);
      CREATE TABLE message (id TEXT PRIMARY KEY, session_id TEXT, time_created INTEGER, time_updated INTEGER, data TEXT);
      CREATE TABLE part (id TEXT PRIMARY KEY, message_id TEXT, session_id TEXT, time_updated INTEGER, data TEXT);
    `);
    db.run("INSERT INTO session VALUES ('ses-main', NULL, ?, ?), ('ses-child', 'ses-main', ?, ?)", [cwd, at(20), cwd, at(20)]);
    return db;
  };
  return { root, file, run, database, claudeDir };
}

function message(db: Database, id: string, minute: number, role: string, data = {}, session = "ses-main", updated = at(minute)) {
  db.run("INSERT INTO message VALUES (?, ?, ?, ?, ?)", [id, session, at(minute), updated, JSON.stringify({ role, time: { created: at(minute) }, ...data })]);
}

function part(db: Database, id: string, messageId: string, data: object, updated: number, session = "ses-main") {
  db.run("INSERT INTO part VALUES (?, ?, ?, ?, ?)", [id, messageId, session, updated, JSON.stringify(data)]);
}

test("OpenCode 读 WAL 可见对话，等流式回复写完，并沿用旧 checkpoint 和更新时间游标", async () => {
  const s = setup();
  let db: Database | undefined;
  try {
    const claude = path.join(s.claudeDir, "projects/demo/old.jsonl");
    fs.mkdirSync(path.dirname(claude), { recursive: true });
    const oldMessage = { type: "user", sessionId: "old", timestamp: new Date(at(1)).toISOString(), message: { content: "合成旧输入" } };
    fs.writeFileSync(claude, JSON.stringify(oldMessage) + "\n");
    const legacy = await s.run();
    expect(legacy.records.map(record => record.body)).toEqual(["[我] 合成旧输入"]);
    expect(legacy.state.databases).toBeUndefined();

    db = s.database(true);
    message(db, "msg-user", 1, "user");
    part(db, "prt-01", "msg-user", { type: "text", text: "<hook-output>忽略</hook-output>\n给商品详情加空值缓存" }, at(1));
    part(db, "prt-02", "msg-user", { type: "text", text: "忽略合成文本", synthetic: true }, at(1));
    part(db, "prt-03", "msg-user", { type: "text", text: "忽略隐藏文本", ignored: true }, at(1));

    message(db, "msg-answer", 2, "assistant", { time: { created: at(2), completed: at(3) } });
    part(db, "prt-04", "msg-answer", { type: "reasoning", text: "忽略思考" }, at(2));
    part(db, "prt-05", "msg-answer", { type: "tool", state: { output: "忽略工具" } }, at(2));
    part(db, "prt-06", "msg-answer", { type: "text", text: "  ## Skills\n- TypeScript  " }, at(3));

    message(db, "msg-compact-user", 4, "user");
    part(db, "prt-07", "msg-compact-user", { type: "text", text: "忽略压缩请求" }, at(4));
    part(db, "prt-08", "msg-compact-user", { type: "compaction", auto: true }, at(4));
    message(db, "msg-compact-ai", 5, "assistant", { agent: "compaction", mode: "compaction", summary: true });
    part(db, "prt-09", "msg-compact-ai", { type: "text", text: "忽略压缩结果" }, at(5));

    message(db, "msg-streaming", 6, "assistant");
    part(db, "prt-10", "msg-streaming", { type: "text", text: "忽略还没写完的回复" }, at(6));
    message(db, "msg-last-user", 20, "user");
    part(db, "prt-11", "msg-last-user", { type: "text", text: "再补一个用例" }, at(20));
    message(db, "msg-child", 21, "user", {}, "ses-child");
    part(db, "prt-12", "msg-child", { type: "text", text: "忽略子会话" }, at(21), "ses-child");

    const first = await s.run(legacy.state);
    expect(first.records.map(record => [record.source, record.source_ref, record.context?.cwd, record.body])).toEqual([
      ["opencode.session", "ses-main#2026-11-27T02:00:00.000Z", cwd, "[我] 给商品详情加空值缓存\n\n[AI] ## Skills\n- TypeScript\n\n[我] 再补一个用例"],
    ]);
    expect(Date.parse(first.records[0]!.t_start)).toBe(at(1));
    expect(Date.parse(first.records[0]!.t_end!)).toBe(at(20));
    expect(first.warnings).toEqual([]);
    expect(first.state.databases?.[s.file]?.updated).toBe(at(5));

    // 流式块写回时，消息列还保留旧更新时间；块在上一次扫描的同一毫秒更新。
    db.run("UPDATE message SET data = ? WHERE id = 'msg-streaming'", [JSON.stringify({ role: "assistant", time: { created: at(6), completed: at(20) } })]);
    db.run("UPDATE part SET time_updated = ?, data = ? WHERE id = 'prt-10'", [at(20), JSON.stringify({ type: "text", text: "已补测试" })]);
    const second = await s.run(first.state, 35);
    expect(second.records.map(record => [record.source_ref, record.body])).toEqual([
      ["ses-main#2026-11-27T02:00:00.000Z#2", "[AI] 已补测试"],
    ]);
    expect((await s.run(second.state, 40)).records).toEqual([]);
  } finally {
    db?.close();
    fs.rmSync(s.root, { recursive: true, force: true });
  }
});

test("OpenCode 遇到数据库锁时保持游标，下次继续读取", async () => {
  const s = setup();
  let db: Database | undefined;
  try {
    db = s.database(false);
    message(db, "msg-first", 1, "user");
    part(db, "prt-01", "msg-first", { type: "text", text: "合成首条" }, at(1));
    const first = await s.run();
    expect(first.records.map(record => record.body)).toEqual(["[我] 合成首条"]);

    db.exec("BEGIN EXCLUSIVE");
    message(db, "msg-second", 23, "user");
    part(db, "prt-02", "msg-second", { type: "text", text: "合成第二条" }, at(23));
    const locked = await s.run(first.state);
    expect(locked.records).toEqual([]);
    expect(locked.warnings).toEqual([]);
    expect(locked.state.databases).toEqual(first.state.databases);
    db.exec("COMMIT");
    expect((await s.run(locked.state)).records.map(record => record.body)).toEqual(["[我] 合成第二条"]);
  } finally {
    db?.close();
    fs.rmSync(s.root, { recursive: true, force: true });
  }
});

test("OpenCode 读取冷 WAL 库时不创建 sidecar，未知消息进入格式统计", async () => {
  const s = setup();
  try {
    const db = s.database(true);
    try {
      for (let i = 0; i < 20; i++) message(db, `msg-${i}`, 1, "new-role");
      db.exec("PRAGMA wal_checkpoint(TRUNCATE)");
    } finally {
      db.close();
    }
    fs.rmSync(s.file + "-shm", { force: true });
    fs.rmSync(s.file + "-wal", { force: true });
    const first = await s.run();
    expect(first.records).toEqual([]);
    expect(first.warnings).toEqual(["AI 会话格式可能已变化，有 20 行没有识别"]);
    expect(fs.readdirSync(s.root)).toEqual(["opencode.db"]);
    expect((await s.run(first.state)).warnings).toEqual([]);
  } finally {
    fs.rmSync(s.root, { recursive: true, force: true });
  }
});

test("OpenCode 未完成消息挡住游标，稍后提交的早时间戳消息仍可采到", async () => {
  const s = setup();
  let db: Database | undefined;
  try {
    db = s.database(true);
    message(db, "msg-first", 1, "user");
    part(db, "prt-first", "msg-first", { type: "text", text: "合成首条" }, at(1));
    message(db, "msg-streaming", 6, "assistant");
    message(db, "msg-later", 20, "user");
    part(db, "prt-later", "msg-later", { type: "text", text: "合成后续" }, at(20));
    const first = await s.run();
    expect(first.records.map(record => record.body)).toEqual(["[我] 合成首条\n\n[我] 合成后续"]);
    // 另一个会话在快照之后写入，比当时未完成的消息还早。
    message(db, "msg-late-commit", 4, "user", {}, "ses-main", at(5) + 1);
    part(db, "prt-late", "msg-late-commit", { type: "text", text: "并行提交的确认" }, at(5) + 1);
    const late = await s.run(first.state, 32);
    expect(late.records.map(record => record.body)).toEqual(["[我] 并行提交的确认"]);

    expect(late.state.databases?.[s.file]?.updated).toBe(at(5) + 1);
  } finally {
    db?.close();
    fs.rmSync(s.root, { recursive: true, force: true });
  }
});
