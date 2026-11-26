import { updateGeneral } from "../src/general-settings.ts";
import { afterEach, beforeEach, expect, test } from "bun:test";
import { AgentReads } from "../src/agent.ts";
import { conversationDetail } from "../src/conversations.ts";
import { dayDrafts, reviewPlan } from "../src/distill/day-review.ts";
import { assignStep, conversationStep, digestStep, frameView, sliceStep, type LLM } from "../src/distill/run.ts";
import { DistillStore } from "../src/distill/store.ts";
import { historySegments } from "../src/history.ts";
import type { LLMRequest } from "../src/llm/index.ts";
import { currentNow } from "../src/now-status.ts";
import type { RecordV1 } from "../../packages/record/index.ts";
import { fixture, setup } from "./helpers.ts";

let ctx: ReturnType<typeof setup>, store: DistillStore;
const minute = 60_000, start = Date.parse("2026-11-20T00:00:00Z");
const at = (offset: number) => new Date(start + offset * minute).toISOString();
const phone = "synthetic-phone";
beforeEach(() => {
  ctx = setup();
  updateGeneral(ctx.db, { language: "zh" });
  store = new DistillStore(ctx.db);
  store.setState("enabled_ms", start);
});
afterEach(() => ctx.cleanup());

const macApp = "com.tencent.xinWeChat", wechat = "com.tencent.mm";
const macMessage = (offset: number, body: string, sender = "合成甲", chat = "温室 小组") => fixture({
  source: "mac.wechat", t_start: at(offset), title: `微信 · ${chat} · ${sender}`, body,
  context: { app: macApp, chat, extra: { sender, from_me: 0, group: Number(sender !== chat) } },
});
const notification = (offset: number, body: string, title = "温室小组（7）", app?: string) => fixture({
  source: "android.notification", device: phone, t_start: at(offset), title, body,
  ...(app ? { context: { app } } : {}),
});
const audio = (offset: number, body: string, extra: Partial<RecordV1> = {}) => fixture({
  source: "android.audio", device: phone, title: "对话记录", kind: "span", t_start: at(offset), t_end: at(offset + 4),
  capture: { method: "asr" }, source_ref: `synthetic-clip-${offset}`, body, ...extra,
});
const review = () => reviewPlan(ctx.db, start, start + 24 * 60 * minute);
const evidence = () => review().segments.flatMap(s => s.evidence);
const framesAt = (offset: number) => sliceStep(ctx.db, false, Date.parse(at(offset)));
const view = (id: string) => {
  const frame = store.frames().find(f => f.record_ids.includes(id))!;
  return frameView(store, frame, { maxRecords: 10, excerpt: () => 1000 });
};

// 手机只录音（0.4.2）：已经传上来的旧聊天通知能搜到，但不再进时间线、草稿，也不和 Mac 微信比对去重。
test("旧的手机聊天通知不进时间线和草稿，原文仍在库里", () => {
  const first = notification(60, "林灯：一号温室已更换传感器。", "温室小组");
  const pay = notification(100, "¥12.00 paid", "Weixin Pay");
  expect(ctx.db.ingest([first, pay], phone).accepted).toBe(2);
  expect(review().segments).toEqual([]);
  expect(dayDrafts(ctx.db, start, Date.parse(at(120)), { covered: new Set() })).toEqual([]);
  expect(ctx.db.get(first.id)?.body).toBe(first.body);
});

test("事项整理能用通知说明进展，只有明确标为我的手机录音才能支撑用户决定和原话", async () => {
  const received = notification(60, "陶雨：决定改用绿色试验箱。");
  const spoken = audio(70, "对方 1：决定改用蓝色试验箱。\n我：试验用白色试验箱。");
  ctx.db.ingest([received, spoken], phone);
  const now = Date.parse(at(100));
  framesAt(100);
  store.upsertThread({ id: "experiment", title: "合成试验", status: "active", needs_regen: 1 });
  for (const frame of store.frames()) store.assign(frame.id, "experiment", "llm", 0.9);
  const llm: LLM = { async complete<T>(req: LLMRequest) {
    const ok = (data: unknown) => ({ ok: true as const, ms: 1, data: data as T });
    if (req.task !== "thread_digest") return ok({ brief: "合成试验进展" });
    const ref = (id: string) => Object.keys(req.refs ?? {}).find(key => req.refs?.[key] === id)!;
    const facts = [
      { record_id: ref(received.id), text: "决定改用绿色试验箱。", kind: "decision" },
      { record_id: ref(received.id), text: "决定改用绿色试验箱。", kind: "open" },
      { record_id: ref(spoken.id), text: "决定改用蓝色试验箱。", kind: "decision" },
      { record_id: ref(spoken.id), text: "试验用白色试验箱。", kind: "decision" },
    ];
    return ok({ title: "合成试验", domain: "work", in_project: false, status_hint: "active", invalidate: [],
      detail: { goal: "合成目标", progress: "合成进展", artifacts: { files: [], urls: [], commands: [], people: [] },
        quotes: facts.filter(f => f.kind === "decision").map(({ record_id, text }) => ({ record_id, text })) },
      new_facts: facts.map(({ record_id, text, kind }) => ({ kind, text, reason: null, confidence: 0.9,
        evidence: [record_id], supports: [{ record_id, text }] })),
    });
  } };
  expect(await digestStep({ db: ctx.db, llm }, store, now)).toMatchObject({ updated: 1, dropped_ungrounded: 2 });
  expect(store.facts("thread_id", "experiment").map(f => [f.kind, f.text]).sort()).toEqual([
    ["decision", "试验用白色试验箱。"], ["open", "决定改用绿色试验箱。"],
  ]);
  expect(store.thread("experiment")?.detail).toMatchObject({ quotes: [{ record_id: spoken.id, text: "试验用白色试验箱。" }] });
});

test("只有手机应用使用记录时没有时间线正文或新事项，Agent 搜索排在录音和聊天之后", async () => {
  const usage = fixture({ source: "android.usage", device: phone, kind: "span", t_start: at(90), t_end: at(130),
    title: "synthetic-needle 使用", body: "骨架正文不外发", context: { app: "example.tools" } });
  ctx.db.ingest([usage], phone);
  expect(review().segments).toEqual([]);
  expect(dayDrafts(ctx.db, start, Date.parse(at(140)), { covered: new Set() })).toEqual([]);
  framesAt(150);
  const llm: LLM = { async complete<T>() { return { ok: true, ms: 1, data: { items: [
    { frame_id: "s1", thread_id: null, new_thread_title: "合成事项", ignore: false, confidence: 0.9 },
  ] } as T }; } };
  expect(view(usage.id).records).toMatchObject([{ id: usage.id, excerpt: "" }]);
  expect(await assignStep({ db: ctx.db, llm }, store, Date.parse(at(150)))).toMatchObject({ calls: 1, created_threads: 0, candidates: 0, ignored: 1 });
  const chat = notification(80, "合成甲：synthetic-needle 已入档。");
  const clip = audio(70, "对方 1：synthetic-needle 已入档。");
  ctx.db.ingest([chat, clip], phone);
  const agent = new AgentReads(ctx.db);
  const ids: string[] = [];
  let cursor: string | null = null;
  do {
    const params = new URLSearchParams({ tool: "codex", q: "synthetic-needle", limit: "1" });
    if (cursor) params.set("cursor", cursor);
    const page = await (await agent.handle("search", params)).json();
    ids.push(...page.records.map((r: { id: string }) => r.id));
    cursor = page.next_cursor;
  } while (cursor);
  expect(ids).toEqual([chat.id, clip.id, usage.id]);
});

test("手机录音分场、区分话轮并按十分钟、字数和私密规则总结，删除后按剩余记录重写", async () => {
  const paragraph = "合成温室的传感器校准已经完成，日照记录已按编号归档。".repeat(10);
  const first = audio(60, `对方 1：${paragraph}\n对方 2：上周的温度记录也备份好了。`);
  const next = audio(65, "我：我会把校准表交给管理员。\n对方 1：明天上午交接。");
  const separate = audio(85, "对方 1：讨论了照明测试。");
  const hidden = audio(120, `对方 1：只有私密录音包含这些字。${paragraph}`, { sensitivity: "private" });
  const mac = audio(62, "[01:02:10] 我：打开合成说明书。", { source: "mac.audio", device: "mac", source_ref: "synthetic-mac" });
  expect(ctx.db.ingest([first, next, separate, hidden], phone).accepted).toBe(4);
  expect(ctx.db.ingest([mac]).accepted).toBe(1);
  const list = historySegments(ctx.db, new URLSearchParams({ from: at(0), to: at(140), device: phone })).conversations;
  expect(list.map(c => c.record_ids)).toEqual([[first.id, next.id], [separate.id], [hidden.id]]);
  expect(conversationDetail(ctx.db, mac.id).record_ids).toEqual([mac.id]);
  const entries = evidence().filter(e => e.source === "android.audio").map(e => ({ ...e, at: new Date(e.at).toISOString() }));
  expect(entries).toContainEqual(expect.objectContaining({ at: first.t_start, role: "other", speaker: "对方 1" }));
  expect(entries).toContainEqual(expect.objectContaining({ at: first.t_start, role: "other", speaker: "对方 2" }));
  expect(entries).toContainEqual(expect.objectContaining({ at: next.t_start, role: "user", text: "我会把校准表交给管理员。" }));
  const calls: LLMRequest[] = [];
  const llm: LLM = { async complete<T>(req: LLMRequest) {
    calls.push(req);
    return { ok: true, ms: 1, data: { title: "温室校准", summary: "温室已完成校准。校准表随后交接。", points: [] } as T };
  } };
  expect((await conversationStep({ db: ctx.db, llm }, Date.parse(at(78.99)))).calls).toBe(0);
  expect(await conversationStep({ db: ctx.db, llm }, Date.parse(at(140)))).toEqual({ calls: 1, done: 1, pending: 0 });
  expect(calls[0]!.prompt).toContain("我：我会把校准表交给管理员");
  expect(calls[0]!.prompt).not.toContain("私密录音");
  expect(conversationDetail(ctx.db, first.id)).toMatchObject({ state: "ready", title: "温室校准", record_ids: [first.id, next.id] });
  framesAt(150);
  expect(view(first.id).records[0]?.conversation_summary?.summary).toContain("完成校准");
  expect(ctx.db.delete(next.id)).toBe(true);
  expect(conversationDetail(ctx.db, first.id)).toMatchObject({ state: "waiting", summary: null, record_ids: [first.id] });
  expect((await conversationStep({ db: ctx.db, llm }, Date.parse(at(150)))).done).toBe(1);
  expect(calls[1]!.prompt).not.toContain("管理员");
});
