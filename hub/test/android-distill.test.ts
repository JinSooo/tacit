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

test("手机单条聊天通知提供会话、发送人和正文，按消息前后两分钟计时", () => {
  const first = notification(60, "林灯：一号温室已更换传感器。", "温室小组");
  const second = notification(61, "陶雨：新的校准报告已归档。", "温室小组");
  const lone = notification(100, "校准报告已送审。", "合成收件箱");
  expect(ctx.db.ingest([first, second, lone], phone).accepted).toBe(3);
  const segments = review().segments;
  expect(segments.map(s => s.seconds)).toEqual([300, 240]);
  expect(segments[0]!.evidence).toMatchObject([
    { at: first.t_start, role: "other", chat: first.title, speaker: "林灯", text: "一号温室已更换传感器。" },
    { at: second.t_start, role: "other", chat: first.title, speaker: "陶雨", text: "新的校准报告已归档。" },
  ]);
  expect(segments[1]!.evidence[0]).toMatchObject({ role: "other", chat: lone.title, text: lone.body });
  expect(dayDrafts(ctx.db, start, Date.parse(at(120)), { covered: new Set() })[0]).toMatchObject({
    title: "温室小组", excerpt: "一号温室已更换传感器。", sources: ["android.notification"],
  });
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

test("微信跨端仅在会话、发件人、正文及两分钟同时匹配时优先使用 Mac 记录", async () => {
  const body = "温室浇灌控制器已经完成校准，下午交接。";
  const fromMac = macMessage(60, body);
  const otherMac = macMessage(61, "校准附件也发给大家了。");
  const directMac = macMessage(160, "说明：合成批号已经改了。", "合成乙", "合成乙");
  const exact = notification(60, `合成甲：${body}`, "温室小组（7）", wechat);
  const truncated = notification(62, "合成甲：温室浇灌控制器已经完成…");
  const prefix = notification(61, "合成甲：温室浇灌控制器已经完成");
  const direct = notification(160, directMac.body, "合成乙");
  const keep = [
    notification(60, `合成乙：${body}`),
    notification(60, `合成甲：${body}`, "道具小组"),
    notification(60, "合成甲：温室浇灌控制器已经拆除。"),
    notification(60, "合成甲：温室…"),
    notification(62.001, `合成甲：${body}`),
    notification(61, `合成甲：${body}`, "温室小组（7）", "example.other.chat"),
  ];
  const dropped = [exact, truncated, prefix, direct];
  ctx.db.ingest([fromMac, otherMac, directMac]);
  expect(ctx.db.ingest([...dropped, ...keep], phone).accepted).toBe(dropped.length + keep.length);
  const plan = review();
  const selected = plan.segments.flatMap(s => s.records.map(r => r.id));
  for (const r of dropped) expect(selected).not.toContain(r.id);
  expect(evidence().map(e => e.reference.id)).toContain(fromMac.id);
  expect(evidence().map(e => e.reference.id)).toContain(directMac.id);
  for (const r of keep) expect(selected).toContain(r.id);
  framesAt(190);
  const modelsSee = store.frames().flatMap(f => frameView(store, f, { maxRecords: 10, excerpt: () => 1000 }).records.map(r => r.id));
  for (const r of dropped) expect(modelsSee).not.toContain(r.id);
  for (const r of keep) expect(modelsSee).toContain(r.id);
  const search = await new AgentReads(ctx.db).handle("search", new URLSearchParams({ tool: "codex", q: "温室浇灌控制器" }));
  const result = await search.json();
  expect(result.records.map((r: { id: string }) => r.id)).toContain(exact.id);
  expect(ctx.db.get(truncated.id)?.body).toBe(truncated.body);
});

test("Mac 微信迟到后撤下已整理的手机副本，Mac 删除后原通知可再次作为材料", async () => {
  const mobile = notification(60, "合成甲：试验的蓝色托盘已收齐。", "温室 小组", wechat);
  ctx.db.ingest([mobile], phone);
  framesAt(90);
  const frame = store.frames()[0]!;
  store.upsertThread({ id: "phone-thread", title: "合成托盘", status: "active", brief: "旧摘要" });
  store.assign(frame.id, "phone-thread", "llm", 0.9);
  expect(view(mobile.id).records).toHaveLength(1);
  const late = macMessage(61, "试验的蓝色托盘已收齐。");
  ctx.db.ingest([late]);
  framesAt(95);
  expect(store.thread("phone-thread")?.brief).toBeNull();
  expect(view(mobile.id).records).toEqual([]);
  const llm: LLM = { async complete() { throw new Error("重复帧不应调用模型"); } };
  expect((await digestStep({ db: ctx.db, llm }, store, Date.parse(at(96)))).calls).toBe(0);
  expect(ctx.db.delete(late.id)).toBe(true);
  expect(view(mobile.id).records.map(r => r.id)).toEqual([mobile.id]);
  expect(evidence().map(e => e.reference.id)).toContain(mobile.id);
  expect(store.thread("phone-thread")?.needs_regen).toBe(1);
});

test("晚到的 Mac 微信替换手机副本后，旧候选和此刻待整理状态均不计重复帧", async () => {
  const mobile = notification(60, "合成甲：白色试验箱已入库。");
  ctx.db.ingest([mobile], phone);
  framesAt(85);
  const mobileFrame = store.frames()[0]!;
  const assign = (expectedFrame: string, ignore: boolean): LLM => ({ async complete<T>(req: LLMRequest) {
    expect(req.refs).toEqual({ s1: expectedFrame });
    return { ok: true, ms: 1, data: { items: [
      { frame_id: "s1", thread_id: null, new_thread_title: "合成试验箱", ignore, confidence: 0.9 },
    ] } as T };
  } });
  expect((await assignStep({ db: ctx.db, llm: assign(mobileFrame.id, false) }, store, Date.parse(at(85)))).candidates).toBe(1);
  const mac = macMessage(61, "白色试验箱已入库。");
  ctx.db.ingest([mac]);
  framesAt(86);
  const macFrame = store.frames().find(f => f.record_ids.includes(mac.id))!;
  expect((await assignStep({ db: ctx.db, llm: assign(macFrame.id, true) }, store, Date.parse(at(86)))).candidates).toBe(0);
  expect(currentNow(ctx.db, Date.parse(at(86)))?.brief).not.toBe("有新活动待整理。");
});

test("有应用包名的手机微信沿用 Mac 微信会话的项目归属", () => {
  store.upsertProject({ id: "greenhouse", name: "合成温室项目", keys: { repos: [], hosts: [], chats: [`${macApp}:温室小组`] } });
  store.upsertThread({ id: "assigned", status: "active", title: "合成校准", project_id: "greenhouse", last_ms: Date.parse(at(55)) });
  const record = notification(60, "合成甲：已完成控制器校准。", "温室 小组", wechat);
  ctx.db.ingest([record], phone);
  expect(framesAt(80).assigned).toBe(1);
  expect(view(record.id)).toMatchObject({ key: `chat:${macApp}:温室 小组`, records: [{ id: record.id, excerpt: record.body }] });
  expect(review().segments[0]?.projectName).toBe("合成温室项目");
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
