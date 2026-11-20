import { expect, test } from "bun:test";
import { toLocalIso } from "../../packages/record/index.ts";
import { reviewPlan, type DraftItem } from "../src/distill/day-review.ts";
import { localDateString } from "../src/distill/requests.ts";
import { DistillStore } from "../src/distill/store.ts";
import { startServer } from "../src/server.ts";
import { fixture, setup } from "./helpers.ts";

const date = "2026-02-06", midnight = Date.parse(`${date}T00:00:00`);
const min = 60_000, now = midnight + 18 * 60 * min;
const at = (minute: number) => toLocalIso(midnight + minute * min);
const note = (minute: number, body: string) =>
  fixture({ source: "manual.note", t_start: at(minute), title: "苗圃手记", body });
const chat = (minute: number, body: string, fromMe: 0 | 1 = 1, name = "苗圃群") =>
  fixture({ source: "mac.wechat", t_start: at(minute), body,
    context: { app: "com.example.Chat", chat: name, extra: { from_me: fromMe } } });
const session = (minute: number, sourceRef: string, body: string, tool?: string) =>
  fixture({ source: "codex.session", source_ref: sourceRef, title: "核对育苗布局", t_start: at(minute),
    kind: "span", t_end: at(minute + 2), body, ...(tool ? { context: { extra: { tool } } } : {}) });
const drafts = (store: DistillStore): DraftItem[] => store.dayView(date, { now })?.drafts;

test("当天未整理时也返回草稿，追加同活动记录后沿用整理段的锚点", () => {
  const ctx = setup();
  try {
    const store = new DistillStore(ctx.db);
    const first = chat(480, "育苗盘放在东边。");
    const second = chat(482, "已经贴好育苗标签。");
    expect(ctx.db.ingest([first]).accepted).toBe(1);
    expect(store.dayView(date, { now })).toMatchObject({ date, detail: null, drafts: [{
      id: first.id, title: "苗圃群", excerpt: "育苗盘放在东边。",
      record_ids: [first.id], sources: ["mac.wechat"], apps: [{ source: "mac.wechat", app: "com.example.Chat" }],
    }] });
    expect(ctx.db.ingest([second]).accepted).toBe(1);
    const firstRefresh = drafts(store);
    const secondRefresh = store.dayView(date, { now: now + 30_000 })?.drafts;
    expect(firstRefresh).toHaveLength(1);
    expect(firstRefresh[0]).toMatchObject({ id: first.id, record_ids: [first.id, second.id], active_seconds: 360 });
    expect(secondRefresh).toEqual(firstRefresh);
    expect(reviewPlan(ctx.db, midnight, now).segments[0]?.id).toBe(firstRefresh[0]?.id);
  } finally { ctx.cleanup(); }
});

test("截止时间只留下跨界录音的后半段，已整理的点记录不会再次出现", () => {
  const ctx = setup();
  try {
    const store = new DistillStore(ctx.db);
    const cutoff = 540;
    const earlier = note(cutoff, "刚把苗床标好。");
    const coveredFractional = { ...note(cutoff, "核对过的手记。"), t_start: new Date(midnight + cutoff * min + 800).toISOString() };
    const audio = fixture({ source: "mac.audio", kind: "span", t_start: at(cutoff - 2), t_end: at(cutoff + 3),
      body: `[${at(cutoff - 1).slice(11, 19)}] 我：刚换了育苗盘。\n[${at(cutoff + 1).slice(11, 19)}] 我：分好了两排豆苗。` });
    const newest = note(cutoff + 60, "取来了一包花种。");
    expect(ctx.db.ingest([earlier, coveredFractional, audio, newest]).accepted).toBe(4);
    store.upsertProject({ id: "nursery", name: "虚构苗圃", keys: { repos: [], hosts: [], chats: [] } });
    store.upsertThread({ id: "seedlings", status: "active", project_id: "nursery", title: "调整育苗排布" });
    store.createFrame({ id: "audio-frame", key: "audio:fixture", record_ids: [audio.id], t_start_ms: Date.parse(audio.t_start),
      t_end_ms: Date.parse(audio.t_end!), chars: audio.body.length, private: 0, status: "new" });
    store.assign("audio-frame", "seedlings", "rule", 1);
    store.upsertDay({ date, detail: { cutoff: at(cutoff), items: [{
      id: audio.id, title: "更换育苗盘", description: "把豆苗的托盘换了一次。", t_start: at(cutoff - 2), t_end: at(cutoff),
      active_seconds: 120, sources: ["mac.audio"], record_ids: [earlier.id, audio.id, coveredFractional.id], project_id: "nursery",
      evidence: [{ id: audio.id, at: audio.t_start, source: audio.source, title: audio.title }],
    }] } });
    const response = store.dayView(date, { now })!;
    expect(response.detail.items.map((item: { id: string }) => item.id)).toEqual([audio.id]);
    expect(response.drafts).toHaveLength(2);
    expect(response.drafts[0]).toMatchObject({
      id: `${audio.id}:${Date.parse(at(cutoff))}`, title: "一场对话", excerpt: "分好了两排豆苗。",
      t_start: at(cutoff), t_end: at(cutoff + 3), active_seconds: 180,
      record_ids: [audio.id], project_id: "nursery", thread_id: "seedlings",
    });
    expect(response.drafts[1].record_ids).toEqual([newest.id]);
    expect(JSON.stringify(response.drafts)).not.toContain("刚换了育苗盘");
    expect(store.dayView(date, { agent: true, now })).not.toHaveProperty("drafts");
    expect(store.dayView(date, { now: now + 24 * 60 * min })).not.toHaveProperty("drafts");
  } finally { ctx.cleanup(); }
});

test("草稿排除各类噪声和私密原文及修正，时间骨架仅供展开", () => {
  const ctx = setup();
  try {
    const store = new DistillStore(ctx.db);
    const corrected = note(760, "修正前公开的手记。");
    const privateNote = { ...note(720, "不会进入草稿或小组件快照的原文。"), sensitivity: "private" as const };
    const noise = [
      fixture({ source: "mac.screen", kind: "span", t_start: at(360), t_end: at(380) }),
      fixture({ source: "mac.browser", source_ref: "browser:fixture", kind: "span", t_start: at(400), t_end: at(420) }),
      fixture({ source: "mac.app", kind: "span", t_start: at(440), t_end: at(460) }),
      session(480, "eval#a", "[我] 假评测正文。", "accuracy-eval"),
      session(540, "release#a", "[我] [tacit-tool-session:release-check]"),
      session(600, "automated#a", "[我] Automation: 合成任务\nAutomation ID: fixture\n\n[AI] 自动输出。"),
      session(620, "automated#b", "[AI] 异步自动输出。"),
      session(660, "summary#a", "[我] This session is being continued from a previous conversation.\n\n[AI] 压缩后的输出。"),
      session(680, "handoff#a", "[我] Context handoff (manual_context): 合成内容。\n\n[AI] 机器交接结果。"),
      session(690, "ack#a", "[我] 继续吧！\n\n[AI] 好的。"),
      privateNote,
      corrected,
      fixture({ source: "manual.correction", corrects: corrected.id, t_start: at(761), body: "私密修正", sensitivity: "private" }),
      chat(780, "同意！"),
      chat(781, "怎么又不跑了？"),
      chat(782, "继续吧。"),
      session(840, "release#b", "[我] 同一个发布检查会话的后续输入。"),
    ];
    const substantive = chat(850, "东侧加装了遮阳板。");
    const background = fixture({ source: "mac.screen", kind: "span", t_start: at(849), t_end: at(851) });
    expect(ctx.db.ingest([...noise, substantive, background]).accepted).toBe(noise.length + 2);
    store.upsertDay({ date, detail: { cutoff: at(550), items: [] } });
    expect(drafts(store)).toHaveLength(1);
    expect(drafts(store)[0]).toMatchObject({
      excerpt: "东侧加装了遮阳板。", record_ids: [substantive.id, background.id], sources: ["mac.wechat"],
    });
    expect(JSON.stringify(drafts(store))).not.toContain("快照的原文");
    expect(ctx.db.get(privateNote.id)?.sensitivity).toBe("private");
    // 无截止时间时，较早的噪声也不会独立成段。
    store.upsertDay({ date, detail: null });
    expect(drafts(store)).toHaveLength(1);
  } finally { ctx.cleanup(); }
});

test("摘录优先用本人原话，脱敏后取一句至多 60 字，无本人原话才用对方原话", () => {
  const ctx = setup();
  try {
    const store = new DistillStore(ctx.db);
    const secret = "sk-FAKEsampleOnly012345678901";
    const mine = chat(481, `入口口令 ${secret} ${"🌱".repeat(70)}。第二句不展示。`);
    const other = chat(480, "早到的对方原话。", 0);
    const otherOnly = chat(540, "育苗盘收好了。下一句不用展示。", 0, "种植台");
    expect(ctx.db.ingest([mine, other, otherOnly]).accepted).toBe(3);
    // 模拟旧版采集器遗留的未脱敏正文，单独验证读时脱敏。
    ctx.db.db.prepare("UPDATE records SET body=? WHERE id=?").run(mine.body, mine.id);
    const [first, second] = drafts(store);
    expect(first?.excerpt).toStartWith("入口口令 [已脱敏:OpenAI]");
    expect(Array.from(first!.excerpt)).toHaveLength(60);
    expect(first?.excerpt).not.toContain(secret);
    expect(second?.excerpt).toBe("育苗盘收好了。");
  } finally { ctx.cleanup(); }
});

test("HTTP 当天无存储行也返回草稿字段，历史日期和 MCP 不返回", async () => {
  const ctx = setup();
  const server = startServer({ db: ctx.db, token: ctx.config.token, agentToken: ctx.config.agentToken, port: 0 });
  const get = (path: string, token = ctx.config.token) => fetch(`http://127.0.0.1:${server.port}${path}`, {
    headers: { Authorization: `Bearer ${token}` },
  });
  try {
    const today = localDateString(Date.now());
    expect(await (await get(`/v1/days/${today}`)).json()).toEqual({ date: today, detail: null, drafts: [] });
    const store = new DistillStore(ctx.db);
    store.upsertDay({ date, detail: { summary: "标好了育苗区。", items: [] } });
    store.upsertDay({ date: today, detail: { summary: "完成了盘点。", items: [] } });
    expect(await (await get(`/v1/days/${date}`)).json()).not.toHaveProperty("drafts");
    const mcp = await (await get(`/v1/agent/get?tool=codex&id=${today}&level=detail`, ctx.config.agentToken)).json();
    expect(mcp.item.date).toBe(today);
    expect(mcp.item).not.toHaveProperty("drafts");
  } finally { await server.stop(true); ctx.cleanup(); }
});

test("合成重日 3200 条记录，生成草稿的 dayView 低于 300 ms", () => {
  const ctx = setup();
  try {
    const store = new DistillStore(ctx.db);
    const records = Array.from({ length: 3200 }, (_, i) => {
      const tStart = 60 + i / 4;
      if (i < 1600) return note(tStart, "核对花盆标签和托盘编号。");
      if (i % 4 === 0) return chat(tStart, "育苗组确认了新的盘点时间。", 1, `合成群 ${i % 24}`);
      if (i % 4 === 1) return session(tStart, `synthetic-${i}#1`, "[我] 核对已贴好的育苗盘标签。\n\n[AI] 标签与入库清单一致。");
      if (i % 4 === 2) return note(tStart, "记录今天的育苗盘清单。");
      return fixture({ source: "mac.screen", kind: "span", t_start: at(tStart), t_end: at(tStart + 0.2),
        context: { app: "com.example.Garden", window: "育苗清单" } });
    });
    expect(ctx.db.ingest(records).accepted).toBe(records.length);
    const started = performance.now();
    const result = drafts(store);
    const elapsed = performance.now() - started;
    console.info(`dayView 3200 synthetic records: ${elapsed.toFixed(1)} ms (${result.length} drafts)`);
    expect(result.length).toBeGreaterThan(1500);
    expect(elapsed).toBeLessThan(300);
  } finally { ctx.cleanup(); }
});
