import { expect, test } from "bun:test";
import fs from "node:fs";
import { at, sessionFixture } from "./adapter-fixture.ts";

const event = (type: string, data: object, minute = 1) => ({ id: `ev-${minute}`, type, timestamp: at(minute), data });

test("Copilot CLI 读取可见正文和 workspace cwd，过滤元事件及子 Agent，续用旧 checkpoint 和增量游标", async () => {
  const s = sessionFixture();
  try {
    const dir = "copilot/session-state/main";
    const target = s.file(`${dir}/events.jsonl`);
    fs.writeFileSync(s.file(`${dir}/workspace.yaml`), "cwd: '/Users/alice/it''s # demo' # workspace\nbranch: main\n");
    s.write(target, [
      event("session.start", { sessionId: "main", context: { cwd: "/Users/alice/from-start" } }, 0),
      event("user.message", { content: "<system-reminder>注入</system-reminder>\n给回调加验签", transformedContent: "含注入的模型输入" }),
      event("user.message", { content: "自动续跑", isAutopilotContinuation: true }, 2),
      event("user.message", { content: "子任务", parentAgentTaskId: "task" }, 3),
      event("user.message", { content: "Agent 投递", causalDependencies: [{ id: "another" }] }, 4),
      event("assistant.message", { content: "子 Agent 回复", parentToolCallId: "tc-1" }, 5),
      event("assistant.message", { content: "", reasoningText: "内部思考", toolRequests: [{ toolCallId: "tc-1" }] }, 6),
      ...["session.compaction_summarized", "tool.execution_complete", "subagent.completed"].map(type => event(type, { content: "元事件" }, 7)),
      event("assistant.message", { content: "已加 HMAC 验签。" }, 8),
    ]);
    s.write(s.file("copilot/session-state/old.jsonl"), [event("user.message", { content: "旧版平铺文件" })]);
    const child = s.file("copilot/session-state/child/events.jsonl");
    s.write(child, [
      event("session.start", { sessionId: "child", detachedFromSpawningParentSessionId: "main" }, 0),
      event("user.message", { content: "派生会话正文" }),
    ]);
    const first = await s.run({}, s.oldCheckpoint());
    expect(first.diagnostics).toEqual([]);
    expect(first.records).toHaveLength(1);
    expect(first.records[0]).toMatchObject({
      source: "copilot_cli.session", source_ref: `main#${at(0)}`,
      body: "[我] 给回调加验签\n\n[AI] 已加 HMAC 验签。",
      context: { app: "copilot-cli", cwd: "/Users/alice/it's # demo" },
    });
    expect(Date.parse(first.records[0]!.t_end!)).toBe(Date.parse(at(8)));
    expect(Object.keys(first.state.sessions).sort()).toEqual(["claude:old", "copilot-cli:main"]);

    s.write(target, [event("assistant.message", { content: "已补单测。" }, 20)], true);
    s.write(child, [event("assistant.message", { content: "派生会话的追加" }, 20)], true);
    s.appendLegacy();
    const next = await s.run({}, first.state);
    expect(next.records.map(r => [r.source_ref, r.body])).toEqual([
      [`old#${at(0)}#2`, "[我] 旧来源的新消息"],
      [`main#${at(0)}#2`, "[AI] 已补单测。"],
    ]);
    expect((await s.run({}, next.state)).records).toEqual([]);
  } finally { s.close(); }
});

test("Copilot CLI 跨采集轮次按原顺序拼接同一次回复的文本片段", async () => {
  const s = sessionFixture();
  try {
    const target = s.file("copilot/session-state/chunks/events.jsonl");
    fs.writeFileSync(s.file("copilot/session-state/chunks/workspace.yaml"), "cwd: { unexpected: value }\n");
    s.write(target, [
      event("user.message", { content: "给出验证结论" }),
      event("assistant.message", { apiCallId: "call", chunkCount: 2, chunkIndex: 0, content: "已完成 " }, 2),
      event("tool.execution_complete", { content: "工具输出" }, 3),
    ]);
    const first = await s.run({ now: Date.parse(at(2)) });
    expect(first.records).toEqual([]);
    s.write(target, [event("assistant.message", { apiCallId: "call", chunkCount: 2, chunkIndex: 1, content: "HMAC 验签。" }, 4)], true);
    const next = await s.run({}, first.state);
    expect(next.records.map(r => r.body)).toEqual(["[我] 给出验证结论\n\n[AI] 已完成 HMAC 验签。"]);
    expect(next.records[0]?.context?.cwd).toBeNull();
    expect(Date.parse(next.records[0]!.t_start)).toBe(Date.parse(at(1)));
    expect(next.diagnostics).toEqual([]);
    expect((await s.run({}, next.state)).records).toEqual([]);
  } finally { s.close(); }
});

test("Copilot CLI 安静三分钟后输出缺尾的回复，workspace cwd 缺失时使用 git_root", async () => {
  const s = sessionFixture();
  try {
    const dir = "copilot/session-state/interrupted";
    const target = s.file(`${dir}/events.jsonl`);
    fs.writeFileSync(s.file(`${dir}/workspace.yaml`), "git_root: '/synthetic/project' # workspace\n");
    s.write(target, [
      event("user.message", { content: "合成问题" }),
      event("assistant.message", { apiCallId: "call", chunkCount: 2, chunkIndex: 0, content: "已收到的分片" }, 2),
      event("tool.execution_complete", {}, 2),
    ]);
    const active = await s.run({ now: Date.parse(at(2)) });
    expect(active.records).toEqual([]);
    const idle = await s.run({ now: Date.parse(at(3)) }, active.state);
    expect(idle.records.map(r => [r.body, r.context?.cwd])).toEqual([
      ["[我] 合成问题\n\n[AI] 已收到的分片", "/synthetic/project"],
    ]);
    expect(idle.state.files[target]?.offset).toBe(fs.statSync(target).size);
    expect((await s.run({}, idle.state)).records).toEqual([]);
  } finally { s.close(); }
});
