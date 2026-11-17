import { expect, test } from "bun:test";
import { toLocalIso } from "../../packages/record/index.ts";
import { reviewInput, reviewPlan } from "../src/distill/day-review.ts";
import { dayStep, distillRound, sliceStep, touchThread, type LLM } from "../src/distill/run.ts";
import { DistillStore } from "../src/distill/store.ts";
import { createHandler } from "../src/server.ts";
import { emptyDayOutput, fixture, setup } from "./helpers.ts";

type ReviewInput = { activities: { key: string; kind: string; active_minutes: number;
  evidence: { key: string; source: string; role: string; text: string; at?: string }[] }[] };
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
  const screen = span(5, 15, { title: "展板编辑", body: "屏幕正文应排除" });
  const browser = span(8, 12, { source: "mac.browser", source_ref: "map-preview", title: "地图预览", body: "浏览器正文应排除" });
  const followup = span(22, 27, { source: "codex.session", source_ref: "demo#22", body: "[我] 已补齐图例，明天才印刷。" });
  const conversation = span(50, 53, { source: "mac.audio", body: "[10:50:05] 我：周六九点集合。" });
  const conversationEnd = span(54, 57, { source: "mac.audio", body: "[10:54:05] 对方：周六九点在车站见。" });
  const noise = span(60, 63, { title: "短窗口应排除", context: { window: "临时查阅" }, body: "短窗口正文应排除" });
  const misc = span(70, 77, { title: "志愿者工作表", context: { window: "志愿者工作表" }, body: "工作表正文应排除" });
  const privateNote = fixture({ source: "manual.note", t_start: point(80), sensitivity: "private", body: "私密正文应排除" });
  const fragment = fixture({ source: "mac.wechat", t_start: point(83), context: { chat: "零散消息", extra: { from_me: 0 } } });
  const note = fixture({ source: "manual.note", t_start: point(84) });
  const scheduled = span(85, 90, { source: "codex.session", source_ref: "synthetic-auto#0",
    body: "[我] Automation: 合成定期任务\nAutomation ID: example\n\n[AI] 合成自动内容应排除。" });
  const scheduledTail = span(91, 93, { source: "codex.session", source_ref: "synthetic-auto#1", body: "[AI] 自动任务续篇应排除。" });
  const lateSession = span(100, 120, { source: "claude_code.session", source_ref: "late-session", body: "[我] 跨截止点内容应排除。" });
  try {
    const records = [first, screen, browser, followup, conversation, conversationEnd, noise, misc,
      privateNote, fragment, note, scheduled, scheduledTail, lateSession];
    expect(ctx.db.ingest(records).accepted).toBe(records.length);
    store.upsertProject({ id: "museum", name: "合成展厅", keys: { repos: [], hosts: [], chats: [] } });
    store.upsertThread({ id: "map", title: "展板", status: "active", project_id: "museum" });
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
      expect(thread?.evidence.map(e => e.at)).toEqual([point(0), point(10), undefined]);
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
    const [a,b,c,d] = review.detail.items;
    expect(review.detail.items).toHaveLength(4);
    expect(a).toMatchObject({ id: first.id, title: "排定导览图", active_seconds: 20 * 60, t_start: point(0), t_end: point(27),
      sources: ["codex.session","mac.screen","mac.browser"],
      apps: [{ source: "codex.session", app: null }, { source: "mac.screen", app: null }, { source: "mac.browser", app: null }],
      record_ids: [first.id, screen.id, browser.id, followup.id], project_id: "museum",
      evidence: [{ id: first.id, at: first.t_start, source: first.source, title: first.title }, { id: followup.id }] });
    expect(b).toMatchObject({ title: "约定车站集合", active_seconds: 6 * 60, t_start: point(50), t_end: point(57) });
    expect(c).toMatchObject({ title: "志愿者工作表", active_seconds: 7 * 60, evidence: [{ id: misc.id }] });
    expect(d).toMatchObject({ description: "有 Claude Code 会话记录。", evidence: [{ id: lateSession.id }] });
    expect(review.detail.items.flatMap((item: { record_ids: string[] }) => item.record_ids)).not.toContain(privateNote.id);
    expect(review.detail.items.flatMap((item: { record_ids: string[] }) => item.record_ids)).not.toContain(noise.id);
    expect(Object.keys(a.evidence[0]).sort()).toEqual(["at", "id", "source", "title"]);
    expect(review.detail.timeline[0]).toEqual({ start: "10:00", end: "10:27", text: "排定导览图" });
    expect((await request(ctx, `/v1/records/${a.evidence[0].id}`)).status).toBe(200);
    expect(ctx.db.get(screen.id)?.body).toBe(screen.body);
  } finally { ctx.cleanup(); }
});

test("同一事项相隔恰好 30 分钟仍接续，间隔再长时另起一段", () => {
  const ctx = setup();
  try {
    const pieces = [[0, 40], [70, 90], [121, 140]].map(([from, to], i) => span(from!, to!, {
      source: "codex.session", source_ref: "synthetic-exhibit#" + i, body: "[我] 核对展厅标识。",
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
      expect(req.prompt).not.toContain("应排除");
      expect(req.prompt).not.toContain("合成私密修正");
      expect(req.prompt).not.toContain("不应进入任何段");
      expect(parse(req.prompt).activities).toHaveLength(1);
      expect(parse(req.prompt).activities[0]!.kind).toBe("session");
      return { ok: true, data: emptyDayOutput as T, ms: 1 };
    } };
    expect(await dayStep({ db: ctx.db, llm }, store, day, base + 25 * min)).toEqual({ ok: true, calls: 1 });
    const items = store.day(day)!.detail.items;
    expect(items).toHaveLength(1);
    expect(items[0]).toMatchObject({
      id: wrote.id, title: "安排活动表", description: "有 Codex 会话记录。",
      t_start: point(0), t_end: point(20), active_seconds: 20 * 60,
      apps: [{ source: "mac.screen", app: "org.example.reader" }, { source: "mac.wechat", app: "org.example.chat" }, { source: "codex.session", app: "codex" }],
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
      [background.id + ":" + (base + 18 * min), base + 18 * min, base + 40 * min, 22 * 60, "project-0", [background.id]],
      [next.id, base + 40 * min, base + 46 * min, 6 * 60, null, [next.id]],
    ]);
    expect(segments[1]!.apps).toEqual([{ source: "codex.session", app: "codex" }, { source: "mac.audio", app: "org.example.call" }]);
    expect(segments[1]!.evidence.map(e => e.reference.id)).toEqual([dialogue.id]);
    expect(segments[0]!.evidence.map(e => [e.at, e.text])).toEqual([[point(0), "检查活动表。"]]);
    expect(segments[2]!.evidence.map(e => [e.at, e.text])).toEqual([[point(40), "末条说明展板已放到入口。"]]);
    expect(segments[3]!.evidence).toEqual([]);
  } finally { ctx.cleanup(); }
});

test("长录音在三十段预算中仍为双方保留首尾和中间发言", () => {
  const ctx = setup();
  try {
    const voices = Array.from({ length: 12 }, (_, i) =>
      `[10:${(i * 4).toString().padStart(2, "0")}:00] ${i % 2 ? "对方" : "我"}：合成讨论 ${i}。`);
    const audio = span(0, 50, { source: "mac.audio", source_ref: "synthetic-long-audio", body: voices.join("\n") });
    const others = Array.from({ length: 29 }, (_, i) => span(55 + i * 2, 56 + i * 2, {
      source: "codex.session", source_ref: "synthetic-other-" + i, body: "[我] 调整合成展板。",
    }));
    expect(ctx.db.ingest([audio, ...others]).accepted).toBe(30);
    const segments = reviewInput(ctx.db, base, base + 120 * min);
    expect(segments).toHaveLength(30);
    const conversation = segments[0]!;
    expect(conversation.evidence.filter(e => e.role === "user").map(e => e.at)).toEqual([point(0), point(16), point(24), point(40)]);
    expect(conversation.evidence.filter(e => e.role === "other").map(e => e.at)).toEqual([point(4), point(20), point(28), point(44)]);
    expect(segments.flatMap(s => s.evidence)).toHaveLength(37);
  } finally { ctx.cleanup(); }
});

test("没有文字依据时用这段覆盖最多的来源和标题，避免借用开头短窗口", async () => {
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
    expect(store.day(day)!.detail.items).toMatchObject([
      { title: "合成展板窗口", description: "有前台窗口记录。", evidence: [{ id: window.id }], record_ids: [transient.id, window.id] },
    ]);
  } finally { ctx.cleanup(); }
});

test("超过 30 段时为项目保留代表，余段按实际覆盖选取，原始记录仍可查询", async () => {
  const ctx = setup(), store = new DistillStore(ctx.db);
  try {
    const records = Array.from({ length: 32 }, (_, i) => span(4 * i, 4 * i + (i < 2 ? 1 : 2), {
      source: "codex.session", source_ref: "synthetic-cap-" + i + "#0", body: "[我] 调整合成展板。",
    }));
    expect(ctx.db.ingest(records).accepted).toBe(32);
    const representative = records[0]!;
    store.upsertProject({ id: "reserved", name: "合成冷门项目", keys: { repos: [], hosts: [], chats: [] } });
    store.upsertThread({ id: "reserved-thread", title: "冷门事项", status: "active", project_id: "reserved" });
    store.createFrame({ id: "reserved-frame", key: "synthetic-cap", record_ids: [representative.id],
      t_start_ms: base, t_end_ms: base + min, chars: 1, private: 0, status: "new" });
    store.assign("reserved-frame", "reserved-thread", "rule", 1);
    const plan = reviewPlan(ctx.db, base, base + 140 * min);
    expect(plan.diagnostics).toEqual({ candidateCount: 32, mergedCount: 0, omittedCount: 2, longestActivityRetained: true, fallbackCount: 0 });
    expect(plan.segments).toHaveLength(30);
    expect(plan.segments[0]!.id).toBe(representative.id);
    expect(plan.omittedRecordIds).toEqual([records[1]!.id, records[31]!.id]);
    const llm: LLM = { async complete<T>(req: import("../src/llm/index.ts").LLMRequest) {
      expect(parse(req.prompt).activities).toHaveLength(30);
      return { ok: true, data: emptyDayOutput as T, ms: 1 };
    } };
    expect(await dayStep({ db: ctx.db, llm }, store, day, base + 140 * min)).toEqual({ ok: true, calls: 1 });
    const detail = store.day(day)!.detail;
    expect(detail.items).toHaveLength(30);
    expect(detail.omitted_record_ids).toEqual(plan.omittedRecordIds);
    expect(ctx.db.get(records[1]!.id)).not.toBeNull();
  } finally { ctx.cleanup(); }
});

test("项目数超过上限时，仍保留最长单段和累计用时最长活动的一段", () => {
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
    expect(plan.segments).toHaveLength(30);
    expect(plan.segments.filter(s => s.activity.projectId)).toHaveLength(28);
    expect(plan.segments.map(s => s.id)).toContain(longest.id);
    expect(plan.segments.map(s => s.id)).toContain(dominant[0]!.id);
    expect(plan.diagnostics.longestActivityRetained).toBe(true);
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
