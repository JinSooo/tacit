import { expect, test } from "bun:test";
import { at, sessionFixture } from "./adapter-fixture.ts";

const start = (id: string, extra = {}) => ({ type: "session_start", id, cwd: "/Users/alice/demo", owner: "alice", ...extra });
const message = (role: string, content: unknown, timestamp: string | number = at(1), extra = {}) => ({
  type: "message", timestamp, message: { role, content, ...extra },
});

test("Droid 读取逐条 ISO 或毫秒时间，过滤注入、工具、思考和派生会话，续用游标", async () => {
  const s = sessionFixture();
  try {
    const target = s.file("factory/sessions/-Users-alice-demo/main.jsonl");
    s.write(target, [
      start("main", { lastCwd: "/Users/alice/demo/src" }),
      message("user", [{ type: "text", text: "<system-reminder>注入</system-reminder>\n上传重试最多 3 次" }]),
      message("assistant", [{ type: "thinking", thinking: "内部思考" }, { type: "tool_use", input: "工具请求" }]),
      message("user", [{ type: "tool_result", content: "工具结果" }]),
      ...[
        { systemNotice: true }, { visibility: "user_only" }, { visibility: "llm_only" },
        { hiddenFromUserViews: true }, { isUserVisible: false }, { hookEventName: "SessionStart" },
      ].map(flags => message("user", "隐藏的文本", at(2), flags)),
      { ...message("user", "内部提示"), id: "__internal__system-reminder__0" },
      message("user", "injected-summary-旧摘要"),
      message("user", "---BEGIN TASK FROM PARENT AGENT---"),
      { type: "compaction_state", timestamp: at(2), summaryText: "压缩后的文字" },
      message("assistant", [{ type: "text", text: "已改成指数退避重试。" }], Date.parse(at(3))),
    ]);
    s.write(s.file("factory/sessions/-Users-alice-demo/main.settings.json"), [message("user", "配置文件")]);
    const markers = [
      { callingSessionId: "main" }, { callingToolUseId: "call" }, { parent: "main" },
      { decompSessionType: "worker" }, { decompMissionId: "mission" }, { forkedAtMessageId: "from-message" },
      ...["subagent", "automation", "exec", "evaluation"].map(tag => ({ tags: [tag] })),
    ];
    for (const [i, marker] of markers.entries()) {
      s.write(s.file(`factory/sessions/-Users-alice-demo/child-${i}.jsonl`), [start(`child-${i}`, marker), message("user", "子会话")]);
    }
    const first = await s.run({}, s.oldCheckpoint());
    expect(first.diagnostics).toEqual([]);
    expect(first.records).toHaveLength(1);
    expect(first.records[0]).toMatchObject({
      source: "droid.session", source_ref: `main#${at(0)}`,
      body: "[我] 上传重试最多 3 次\n\n[AI] 已改成指数退避重试。",
      context: { app: "droid", cwd: "/Users/alice/demo/src" },
    });
    expect(Date.parse(first.records[0]!.t_start)).toBe(Date.parse(at(1)));
    expect(Date.parse(first.records[0]!.t_end!)).toBe(Date.parse(at(3)));
    expect(Object.keys(first.state.sessions).sort()).toEqual(["claude:old", "droid:main"]);

    s.write(target, [message("assistant", "也补了测试。", at(20))], true);
    s.write(s.file("factory/sessions/-Users-alice-demo/child-0.jsonl"), [message("user", "追加的子会话文字")], true);
    s.appendLegacy();
    const second = await s.run({}, first.state);
    expect(second.records.map(r => [r.source_ref, r.body])).toEqual([
      [`old#${at(0)}#2`, "[我] 旧来源的新消息"],
      [`main#${at(0)}#2`, "[AI] 也补了测试。"],
    ]);
    expect((await s.run({}, second.state)).records).toEqual([]);
  } finally { s.close(); }
});
