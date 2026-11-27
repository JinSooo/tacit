import { afterEach, expect, test } from "bun:test";
import { Database } from "bun:sqlite";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { pathToFileURL } from "node:url";
import type { RecordV1 } from "../../packages/record/index.ts";
import { collect, type State } from "./main.ts";

const base = Date.parse("2026-11-07T10:00:00Z");
const minute = 60_000;
const temporary: string[] = [];
afterEach(() => { for (const dir of temporary.splice(0)) fs.rmSync(dir, { recursive: true, force: true }); });

function setup() {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "ra-antigravity-test-"));
  temporary.push(root);
  const antigravityDir = path.join(root, "gemini");
  const claudeDir = path.join(root, "claude");
  const codexDir = path.join(root, "codex");
  const data = (app = "antigravity") => path.join(antigravityDir, app);
  const logs = (id: string, app?: string) => path.join(data(app), "brain", id, ".system_generated", "logs");
  const write = (file: string, events: unknown[], mtime = base, append = false) => {
    fs.mkdirSync(path.dirname(file), { recursive: true });
    const lines = events.map(event => JSON.stringify(event)).join("\n") + "\n";
    fs.writeFileSync(file, lines, { flag: append ? "a" : "w" });
    fs.utimesSync(file, mtime / 1000, mtime / 1000);
  };
  const summaries = (rows: [id: string, workspace: string, parent?: string, depth?: number][], app?: string) => {
    const file = path.join(data(app), "conversation_summaries.db");
    fs.mkdirSync(path.dirname(file), { recursive: true });
    const db = new Database(file);
    try {
      db.exec(`
        PRAGMA journal_mode = WAL;
        CREATE TABLE IF NOT EXISTS conversation_summaries (
          conversation_id TEXT PRIMARY KEY, workspace_uris TEXT,
          parent_conversation_id TEXT, nesting_depth INTEGER
        );
      `);
      const insert = db.query("INSERT OR REPLACE INTO conversation_summaries VALUES (?, ?, ?, ?)");
      for (const [id, workspace, parent = "", depth = 0] of rows) insert.run(id, workspace, parent, depth);
      insert.finalize();
      db.exec("PRAGMA wal_checkpoint(TRUNCATE)");
    } finally { db.close(); }
    // Bun 的 SQLite 在关闭写入连接后可能仍留空 sidecar，模拟已归档的 WAL 库。
    fs.rmSync(file + "-shm", { force: true });
    fs.rmSync(file + "-wal", { force: true });
    return file;
  };
  const run = async (state?: State, now = base + 10 * minute) => {
    const records: RecordV1[] = [];
    const warnings: { unrecognized?: number; damaged?: number }[] = [];
    const next = await collect({
      device: "mac", claudeDir, codexDir, antigravityDir, now, state,
      onRecord: record => { records.push(record); },
      onWarning: () => {}, onDiagnostics: diagnostic => { warnings.push(diagnostic); },
    });
    return { records, state: next, warnings };
  };
  return { root, data, logs, write, summaries, run, claudeDir, codexDir };
}

function step(type: string, content?: unknown, minutes = 1, source = type === "USER_INPUT" ? "USER_EXPLICIT" : "MODEL") {
  return { type, source, content, created_at: new Date(base + minutes * minute).toISOString(), status: "DONE" };
}

test("Antigravity 只采可见消息，优先读完整转录，三个目录之外不采", async () => {
  const s = setup();
  const project = path.join(s.root, "合成 project");
  fs.mkdirSync(path.join(project, ".git"), { recursive: true });
  const summary = s.summaries([["desktop", JSON.stringify(["https://invalid", pathToFileURL(project).href, "/synthetic/second"])]]);
  const logs = s.logs("desktop");
  s.write(path.join(logs, "transcript_full.jsonl"), [
    step("USER_INPUT", "<system-reminder>忽略注入</system-reminder>\n修复合成页面"),
    { ...step("PLANNER_RESPONSE", undefined, 2), thinking: "忽略思考", tool_calls: [{ args: { content: "忽略工具" } }] },
    step("GENERIC", "忽略工具结果", 2),
    step("CHECKPOINT", "忽略中间步骤", 2),
    step("PLANNER_RESPONSE", "  合成页面已修复  ", 3),
  ]);
  s.write(path.join(logs, "transcript.jsonl"), [step("USER_INPUT", "忽略同目录短版")]);
  s.write(path.join(logs, "chunks/transcript_full/transcript_full.jsonl"), [step("USER_INPUT", "忽略分片")]);
  s.write(path.join(s.logs("hosted", "antigravity-acp"), "transcript_full.jsonl"), [step("USER_INPUT", "忽略托管数据")]);
  s.write(path.join(s.logs("cli", "antigravity-cli"), "transcript.jsonl"), [step("USER_INPUT", "合成 CLI 请求")]);
  s.summaries([["ide", "/synthetic/ide\nfile:///synthetic/second"]], "antigravity-ide");
  s.write(path.join(s.logs("ide", "antigravity-ide"), "transcript_full.jsonl"), [step("USER_INPUT", "合成 IDE 请求")]);

  const { records, warnings } = await s.run();
  expect(records.map(record => record.body)).toEqual(["[我] 修复合成页面\n\n[AI] 合成页面已修复", "[我] 合成 CLI 请求", "[我] 合成 IDE 请求"]);
  expect(records[0]).toMatchObject({
    source: "antigravity.session",
    source_ref: "desktop#2026-11-07T10:00:00.000Z",
    title: "Antigravity · 合成 project · 修复合成页面",
    context: { app: "antigravity", cwd: project, repo: project },
  });
  expect(Date.parse(records[0]!.t_start)).toBe(base + minute);
  expect(Date.parse(records[0]!.t_end!)).toBe(base + 3 * minute);
  expect(records[1]!.context?.cwd).toBeNull();
  expect(records[2]!.context?.cwd).toBe("/synthetic/ide");
  expect(warnings).toEqual([]);
  expect(fs.existsSync(summary + "-shm")).toBe(false);
  expect(fs.existsSync(summary + "-wal")).toBe(false);
});

test("Antigravity 跳过两种子会话标记，也撤下后来才识别出的待发送子会话", async () => {
  const s = setup();
  s.summaries([["by-parent", "", "parent"], ["by-depth", "", "", 1]]);
  for (const id of ["parent", "by-parent", "by-depth", "late"]) {
    s.write(path.join(s.logs(id), "transcript_full.jsonl"), [step("USER_INPUT", id)], base + minute);
  }
  const pending = await s.run(undefined, base + 2 * minute);
  expect(pending.records).toEqual([]);
  expect(Object.keys(pending.state.sessions).sort()).toEqual(["antigravity:late", "antigravity:parent"]);
  s.summaries([["late", "", "parent"]]);
  const { records, state } = await s.run(pending.state);
  expect(records.map(record => record.body)).toEqual(["[我] parent"]);
  expect(Object.keys(state.sessions)).toEqual(["antigravity:parent"]);
});

test("Antigravity 元数据库损坏时照常产出，异常字段组合进入格式告警", async () => {
  const s = setup();
  const file = path.join(s.logs("visible"), "transcript_full.jsonl");
  s.write(file, [step("USER_INPUT", "合成输入"), step("PLANNER_RESPONSE", "合成回复")]);
  fs.writeFileSync(path.join(s.data(), "conversation_summaries.db"), "invalid synthetic database");
  const invalid = [
    step("USER_INPUT", "未知来源", 1, "NEW_SOURCE"),
    step("PLANNER_RESPONSE", ["错误正文"]),
    { ...step("USER_INPUT", "错误时间"), created_at: "bad-time" },
    { content: "没有类型" },
  ];
  s.write(path.join(s.logs("unknown"), "transcript_full.jsonl"), Array.from({ length: 20 }, (_, i) => invalid[i % invalid.length]));
  const { records, warnings } = await s.run();
  expect(records.map(record => record.body)).toEqual(["[我] 合成输入\n\n[AI] 合成回复"]);
  expect(records[0]!.context?.cwd).toBeNull();
  expect(warnings).toEqual([{ unrecognized: 20 }]);
});

test("Antigravity 以旧文件偏移只采追加内容并延续 part", async () => {
  const s = setup();
  const file = path.join(s.logs("append"), "transcript_full.jsonl");
  s.write(file, [step("USER_INPUT", "合成问题")]);
  const first = await s.run();
  expect(first.records.map(record => record.body)).toEqual(["[我] 合成问题"]);
  const offset = fs.statSync(file).size;
  expect(first.state.files[file]?.offset).toBe(offset);
  s.write(file, [step("PLANNER_RESPONSE", "合成后续", 12)], base + 12 * minute, true);
  const second = await s.run(first.state, base + 16 * minute);
  expect(second.records.map(record => [record.source_ref, record.body])).toEqual([["append#2026-11-07T10:00:00.000Z#2", "[AI] 合成后续"]]);
  expect(second.state.files[file]?.offset).toBe(fs.statSync(file).size);
  expect((await s.run(second.state, base + 20 * minute)).records).toEqual([]);
});

test("旧版 Claude Code 和 Codex checkpoint 与 Antigravity 一起续用，不重发旧消息", async () => {
  const s = setup();
  const claudeFile = path.join(s.claudeDir, "projects/demo/session.jsonl");
  const codexFile = path.join(s.codexDir, "sessions/rollout.jsonl");
  const date = (minutes: number) => new Date(base + minutes * minute).toISOString();
  const claude = (text: string, minutes: number) =>
    ({ type: "user", sessionId: "old-claude", timestamp: date(minutes), message: { role: "user", content: text } });
  const codex = (text: string, minutes: number) =>
    ({ type: "response_item", timestamp: date(minutes), payload: { type: "message", role: "user", content: text } });
  s.write(claudeFile, [claude("旧 Claude 合成文字", 1)]);
  s.write(codexFile, [{ type: "session_meta", payload: { id: "old-codex", cwd: s.root } }, codex("旧 Codex 合成文字", 1)]);
  const state: State = { version: 2, since: base, replaySince: base, files: {}, sessions: {} };
  for (const [provider, id, file] of [["claude", "old-claude", claudeFile], ["codex", "old-codex", codexFile]] as const) {
    const stat = fs.statSync(file);
    const session = `${provider}:${id}`;
    state.files[file] = { offset: stat.size, size: stat.size, mtime: stat.mtimeMs, identity: `${stat.dev}:${stat.ino}`, session, cwd: s.root };
    state.sessions[session] = { provider, id, cwd: s.root, seen: {}, buckets: { [base]: { part: 1, messages: [] } }, mtime: base };
  }
  s.write(claudeFile, [claude("新 Claude 合成文字", 2)], base + 2 * minute, true);
  s.write(codexFile, [codex("新 Codex 合成文字", 2)], base + 2 * minute, true);
  s.write(path.join(s.logs("new-agent"), "transcript_full.jsonl"), [step("USER_INPUT", "新 Antigravity 合成文字")]);
  const next = await s.run(state);
  expect(next.records.map(record => [record.source, record.source_ref, record.body])).toEqual([
    ["claude_code.session", "old-claude#2026-11-07T10:00:00.000Z#2", "[我] 新 Claude 合成文字"],
    ["codex.session", "old-codex#2026-11-07T10:00:00.000Z#2", "[我] 新 Codex 合成文字"],
    ["antigravity.session", "new-agent#2026-11-07T10:00:00.000Z", "[我] 新 Antigravity 合成文字"],
  ]);
  expect((await s.run(next.state)).records).toEqual([]);
});
