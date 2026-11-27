import { expect, test } from "bun:test";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import type { RecordV1 } from "../../packages/record/index.ts";
import { collect, type State } from "./main.ts";

const base = Date.parse("2026-11-27T02:00:00Z");
const date = (minute: number) => new Date(base + minute * 60_000).toISOString();

test("Gemini CLI 只读主会话，续用旧 checkpoint 并按字节导入新增消息", async () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "ra-gemini-test-"));
  try {
    const geminiDir = path.join(root, "gemini");
    const claudeDir = path.join(root, "claude");
    const codexDir = path.join(root, "codex");
    const claude = path.join(claudeDir, "projects/demo/old.jsonl");
    const transcript = "session-2026-11-27T02-15-a1b2c3d4.jsonl";
    const write = (file: string, events: unknown[], append = false) => {
      fs.mkdirSync(path.dirname(file), { recursive: true });
      fs.writeFileSync(file, events.map(event => JSON.stringify(event)).join("\n") + "\n", { flag: append ? "a" : "w" });
      fs.utimesSync(file, base / 1000, base / 1000);
    };
    const run = async (state?: State, minute = 24) => {
      const records: RecordV1[] = [];
      const warnings: string[] = [];
      const next = await collect({
        device: "test", now: base + minute * 60_000, state, claudeDir, codexDir, geminiDir, antigravityDir: root,
        onRecord: record => { records.push(record); }, onWarning: warning => { warnings.push(warning); },
      });
      return { records, warnings, state: next };
    };
    write(claude, [{ type: "user", sessionId: "old", timestamp: date(1), message: { content: "合成旧输入" } }]);
    const legacy = await run();
    expect(legacy.records.map(record => record.body)).toEqual(["[我] 合成旧输入"]);

    const project = path.join(geminiDir, "tmp/demo");
    const file = path.join(project, "chats", transcript);
    const id = "a1b2c3d4-1111-4222-8333-444455556666";
    const metadata = { sessionId: id, kind: "main", directories: ["/synthetic/metadata"] };
    const user = { id: "m-001", timestamp: date(15), type: "user", content: [{ text: "<hook-output>忽略钩子</hook-output>\n修改分页" }, "使用游标"] };
    const reply = { id: "m-002", timestamp: date(16), type: "gemini", content: "已补充单测", thoughts: [{ description: "忽略思考" }], toolCalls: [{ name: "忽略工具" }] };
    write(path.join(geminiDir, "projects.json"), [{ projects: { "/synthetic/demo": "demo" } }]);
    fs.mkdirSync(project, { recursive: true });
    fs.writeFileSync(path.join(project, ".project_root"), "/synthetic/marker\n");
    write(file, [
      metadata, user, reply,
      { ...reply, id: "info", type: "info" },
      { ...reply, id: "tool", content: [{ text: "忽略思考", thought: true }, { functionCall: { name: "ignored" } }] },
      { ...user, id: "no-time", timestamp: undefined },
      { $set: { messages: ["忽略元数据"] } }, { $patch: { id: reply.id, content: "忽略补丁" } }, { $rewindTo: user.id },
    ]);
    write(path.join(project, "chats", id, transcript), [metadata, user]);
    write(path.join(project, "chats/session-subagent-abcd.jsonl"), [{ sessionId: "child", kind: "subagent" }, user]);
    write(path.join(geminiDir, "antigravity/tmp/demo/chats", transcript), [metadata, user]);
    const first = await run(legacy.state);
    expect(first.records.map(record => [record.source, record.source_ref, record.context?.cwd, record.body])).toEqual([
      ["gemini_cli.session", `${id}#2026-11-27T02:00:00.000Z`, "/synthetic/demo", "[我] 修改分页\n使用游标\n\n[AI] 已补充单测"],
    ]);
    expect(Date.parse(first.records[0]!.t_start)).toBe(Date.parse(date(15)));
    expect(first.state.files[file]?.offset).toBe(fs.statSync(file).size);
    expect(first.warnings).toEqual([]);

    write(file, [{ id: "m-003", timestamp: date(25), type: "gemini", content: { text: "翻页测试通过" } }], true);
    const second = await run(first.state, 30);
    expect(second.records.map(record => [record.source_ref, record.body])).toEqual([
      [`${id}#2026-11-27T02:00:00.000Z#2`, "[AI] 翻页测试通过"],
    ]);
    expect((await run(second.state, 35)).records).toEqual([]);
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});
