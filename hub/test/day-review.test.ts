import { expect, test } from "bun:test";
import { toLocalIso } from "../../packages/record/index.ts";
import { dayStep, distillRound, sliceStep, touchThread, type LLM } from "../src/distill/run.ts";
import { DistillStore } from "../src/distill/store.ts";
import { createHandler } from "../src/server.ts";
import { emptyDayOutput, fixture, setup } from "./helpers.ts";

type ReviewInput = { activities: { key: string; kind: string; active_minutes: number;
  evidence: { key: string; source: string; role: string; text: string }[] }[] };
const parse = (prompt: string) => JSON.parse(/<data>\n([\s\S]*)\n<\/data>/.exec(prompt)![1]!) as ReviewInput;
const day = "2026-11-16", base = Date.parse(day + "T10:00:00"), min = 60_000;
const point = (offset: number) => toLocalIso(base + offset * min);
const span = (from: number, to: number, overrides: Parameters<typeof fixture>[0] = {}) => fixture({
  kind: "span", t_start: point(from), t_end: point(to), ...overrides,
});
const request = (ctx: ReturnType<typeof setup>, route: string, method = "GET") =>
  createHandler({ db: ctx.db, token: ctx.config.token })(new Request("http://127.0.0.1:47823" + route, {
    method, headers: { host: "127.0.0.1:47823", authorization: `Bearer ${ctx.config.token}` },
  }));

test("回顾按同一事项聚合跨时段活动，保留实际时长和来源，保留可点回的原文", async () => {
  const ctx = setup(), store = new DistillStore(ctx.db), now = base + 110 * min;
  const first = span(0, 10, { source: "codex.session", source_ref: "demo#0", title: "核对导览图", body: "[我] 入口改到北门。\n\n[AI] 请补齐图例。" });
  const screen = span(5, 15, { title: "展板编辑", body: "屏幕正文应排除" });
  const browser = span(8, 12, { source: "mac.browser", source_ref: "map-preview", title: "地图预览", body: "浏览器正文应排除" });
  const followup = span(40, 45, { source: "codex.session", source_ref: "demo#40", body: "[我] 已补齐图例，明天才印刷。" });
  const conversation = span(50, 52, { source: "mac.audio", body: "[10:50:05] 我：周六九点集合。" });
  const conversationEnd = span(55, 57, { source: "mac.audio", body: "[10:55:05] 对方：周六九点在车站见。" });
  const noise = span(60, 63, { title: "短窗口应排除", context: { window: "临时查阅" }, body: "短窗口正文应排除" });
  const misc = span(70, 77, { title: "志愿者工作表", context: { window: "志愿者工作表" }, body: "工作表正文应排除" });
  const privateNote = fixture({ source: "manual.note", t_start: point(80), sensitivity: "private", body: "私密正文应排除" });
  const lateSession = span(100, 120, { source: "claude_code.session", source_ref: "late-session", body: "[我] 跨截止点内容应排除。" });
  try {
    const records = [first, screen, browser, followup, conversation, conversationEnd, noise, misc, privateNote, lateSession];
    expect(ctx.db.ingest(records).accepted).toBe(records.length);
    store.upsertThread({ id: "map", title: "展板", status: "active" });
    for (const [i, record] of [first, screen, browser, followup].entries()) {
      const id = `f${i}`;
      store.createFrame({ id, key: "app:demo", record_ids: [record.id], t_start_ms: Date.parse(record.t_start),
        t_end_ms: Date.parse(record.t_end!), chars: 1, private: 0, status: "new" });
      store.assign(id, "map", "rule", 1);
    }
    const llm: LLM = { async complete<T>(req: import("../src/llm/index.ts").LLMRequest) {
      expect(req.task).toBe("day");
      expect(req.prompt).not.toContain("应排除");
      const { activities: [thread, audio] } = parse(req.prompt);
      expect(thread?.active_minutes).toBe(20);
      expect(thread?.evidence.map(e => e.role)).toEqual(["user", "assistant", "user"]);
      expect(audio?.evidence.map(e => e.role)).toEqual(["user", "other"]);
      return { ok: true, data: { highlight: { activity: thread!.key, text: "定下导览入口并补齐图例" }, items: [
        { activity: audio!.key, title: "约定车站集合", description: "周六九点在车站见。", refs: ["r2"] },
        { activity: thread!.key, title: "排定导览图", description: "入口改到北门，图例已补齐。展板还没印。", refs: ["r1","r3"] },
        { activity: "outside", title: "虚构事项", description: "不会出现在结果里。", refs: ["r1"] },
      ] } as T, ms: 1 };
    } };
    expect(await dayStep({ db: ctx.db, llm }, store, day, now)).toEqual({ ok: true, calls: 1 });
    const review = await (await request(ctx, `/v1/days/${day}`)).json();
    expect(review.brief).toBe("定下导览入口并补齐图例");
    expect(review.detail.cutoff).toBe(toLocalIso(now));
    const [a,b,c] = review.detail.items;
    expect(review.detail.items).toHaveLength(3);
    expect(a).toMatchObject({ id: "thread:map", title: "排定导览图", active_seconds: 20 * 60, t_start: point(0), t_end: point(45),
      sources: ["codex.session","mac.screen","mac.browser"],
      evidence: [{ id: first.id, at: first.t_start, source: first.source, title: first.title }, { id: followup.id }] });
    expect(b).toMatchObject({ title: "约定车站集合", active_seconds: 4 * 60, t_start: point(50), t_end: point(57) });
    expect(c).toMatchObject({ title: "志愿者工作表", active_seconds: 7 * 60, evidence: [{ id: misc.id }] });
    expect(review.detail.timeline.filter((chapter: {text:string}) => chapter.text === "排定导览图")).toEqual([
      {start:"10:00",end:"10:15",text:"排定导览图"}, {start:"10:40",end:"10:45",text:"排定导览图"},
    ]);
    expect((await request(ctx, `/v1/records/${a.evidence[0].id}`)).status).toBe(200);
    expect(ctx.db.get(screen.id)?.body).toBe(screen.body);
  } finally { ctx.cleanup(); }
});

test("模型给错依据时不覆盖已有回顾，重试成功时同时更新事项和页首", async () => {
  const ctx = setup(), store = new DistillStore(ctx.db);
  const record = span(0, 12, { source: "codex.session", source_ref: "poster-session", body: "[我] 新展板已摆好。" });
  const now = base + 30 * min;
  try {
    ctx.db.ingest([record]);
    store.upsertDay({ date: day, brief: "已有摘要", detail: { summary: "已有摘要", items: [], timeline: [] }, needs_regen: 1 });
    const model = (ref: string): LLM => ({ async complete<T>(req: import("../src/llm/index.ts").LLMRequest) {
      const a = parse(req.prompt).activities[0]!.key;
      return { ok: true, data: { highlight: { activity: a, text: "展板已摆好" },
        items: [{ activity: a, title: "摆放展板", description: "新展板已摆好。", refs: [ref] }] } as T, ms: 1 };
    } });
    expect((await dayStep({ db: ctx.db, llm: model("absent") }, store, day, now)).ok).toBe(false);
    expect((await (await request(ctx, `/v1/days/${day}`)).json())).toMatchObject({ brief: "已有摘要", needs_regen: 1, failed: true });
    expect((await dayStep({ db: ctx.db, llm: model("r1") }, store, day, now)).ok).toBe(true);
    const result = await (await request(ctx, `/v1/days/${day}`)).json();
    expect(result).toMatchObject({ brief: "展板已摆好", needs_regen: 0,
      detail: { summary: "展板已摆好", items: [{ title: "摆放展板" }] } });
    expect(result.failed).toBeUndefined();
  } finally { ctx.cleanup(); }
});

test("历史回顾通过旧库读取，但接口只暴露已约定字段", async () => {
  const ctx = setup(), store = new DistillStore(ctx.db);
  const detail = { summary: "旧摘要", timeline: [{ start: "10:00", end: "11:00", text: "旧标签" }], sections: { old: "旧内容" } };
  try {
    store.upsertDay({ date: day, detail, needs_regen: 0 });
    expect((await (await request(ctx, `/v1/days/${day}`)).json()).detail).toEqual({ summary: detail.summary, timeline: detail.timeline });
    expect((await (await request(ctx, `/v1/agent/get?tool=codex&id=${day}&level=detail`)).json()).item.detail).not.toHaveProperty("sections");
    expect(store.day(day)?.detail).toEqual(detail);
  } finally { ctx.cleanup(); }
});

test.each(["删除", "修正为私密"])("跨午夜录音按转写行归当天，%s 时撤下两天的回顾", async action => {
  const ctx = setup(), store = new DistillStore(ctx.db);
  const earlier = "2026-11-16", later = "2026-11-17";
  const midnight = Date.parse(later + "T00:00:00"), now = midnight + 20 * min;
  const audio = fixture({ source: "mac.audio", source_ref: "synthetic-midnight-audio", kind: "span",
    t_start: toLocalIso(midnight - 2 * min), t_end: toLocalIso(midnight + 2 * min),
    body: "[23:59:55] 我：合成的前一天发言。\n[00:00:00] 对方：合成的零点说明。\n[00:01:30] 我：合成的第二天决定。" });
  try {
    expect(ctx.db.ingest([audio]).accepted).toBe(1);
    sliceStep(ctx.db, false, now, Date.parse(earlier + "T00:00:00"));
    const expected = [["合成的前一天发言。"], ["合成的零点说明。","合成的第二天决定。"]];
    for (const [i, date] of [earlier,later].entries()) {
      expect(store.day(date)?.needs_regen).toBe(1);
      const llm: LLM = { async complete<T>(req: import("../src/llm/index.ts").LLMRequest) {
        const a = parse(req.prompt).activities[0]!;
        expect(a.evidence.map(e => e.text)).toEqual(expected[i]!);
        return { ok: true, data: { ...emptyDayOutput, items: [{ activity: a.key, title: "商量周末路线", description: a.evidence.map(e => e.text).join(""), refs: a.evidence.map(e => e.key) }] } as T, ms: 1 };
      } };
      expect(await dayStep({ db: ctx.db, llm }, store, date, now)).toEqual({ ok: true, calls: 1 });
      expect(store.day(date)?.detail.items[0]).toMatchObject({ active_seconds: 120,
        evidence: [{ id: audio.id, at: audio.t_start }] });
    }
    if (action === "删除") expect((await request(ctx, "/v1/records/" + audio.id, "DELETE")).status).toBe(200);
    else expect(ctx.db.ingest([fixture({ source: "manual.correction", corrects: audio.id, sensitivity: "private",
      t_start: toLocalIso(now), body: "合成的私密修正。" })]).accepted).toBe(1);
    for (const date of [earlier,later]) expect(store.day(date)).toMatchObject({ detail: null, brief: null, needs_regen: 1 });
  } finally { ctx.cleanup(); }
});

test("定时整理关闭旧问题、按使用天归档，暂停事项跨天仍可接续", async () => {
  const ctx = setup(), store = new DistillStore(ctx.db);
  const start = new Date("2026-11-01T10:00:00").getTime(), day = 86_400_000, now = start + 12 * day;
  try {
    const days = Array.from({ length: 9 }, (_, i) => fixture({ t_start: toLocalIso(start + i * day) }));
    expect(ctx.db.ingest(days).accepted).toBe(days.length);
    store.setState("enabled_ms", start);
    store.setState("last_rowid", days.length);
    store.setState("cursor_ms", now);
    store.upsertThread({ id: "older", title: "合成事项", status: "active", last_ms: start, needs_regen: 0, domain: "work" });
    store.upsertThread({ id: "other", title: "合成事项乙", status: "active", last_ms: start + 3 * day, needs_regen: 0, domain: "work" });
    store.createPending({ id: "old-question", kind: "thread_done", payload: { thread_id: "older" }, created_at: toLocalIso(start) });
    const llm: LLM = { async complete() { throw new Error("这轮没有新片段"); } };
    const round = await distillRound({ db: ctx.db, llm, now: () => now });
    expect(round.lifecycle).toEqual({ paused: 1, asked: 0, archived: 1, expired: 1 });
    expect(store.pending()).toEqual([]);
    expect(store.thread("older")?.status).toBe("archived");
    expect(store.thread("other")?.status).toBe("paused");

    const followup = fixture({ t_start: toLocalIso(now) });
    expect(ctx.db.ingest([followup]).accepted).toBe(1);
    const frame = { id: "later", key: "app:test", record_ids: [followup.id], chars: 5, private: 0,
      status: "new" as const, t_start_ms: now, t_end_ms: now + 60_000 };
    store.createFrame(frame);
    store.assign(frame.id, "other", "rule", 1);
    touchThread(store, "other", frame);
    expect(store.thread("other")).toMatchObject({ status: "active", last_ms: frame.t_end_ms });
  } finally { ctx.cleanup(); }
});
