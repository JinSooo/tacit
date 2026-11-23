import { afterEach, beforeEach, expect, test } from "bun:test";
import { HubDB } from "../src/db.ts";
import { DistillStore } from "../src/distill/store.ts";
import { projectStep, distillRound, frameView, assignStep, digestStep, LIMITS, type LLM } from "../src/distill/run.ts";
import { persistFrames } from "../src/distill/frames.ts";
import { ulid, toLocalIso } from "../../packages/record/index.ts";
import * as P from "../src/distill/prompts.ts";
import { conversationsIn, saveSummary } from "../src/conversations.ts";
import { hubStatus } from "../src/status.ts";
import type { LLMRequest } from "../src/llm/index.ts";
import { fixture, setup } from "./helpers.ts";

let ctx: ReturnType<typeof setup>, store: DistillStore;
beforeEach(() => { ctx = setup(); store = new DistillStore(ctx.db); });
afterEach(() => ctx.cleanup());
const now = new Date("2026-11-08T18:00:00").getTime(), date = "2026-11-08";
const base = new Date(`${date}T10:00:00`).getTime(), MIN = 60_000;
const projectDetail = { goal: "目标", status: "项目进展", people: [] };

function seed() {
  const record = fixture({ t_start: new Date(base).toISOString(), body: "合成活动证据" });
  ctx.db.ingest([record]);
  store.upsertProject({ id: "p", name: "合成项目", keys: { repos: [], hosts: [], chats: [] }, needs_regen: 1 });
  store.upsertThread({ id: "t", title: "合成线程", project_id: "p", domain: "work", status: "active", brief: "合成线程简略版", needs_regen: 0, last_ms: base });
  store.createFrame({ id: "f", record_ids: [record.id], key: "app:synthetic", t_start_ms: base, t_end_ms: base + MIN, chars: 10, private: 0, status: "new" });
  store.assign("f", "t", "user", 1);
  store.upsertDay({ date, needs_regen: 1 });
}
function retryModel() {
  const calls: LLMRequest[] = [], failed = new Set<string>();
  const llm: LLM = { async complete<T>(req: LLMRequest) {
    calls.push(req);
    if (req.task === "project_brief" && !failed.has(req.prompt)) {
      failed.add(req.prompt); return { ok: false, error: "合成短暂故障", ms: 1 };
    }
    const data = req.system === P.PROJECT_SYSTEM ? projectDetail : { brief: "最终简略版" };
    return { ok: true, data: data as T, ms: 1 };
  } };
  return { llm, calls };
}

test("项目简略版失败后重开数据库，调度只重试简略版", async () => {
  seed(); const fake = retryModel();
  await projectStep({ db: ctx.db, llm: fake.llm }, store, now);
  const key = "project_brief:p";
  expect(store.project("p")).toMatchObject({ detail: projectDetail, brief: null, needs_regen: 0 });
  expect(store.getState(key)).toBe(true);
  expect(hubStatus(ctx.db, { port: 1, now }).distill.needs_regen.projects).toBe(1);
  store.upsertDay({ date, needs_regen: 0 });
  store.setState("cursor_ms", now); store.setState("dedup_ms", now);
  const reopened = new HubDB(ctx.file, ctx.config.dbKey);
  try {
    await distillRound({ db: reopened, llm: fake.llm, now: () => now }, { slow: true, days: "all" });
  } finally { reopened.close(); }
  expect(fake.calls.filter(c => c.system === P.PROJECT_SYSTEM)).toHaveLength(1);
  expect(fake.calls.filter(c => c.system === P.BRIEF_SYSTEM)).toHaveLength(2);
  expect(store.project("p")).toMatchObject({ detail: projectDetail, brief: "最终简略版", needs_regen: 0 });
  expect(store.getState(key)).toBeNull();
});

test("项目简略版待生成时有新变化，仍重做详细版", async () => {
  seed(); const fake = retryModel(), deps = { db: ctx.db, llm: fake.llm };
  await projectStep(deps, store, now);
  store.upsertThread({ ...store.thread("t")!, brief: "新的输入内容" });
  store.upsertProject({ ...store.project("p")!, needs_regen: 1 });
  await projectStep(deps, store, now);
  const calls = fake.calls.filter(c => c.system === P.PROJECT_SYSTEM);
  expect(calls).toHaveLength(2);
  expect(calls[1]!.prompt).toContain("新的输入内容");
});

test("三条同场录音：单片段及跨片段请求仅含一份总结，正文与证据 id 全保留，下一请求重新提供总结", async () => {
  const records = Array.from({ length: 3 }, (_, i) => fixture({ source: "mac.audio", source_ref: `audio-${i}`, kind: "span",
    t_start: new Date(base + i * 2 * MIN).toISOString(), t_end: new Date(base + (i * 2 + 1) * MIN).toISOString(),
    body: `第${i + 1}条独立正文${"内容".repeat(110)}`, capture: { method: "asr" } }));
  ctx.db.ingest(records);
  const group = conversationsIn(ctx.db, base, base + 10 * MIN)[0]!;
  const summary = "整场唯一总结：讨论构建和发布".repeat(8), point = "唯一要点：保留原始证据";
  saveSummary(ctx.db, group, { title: "构建发布讨论", summary, points: [point] });
  const frames = records.map((r, i) => ({ id: `f${i}`, record_ids: [r.id], key: "app:audio", t_start_ms: base + i * 2 * MIN, t_end_ms: base + (i * 2 + 1) * MIN, chars: r.body.length, private: 0, status: "new" as const }));
  const opts = { maxRecords: 10, excerpt: () => 240 };
  const single = frameView(store, { ...frames[0]!, record_ids: records.map(r => r.id) }, opts);
  expect(JSON.stringify(single).split(summary)).toHaveLength(2);
  for (const f of frames) store.createFrame(f);
  const calls: LLMRequest[] = [];
  const llm: LLM = { async complete<T>(req: LLMRequest) {
    calls.push(req);
    // 不改归属，方便同一组片段再次进入请求。
    return { ok: true, data: { items: [] } as T, ms: 1 };
  } };
  await assignStep({ db: ctx.db, llm }, store, now);
  await assignStep({ db: ctx.db, llm }, store, now);
  expect(calls).toHaveLength(2);
  for (const call of calls) {
    expect(call.prompt.split(summary)).toHaveLength(2);
    expect(call.prompt.split(point)).toHaveLength(2);
    for (const record of records) { expect(call.prompt).toContain(record.body); expect(call.prompt).toContain(record.id); }
  }
  // digest 共用请求拼装：按记录预算仍保留各自正文。
  const prompt = P.threadPrompt({ title: "线程", detail: {} }, [], frames.map(f => frameView(store, f, { maxRecords: Infinity, excerpt: () => Infinity })));
  expect(prompt.split(summary)).toHaveLength(2);
  for (const record of records) expect(prompt).toContain(record.body);
});

test("生成项目简略版期间的新失效标记不被成功回写覆盖", async () => {
  seed();
  const llm: LLM = { async complete<T>(req: LLMRequest) {
    if (req.task === "project_brief") {
      store.upsertProject({ ...store.project("p")!, needs_regen: 1 });
      return { ok: true, data: { brief: "合成简略" } as T, ms: 1 };
    }
    return { ok: true, data: projectDetail as T, ms: 1 };
  } };
  await projectStep({ db: ctx.db, llm }, store, now);
  expect(store.project("p")!.needs_regen).toBe(1);
});

test("conversationsIn 经单条 SQL 继承修正记录的私密标记，不逐条回查", () => {
  const normal = fixture({ source: "android.audio", device: "phone-synth", source_ref: "a-1", kind: "span",
    t_start: toLocalIso(base), t_end: toLocalIso(base + MIN), body: "我：普通内容", capture: { method: "asr" } });
  const initiallyPrivate = fixture({ source: "android.audio", device: "phone-synth", source_ref: "a-2", kind: "span",
    t_start: toLocalIso(base + 30 * MIN), t_end: toLocalIso(base + 31 * MIN), body: "我：原私密内容", sensitivity: "private", capture: { method: "asr" } });
  const markPrivate = fixture({ source: "manual.correction", device: "phone-synth", corrects: normal.id,
    t_start: toLocalIso(base + 2 * MIN), body: "我：改标为私密", sensitivity: "private" });
  const tryRelax = fixture({ source: "manual.correction", device: "phone-synth", corrects: initiallyPrivate.id,
    t_start: toLocalIso(base + 32 * MIN), body: "我：修正文案", sensitivity: "normal" });
  expect(ctx.db.ingest([normal, initiallyPrivate, markPrivate, tryRelax]).accepted).toBe(4);
  const groups = conversationsIn(ctx.db, base, base + 40 * MIN, "phone-synth");
  expect(groups).toHaveLength(2);
  expect(groups[0]!.private).toBe(true);
  expect(groups[1]!.private).toBe(true);
});

test("批量展开大量手机录音片段不触发 O(N²) 窗口重查与内存暴涨", async () => {
  store.setState("enabled_ms", 0);
  const records = Array.from({ length: 300 }, (_, i) => {
    const start = base + i * 2 * MIN;
    return fixture({
      id: ulid(start), device: "phone-synth", source: "android.audio", source_ref: `batch-${i}`, kind: "span",
      t_start: toLocalIso(start), t_end: toLocalIso(start + 30_000), title: `合成录音 ${i}`,
      body: "我：核对苗圃浇水节奏。\n对方：明天上午完成。", capture: { method: "asr" },
    });
  });
  expect(ctx.db.ingest(records).accepted).toBe(300);
  const firstGroup = conversationsIn(ctx.db, base, base + 650 * MIN, "phone-synth")[0]!;
  saveSummary(ctx.db, firstGroup, { title: "苗圃浇水讨论", summary: "确认明天上午完成浇水。", points: ["明天上午完成"] });
  const persisted = persistFrames(ctx.db, 0, base + 700 * MIN);
  expect(persisted.frames).toHaveLength(300);

  const rssBefore = process.memoryUsage().rss;
  const assignPrompts: string[] = [];
  const llm: LLM = {
    async complete<T>(req: LLMRequest) {
      if (req.task === "assign") {
        assignPrompts.push(req.prompt);
        return { ok: true, data: { items: [] } as T, ms: 1 };
      }
      return { ok: true, data: {
        domain: "life", in_project: false, title: "苗圃浇水",
        detail: { goal: "", progress: "已核对浇水节奏", artifacts: { files: [], urls: [], commands: [], people: [] }, quotes: [] },
        new_facts: [], invalidate: [], brief: "核对苗圃浇水节奏。",
      } as T, ms: 1 };
    },
  };
  await assignStep({ db: ctx.db, llm }, store, base + 700 * MIN);
  expect(assignPrompts.length).toBeGreaterThan(0);
  expect(assignPrompts[0]).toContain("苗圃浇水讨论");

  store.upsertThread({ id: "t-audio", title: "苗圃浇水", status: "active", needs_regen: 1, last_ms: base + 600 * MIN });
  for (const frame of persisted.frames) store.assign(frame.id, "t-audio", "rule", 1);
  const digest = await digestStep({ db: ctx.db, llm }, store, base + 700 * MIN, "all");
  expect(digest.updated).toBe(1);
  const rssDeltaMB = (process.memoryUsage().rss - rssBefore) / 1048576;
  expect(rssDeltaMB).toBeLessThan(150);
});
