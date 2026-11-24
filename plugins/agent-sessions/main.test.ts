import { afterEach, describe, expect, test } from "bun:test";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { zstdCompressSync } from "node:zlib";
import { createHash } from "node:crypto";
import { collect, type State } from "./main.ts";
import { cleanUserText, injectionRules, injectedBlockRules } from "./filters.ts";
import { validateRecord, type RecordV1 } from "../../packages/record/index.ts";

const temporary: string[] = [];
const base = Date.parse("2026-11-07T10:00:00Z");
function setup() {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "ra-agent-test-")); temporary.push(root);
  const claudeDir = path.join(root, "claude"); const codexDir = path.join(root, "codex");
  const project = path.join(root, "project"); fs.mkdirSync(path.join(project, ".git"), { recursive: true });
  const cwd = path.join(project, "src"); fs.mkdirSync(cwd);
  const file = (provider: "claude" | "codex", name = "session.jsonl") => {
    const target = path.join(provider === "claude" ? claudeDir : codexDir, provider === "claude" ? "projects/encoded" : "sessions/2026/11/07", name);
    fs.mkdirSync(path.dirname(target), { recursive: true }); return target;
  };
  const write = (target: string, events: unknown[], mtime = base) => { fs.writeFileSync(target, events.map(e => JSON.stringify(e)).join("\n") + "\n"); fs.utimesSync(target, mtime / 1000, mtime / 1000); };
  const run = async (now = base + 3_600_000, state?: State, since?: number) => {
    const records: RecordV1[] = [];
    const next = await collect({ device: "mac", claudeDir, codexDir, now, state, since, onRecord(record) { expect(validateRecord(record)).toEqual({ ok: true }); records.push(record); } });
    return { records, state: next };
  };
  return { root, cwd, project, claudeDir, codexDir, file, write, run };
}
function claude(role: string, text: unknown, time = base + 60_000, extra = {}) {
  return { type: role, sessionId: "claude-session", timestamp: new Date(time).toISOString(), message: { role, content: typeof text === "string" ? [{ type: "text", text }] : text }, ...extra };
}
function codex(role: string, text: unknown, time = base + 60_000, extra = {}) {
  return { type: "response_item", timestamp: new Date(time).toISOString(), payload: { type: "message", role, content: typeof text === "string" ? [{ type: role === "user" ? "input_text" : "output_text", text }] : text, ...extra } };
}
function meta(cwd: string) { return { type: "session_meta", timestamp: new Date(base).toISOString(), payload: { id: "codex-session", cwd } }; }
afterEach(() => { for (const dir of temporary.splice(0)) fs.rmSync(dir, { recursive: true, force: true }); });

// 回归：提炼层的 CLI 调用在 distill-work 里运行，不能被当成用户会话采回来（2026-11-08 设计时预防）。
test("distill-work 目录下的会话不输出", async () => {
  const s = setup(); const work = path.join(s.root, "data", "distill-work"); fs.mkdirSync(work, { recursive: true });
  s.write(s.file("claude"), [claude("user", "提炼调用的合成提示词", base + 60_000, { cwd: work })]);
  s.write(s.file("codex", "rollout-x.jsonl"), [meta(path.join(work, "sub")), codex("user", "提炼调用的合成提示词")]);
  const records: RecordV1[] = [];
  await collect({ device: "mac", claudeDir: s.claudeDir, codexDir: s.codexDir, now: base + 3_600_000, excludeDirs: [work], onRecord: r => { records.push(r); } });
  expect(records).toHaveLength(0);
});

describe("注入过滤列表", async () => {
  const samples: { [name: string]: string } = {
    command: "<command-name>/synthetic</command-name>扩展正文", task: "<task-notification>完成</task-notification>",
    skill: "Base directory for this skill: /synthetic\n技能说明", summary: "This session is being continued from a previous conversation that ran out of context.",
    interrupted: "[Request interrupted by user]", automation: "You are running an automation. 继续任务",
    orchestrator: "Delegated task node:delegated-task:fixture (合成任务) in child thread fixture [completed]:\n合成结果",
  };
  for (const rule of injectionRules) test(rule.name, () => expect(cleanUserText(samples[rule.name]!)).toBe(""));
  for (const rule of injectedBlockRules) test(rule.name, async () => {
    const tag = rule.tag.split("|")[0]!;
    expect(cleanUserText(`<${tag}>合成注入</${tag}>`)).toBe("");
    expect(cleanUserText(`<${tag}>合成注入</${tag}>\n请修正标题`)).toBe("请修正标题");
  });
  test("相邻块、项目指令、未闭合块和普通引用", async () => {
    expect(cleanUserText("# AGENTS.md instructions for /synthetic\n\n<INSTRUCTIONS>合成规则</INSTRUCTIONS><environment_context>合成环境</environment_context>\n用户正文")).toBe("用户正文");
    expect(cleanUserText("<system-reminder>未闭合")).toBe("");
    expect(cleanUserText("请过滤 <system-reminder> 等标签")).toBe("请过滤 <system-reminder> 等标签");
    expect(cleanUserText("<local-command-stdout>输出</local-command-stdout>")).toBe("");
  });
});

test("两种格式只留下亲自输入和可见回复，并生成上下文、标题和真实换行正文", async () => {
  const s = setup();
  s.write(s.file("claude"), [claude("user", "修复\n合成问题", base + 60_000, { cwd: s.cwd }), claude("assistant", [
    { type: "thinking", thinking: "不应输出" }, { type: "tool_use", input: "不应输出" }, { type: "text", text: "修好了" },
  ], base + 120_000), claude("user", [{ type: "tool_result", content: "不应输出" }, { type: "image", data: "不应输出" }]),
  claude("system", "不应输出"), claude("user", "不应输出", base, { isMeta: true }), claude("user", "不应输出", base, { isCompactSummary: true }),
  claude("user", "不应输出", base, { isSidechain: true }), claude("user", "不应输出", base, { origin: { kind: "hook" } }),
  claude("user", "不应输出", base, { promptSource: "system" }), claude("user", "不应输出", base, { turnOrigin: "task_notification" })]);
  s.write(s.file("codex"), [meta(s.cwd), codex("user", "合成请求"), codex("assistant", "可见回复", base + 180_000),
    codex("developer", "不应输出"), codex("system", "不应输出"), codex("assistant", "不应输出", base, { channel: "analysis" }),
    codex("assistant", "不应输出", base, { recipient: "tools.exec" }),
    { type: "event_msg", timestamp: new Date(base).toISOString(), payload: { type: "user_message", message: "合成请求" } },
    { type: "response_item", timestamp: new Date(base).toISOString(), payload: { type: "reasoning", content: [{ type: "text", text: "不应输出" }] } },
    { type: "response_item", payload: { type: "function_call_output", output: "不应输出" } },
  ]);
  const { records } = (await s.run()); expect(records).toHaveLength(2);
  for (const record of records) { expect(record.body).not.toContain("不应输出"); expect(record.context?.repo).toBe(s.project); expect(record.context?.cwd).toBe(s.cwd); expect(record.capture.method).toBe("file"); }
  expect(records[0]!.body).toBe("[我] 修复\n合成问题\n\n[AI] 修好了");
  expect(records[0]!.title).toContain("Claude Code · project · 修复 合成问题");
  expect(Date.parse(records[0]!.t_end!)).toBe(base + 120_000);
});

test("整点分桶：结束十分钟后关闭，未改三十分钟也关闭，空跑不重复", async () => {
  const s = setup(); const file = s.file("claude");
  s.write(file, [claude("user", "前一小时", base + 59 * 60_000), claude("user", "当前小时", base + 61 * 60_000)], base + 69 * 60_000);
  const first = (await s.run(base + 70 * 60_000)); expect(first.records).toHaveLength(0);
  const second = (await s.run(base + 70 * 60_000 + 1, first.state)); expect(second.records).toHaveLength(1);
  expect(second.records[0]!.body).toContain("前一小时");
  const idle = (await s.run(base + 99 * 60_000, second.state)); expect(idle.records).toHaveLength(1); expect(idle.records[0]!.body).toContain("当前小时");
  expect((await s.run(base + 100 * 60_000, idle.state)).records).toHaveLength(0);
});

test("会话安静三分钟就输出，一直有新内容时一批最多等十五分钟，同小时后续用 #2", async () => {
  const s = setup(); const file = s.file("claude");
  s.write(file, [claude("user", "先问一句", base + 60_000), claude("assistant", "答了", base + 2 * 60_000)], base + 2 * 60_000);
  const waiting = await s.run(base + 4 * 60_000); expect(waiting.records).toHaveLength(0);
  const quiet = await s.run(base + 5 * 60_000, waiting.state);
  expect(quiet.records.map(r => r.source_ref)).toEqual([`claude-session#${new Date(base).toISOString()}`]);
  expect(quiet.records[0]!.body).toBe("[我] 先问一句\n\n[AI] 答了");
  // 文件一直在写：不等安静，最早一条等满十五分钟就输出。
  const busy = (time: number) => { fs.appendFileSync(file, JSON.stringify(claude("user", `接着 ${time}`, base + time * 60_000)) + "\n"); fs.utimesSync(file, (base + time * 60_000) / 1000, (base + time * 60_000) / 1000); };
  busy(6); busy(20);
  const notYet = await s.run(base + 20 * 60_000 + 59_000, quiet.state); expect(notYet.records).toHaveLength(0);
  busy(21);
  const capped = await s.run(base + 21 * 60_000, notYet.state);
  expect(capped.records.map(r => r.source_ref)).toEqual([`claude-session#${new Date(base).toISOString()}#2`]);
  expect(capped.records[0]!.body).toBe("[我] 接着 6\n\n[我] 接着 20\n\n[我] 接着 21");
  expect((await s.run(base + 21 * 60_000, capped.state)).records).toHaveLength(0);
});

test("增量只读追加字节；同桶追加使用 #2，新桶单独输出，偏移按 UTF8 字节计", async () => {
  const s = setup(); const file = s.file("claude"); s.write(file, [claude("user", "首条中文")]);
  const first = (await s.run(base + 2 * 3_600_000)); expect(first.records).toHaveLength(1);
  expect(first.state.files[file]!.offset).toBe(fs.statSync(file).size);
  // 修改已消费前缀为非法 JSON；重读会产生坏行诊断。
  const fd = fs.openSync(file, "r+"); fs.writeSync(fd, "!", 0, "utf8"); fs.closeSync(fd);
  fs.appendFileSync(file, [claude("user", "迟到消息", base + 120_000), claude("assistant", "下一桶", base + 3_660_000)].map(e => JSON.stringify(e)).join("\n") + "\n");
  const diagnostics: string[] = []; const records: RecordV1[] = [];
  const next = await collect({ device: "mac", claudeDir: s.claudeDir, codexDir: s.codexDir, now: base + 3 * 3_600_000, state: first.state, onWarning: warning => diagnostics.push(warning), onRecord: record => { expect(validateRecord(record).ok).toBe(true); records.push(record); } });
  const second = { state: next, records }; expect(second.records).toHaveLength(2); expect(diagnostics).toHaveLength(0);
  expect(second.records[0]!.source_ref).toBe(first.records[0]!.source_ref + "#2");
  expect(second.records[0]!.body).toBe("[我] 迟到消息"); expect(second.records[1]!.body).toBe("[AI] 下一桶");
});

test("半行和多字节字符等待完整换行，不丢失续写", async () => {
  const s = setup(); const file = s.file("claude"); const line = Buffer.from(JSON.stringify(claude("user", "中文续写")) + "\n");
  const split = line.indexOf(Buffer.from("中文")) + 1; fs.writeFileSync(file, line.subarray(0, split));
  const first = (await s.run(base + 2 * 3_600_000)); expect(first.records).toHaveLength(0); expect(first.state.files[file]!.offset).toBe(0);
  fs.appendFileSync(file, line.subarray(split)); expect((await s.run(base + 2 * 3_600_000, first.state)).records[0]!.body).toBe("[我] 中文续写");
});

test("首次按文件 mtime 和消息时间回溯七天，--since 覆盖默认值", async () => {
  const s = setup(); const now = base + 8 * 86400_000;
  s.write(s.file("claude", "old.jsonl"), [claude("user", "旧文件")], base);
  s.write(s.file("claude", "new.jsonl"), [claude("user", "旧消息"), claude("user", "近期消息", now - 3_600_000)], now - 3_600_000);
  expect((await s.run(now)).records.map(r => r.body)).toEqual(["[我] 近期消息"]);
  expect((await s.run(now, undefined, base - 1)).records).toHaveLength(2); // 同会话同桶跨文件合并，另一个小时仍单独成条。
});

test("已有 state 时 --since 重新读取：补出首次窗口外的旧会话，已输出的不重发，增量游标不倒退", async () => {
  const s = setup(); const now = base + 20 * 86400_000;
  const old = s.file("claude", "old.jsonl"), recent = s.file("claude", "recent.jsonl");
  s.write(old, [claude("user", "很早的会话")], base);
  s.write(recent, [claude("user", "近期已输出", now - 3 * 3_600_000, { sessionId: "recent-session" })], now - 3 * 3_600_000);
  const first = await s.run(now);
  expect(first.records.map(r => r.body)).toEqual(["[我] 近期已输出"]);
  const imported = await s.run(now, first.state, base - 1);
  expect(imported.records.map(r => r.body)).toEqual(["[我] 很早的会话"]);
  expect(imported.state.replaySince).toBe(first.state.replaySince); expect(imported.state.since).toBe(first.state.since);
  // 之后的常规增量不再重读。
  expect((await s.run(now + 60_000, imported.state)).records).toHaveLength(0);
  // 超出八天去重窗口的消息重新导入时可能再输出一次，但 source_ref 与原记录相同，由 hub 去重，不会出现新条目。
  const again = await s.run(now + 10 * 86400_000, imported.state, base - 1);
  const known = new Set([...first.records, ...imported.records].map(r => r.source_ref));
  expect(again.records.length).toBeGreaterThan(0);
  expect(again.records.every(r => known.has(r.source_ref))).toBe(true);
});

test("压缩归档、迁移去重、重跑和 AI 四千字截断", async () => {
  const s = setup(); const archive = path.join(s.codexDir, "archived_sessions/session.jsonl.zst"); fs.mkdirSync(path.dirname(archive), { recursive: true });
  const events = [meta(s.cwd), codex("user", "压缩请求"), codex("assistant", "答".repeat(4001), base + 120_000)];
  fs.writeFileSync(archive, zstdCompressSync(Buffer.from(events.map(e => JSON.stringify(e)).join("\n"))));
  const first = (await s.run(base + 10 * 60_000)); expect(first.records).toHaveLength(0);
  const closed = (await s.run(base + 16 * 60_000, first.state)); expect(closed.records).toHaveLength(1);
  expect(closed.records[0]!.body).toContain("答".repeat(4000) + "…[已截断]"); expect(closed.records[0]!.body).not.toContain("答".repeat(4001));
  s.write(s.file("codex"), events); expect((await s.run(base + 16 * 60_000, closed.state)).records).toHaveLength(0);
});

test("损坏完整行跳过；文件缩短或替换后去重重读", async () => {
  const s = setup(); const file = s.file("claude"); s.write(file, [claude("user", "旧消息")]);
  const first = (await s.run()); fs.writeFileSync(file, "bad\n"); expect((await s.run(base + 2 * 3_600_000, first.state)).records).toHaveLength(0);
  fs.unlinkSync(file); s.write(file, [claude("user", "旧消息"), claude("user", "新消息", base + 180_000)]);
  expect((await s.run(base + 2 * 3_600_000, first.state)).records[0]!.body).toBe("[我] 新消息");
});

test("CLI 输出协议，state 只读，错误不泄露日志", async () => {
  const s = setup(), at = Date.now() - 2 * 3_600_000;
  // 重导会重读旧文件，只有八天去重窗口内的消息由 checkpoint 跳过。
  s.write(s.file("claude"), [claude("user", "CLI 合成消息", at)], at);
  const since = new Date(at - 60_000).toISOString();
  const args = [process.execPath, path.join(import.meta.dir, "main.ts"), "--device", "mac", "--since", since];
  const env = { ...process.env, RA_CLAUDE_DIR: s.claudeDir, RA_CODEX_DIR: s.codexDir };
  const result = Bun.spawnSync(args, { env }); expect(result.exitCode).toBe(0);
  const output = result.stdout.toString().trim().split("\n").map(line => JSON.parse(line));
  expect(output.at(-1).type).toBe("checkpoint"); expect(output[0].type).toBe("record"); expect(validateRecord(output[0].record).ok).toBe(true);
  // 回归：runner 首次运行传的 state 文件还不存在，曾经因此直接失败（2026-11-08 端到端验收发现）。
  const first = Bun.spawnSync([...args, "--state", path.join(s.root, "missing-state.json")], { env });
  expect(first.exitCode).toBe(0); expect(first.stdout.toString()).toContain('"type":"checkpoint"');
  const stateFile = path.join(s.root, "state.json"); const stateText = JSON.stringify(output.at(-1).state); fs.writeFileSync(stateFile, stateText);
  const next = Bun.spawnSync([...args, "--state", stateFile], { env });
  expect(next.exitCode).toBe(0);
  expect(next.stdout.toString().trim().split("\n").map(line => JSON.parse(line).type)).toEqual(["checkpoint"]);
  expect(fs.readFileSync(stateFile, "utf8")).toBe(stateText);
  fs.writeFileSync(stateFile, "{秘密损坏状态"); const broken = Bun.spawnSync([...args, "--state", stateFile], { env }); expect(broken.exitCode).not.toBe(0); expect(broken.stderr.toString()).not.toContain("秘密"); expect(broken.stdout.length).toBe(0);
});

test("真实格式的图片占位、技能展开、插件目录和澄清回答（合成内容）", async () => {
  expect(cleanUserText('<image name="synthetic.png" path="/synthetic/image.png" />')).toBe("");
  expect(cleanUserText('<image name="one.png" /><image name="two.png" />\n请分析布局')).toBe("请分析布局");
  expect(cleanUserText("[Image: 合成图片]\n用户文字")).toBe("用户文字");
  expect(cleanUserText("<skill><name>合成技能</name><path>/synthetic</path>技能正文</skill>")).toBe("");
  expect(cleanUserText('<send_user_message_question_reply>[{"question":"AI 问题","questionItemId":"synthetic","answer":"我的回答"}]</send_user_message_question_reply>')).toBe("我的回答");
});

test("压缩文件改写后从头解压去重，仅输出新增内容", async () => {
  const s = setup(); const file = s.file("codex", "synthetic.jsonl.zst");
  const events = [meta(s.cwd), codex("user", "已读内容")];
  fs.writeFileSync(file, zstdCompressSync(Buffer.from(events.map(e => JSON.stringify(e)).join("\n") + "\n")));
  const first = (await s.run(base + 7_200_000)); expect(first.records).toHaveLength(1);
  events.push(codex("user", "新增内容", base + 120_000));
  fs.writeFileSync(file, zstdCompressSync(Buffer.from(events.map(e => JSON.stringify(e)).join("\n") + "\n")));
  const next = (await s.run(base + 7_200_000, first.state)); expect(next.records).toHaveLength(1); expect(next.records[0]!.body).toBe("[我] 新增内容");
});

test("超长单条用户消息截断后输出，正文包含前缀和标记仍不超过上限", async () => {
  const s = setup(); s.write(s.file("claude"), [claude("user", "字".repeat(200001))]);
  const result = await s.run(base + 7_200_000);
  expect(result.records).toHaveLength(1);
  expect(result.records[0]!.body.length).toBe(150000);
  expect(result.records[0]!.body.endsWith("…[已截断]")).toBe(true);
  expect((await s.run(base + 7_200_000, result.state)).records).toHaveLength(0);
});

test("超长桶按消息边界拆分、连续 part，与迟到追加共用计数器", async () => {
  const s = setup(); const file = s.file("claude");
  const messages = Array.from({ length: 7 }, (_, index) => claude("user", `${index}:` + "文".repeat(40000), base + (index + 1) * 60000));
  s.write(file, messages);
  const first = await s.run(base + 7_200_000); expect(first.records).toHaveLength(3);
  const reference = first.records[0]!.source_ref;
  expect(first.records.map(r => r.source_ref)).toEqual([reference, reference + "#2", reference + "#3"]);
  expect(first.records.map(r => Date.parse(r.t_start))).toEqual([base + 60000, base + 240000, base + 420000]);
  for (const record of first.records) { expect(record.body.length).toBeLessThanOrEqual(150000); expect(record.body).not.toContain("已截断"); }
  expect((await s.run(base + 7_200_000, first.state)).records).toHaveLength(0);
  fs.appendFileSync(file, JSON.stringify(claude("user", "迟到内容", base + 480000)) + "\n");
  expect((await s.run(base + 7_200_000, first.state)).records[0]!.source_ref).toBe(reference + "#4");
});

test("损坏行累计一条诊断，跳过后正常输出 checkpoint，半行仍等待追加", async () => {
  const s = setup(); const file = s.file("claude"); const warnings: string[] = []; const records: RecordV1[] = [];
  const initial = JSON.stringify(claude("user", "有效消息"));
  const partial = JSON.stringify(claude("user", "下次完整消息", base + 120000));
  fs.writeFileSync(file, `损坏内容\n${initial}\n{"type":"user",}\n${partial.slice(0, 50)}`);
  const state = await collect({ device: "mac", claudeDir: s.claudeDir, codexDir: s.codexDir, now: base + 7_200_000, onWarning: text => warnings.push(text), onRecord: record => { records.push(record); } });
  expect(warnings).toEqual(["跳过 2 行损坏数据"]); expect(records.map(r => r.body)).toEqual(["[我] 有效消息"]);
  const offset = state.files[file]!.offset;
  fs.appendFileSync(file, partial.slice(50) + "\n");
  const next = await s.run(base + 7_200_000, state); expect(next.records[0]!.body).toBe("[我] 下次完整消息"); expect(next.state.files[file]!.offset).toBeGreaterThan(offset);
  const cli = Bun.spawnSync(["bun", path.join(import.meta.dir, "main.ts"), "--device", "mac"], { env: { ...process.env, RA_CLAUDE_DIR: s.claudeDir, RA_CODEX_DIR: s.codexDir } });
  expect(cli.exitCode).toBe(0); expect(cli.stderr.toString().trim()).toBe("跳过 2 行损坏数据");
  expect(JSON.parse(cli.stdout.toString().trim().split("\n").at(-1)!)).toMatchObject({ type: "checkpoint", sessionWarnings: { damaged: 2 } });
});

test("巨型工具行不隐藏后面的可见文字，字段逆序与压缩流结果一致", async () => {
  const s = setup(); const file = s.file("codex");
  const big = "合成输出".repeat(1_500_000);
  const events = [meta(s.cwd), ...["function_call_output", "custom_tool_call_output", "item_completed"].map(type => ({ payload: { output: big, type }, timestamp: new Date(base).toISOString(), type: "response_item" })),
    { payload: { content: [{ text: "可见问题", type: "input_text" }], role: "user", type: "message" }, timestamp: new Date(base + 60000).toISOString(), type: "response_item" },
  ];
  s.write(file, events);
  s.write(s.file("claude"), [claude("user", [{ content: big, type: "tool_result" }, { text: "混合消息仍保留", type: "text" }]), claude("user", big, base + 120000)]);
  const result = await s.run(base + 7_200_000); expect(result.records.find(r => r.source === "codex.session")?.body).toBe("[我] 可见问题");
  const userRecords = result.records.filter(r => r.source === "claude_code.session"); expect(userRecords).toHaveLength(2); expect(userRecords[0]!.body).toBe("[我] 混合消息仍保留"); expect(userRecords[1]!.body.length).toBe(150000);
  fs.writeFileSync(file + ".zst", zstdCompressSync(fs.readFileSync(file)));
  fs.unlinkSync(file);
  const archived = await s.run(base + 7_200_000, result.state); expect(archived.records).toHaveLength(0); expect(archived.state.files[file]).toBeUndefined();
});

test("八天后清理已输出桶哈希和休眠会话，保留文件偏移与 cwd 以恢复追加", async () => {
  const s = setup(); const file = s.file("codex");
  s.write(file, [meta(s.cwd), codex("user", "八天以前的消息")]);
  const first = await s.run(base + 7_200_000); expect(first.records).toHaveLength(1);
  const now = base + 10 * 86400_000;
  const pruned = await s.run(now, first.state); expect(pruned.records).toHaveLength(0); expect(Object.keys(pruned.state.sessions)).toHaveLength(0);
  expect(pruned.state.files[file]!.offset).toBe(first.state.files[file]!.offset); expect(pruned.state.files[file]!.cwd).toBe(s.cwd);
  fs.appendFileSync(file, JSON.stringify(codex("user", "休眠后新消息", now - 3_600_000)) + "\n"); fs.utimesSync(file, (now - 3_600_000) / 1000, (now - 3_600_000) / 1000);
  const resumed = await s.run(now, pruned.state); expect(resumed.records.map(r => r.body)).toEqual(["[我] 休眠后新消息"]); expect(resumed.records[0]!.context?.cwd).toBe(s.cwd);
  expect(resumed.records[0]!.context?.repo).toBe(s.project); expect(resumed.records[0]!.source_ref).toStartWith("codex-session#");
  // 归档在去重窗口外出现，只重读近期消息，旧消息不会复活。
  const archive = path.join(s.codexDir, "archived_sessions/moved.jsonl.zst"); fs.mkdirSync(path.dirname(archive), { recursive: true }); fs.writeFileSync(archive, zstdCompressSync(fs.readFileSync(file))); fs.unlinkSync(file);
  const moved = await s.run(now, resumed.state); expect(moved.records).toHaveLength(0); expect(moved.state.files[file]).toBeUndefined();
});

test("活动会话也删除八天以前的已输出桶，不清掉未输出内容", async () => {
  const s = setup(); const file = s.file("claude"); s.write(file, [claude("user", "旧消息")]);
  const first = await s.run(base + 7_200_000); const session = first.state.sessions["claude:claude-session"]!;
  const oldHour = String(base); expect(session.seen[oldHour]!.length).toBe(1);
  const now = base + 10 * 86400_000;
  s.write(file, [claude("user", "旧消息"), claude("user", "新近未关闭消息", now - 60000)], now);
  const current = await s.run(now, first.state); const active = current.state.sessions["claude:claude-session"]!;
  expect(active.seen[oldHour]).toBeUndefined(); expect(active.buckets[oldHour]).toBeUndefined();
  expect(Object.values(active.buckets).flatMap(b => b.messages).map(m => m.text)).toEqual(["新近未关闭消息"]);
});

test("v1 checkpoint 自动迁移，不重发；迁移后休眠再恢复仍保留上下文", async () => {
  const s = setup(); const file = s.file("codex"); s.write(file, [meta(s.cwd), codex("user", "旧版本消息")]);
  const first = await s.run(base + 7_200_000);
  const old = structuredClone(first.state) as any; old.version = 1; delete old.replaySince;
  for (const session of Object.values(old.sessions) as any[]) session.seen = Object.values(session.seen).flat();
  for (const progress of Object.values(old.files) as any[]) delete progress.cwd;
  const migrated = await s.run(base + 7_200_000, old); expect(migrated.state.version).toBe(2); expect(migrated.records).toHaveLength(0); expect(migrated.state.files[file]!.cwd).toBe(s.cwd);
  const now = base + 12 * 86400_000; const pruned = await s.run(now, migrated.state); expect(Object.keys(pruned.state.sessions)).toHaveLength(0);
  fs.appendFileSync(file, JSON.stringify(codex("user", "新版本消息", now - 3_600_000)) + "\n"); fs.utimesSync(file, (now - 3_600_000) / 1000, (now - 3_600_000) / 1000);
  const next = await s.run(now, pruned.state); expect(next.records.map(r => r.body)).toEqual(["[我] 新版本消息"]); expect(next.records[0]!.context?.cwd).toBe(s.cwd);
});

test("超预算的乱序小时桶按一次性排序分条，重跑的标识和正文一致", async () => {
  const s = setup();
  const large = "文".repeat(88_000);
  const count = 800;
  const first = s.file("claude", "a.jsonl"), second = s.file("claude", "b.jsonl");
  const time = (i: number) => base + i * 1000;
  const content = (i: number) => `${i} ${large}`;
  const write = (file: string, i: number) => fs.appendFileSync(file, JSON.stringify(claude("user", content(i), time(i))) + "\n");
  // 晚时刻先出现；单文件也不保证按时刻排序，两个文件还有重复消息。
  for (let i = count - 1; i >= 0; i--) write(i % 2 ? first : second, i);
  write(second, 1);
  for (const file of [first, second]) fs.utimesSync(file, base / 1000, base / 1000);
  const hash = createHash("sha256");
  for (let i = 0; i < count; i++) {
    const ref = `claude-session#${new Date(base).toISOString()}${i ? "#" + (i + 1) : ""}`;
    hash.update(JSON.stringify([ref, time(i), time(i), "[我] " + content(i)]));
  }
  const expected = hash.digest("hex");
  const worker = path.join(s.root, "measure.ts");
  fs.writeFileSync(worker, `
    import { createHash } from "node:crypto";
    import { collect } from ${JSON.stringify(path.join(import.meta.dir, "main.ts"))};
    Bun.gc(true);
    const baselineKiB = process.resourceUsage().maxRSS;
    const options = {
      device: "mac", claudeDir: ${JSON.stringify(s.claudeDir)}, codexDir: ${JSON.stringify(s.codexDir)},
      now: ${base + 7_200_000}, excludeDirs: [],
    };
    async function scan() {
      const hash = createHash("sha256");
      let count = 0;
      const state = await collect({ ...options, onRecord(r) {
        count++;
        hash.update(JSON.stringify([r.source_ref, Date.parse(r.t_start), Date.parse(r.t_end), r.body]));
      } });
      return { state, count, digest: hash.digest("hex") };
    }
    const first = await scan();
    const peakKiB = process.resourceUsage().maxRSS - baselineKiB;
    const retry = await scan();
    await collect({ ...options, state: first.state, since: ${base - 1}, onRecord() { throw new Error("成功后重扫重复输出"); } });
    console.log(JSON.stringify({ count: first.count, digest: first.digest, retryDigest: retry.digest, peakKiB }));
  `);
  const result = Bun.spawnSync([process.execPath, worker], { env: { ...process.env, TMPDIR: s.root } });
  expect(result.exitCode).toBe(0);
  const stats = JSON.parse(result.stdout.toString());
  expect(stats).toMatchObject({ count, digest: expected, retryDigest: expected });
  // 正文超过 134 MiB (UTF-16)。RSS 包含 Bun 堆和 I/O 临时对象，旧版此用例超过 700 MiB。
  expect(stats.peakKiB).toBeLessThan(256 * 1024);
  expect(fs.readdirSync(s.root).sort()).toEqual(["claude", "measure.ts", "project"]);
}, 25_000);

test("活动桶超过消息预算时保留原游标，关闭后按原分条规则完整导入", async () => {
  const s = setup();
  const file = s.file("claude");
  s.write(file, [claude("user", "上一时间段")]);
  const initial = await s.run(base + 3_600_000);
  const offset = initial.state.files[file]!.offset;
  const now = base + 3_660_000;
  const messages = Array.from({ length: 20_001 }, (_, i) => `消息 ${i}`);
  fs.appendFileSync(file, messages.map(text => JSON.stringify(claude("user", text, now))).join("\n") + "\n");
  fs.utimesSync(file, now / 1000, now / 1000);
  await expect(s.run(now, initial.state)).rejects.toThrow("待保存内容超过上限");
  expect(initial.state.files[file]!.offset).toBe(offset);
  const closed = await s.run(now + 30 * 60_000, initial.state);
  const bodies = closed.records.flatMap(record => record.body.split("\n\n"));
  expect(bodies).toEqual(messages.map(text => "[我] " + text));
  expect((await s.run(now + 30 * 60_000, closed.state)).records).toHaveLength(0);
}, 15_000);

test("单文件格式变化告警；未知事件、角色、时刻及正文均计数，正常事件继续采集", async () => {
  const s = setup();
  const at = Date.now() - 2 * 3_600_000;
  const unknown = [
    { type: "new_event", body: "合成日志原文" },
    { ...codex("new_role", "合成日志原文", at) },
    { ...claude("user", "合成日志原文", at), timestamp: "new_date" },
    claude("user", [{ type: "text", text: { value: "合成日志原文" } }], at),
    ["合成日志原文"],
  ];
  s.write(s.file("claude"), Array.from({ length: 20 }, (_, i) => unknown[i % unknown.length]), at);
  s.write(s.file("claude", "ordinary.jsonl"), Array.from({ length: 55 }, () => claude("user", "可见消息", at)), at);
  const env = { ...process.env, RA_CLAUDE_DIR: s.claudeDir, RA_CODEX_DIR: s.codexDir, RA_DATA_DIR: s.root };
  const result = Bun.spawnSync([process.execPath, path.join(import.meta.dir, "main.ts"), "--device", "mac"], { env });
  expect(result.exitCode).toBe(0);
  const lines = result.stdout.toString().trim().split("\n").map(line => JSON.parse(line));
  expect(lines.at(-1).sessionWarnings).toEqual({ unrecognized: 20 });
  expect(lines.filter(line => line.type === "record").map(line => line.record.body)).toEqual(["[我] 可见消息"]);
  expect(result.stderr.toString().trim()).toBe("Claude Code / Codex 会话格式可能已变化，有 20 行没有识别");
  expect(JSON.stringify(lines.at(-1)) + result.stderr.toString()).not.toContain("合成日志原文");
});

test("整轮告警要求至少 50 行且严格过半，已知工具和被过滤的正文照常识别", async () => {
  const s = setup();
  const files = Array.from({ length: 5 }, (_, i) => s.file("codex", `${i}.jsonl`));
  const known = [meta(s.cwd), { type: "event_msg", payload: { type: "token_count" } },
    { type: "turn_context" }, { type: "response_item", payload: { type: "function_call_output" } },
    codex("assistant", "分析", base, { channel: "analysis" }),
    codex("developer", "指令"), codex("user", [{ type: "input_image" }]), codex("user", "正常消息")];
  const unknown = [{ type: "new_event" }, codex("new_role", "未识别角色"),
    { ...codex("user", "正文"), timestamp: "new_date" }, codex("user", [{ type: "new_block" }]),
    codex("user", [{ type: "input_text", text: 42 }])];
  const run = async (bad: number, good: number, reduceLast = false) => {
    const warnings: string[] = [];
    for (const [i, file] of files.entries()) {
      s.write(file, [...Array.from({ length: good }, (_, i) => known[i % known.length]),
        ...Array.from({ length: bad - (i === files.length - 1 && reduceLast ? 1 : 0) }, (_, i) => unknown[i % unknown.length])]);
    }
    await collect({ device: "mac", claudeDir: s.claudeDir, codexDir: s.codexDir, now: base + 7_200_000, onWarning: warning => warnings.push(warning) });
    return warnings;
  };
  expect(await run(0, 30)).toEqual([]);
  expect(await run(10, 1, true)).toEqual([]); // 49 行，比例过半
  expect(await run(10, 10)).toEqual([]);  // 50 行，比例刚好一半
  expect(await run(10, 9)).toEqual(["Claude Code / Codex 会话格式可能已变化，有 50 行没有识别"]);
});

test("runner 将诊断计数交给采集端，checkpoint 保存和去重照常", async () => {
  const { runPlugin } = await import("../../hub/src/run-plugin.ts");
  const { HubDB } = await import("../../hub/src/db.ts");
  const s = setup();
  const now = Date.now();
  const at = now - 7_200_000;
  const file = s.file("claude");
  s.write(file, Array.from({ length: 20 }, () => ({ type: "new_event" })), at);
  s.write(s.file("claude", "valid.jsonl"), [claude("user", "合成正文", at)], at);
  fs.appendFileSync(file, "{损坏的合成日志}\n");
  const db = new HubDB(path.join(s.root, "synthetic-history.db"), "synthetic-db-key-0123456789");
  const command = [process.execPath, path.join(import.meta.dir, "main.ts")];
  const env = { ...process.env, RA_CLAUDE_DIR: s.claudeDir, RA_CODEX_DIR: s.codexDir, RA_DATA_DIR: s.root };
  const run = () => runPlugin({ db, dataDir: s.root, name: "agent-sessions", command, env });
  try {
    const first = await run();
    expect(first).toMatchObject({ accepted: 1, stateWritten: true, warnings: ["Claude Code / Codex 会话格式可能已变化，有 20 行没有识别", "跳过 1 行损坏数据"] });
    expect(JSON.stringify(first)).not.toContain("合成");
    fs.unlinkSync(path.join(s.root, "plugins/agent-sessions/state.json"));
    expect(await run()).toMatchObject({ accepted: 0, duplicates: 1, stateWritten: true });
    const next = await run();
    expect(next).toMatchObject({ accepted: 0, duplicates: 0, stateWritten: true });
    expect(next.warnings).toBeUndefined();
  } finally { db.close(); }
});
