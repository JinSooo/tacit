import { expect, test } from "bun:test";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import type { RecordV1 } from "../../packages/record/index.ts";
import { collect, type State } from "./main.ts";

const base = Date.parse("2026-11-27T02:00:00Z");
const date = (minute: number) => new Date(base + minute * 60_000).toISOString();

test("Qwen Code 只读有逐条时间的真实对话，沿用旧 checkpoint 和增量偏移", async () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "ra-qwen-test-"));
  try {
    const qwenDir = path.join(root, "qwen");
    const claudeDir = path.join(root, "claude");
    const codexDir = path.join(root, "codex");
    const write = (file: string, events: unknown[], append = false) => {
      fs.mkdirSync(path.dirname(file), { recursive: true });
      fs.writeFileSync(file, events.map(event => JSON.stringify(event)).join("\n") + "\n", { flag: append ? "a" : "w" });
      fs.utimesSync(file, base / 1000, base / 1000);
    };
    const run = async (state?: State, minute = 29) => {
      const records: RecordV1[] = [];
      const next = await collect({
        device: "test", now: base + minute * 60_000, state, qwenDir, claudeDir, codexDir, antigravityDir: root, geminiDir: root,
        onRecord: record => { records.push(record); },
        onWarning: warning => { throw new Error(warning); },
      });
      return { records, state: next };
    };
    write(path.join(claudeDir, "projects/demo/old.jsonl"), [
      { type: "user", sessionId: "old", timestamp: date(1), message: { content: "合成旧输入" } },
    ]);
    const legacy = await run();
    expect(legacy.records.map(record => record.body)).toEqual(["[我] 合成旧输入"]);

    const file = path.join(qwenDir, "projects/synthetic-demo/chats/ses-qwen-001.jsonl");
    const common = { cwd: "/synthetic/demo", sessionId: "ses-qwen-001", version: "0.28.7" };
    const user = { ...common, uuid: "u-001", parentUuid: null, timestamp: date(20), type: "user",
      message: { role: "user", parts: [{ text: "<system-reminder>忽略注入</system-reminder>\n给 CSV 加转义" }] } };
    const intermediate = { ...common, uuid: "u-002", parentUuid: "u-001", timestamp: date(21), type: "assistant",
      message: { role: "model", parts: [{ text: "忽略思考", thought: true }, { functionCall: { name: "read_file" } }] } };
    const tool = { ...common, uuid: "u-003", parentUuid: "u-002", timestamp: date(22), type: "tool_result",
      message: { role: "user", parts: [{ functionResponse: { response: { output: "忽略工具结果" } } }] } };
    const reply = { ...common, uuid: "u-004", parentUuid: "u-003", timestamp: date(23), type: "assistant",
      message: { role: "model", parts: [{ text: "已处理引号和换行" }, { inlineData: { data: "忽略图片" } }] } };
    const noise = { ...user, message: { role: "user", parts: [{ text: "忽略程序输入" }] } };
    const subtypes = ["agent_mention", "agent_message", "notification", "background_task_completed", "cron", "agent_bootstrap", "agent_launch_prompt", "agent_retry"];
    write(file, [
      user,
      { ...user, timestamp: date(21), backgroundTurn: false, message: { role: "user", parts: [{ text: "保留 false 的消息" }] } },
      { ...user, timestamp: date(22), backgroundTurn: null, message: { role: "user", parts: [{ text: "保留 null 的消息" }] } },
      intermediate, tool, reply, ...subtypes.map(subtype => ({ ...noise, subtype })),
      { ...noise, type: "system", subtype: "chat_compression" }, { ...noise, backgroundTurn: true }, { ...noise, backgroundTurn: { id: "task" } },
      { ...noise, externalInputKind: "notification" }, { ...noise, clientInitiatedSkills: true },
      { ...noise, timestamp: undefined }, { ...noise, agentId: "subagent", cwd: "/synthetic/child" },
    ]);
    write(path.join(path.dirname(file), "child.jsonl"), [
      { ...user, sessionId: "child", isSidechain: true }, { ...reply, sessionId: "child", agentId: "subagent" },
    ]);
    const first = await run(legacy.state);
    expect(first.records.map(record => [record.source, record.source_ref, record.context?.cwd, record.body])).toEqual([
      ["qwen_code.session", "ses-qwen-001#2026-11-27T02:00:00.000Z", "/synthetic/demo", "[我] 给 CSV 加转义\n\n[我] 保留 false 的消息\n\n[我] 保留 null 的消息\n\n[AI] 已处理引号和换行"],
    ]);
    expect(Date.parse(first.records[0]!.t_end!)).toBe(Date.parse(date(23)));
    expect(first.state.files[file]?.offset).toBe(fs.statSync(file).size);

    write(file, [{ ...reply, uuid: "u-005", timestamp: date(30), message: { role: "model", parts: [{ text: "导出测试通过" }] } }], true);
    const second = await run(first.state, 34);
    expect(second.records.map(record => [record.source_ref, record.body])).toEqual([
      ["ses-qwen-001#2026-11-27T02:00:00.000Z#2", "[AI] 导出测试通过"],
    ]);
    expect((await run(second.state, 39)).records).toEqual([]);
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});
