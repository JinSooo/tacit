import { expect, test } from "bun:test";
import fs from "node:fs";
import { at, sessionFixture } from "./adapter-fixture.ts";

const message = (role: string, text: string, minute = 1, extra = {}) => ({
  type: "message", role, timestamp: at(minute), cwd: "/Users/alice/demo",
  content: [{ type: role === "user" ? "input_text" : "output_text", text }], ...extra,
});

test("CodeBuddy 读取有逐条时间的可见正文，过滤钩子、工具、摘要、通知及子会话，续用游标", async () => {
  const s = sessionFixture();
  try {
    const dir = "codebuddy/projects/compressed";
    const target = s.file(`${dir}/main.jsonl`);
    s.write(target, [
      message("user", "<system-reminder data-role=\"hook\">钩子输出</system-reminder>\n把超时改成 10 秒"),
      message("user", "不是用户输入", 2, { isMeta: true }),
      message("user", "不是用户输入", 3, { providerData: { isMeta: true } }),
      message("user", "Agent 投递", 4, { providerData: { "runtime:initiator": "agent" } }),
      message("user", "系统通知", 5, { providerData: { interactionType: "notification" } }),
      message("assistant", "中间回复", 6, { status: "in_progress" }),
      message("user", "合成侧链", 7, { isSidechain: true, cwd: "/synthetic/sidechain" }),
      ...["function_call", "function_call_output", "function_call_result", "reasoning", "thinking", "summary", "topic", "resend-fork-notice"]
        .map(type => ({ type, timestamp: at(7), content: "中间记录" })),
      message("assistant", "已将默认超时改成 10000ms。", 8, { status: "completed", timestamp: undefined, __timestamp: at(8), cwd: undefined }),
    ]);
    s.write(s.file(`${dir}/main/subagents/agent-child.jsonl`), [message("user", "子 Agent 路径")]);
    s.write(s.file(`${dir}/sidechain.jsonl`), [
      message("user", "侧链", 2, { isSidechain: true }), message("assistant", "侧链回复", 3, { isSidechain: true }),
    ]);
    const invalid = message("user", "时间不可知", 3, { timestamp: undefined, time: at(3) });
    const wrapped = { item: message("user", "未知包装"), timestamp: at(3) };
    s.write(s.file(`${dir}/unknown.jsonl`), Array.from({ length: 20 }, (_, i) => i % 2 ? invalid : wrapped));

    const old = s.oldCheckpoint();
    const stat = fs.statSync(target);
    old.files[target] = { skipped: true, offset: stat.size, size: stat.size, mtime: stat.mtimeMs, identity: `${stat.dev}:${stat.ino}`, session: null };
    const first = await s.run({}, old);
    expect(first.diagnostics).toEqual([{ unrecognized: 20 }]);
    expect(first.records).toHaveLength(1);
    expect(first.records[0]).toMatchObject({
      source: "codebuddy.session", source_ref: `main#${at(0)}`,
      body: "[我] 把超时改成 10 秒\n\n[AI] 已将默认超时改成 10000ms。",
      context: { app: "codebuddy", cwd: "/Users/alice/demo" },
    });
    expect(Date.parse(first.records[0]!.t_end!)).toBe(Date.parse(at(8)));
    s.write(target, [message("assistant", "已补边界测试。", 20, { cwd: undefined })], true);
    s.appendLegacy();
    const next = await s.run({}, first.state);
    expect(next.diagnostics).toEqual([]);
    expect(next.records.map(r => [r.source_ref, r.body])).toEqual([
      [`old#${at(0)}#2`, "[我] 旧来源的新消息"],
      [`main#${at(0)}#2`, "[AI] 已补边界测试。"],
    ]);
    expect(next.records[1]?.context?.cwd).toBe("/Users/alice/demo");
    expect((await s.run({}, next.state)).records).toEqual([]);
  } finally { s.close(); }
});
