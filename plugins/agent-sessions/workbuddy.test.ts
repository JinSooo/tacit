import { expect, test } from "bun:test";
import { at, sessionFixture } from "./adapter-fixture.ts";

const user = (text: string, extra = {}) => ({
  type: "message", role: "user", timestamp: at(1), cwd: "/Users/alice/work",
  content: [{ type: "input_text", text }], ...extra,
});
const reply = (text: string, minute: number) => ({
  type: "message", role: "assistant", status: "completed", timestamp: at(minute), content: [{ type: "output_text", text }],
});

test("WorkBuddy 缺省目录安静跳过，按同源格式独立识别来源、过滤并续用游标", async () => {
  const s = sessionFixture();
  try {
    const empty = await s.run({}, s.oldCheckpoint());
    expect(empty.records).toEqual([]);
    expect(empty.diagnostics).toEqual([]);
    const dir = "workbuddy/projects/compressed";
    const target = s.file(`${dir}/same-id.jsonl`);
    s.write(s.file("codebuddy/projects/compressed/same-id.jsonl"), [user("CLI 项目")]);
    s.write(target, [
      user("<system-reminder data-role=\"hook\">钩子输出</system-reminder>\n核对导入表"),
      user("系统消息", { providerData: { isMeta: true } }),
      { type: "function_call", timestamp: at(2), name: "read", arguments: "工具输入" },
      { type: "function_call_output", timestamp: at(3), output: "工具输出" },
      { type: "summary", timestamp: at(4), content: "压缩摘要" },
      reply("已核对三个字段。", 5),
    ]);
    s.write(s.file(`${dir}/same-id/subagents/agent-child.jsonl`), [user("子 Agent 路径")]);
    s.write(s.file(`${dir}/sidechain.jsonl`), [user("侧链", { isSidechain: true }), reply("侧链回复", 2)]);
    s.write(s.file("workbuddy-ai/projects/compressed/other.jsonl"), [user("未经证实的目录")]);
    const first = await s.run({}, empty.state);
    expect(first.diagnostics).toEqual([]);
    expect(first.records.map(r => r.source)).toEqual(["codebuddy.session", "workbuddy.session"]);
    expect(first.records[1]).toMatchObject({
      source_ref: `same-id#${at(0)}`, body: "[我] 核对导入表\n\n[AI] 已核对三个字段。",
      context: { app: "workbuddy", cwd: "/Users/alice/work" },
    });
    expect(Date.parse(first.records[1]!.t_end!)).toBe(Date.parse(at(5)));
    s.write(target, [reply("已去掉空列。", 20)], true);
    s.appendLegacy();
    const next = await s.run({}, first.state);
    expect(next.records.map(r => [r.source, r.source_ref, r.body])).toEqual([
      ["claude_code.session", `old#${at(0)}#2`, "[我] 旧来源的新消息"],
      ["workbuddy.session", `same-id#${at(0)}#2`, "[AI] 已去掉空列。"],
    ]);
    expect(next.records[1]?.context?.cwd).toBe("/Users/alice/work");
    expect((await s.run({}, next.state)).records).toEqual([]);
  } finally { s.close(); }
});
