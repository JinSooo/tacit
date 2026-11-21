import { expect, test } from "bun:test";
import { toLocalIso } from "../../packages/record/index.ts";
import { composeReview, reviewInput, reviewMaterial, reviewPlan } from "../src/distill/day-review.ts";
import { dayStep, distillRound, sliceStep, touchThread, type LLM } from "../src/distill/run.ts";
import { DistillStore } from "../src/distill/store.ts";
import { createHandler } from "../src/server.ts";
import { emptyDayOutput, fixture, setup } from "./helpers.ts";

type ReviewInput = { activities: { key: string; kind: string; active_minutes: number; project: string | null; summary_eligible: boolean;
  evidence: { key: string; source: string; role: string; text: string; at?: string; chat?: string; speaker?: string }[] }[] };
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

test("段保留连续活动的实际时长、全部原文和模型引用，排除私密与零碎记录", async () => {
  const ctx = setup(), store = new DistillStore(ctx.db), now = base + 110 * min;
  const first = span(0, 10, { source: "codex.session", source_ref: "demo#0", title: "核对导览图", body: "[我] 入口改到北门。\n\n[AI] 请补齐图例。" });
  const screen = span(1, 4, { title: "展板编辑", body: "屏幕正文应排除" });
  const browser = span(1, 2, { source: "mac.browser", source_ref: "map-preview", title: "地图预览", body: "浏览器正文应排除" });
  const followup = span(3, 8, { source: "codex.session", source_ref: "demo#22", body: "[我] 已补齐图例，明天才印刷。" });
  const conversation = span(50, 53, { source: "mac.audio", body: "[10:50:05] 我：周六九点集合。" });
  const conversationEnd = span(54, 57, { source: "mac.audio", body: "[10:54:05] 合成向导：周六九点在车站见。\n[10:54:10] 对方 1：我搭早班车。" });
  const noise = span(60, 63, { title: "短窗口应排除", context: { window: "临时查阅" }, body: "短窗口正文应排除" });
  const chatStart = fixture({ source: "mac.wechat", t_start: point(65),
    context: { chat: "合成展览群", extra: { from_me: 1 } }, body: "我已经把手册放在入口。" });
  const chatEnd = fixture({ source: "mac.wechat", t_start: point(67),
    context: { chat: "合成展览群", extra: { from_me: 0, sender: "合成编辑" } }, body: "我已经换成新版手册了。" });
  const misc = span(70, 77, { title: "志愿者工作表", context: { window: "志愿者工作表" }, body: "工作表正文应排除" });
  const privateChat = span(78, 81, { source: "mac.wechat", sensitivity: "private",
    context: { chat: "合成私密群", extra: { from_me: 0, sender: "合成私密联系人" } }, body: "私密正文应排除" });
  const fragment = fixture({ source: "mac.wechat", t_start: point(83), context: { chat: "零散消息", extra: { from_me: 0 } } });
  const note = fixture({ source: "manual.note", t_start: point(84) });
  const scheduled = span(85, 90, { source: "codex.session", source_ref: "synthetic-auto#0",
    body: "[我] Automation: 合成定期任务\nAutomation ID: example\n\n[AI] 合成自动内容应排除。" });
  const scheduledTail = span(91, 93, { source: "codex.session", source_ref: "synthetic-auto#1", body: "[AI] 自动任务续篇应排除。" });
  const lateSession = span(100, 120, { source: "claude_code.session", source_ref: "late-session", body: "[我] 跨截止点内容应排除。" });
  try {
    const records = [first, screen, browser, followup, conversation, conversationEnd, noise, chatStart, chatEnd, misc,
      privateChat, fragment, note, scheduled, scheduledTail, lateSession];
    expect(ctx.db.ingest(records).accepted).toBe(records.length);
    store.upsertProject({ id: "museum", name: "合成展厅", keys: { repos: [], hosts: [], chats: [] } });
    store.upsertThread({ id: "map", title: "展板", status: "active", project_id: "museum" });
    for (const [i, record] of [first, screen, browser, followup].entries()) {
      const id = `f${i}`;
      store.createFrame({ id, key: "app:demo", record_ids: [record.id], t_start_ms: Date.parse(record.t_start),
        t_end_ms: Date.parse(record.t_end!), chars: 1, private: 0, status: "new" });
      store.assign(id, "map", "rule", 1);
    }
    const summary = "合成展厅定下了导览入口并补齐图例。和合成向导约在车站集合。合成编辑已把入口的手册换成新版。";
    const llm: LLM = { async complete<T>(req: import("../src/llm/index.ts").LLMRequest) {
      expect(req.task).toBe("day");
      expect(req.prompt).not.toContain("屏幕正文应排除");
      expect(req.prompt).not.toContain("合成私密群");
      expect(req.prompt).not.toContain("合成私密联系人");
      expect(req.prompt).not.toContain("私密正文应排除");
      const { activities: [thread, audio, chat] } = parse(req.prompt);
      expect(thread?.project).toBe("合成展厅");
      expect(thread?.active_minutes).toBe(10);
      expect(thread?.evidence.map(e => e.role)).toEqual(["user", "user", "assistant"]);
      expect(thread?.evidence.map(e => e.at)).toEqual([point(0), undefined, point(10)]);
      expect(audio?.project).toBeNull();
      expect(audio?.evidence.map(e => e.role)).toEqual(["user", "other", "other"]);
      expect(audio?.evidence.map(e => e.speaker)).toEqual([undefined, "合成向导", undefined]);
      expect(chat?.summary_eligible).toBe(true);
      expect(chat?.evidence.map(e => [e.chat, e.speaker])).toEqual([["合成展览群", undefined], ["合成展览群", "合成编辑"]]);
      return { ok: true, data: { highlight: { activities: [thread!.key, audio!.key, chat!.key], text: summary }, items: [
        { activity: audio!.key, title: "约定车站集合", description: "周六九点在车站见。", refs: [audio!.evidence[1]!.key] },
        { activity: thread!.key, title: "排定导览图", description: "入口改到北门，图例已补齐。展板还没印。", refs: [thread!.evidence[0]!.key,thread!.evidence[1]!.key] },
        { activity: chat!.key, title: "入口换上新版手册", description: "新版手册已放在入口。", refs: [chat!.evidence[1]!.key] },
        { activity: "outside", title: "虚构事项", description: "不会出现在结果里。", refs: ["r1"] },
      ] } as T, ms: 1 };
    } };
    expect(await dayStep({ db: ctx.db, llm }, store, day, now)).toEqual({ ok: true, calls: 1 });
    const review = await (await request(ctx, `/v1/days/${day}`)).json();
    expect(review.brief).toBe(summary);
    expect(review.detail.summary).toBe(summary);
    const agentDay = await (await request(ctx, `/v1/agent/get?tool=codex&level=detail&id=${day}`)).json();
    expect(agentDay.item.detail.summary).toBe(summary);
    expect(review.detail.cutoff).toBe(toLocalIso(now));
    const [a,b] = review.detail.items;
    expect(review.detail.items).toHaveLength(3);
    expect(a).toMatchObject({ id: first.id, title: "排定导览图", active_seconds: 10 * 60, t_start: point(0), t_end: point(10),
      sources: ["codex.session"], apps: [{ source: "codex.session", app: null }],
      record_ids: [first.id, screen.id, browser.id, followup.id], project_id: "museum",
      evidence: [{ id: first.id, at: first.t_start, source: first.source, title: first.title }, { id: followup.id }] });
    expect(b).toMatchObject({ title: "约定车站集合", active_seconds: 6 * 60, t_start: point(50), t_end: point(57) });
    expect(review.detail.omitted_record_ids).toEqual(expect.arrayContaining([misc.id, lateSession.id]));
    expect(ctx.db.get(misc.id)?.title).toBe(misc.title);
    expect(review.detail.items.flatMap((item: { record_ids: string[] }) => item.record_ids)).not.toContain(privateChat.id);
    expect(review.detail.items.flatMap((item: { record_ids: string[] }) => item.record_ids)).not.toContain(noise.id);
    expect(Object.keys(a.evidence[0]).sort()).toEqual(["at", "id", "source", "title"]);
    expect(review.detail.timeline[0]).toEqual({ start: "10:00", end: "10:10", text: "排定导览图" });
    expect((await request(ctx, `/v1/records/${a.evidence[0].id}`)).status).toBe(200);
    expect(ctx.db.get(screen.id)?.body).toBe(screen.body);
  } finally { ctx.cleanup(); }
});

test("同一事项相隔恰好 30 分钟仍接续，间隔再长时另起一段", () => {
  const ctx = setup();
  try {
    const pieces = [[0, 40], [70, 90], [121, 140]].map(([from, to], i) => span(from!, to!, {
      source: "mac.wechat", context: { chat: "合成展厅", extra: { from_me: 1 } }, body: "核对展厅标识。",
    }));
    expect(ctx.db.ingest(pieces).accepted).toBe(3);
    const segments = reviewInput(ctx.db, base, base + 150 * min);
    expect(segments.map(a => [a.start, a.end, a.seconds, a.records.map(r => r.id)])).toEqual([
      [base, base + 90 * min, 60 * 60, [pieces[0]!.id, pieces[1]!.id]],
      [base + 121 * min, base + 140 * min, 19 * 60, [pieces[2]!.id]],
    ]);
    expect(segments[0]!.id).not.toBe(segments[1]!.id);
  } finally { ctx.cleanup(); }
});

test("同一活动间隔不足 30 分钟但实际覆盖不足六成，保留两个段", () => {
  const ctx = setup();
  try {
    const first = span(0, 5, { source: "codex.session", source_ref: "synthetic-gap#0", body: "[我] 核对标识。" });
    const last = span(15, 20, { source: "codex.session", source_ref: "synthetic-gap#1", body: "[我] 更新标识。" });
    expect(ctx.db.ingest([first, last]).accepted).toBe(2);
    expect(reviewInput(ctx.db, base, base + 30 * min).map(s => s.id)).toEqual([first.id, last.id]);
  } finally { ctx.cleanup(); }
});

test("时间完全交叠时用户作主段，其他来源和记录仍在同一段", async () => {
  const ctx = setup(), store = new DistillStore(ctx.db);
  try {
    const read = span(0, 20, { context: { app: "org.example.reader" }, body: "屏幕正文应排除" });
    const received = span(0, 20, { source: "mac.wechat", context: { app: "org.example.chat", chat: "志愿者", extra: { from_me: 0 } },
      body: "图书馆十点开门。" });
    const wrote = span(0, 20, { source: "codex.session", source_ref: "synthetic-event#0", context: { app: "codex" },
      body: "[我] 把活动表放到入口。", title: "安排活动表" });
    const hidden = span(0, 20, { source: "manual.note", body: "不应进入任何段" });
    const correction = fixture({ source: "manual.correction", corrects: hidden.id, sensitivity: "private", body: "合成私密修正" });
    expect(ctx.db.ingest([read, received, wrote, hidden, correction]).accepted).toBe(5);
    const llm: LLM = { async complete<T>(req: import("../src/llm/index.ts").LLMRequest) {
      expect(req.prompt).not.toContain("屏幕正文应排除");
      expect(req.prompt).not.toContain("合成私密修正");
      expect(req.prompt).not.toContain("不应进入任何段");
      expect(parse(req.prompt).activities).toHaveLength(1);
      expect(parse(req.prompt).activities[0]!.kind).toBe("session");
      const a = parse(req.prompt).activities[0]!;
      return { ok: true, data: { highlight: null, items: [{ activity: a.key, title: "活动表放在入口",
        description: "决定将活动表放在入口。", refs: [a.evidence.find(e => e.role === "user")!.key] }] } as T, ms: 1 };
    } };
    expect(await dayStep({ db: ctx.db, llm }, store, day, base + 25 * min)).toEqual({ ok: true, calls: 1 });
    const items = store.day(day)!.detail.items;
    expect(items).toHaveLength(1);
    expect(items[0]).toMatchObject({
      id: wrote.id, title: "活动表放在入口", description: "决定将活动表放在入口。",
      t_start: point(0), t_end: point(20), active_seconds: 20 * 60,
      apps: [{ source: "codex.session", app: "codex" }],
      record_ids: [read.id, received.id, wrote.id],
    });
  } finally { ctx.cleanup(); }
});

test("长 AI 会话中部让位给有时间戳的对话，项目时长与原文不串项目", async () => {
  const ctx = setup(), store = new DistillStore(ctx.db);
  try {
    const background = span(0, 40, { source: "codex.session", source_ref: "synthetic-background#0",
      context: { app: "codex" }, body: "[我] 检查活动表。\n\n[AI] 批次中没有单独时间的草案。\n\n[AI] 末条说明展板已放到入口。" });
    const dialogue = span(14, 23, { source: "mac.audio", source_ref: "synthetic-dialogue", context: { app: "org.example.call" },
      body: "[10:16:00] 对方：给下午的分享会留十个座位。" });
    const next = span(40, 46, { source: "mac.screen", title: "合成新窗口" });
    expect(ctx.db.ingest([background, dialogue, next]).accepted).toBe(3);
    for (const [i, record] of [background, dialogue].entries()) {
      const projectId = "project-" + i, threadId = "thread-" + i;
      store.upsertProject({ id: projectId, name: "合成项目 " + i, keys: { repos: [], hosts: [], chats: [] } });
      store.upsertThread({ id: threadId, status: "active", title: "合成事项", project_id: projectId });
      store.createFrame({ id: threadId, key: threadId, record_ids: [record.id], t_start_ms: Date.parse(record.t_start),
        t_end_ms: Date.parse(record.t_end!), chars: record.body.length, private: 0, status: "new" });
      store.assign(threadId, threadId, "rule", 1);
    }
    const segments = reviewInput(ctx.db, base, base + 50 * min);
    expect(segments.map(s => [s.id, s.start, s.end, s.seconds, s.activity.projectId, s.records.map(r => r.id)])).toEqual([
      [background.id, base, base + 14 * min, 14 * 60, "project-0", [background.id]],
      [dialogue.id, base + 14 * min, base + 18 * min, 4 * 60, "project-1", [dialogue.id]],
      [`${background.id}:${base + 18 * min}`, base + 18 * min, base + 30 * min, 12 * 60, "project-0", [background.id]],
    ]);
    expect(segments[1]!.apps).toEqual([{ source: "codex.session", app: "codex" }, { source: "mac.audio", app: "org.example.call" }]);
    expect(segments[1]!.evidence.map(e => e.reference.id)).toEqual([dialogue.id]);
    expect(segments[0]!.evidence.map(e => e.role)).toEqual(["user", "assistant", "assistant"]);
    const material = reviewMaterial(segments);
    expect(material).toHaveLength(3);
    expect(material[1]!.continues).toBeUndefined();
    expect(reviewPlan(ctx.db, base, base + 50 * min).omittedRecordIds).toContain(next.id);
  } finally { ctx.cleanup(); }
});

test("长录音在三十段预算中仍为双方保留首尾和中间发言", () => {
  const ctx = setup();
  try {
    const voices = Array.from({ length: 12 }, (_, i) =>
      `[10:${(i * 4).toString().padStart(2, "0")}:00] ${i % 2 ? "对方" : "我"}：合成讨论 ${i}。`);
    const audio = span(0, 50, { source: "mac.audio", source_ref: "synthetic-long-audio", body: voices.join("\n") });
    const others = Array.from({ length: 29 }, (_, i) => span(55 + i * 5, 56 + i * 5, {
      source: "codex.session", source_ref: "synthetic-other-" + i, body: "[我] 调整合成展板。",
    }));
    expect(ctx.db.ingest([audio, ...others]).accepted).toBe(30);
    const segments = reviewInput(ctx.db, base, base + 210 * min);
    expect(segments).toHaveLength(30);
    const conversation = segments[0]!;
    expect(conversation.evidence.filter(e => e.role === "user").map(e => e.at)).toEqual([point(0), point(16), point(24), point(40)]);
    expect(conversation.evidence.filter(e => e.role === "other").map(e => e.at)).toEqual([point(4), point(20), point(28), point(44)]);
    expect(segments.flatMap(s => s.evidence)).toHaveLength(37);
  } finally { ctx.cleanup(); }
});

test("只有时间骨架时不编造一条回顾，不调用模型，原文仍可查看", async () => {
  const ctx = setup(), store = new DistillStore(ctx.db);
  try {
    const transient = span(0, 1, { source: "mac.browser", source_ref: "synthetic-short-browser", title: "合成短页面" });
    const window = span(2, 14, { title: "合成展板窗口", context: { app: "org.example.editor" } });
    expect(ctx.db.ingest([transient, window]).accepted).toBe(2);
    store.upsertThread({ id: "synthetic-thread", status: "active", title: "合成事项" });
    store.createFrame({ id: "synthetic-frame", key: "synthetic-app", record_ids: [transient.id, window.id],
      t_start_ms: base, t_end_ms: base + 14 * min, chars: 1, private: 0, status: "new" });
    store.assign("synthetic-frame", "synthetic-thread", "rule", 1);
    const llm: LLM = { async complete() { throw new Error("只有应用和时间元数据"); } };
    expect(await dayStep({ db: ctx.db, llm }, store, day, base + 20 * min)).toEqual({ ok: true, calls: 0 });
    expect(store.day(day)!.detail).toMatchObject({ items: [], summary: null,
      omitted_record_ids: [transient.id, window.id] });
    expect(ctx.db.get(window.id)?.title).toBe("合成展板窗口");
  } finally { ctx.cleanup(); }
});

test("超过 50 个输入候选时为项目保留代表，余段按实际覆盖选取，原始记录仍可查询", async () => {
  const ctx = setup(), store = new DistillStore(ctx.db);
  try {
    const records = Array.from({ length: 52 }, (_, i) => span(6 * i, 6 * i + (i < 2 ? 1 : 2), {
      source: "codex.session", source_ref: "synthetic-cap-" + i + "#0", body: "[我] 调整合成展板。",
    }));
    expect(ctx.db.ingest(records).accepted).toBe(52);
    const representative = records[0]!;
    store.upsertProject({ id: "reserved", name: "合成冷门项目", keys: { repos: [], hosts: [], chats: [] } });
    store.upsertThread({ id: "reserved-thread", title: "冷门事项", status: "active", project_id: "reserved" });
    store.createFrame({ id: "reserved-frame", key: "synthetic-cap", record_ids: [representative.id],
      t_start_ms: base, t_end_ms: base + min, chars: 1, private: 0, status: "new" });
    store.assign("reserved-frame", "reserved-thread", "rule", 1);
    const plan = reviewPlan(ctx.db, base, base + 330 * min);
    expect(plan.diagnostics).toEqual({ candidateCount: 52, mergedCount: 0, omittedCount: 2, longestActivityRetained: true, fallbackCount: 0 });
    expect(plan.segments).toHaveLength(50);
    expect(plan.segments[0]!.id).toBe(representative.id);
    expect(plan.omittedRecordIds).toEqual([records[1]!.id, records[51]!.id]);
    const llm: LLM = { async complete<T>(req: import("../src/llm/index.ts").LLMRequest) {
      expect(parse(req.prompt).activities).toHaveLength(50);
      return { ok: true, data: emptyDayOutput as T, ms: 1 };
    } };
    expect(await dayStep({ db: ctx.db, llm }, store, day, base + 330 * min)).toEqual({ ok: true, calls: 1 });
    const detail = store.day(day)!.detail;
    expect(detail.items).toHaveLength(0);
    expect(new Set(detail.omitted_record_ids)).toEqual(new Set(records.map(r => r.id)));
    expect(ctx.db.get(records[1]!.id)).not.toBeNull();
  } finally { ctx.cleanup(); }
});

test("项目数在五十候选预算内时，保留最长单段和累计用时最长活动", () => {
  const ctx = setup(), store = new DistillStore(ctx.db);
  try {
    const projects = Array.from({ length: 32 }, (_, i) => span(i * 3, i * 3 + 2, {
      source: "codex.session", source_ref: "synthetic-project-" + i, body: "[我] 核对合成图例。",
    }));
    const longest = span(100, 107, { source: "codex.session", source_ref: "synthetic-longest", body: "[我] 校对一张展板。" });
    const dominant = Array.from({ length: 4 }, (_, i) => span(120 + i * 35, 122 + i * 35, {
      source: "codex.session", source_ref: "synthetic-dominant#" + i, body: "[我] 更新全套图例。",
    }));
    expect(ctx.db.ingest([...projects, longest, ...dominant]).accepted).toBe(37);
    for (const [i, record] of projects.entries()) {
      const id = "project-" + i;
      store.upsertProject({ id, name: id, keys: { repos: [], hosts: [], chats: [] } });
      store.upsertThread({ id, title: id, status: "active", project_id: id });
      store.createFrame({ id, key: id, record_ids: [record.id], t_start_ms: Date.parse(record.t_start),
        t_end_ms: Date.parse(record.t_end!), chars: 1, private: 0, status: "new" });
      store.assign(id, id, "rule", 1);
    }
    const plan = reviewPlan(ctx.db, base, base + 240 * min);
    expect(plan.segments).toHaveLength(37);
    expect(plan.segments.filter(s => s.activity.projectId)).toHaveLength(32);
    expect(plan.segments.map(s => s.id)).toContain(longest.id);
    expect(plan.segments.map(s => s.id)).toContain(dominant[0]!.id);
    expect(plan.diagnostics.longestActivityRetained).toBe(true);
  } finally { ctx.cleanup(); }
});

test("无文字依据的长窗口不挤占有内容的段和模型预算", () => {
  const ctx = setup();
  try {
    const windows = Array.from({ length: 31 }, (_, i) => span(i * 7, i * 7 + 6, {
      title: "合成窗口 " + i, context: { window: "synthetic-window-" + i },
    }));
    const decision = span(220, 221, { source: "codex.session", source_ref: "synthetic-decision",
      body: "[我] 展览入口改到北门，版式还没有改。" });
    expect(ctx.db.ingest([...windows, decision]).accepted).toBe(32);
    const plan = reviewPlan(ctx.db, base, base + 230 * min);
    expect(plan.segments.map(s => s.id)).toEqual([decision.id]);
    expect(new Set(plan.omittedRecordIds)).toEqual(new Set(windows.map(r => r.id)));
    expect(reviewMaterial(plan.segments)[0]!.evidence[0]!.text).toContain("版式还没有改");
  } finally { ctx.cleanup(); }
});

test("相接事项的引用全局唯一，不能把前一段的 r1 当成本段的依据", () => {
  const ctx = setup();
  try {
    const records = [0, 45].map((offset, i) => span(offset, offset + 10, {
      source: "codex.session", source_ref: "synthetic-continuation#" + i, body: "[我] 入口海报完成试排。",
    }));
    expect(ctx.db.ingest(records).accepted).toBe(2);
    const plan = reviewPlan(ctx.db, base, base + 60 * min), material = reviewMaterial(plan.segments);
    const refs = material.map(a => a.evidence[0]!.key);
    expect(new Set(refs).size).toBe(2);
    expect(material[1]!.continues).toBe(material[0]!.key);
    const output = { highlight: null, items: material.map(a => ({ activity: a.key,
      title: "入口海报完成试排", description: "海报完成试排。", refs: [a.evidence[0]!.key] })) };
    const compose = () => composeReview(plan.segments, output, base + 24 * 60 * min, point(60), [], plan.dependencyRecordIds)!;
    expect(compose().items.map(item => item.evidence[0]!.id)).toEqual(records.map(r => r.id));
    output.items[1]!.refs = [refs[0]!];
    expect(compose().items).toHaveLength(1);
    expect(compose().omitted_record_ids).toContain(records[1]!.id);
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
        items: [{ activity: a, title: "摆放展板", description: "新展板已摆好。", refs: [ref === "valid" ? parse(req.prompt).activities[0]!.evidence[0]!.key : ref] }] } as T, ms: 1 };
    } });
    expect((await dayStep({ db: ctx.db, llm: model("absent") }, store, day, now)).ok).toBe(false);
    expect((await (await request(ctx, `/v1/days/${day}`)).json())).toMatchObject({ brief: "已有摘要", needs_regen: 1, failed: true });
    expect((await dayStep({ db: ctx.db, llm: model("valid") }, store, day, now)).ok).toBe(true);
    const result = await (await request(ctx, `/v1/days/${day}`)).json();
    expect(result).toMatchObject({ brief: "展板已摆好", needs_regen: 0,
      detail: { summary: "展板已摆好", items: [{ title: "摆放展板" }] } });
    expect(result.failed).toBeUndefined();
  } finally { ctx.cleanup(); }
});

test("个别引用编号写坏时保留该段，只丢坏引用", () => {
  const ctx = setup();
  try {
    ctx.db.ingest([span(0, 12, { source: "codex.session", source_ref: "poster-refs", body: "[我] 新展板已摆好。" })]);
    const plan = reviewPlan(ctx.db, base, base + 86400000);
    const a = reviewMaterial(plan.segments)[0]!;
    const detail = composeReview(plan.segments, { highlight: { activity: a.key, text: "展板已摆好" },
      items: [{ activity: a.key, content: "result", title: "摆放展板", description: "新展板已摆好。",
        refs: [a.evidence[0]!.key, `${a.evidence[0]!.key}冒`] }] }, base + 86400000, point(12), [], [])!;
    expect(detail.items.map(i => i.title)).toEqual(["摆放展板"]);
    expect(detail.summary).toBe("展板已摆好");
  } finally { ctx.cleanup(); }
});

test("当天概述允许部分编号失效，先脱敏并合成单段，超长优先截在句末", () => {
  const ctx = setup();
  try {
    ctx.db.ingest([span(0, 12, { source: "codex.session", source_ref: "synthetic-summary", body: "[我] 新展板已摆好。" })]);
    const plan = reviewPlan(ctx.db, base, base + 86400000), activity = reviewMaterial(plan.segments)[0]!;
    const compose = (activities: string[], text: string) => composeReview(plan.segments, {
      highlight: { activities, text },
      items: [{ activity: activity.key, content: "result", title: "摆放展板", description: "新展板已摆好。", refs: [activity.evidence[0]!.key] }],
    }, base + 86400000, point(12), [], [])!.summary;
    const syntheticKey = "sk-proj-" + "aB3_".repeat(6);
    const text = `新展板已摆好。\r\n 清除了测试密钥 ${syntheticKey}。\n正在试装 0.2.2 ${"未完".repeat(80)}`;
    expect(compose(["unknown", activity.key], text)).toBe("新展板已摆好。 清除了测试密钥 [已脱敏:OpenAI]。");
    const atLimit = "𠮷".repeat(159) + "。";
    expect(compose([activity.key], atLimit + "未完")).toBe(atLimit);
    expect(compose([activity.key], "𠮷".repeat(161))).toBe("𠮷".repeat(160));
    expect(compose(["unknown"], text)).toBe("摆放展板");
  } finally { ctx.cleanup(); }
});

test("整理中途原文改为私密，已返回的模型段也不能重新写回", async () => {
  const ctx = setup(), store = new DistillStore(ctx.db);
  const record = span(0, 5, { source: "codex.session", source_ref: "synthetic-inflight", body: "[我] 核对合成图例。" });
  try {
    expect(ctx.db.ingest([record]).accepted).toBe(1);
    const llm: LLM = { async complete<T>(req: import("../src/llm/index.ts").LLMRequest) {
      const a = parse(req.prompt).activities[0]!;
      expect(ctx.db.ingest([fixture({ source: "manual.correction", corrects: record.id, sensitivity: "private",
        body: "改为私密的合成记录", t_start: point(10) })]).accepted).toBe(1);
      return { ok: true, data: { highlight: null, items: [{ activity: a.key, title: "合成图例",
        description: "核对了合成图例。", refs: ["r1"] }] } as T, ms: 1 };
    } };
    expect(await dayStep({ db: ctx.db, llm }, store, day, base + 20 * min)).toEqual({ ok: false, calls: 1 });
    expect(store.day(day)).toMatchObject({ detail: null, needs_regen: 1 });
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

test("goal、自动任务和 Claude 交接不计用户在场时间，也不能成为摘要", () => {
  const ctx = setup();
  try {
    const automatic = [
      span(0, 180, { source: "codex.session", source_ref: "synthetic-goal", body: '[我] <codex_internal_context source="goal">\nContinue the synthetic task.\n</codex_internal_context>\n\n[AI] 展板完成试排。' }),
      span(190, 240, { source: "claude_code.session", source_ref: "synthetic-handoff", body: '[我] Context handoff (manual_context):\nHistorical synthetic material.\n\n[AI] 图例已补齐。' }),
      span(250, 300, { source: "codex.session", source_ref: "synthetic-automation", body: '[我] Automation: 合成检查\nAutomation ID: synthetic\n\n[AI] 完成合成检查。' }),
    ];
    ctx.db.ingest(automatic);
    const plan = reviewPlan(ctx.db, base, base + 310 * min), material = reviewMaterial(plan.segments);
    expect(plan.segments).toHaveLength(3);
    expect(plan.segments.every(s => s.start === s.end && s.seconds === 0)).toBe(true);
    expect(material.every(s => !s.summary_eligible)).toBe(true);
    expect(material.flatMap(s => s.evidence).every(e => e.role === "assistant")).toBe(true);
    const result = composeReview(plan.segments, { highlight: { activity: material[0]!.key, text: "不应入选" },
      items: material.map(s => ({ activity: s.key, title: "完成展板试排", description: "展板完成试排。", content: "result", refs: [s.evidence[0]!.key] })) }, base + 86400000, point(310), [], [])!;
    expect(result.summary).toBeNull();
    expect(result.timeline).toEqual([]);
  } finally { ctx.cleanup(); }
});

test("续跑产出并回同日用户发起段，不拉长时间；摘要选有用户在场的主线", () => {
  const ctx = setup();
  try {
    const initiated = span(10, 30, { source: "codex.session", source_ref: "synthetic-exhibit#0", body: "[我] 检查展板并修复图例。" });
    const continued = span(40, 190, { source: "codex.session", source_ref: "synthetic-exhibit#1", body: '[我] <codex_internal_context source="goal">Continue</codex_internal_context>\n\n[AI] 图例修复并通过检查。' });
    ctx.db.ingest([initiated, continued]);
    const plan = reviewPlan(ctx.db, base, base + 200 * min), material = reviewMaterial(plan.segments);
    expect(plan.segments).toHaveLength(1);
    expect(plan.segments[0]).toMatchObject({ start: base + 10 * min, end: base + 30 * min, seconds: 1200 });
    expect(plan.segments[0]!.records.map(r => r.id)).toEqual([initiated.id, continued.id]);
    expect(material[0]!.evidence.some(e => e.text.includes("图例修复"))).toBe(true);
    expect(material[0]!.evidence.some(e => e.text.includes("Continue"))).toBe(false);
  } finally { ctx.cleanup(); }
});

test("只有 AI 回复的后续批次接着上一条输入计时，每条输入仍最多三十分钟", () => {
  const ctx = setup();
  try {
    const ask = span(10, 25, { source: "codex.session", source_ref: "synthetic-reply#2026-11-16T01:00:00.000Z", body: "[我] 检查展板。\n\n[AI] 开始检查。" });
    const reply = span(25, 33, { source: "codex.session", source_ref: "synthetic-reply#2026-11-16T01:00:00.000Z#2", body: "[AI] 展板已检查，图例补齐。" });
    const late = span(45, 60, { source: "codex.session", source_ref: "synthetic-reply#2026-11-16T01:00:00.000Z#3", body: "[AI] 又补了一张导览图。" });
    ctx.db.ingest([ask, reply, late]);
    const plan = reviewPlan(ctx.db, base, base + 70 * min);
    expect(plan.segments).toHaveLength(1);
    expect(plan.segments[0]).toMatchObject({ start: base + 10 * min, end: base + 33 * min, seconds: 23 * 60 });
    expect(plan.segments[0]!.records.map(r => r.id)).toEqual([ask.id, reply.id, late.id]);
  } finally { ctx.cleanup(); }
});

test("结构化判断排除纯请求与空录音，保留后续结果和用户明确判断", () => {
  const ctx = setup();
  try {
    const records = [
      span(0, 5, { source: "codex.session", source_ref: "synthetic-request#0", body: "[我] 请调整展板。" }),
      span(45, 50, { source: "codex.session", source_ref: "synthetic-request#1", body: "[我] 我认为现在图例对比度足够。\n\n[AI] 展板已调整。" }),
      span(90, 91, { source: "mac.audio", body: "[11:30:00] 我：嗯，那个。" }),
    ];
    ctx.db.ingest(records);
    const plan = reviewPlan(ctx.db, base, base + 100 * min), material = reviewMaterial(plan.segments);
    expect(material[1]!.continues).toBe(material[0]!.key);
    const output = { highlight: null, omissions: [0,2].map(i => ({activity: material[i]!.key, reason:i===0?"request_only":"empty", title:"",description:"",refs:[]})), items: material.map((s,i) => ({ activity: s.key,
      content: (["request_only", "judgment", "empty"] as const)[i]!,
      title: i === 1 ? "认为图例对比度足够" : "要求调整展板", description: "展板已调整，认为图例对比度足够。", refs: [s.evidence[0]!.key] })) };
    const detail = composeReview(plan.segments, output, base + 86400000, point(100), [], [])!;
    expect(detail.items.map(i => i.title)).toEqual(["认为图例对比度足够"]);
    expect(detail.omitted_record_ids).toEqual([records[0]!.id,records[2]!.id]);
    output.items[1]!.content = "request_only";
    expect(composeReview(plan.segments, output, base + 86400000, point(100), [], [])!.items).toHaveLength(1);
  } finally { ctx.cleanup(); }
});

test("同批跨度在输入预算内保留实际区间与全部发言", () => {
  const ctx = setup();
  try {
    const near = span(10, 13, { source: "claude_code.session", source_ref: "synthetic-near", body: "[我] 图例改用深色。\n\n[AI] 已改。\n\n[我] 认为对比度足够。" });
    const far = span(60, 120, { source: "claude_code.session", source_ref: "synthetic-far", body: "[我] 检查导览图。\n\n[AI] 已检查。\n\n[我] 决定保留北门入口。" });
    ctx.db.ingest([near,far]);
    const plan = reviewPlan(ctx.db, base, base + 130 * min);
    expect(plan.segments).toHaveLength(2);
    expect(plan.segments[0]!.evidence.filter(e => e.role === "user").map(e => e.text)).toEqual(["图例改用深色。","认为对比度足够。"]);
    expect(new Set(plan.segments.map(s => s.id)).size).toBe(2);
    const material = reviewMaterial(plan.segments);
    const detail = composeReview(plan.segments, {highlight:null, items:material.map(s => ({activity:s.key,title:"导览图完成调整",description:"导览图完成调整。",refs:[s.evidence[0]!.key],content:"result"}))},base+86400000,point(130),[],[])!;
    expect(detail.items.every(i => i.record_ids.length === 1)).toBe(true);
  } finally { ctx.cleanup(); }
});

test("批次计时保留实际起止，单输入截到三十分钟，多输入按总预算", () => {
  const ctx = setup();
  try {
    ctx.db.ingest([
      span(0, 45, { source: "codex.session", source_ref: "cap-one", body: "[我] 调整展板。\n\n[AI] 展板已调整。" }),
      span(90, 140, { source: "codex.session", source_ref: "cap-two", body: "[我] 调整入口。\n\n[我] 补齐图例。\n\n[AI] 完成。" }),
    ]);
    expect(reviewInput(ctx.db, base, base + 150 * min).map(s => [s.start, s.end, s.seconds])).toEqual([
      [base, base + 30 * min, 1800], [base + 90 * min, base + 140 * min, 3000],
    ]);
  } finally { ctx.cleanup(); }
});

test("晚间真实输入按实际覆盖参与预算，不被早间统一四分钟窗口挤掉", () => {
  const ctx = setup();
  try {
    const early = Array.from({length:30}, (_,i) => span(i*4,i*4+1, {source:"codex.session", source_ref:`morning-${i}`,body:"[我] 核对图例。\n\n[AI] 图例已核对。"}));
    const late = span(600,620,{source:"codex.session",source_ref:"evening",body:"[我] 修好展板。\n\n[AI] 展板已修复。"});
    ctx.db.ingest([...early,late]);
    const plan=reviewPlan(ctx.db,base,base+700*min);
    expect(plan.segments).toHaveLength(31);
    expect(plan.segments.some(s=>s.id===late.id && s.seconds===1200)).toBe(true);
  } finally {ctx.cleanup();}
});

test("评测协议排除整个会话及续跑，正常讨论工具仍保留且原文可搜索", () => {
  const ctx=setup();
  try {
    const records=[
      span(0,5,{source:"claude_code.session",source_ref:"eval#0",body:"[我] <pasted_content id=synthetic>\n答案字段为 标签，evidence_ids 填依据。\n# MCP Server Instructions\n## tacit_eval\n仅查询数据。\n</pasted_content>\n\n[AI] 结构化输出失败。"}),
      span(8,10,{source:"claude_code.session",source_ref:"eval#1",body:"[AI] 检索完成。"}),
      span(15,20,{source:"codex.session",source_ref:"release",body:"[我] [tacit-tool-session:release-check]\n检查发布。"}),
      span(30,35,{source:"codex.session",source_ref:"normal",body:"[我] 修复 mcp__tacit_eval__ 工具报错。\n\n[AI] 已修复。"}),
    ];
    ctx.db.ingest(records);
    const plan=reviewPlan(ctx.db,base,base+40*min);
    expect(plan.segments.map(s=>s.id)).toEqual([records[3]!.id]);
    expect(ctx.db.get(records[0]!.id)?.body).toContain("结构化输出失败");
  }finally{ctx.cleanup();}
});

test("单纯授权不能被模型当决定，后续同活动结果仍归发起段", () => {
  const ctx=setup();
  try{
    const records=[span(0,1,{source:"codex.session",source_ref:"approve",body:"[我] 同意现在更新正式库"}),
      span(10,11,{source:"codex.session",source_ref:"install#0",body:"[我] 安装吧"}),
      span(20,30,{source:"codex.session",source_ref:"install#1",body:"[AI] 新版安装完成。"})];
    ctx.db.ingest(records);
    const plan=reviewPlan(ctx.db,base,base+40*min), material=reviewMaterial(plan.segments);
    const detail=composeReview(plan.segments,{highlight:null,items:material.map(s=>({activity:s.key,title:"新版已安装",description:"新版安装完成。",content:"result",refs:[s.evidence[0]!.key]}))},base+86400000,point(40),[],[])!;
    expect(detail.items).toHaveLength(1);
    expect(detail.items[0]!.record_ids).toContain(records[2]!.id);
    expect(detail.omitted_record_ids).toContain(records[0]!.id);
  }finally{ctx.cleanup();}
});


test("无效或缺失省略类别恢复模型结果，无文字时报警且原文未入时间线", () => {
  const ctx = setup();
  try {
    const records = [0,10,20,30].map((n,i) => span(n,n+5,{source:"codex.session",source_ref:`synthetic-result-${i}`,
      body:"[我] 检查展板。\n\n[AI] 已复现图例重叠，原因是宽度没有更新。"}));
    ctx.db.ingest(records);
    const plan=reviewPlan(ctx.db,base,base+40*min), material=reviewMaterial(plan.segments), warnings:string[]=[];
    const detail=composeReview(plan.segments,{highlight:null,items:[{activity:material[0]!.key,content:"empty",title:"图例重叠已复现",description:"定位到宽度没有更新。",refs:[material[0]!.evidence[1]!.key]}],
      omissions:[{activity:material[1]!.key,reason:"not_important",title:"图例重叠已复现",description:"定位到宽度没有更新。",refs:[material[1]!.evidence[1]!.key]},
        {activity:material[2]!.key,reason:"unfinished",title:"",description:"",refs:[]}]},base+86400000,point(40),[],[],a=>warnings.push(a))!;
    expect(detail.items).toHaveLength(2);
    expect(warnings).toHaveLength(4);
    expect(detail.omitted_record_ids).toEqual(records.slice(2).map(r=>r.id));
  } finally {ctx.cleanup();}
});

test("五十候选的结果最多三十段，同项目不同事项不合并", () => {
  const ctx=setup(), store=new DistillStore(ctx.db);
  try {
    const records=Array.from({length:50},(_,i)=>span(i*3,i*3+2,{source:"codex.session",source_ref:`synthetic-limit-${i}`,body:"[我] 检查展板。\n\n[AI] 图例位置已修正。"}));
    ctx.db.ingest(records);
    store.upsertProject({id:"exhibit",name:"合成展览",keys:{repos:[],hosts:[],chats:[]}});
    records.slice(0,2).forEach((r,i)=>{
      const id=`synthetic-thread-${i}`;
      store.upsertThread({id,title:id,status:"active",project_id:"exhibit"});
      store.createFrame({id,key:id,record_ids:[r.id],t_start_ms:Date.parse(r.t_start),t_end_ms:Date.parse(r.t_end!),chars:1,private:0,status:"new"});store.assign(id,id,"rule",1);
    });
    const plan=reviewPlan(ctx.db,base,base+151*min), material=reviewMaterial(plan.segments);
    expect(material).toHaveLength(50);
    const items = material.map((a,i) => ({ activity:a.key, content:"result" as const, title:"图例位置修正", description:`第 ${i} 张图例位置已修正。`, refs:[a.evidence[1]!.key] }));
    const compose = (activities: string[]) => composeReview(plan.segments, { highlight: { activities, text:"合成图例完成修正" }, items },
      base+86400000,point(151),[],[])!;
    const detail = compose([material[1]!.key]);
    expect(detail.items).toHaveLength(30);
    expect(detail.items[0]!.record_ids).toEqual([records[0]!.id]);
    expect(detail.items[1]!.record_ids).toEqual([records[1]!.id]);
    expect(detail.items[0]!.description).toContain("第 0 张");
    expect(detail.summary).toBe("合成图例完成修正");
    expect(detail.items[0]!.active_seconds).toBe(120);
    expect(detail.omitted_record_ids).toHaveLength(20);
    const discarded = plan.segments.find(segment => detail.omitted_record_ids.includes(segment.id))!;
    expect(compose([discarded.key]).summary).toBe("图例位置修正");
  } finally {ctx.cleanup();}
});

test("无效省略缺文字在运行记录留下警告且保留全天原文", async () => {
  const ctx=setup(),store=new DistillStore(ctx.db);
  try {
    const record=span(0,5,{source:"codex.session",source_ref:"synthetic-warning",body:"[我] 核对展板。\n\n[AI] 发现图例重叠。"});
    ctx.db.ingest([record]);
    const llm:LLM={async complete<T>() {
      ctx.db.db.prepare("INSERT INTO runtime_calls(id,at,at_ms,kind,revision) VALUES(?,?,?,?,?)").run("synthetic-day-warning",point(6),base+6*min,"model",0);
      return {ok:true,data:{highlight:null,items:[],omissions:[]} as T,ms:1,call_id:"synthetic-day-warning"};
    }};
    expect(await dayStep({db:ctx.db,llm},store,day,base+6*min)).toEqual({ok:true,calls:1});
    expect(store.day(day)!.detail.omitted_record_ids).toContain(record.id);
    expect(ctx.db.db.prepare("SELECT error FROM runtime_calls WHERE id=?").get("synthetic-day-warning")).toMatchObject({error:"schema_mismatch"});
  } finally {ctx.cleanup();}
});

test("逐条聊天消息按前后两分钟并集计时，候选与最终段均为五分钟", () => {
  const ctx = setup();
  try {
    ctx.db.ingest([10, 11].map(n => fixture({ source: "mac.wechat", t_start: point(n),
      context: { chat: "合成展览群", extra: { from_me: 1 } }, body: "图例已经核对。" })));
    const plan = reviewPlan(ctx.db, base, base + 30 * min);
    expect(plan.segments).toHaveLength(1);
    expect(plan.segments[0]).toMatchObject({ start: base + 8 * min, end: base + 13 * min, seconds: 300 });
    const a = reviewMaterial(plan.segments)[0]!;
    const detail = composeReview(plan.segments, { highlight: null, items: [{ activity: a.key,
      title: "核对图例", description: "图例已经核对。", refs: [a.evidence[0]!.key], content: "result" }] },
      base + 30 * min, point(30), [], [])!;
    expect(detail.items[0]!.active_seconds).toBe(300);
  } finally { ctx.cleanup(); }
});

test("聊天窗口裁在当天边界内，高优先级录音占用时间不重复计", () => {
  const ctx = setup();
  try {
    ctx.db.ingest([0, 1, 10, 11].map(n => fixture({ source: "mac.wechat", t_start: point(n),
      context: { chat: "合成展览群", extra: { from_me: 0 } }, body: "图例已经核对。" })));
    ctx.db.ingest([span(9, 12, { source: "mac.audio", body: "[10:10:00] 我：已经核对展板。" })]);
    const segments = reviewInput(ctx.db, base, base + 12 * min);
    expect(segments.every(s => s.start >= base && s.end <= base + 12 * min)).toBe(true);
    expect(segments.filter(s => s.activity.kind === "chat")[0]!.seconds).toBe(180);
    expect(segments.every((s,i) => !i || segments[i-1]!.end <= s.start)).toBe(true);
  } finally { ctx.cleanup(); }
});

function assignSyntheticThread(ctx: ReturnType<typeof setup>, records: ReturnType<typeof fixture>[]) {
  const store = new DistillStore(ctx.db);
  store.upsertThread({ id: "synthetic-joined", title: "合成展板", status: "active" });
  records.forEach((r,i) => {
    const id = `synthetic-joined-${i}`;
    store.createFrame({ id, key: id, record_ids: [r.id], t_start_ms: Date.parse(r.t_start),
      t_end_ms: Date.parse(r.t_end!), chars: 1, private: 0, status: "new" });
    store.assign(id, "synthetic-joined", "rule", 1);
  });
}

test("候选覆盖率先切开后恢复六成时，同事项相邻段在预算内也合并", () => {
  const ctx = setup();
  try {
    const records = [[0,5],[15,20],[20,40]].map(([s,e],i) => span(s!,e!, {
      source: "codex.session", source_ref: `synthetic-coverage-${i}`, body: "[我] 图例已核对。" }));
    ctx.db.ingest(records);
    assignSyntheticThread(ctx, records);
    const plan = reviewPlan(ctx.db, base, base + 45 * min);
    expect(plan.segments).toHaveLength(1);
    expect(plan.diagnostics.mergedCount).toBe(1);
    expect(plan.segments[0]!.seconds).toBe(1800);
  } finally { ctx.cleanup(); }
});

for (const scenario of ["ten", "interrupted", "forty", "sparse"] as const) {
  test(`同事项输出合并边界：${scenario}`, () => {
    const ctx = setup();
    try {
      const gap = scenario === "forty" ? 40 : 10, duration = scenario === "sparse" ? 5 : 20;
      const records = [span(0,duration, { source: "codex.session", source_ref: "synthetic-left", body: "[我] 图例已核对。" }),
        span(duration+gap,duration+gap+25, { source: "codex.session", source_ref: "synthetic-right", body: "[我] 展板已经试排。" })];
      if (scenario === "sparse") records[1] = span(15,20, { source: "codex.session", source_ref: "synthetic-right", body: "[我] 展板已经试排。" });
      ctx.db.ingest(records); assignSyntheticThread(ctx, records);
      // 单独读每段，模拟模型省略了中间候选后剩下的两个输出。
      const segments = records.map(r => reviewInput(ctx.db, Date.parse(r.t_start), Date.parse(r.t_end!)+1)[0]!);
      if (scenario === "interrupted") {
        const middle = span(21,29, { source: "codex.session", source_ref: "synthetic-middle", body: "[我] 另一展厅已经核对。" });
        ctx.db.ingest([middle]);
        segments.splice(1,0,reviewInput(ctx.db,base+21*min,base+29*min+1)[0]!);
      }
      segments.forEach((s,i) => s.key = `a${i+1}`);
      const material = reviewMaterial(segments);
      const detail = composeReview(segments, { highlight: null, items: material.map((s,i) => ({ activity:s.key,
        title:`合成结果${i}`, description:i===0?"图例已经核对。余下文字。":"展板已经试排。第二句。",
        refs:[s.evidence[0]!.key], content:"result" })) },base+120*min,point(120),[],[])!;
      expect(detail.items).toHaveLength(scenario === "ten" ? 1 : segments.length);
      if (scenario === "ten") {
        expect(detail.items[0]).toMatchObject({title:"合成结果1", active_seconds:2700,
          description:"展板已经试排。 图例已经核对。"});
        expect(detail.items[0]!.record_ids).toEqual(records.map(r=>r.id));
        expect(detail.items[0]!.evidence).toHaveLength(2);
      }
    } finally { ctx.cleanup(); }
  });
}

test("未归属线程的 AI 段按真实会话识别，不沿用旧帧的共享应用键", () => {
  const ctx = setup(), store = new DistillStore(ctx.db);
  try {
    const records = [0, 1].map(i => span(i*10,i*10+10, { source: "codex.session",
      source_ref: `synthetic-distinct-${i}`, body: "[我] 已经核对图例。" }));
    ctx.db.ingest(records);
    records.forEach((r,i) => store.createFrame({ id: `synthetic-legacy-${i}`, key: "app:synthetic-shared",
      record_ids: [r.id], t_start_ms: Date.parse(r.t_start), t_end_ms: Date.parse(r.t_end!),
      chars: 1, private: 0, status: "new" }));
    expect(reviewInput(ctx.db,base,base+21*min)).toHaveLength(2);
  } finally { ctx.cleanup(); }
});
