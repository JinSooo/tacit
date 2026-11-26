import { afterEach, beforeEach, expect, test } from "bun:test";
import { toLocalIso, type RecordV1 } from "../../packages/record/index.ts";
import { DistillRequests, localDayStart } from "../src/distill/requests.ts";
import { dayStep, distillRound, distillTick, type LLM, type LoopState } from "../src/distill/run.ts";
import { DistillStore } from "../src/distill/store.ts";
import { readTimelineSettings, updateGeneral } from "../src/general-settings.ts";
import { fitSummary, MAX_DAY_SUMMARY_CHARS, summaryLength, summaryProblem } from "../src/distill/prompts.ts";
import type { LLMRequest } from "../src/llm/types.ts";
import { fixture, setup } from "./helpers.ts";

const date = "2026-03-10", start = localDayStart(date)!, min = 60_000;
const at = (minute: number) => start + minute * min;
const chat = (minute: number, name: string, body: string) => fixture({
  source: "mac.wechat", t_start: toLocalIso(at(minute)), title: name, body,
  context: { chat: name, extra: { from_me: 1, sender: "小禾" } },
});
type Material = { key: string; evidence: { key: string; text: string; secondary?: boolean }[] };
const data = (req: LLMRequest) => JSON.parse(req.prompt.split("<data>\n")[1]!.split("\n</data>")[0]!);
const materials = (req: LLMRequest): Material[] => data(req).activities;
let ctx: ReturnType<typeof setup>, store: DistillStore, calls: LLMRequest[];
let failOverview: boolean, overviewText: string, beforePolish: (() => void) | undefined;
const llm: LLM = { async complete<T>(req: LLMRequest) {
  calls.push(req);
  let output: unknown;
  if (req.task === "day" || req.task === "day_polish") {
    if (req.task === "day_polish") beforePolish?.();
    const activities = materials(req);
    output = {
      highlight: null,
      items: activities.filter(a => !a.evidence.some(e => e.text.includes("今天早呀"))).map(a => ({
        activity: a.key, content: "result", title: "苗圃进展", description: "小禾确认了这处苗床的安排。",
        refs: [a.evidence.find(e => !e.secondary)!.key],
      })),
      omissions: activities.filter(a => a.evidence.some(e => e.text.includes("今天早呀"))).map(a => ({
        activity: a.key, reason: "empty", title: "", description: "", refs: [],
      })),
    };
  } else if (req.task === "day_brief") {
    if (failOverview) return { ok: false, error: "schema_mismatch", ms: 1 };
    output = { summary: overviewText };
  } else if (req.task === "assign") {
    output = { items: [] };
  } else return { ok: false, error: "schema_mismatch", ms: 1 };
  return { ok: true, data: output as T, ms: 1 };
} };

beforeEach(() => {
  ctx = setup();
  updateGeneral(ctx.db, { language: "zh" });
  store = new DistillStore(ctx.db);
  calls = [];
  failOverview = false;
  overviewText = "小禾确认了苗床安排。春苗已经分好。";
  beforePolish = undefined;
});
afterEach(() => ctx.cleanup());

const deps = (now: number) => ({ db: ctx.db, now: () => now, llm, log: () => {} });
const round = (minute: number, slow = false) => distillRound(deps(at(minute)), {
  slow, days: "all", enabledDefault: at(minute),
});
const view = (minute: number) => store.dayView(date, { now: at(minute) })!;
const polishCalls = () => calls.filter(req => req.task === "day_polish");
const overviewCalls = () => calls.filter(req => req.task === "day_brief");
const save = (...records: RecordV1[]) => expect(ctx.db.ingest(records).accepted).toBe(records.length);
const setModes = (polish: string, overview: string) =>
  store.setState("general_settings", { language: "zh", timeline_polish: polish, timeline_overview: overview });

function covers(minute: number, records: RecordV1[]) {
  const { detail, drafts } = view(minute);
  const listed = new Set<string>([...detail.items.flatMap((item: { record_ids: string[] }) => item.record_ids),
    ...drafts.flatMap((item: { record_ids: string[] }) => item.record_ids), ...detail.omitted_record_ids]);
  for (const record of records) expect(listed.has(record.id)).toBe(true);
}

test("快轮只润色最后活动严格早于 30 分钟的草稿，保留锚点，省略也进入检查点", async () => {
  const done = chat(480, "东区苗床", "东边的苗床已经贴好标签。");
  const omitted = chat(500, "种植闲聊", "今天早呀，天气不错。");
  const boundary = chat(510, "西区苗床", "西边的苗床已经换土。");
  const open = chat(535, "北区苗床", "刚给北边的苗床浇了水。");
  const noise = fixture({ t_start: toLocalIso(at(520)), body: "虚构屏幕骨架" });
  save(done, omitted, boundary, open, noise);
  expect(view(540).drafts.map((item: { id: string }) => item.id)).toEqual([done.id, omitted.id, boundary.id, open.id]);

  await round(540);
  expect(polishCalls()).toHaveLength(1);
  expect(materials(polishCalls()[0]!)).toHaveLength(2);
  expect(polishCalls()[0]!.prompt).not.toContain(boundary.body);
  expect(polishCalls()[0]!.prompt).not.toContain(open.body);
  expect(view(540).detail.items.map((item: { id: string }) => item.id)).toEqual([done.id]);
  expect(view(540).drafts.map((item: { id: string }) => item.id)).toEqual([boundary.id, open.id]);
  expect(view(540).detail.omitted_record_ids).toEqual(expect.arrayContaining([omitted.id, noise.id]));
  expect(view(540).detail.cutoff).toBe(toLocalIso(at(502)));
  covers(540, [done, omitted, boundary, open, noise]);

  await round(555);
  expect(materials(polishCalls()[1]!)).toHaveLength(1);
  expect(data(polishCalls()[1]!).recent).toEqual([{ title: "苗圃进展", description: "小禾确认了这处苗床的安排。" }]);
  expect(view(555).drafts.map((item: { id: string }) => item.id)).toEqual([open.id]);
  covers(555, [done, omitted, boundary, open, noise]);
});

test("迟到成员只重润色一段，落在截止前空档的独立记录也会出现在草稿", async () => {
  const first = chat(480, "东区苗床", "东边的苗床已经换土。");
  const second = chat(535, "西区苗床", "西边新挂了遮阳布。");
  save(first, second);
  await round(580);
  const before = view(580).detail.items[1];
  const late = chat(481, "东区苗床", "补记了一袋营养土。");
  const inGap = chat(508, "南区苗床", "南区苗床装好了围栏。");
  save(late, inGap);
  expect(view(580).drafts.map((item: { id: string }) => item.id)).toEqual([first.id, inGap.id]);
  covers(580, [first, second, late, inGap]);

  await round(595);
  const batch = polishCalls()[1]!;
  expect(materials(batch)).toHaveLength(2);
  expect(batch.prompt).toContain(late.body);
  expect(batch.prompt).toContain(inGap.body);
  expect(batch.prompt).not.toContain(second.body);
  expect(view(595).detail.items[2]).toEqual(before);
  expect(view(595).detail.items[0]).toMatchObject({ id: first.id, record_ids: [first.id, late.id] });
  expect(view(595).drafts).toEqual([]);
  await round(610);
  expect(polishCalls()).toHaveLength(2);
  covers(610, [first, second, late, inGap]);
});

test("AI 会话草稿标题只留首条输入，描述不重复标题", () => {
  const session = (minute: number, source_ref: string, body: string, title = "Claude Code · 合成苗圃 · 核对东边苗床。还要补图例") => fixture({
    kind: "span", source: "claude_code.session", source_ref, t_start: toLocalIso(at(minute)),
    t_end: toLocalIso(at(minute + 1)), title, body,
  });
  const single = session(480, "garden#1", "[我] 核对东边苗床。还要补图例\n\n[AI] 已核对。");
  const followed = session(560, "garden#2", "[我] 核对东边苗床。\n\n[AI] 已核对。\n\n[我] 那就把花苗移过去。");
  // 记录标题被截短时只剩长输入的开头。
  const clipped = session(640, "garden#3", "[我] 把东边苗床的花苗、豆苗和春苗都重新排一遍并标上名字\n\n[AI] 已排好。",
    "Claude Code · 合成苗圃 · 把东边苗床的花苗、豆苗和春苗都重新排");
  save(single, followed, clipped);
  const drafts = view(650).drafts;
  expect(drafts.map((item: { title: string; excerpt: string }) => [item.title, item.excerpt])).toEqual([
    ["核对东边苗床。", ""],
    ["核对东边苗床。", "那就把花苗移过去。"],
    ["把东边苗床的花苗、豆苗和春苗都重新排", ""],
  ]);
});

test("迟到的 AI 续跑结果只归回发起段，孤立续跑不成段", async () => {
  const session = (minute: number, source_ref: string, body: string) => fixture({
    kind: "span", source: "codex.session", source_ref, t_start: toLocalIso(at(minute)),
    t_end: toLocalIso(at(minute + 1)), body,
  });
  const asked = session(480, "nursery#1", "[我] 已经确定把花苗移到东边，再请核对苗床。");
  const result = session(530, "nursery#2", "[AI] 核对完毕，东边苗床可以容纳两排花苗。");
  const unrelated = session(540, "orphan#1", "[AI] 汇总了一个孤立的虚构任务。");
  save(asked);
  await round(520);
  save(result, unrelated);
  await round(550);
  expect(polishCalls()).toHaveLength(1);
  expect(view(550).drafts[0]).toMatchObject({ id: asked.id, record_ids: [asked.id, result.id] });
  await round(570);
  expect(polishCalls()).toHaveLength(2);
  expect(materials(polishCalls()[1]!)).toHaveLength(1);
  expect(polishCalls()[1]!.prompt).toContain("东边苗床可以容纳两排花苗");
  expect(polishCalls()[1]!.prompt).not.toContain("孤立的虚构任务");
  expect(view(570).detail.items[0]).toMatchObject({ id: asked.id, record_ids: [asked.id, result.id] });
  expect(view(570).detail.omitted_record_ids).toContain(unrelated.id);
  covers(570, [asked, result, unrelated]);
});

test("删除锚点立即撤下文案和概述，剩余成员保持段 ID，修正也只重写相关段", async () => {
  const anchor = chat(480, "东区苗床", "找到一张旧的苗床图。");
  const kept = chat(481, "东区苗床", "已经核对了东边的苗床。");
  const separate = chat(540, "西区苗床", "西边正在补发苗床标签。");
  save(anchor, kept, separate);
  await round(580, true);
  expect(view(580).detail.summary).toBeTruthy();
  expect(ctx.db.delete(anchor.id)).toBe(true);
  expect(store.day(date)!.detail.items.map((item: { id: string }) => item.id)).toEqual([separate.id]);
  expect(store.day(date)!.detail.summary).toBeNull();
  expect(view(580).drafts[0]).toMatchObject({ id: anchor.id, record_ids: [kept.id] });
  await round(595);
  expect(materials(polishCalls()[1]!)).toHaveLength(1);
  expect(polishCalls()[1]!.prompt).not.toContain(anchor.body);
  expect(view(595).detail.items[0]).toMatchObject({ id: anchor.id, record_ids: [kept.id] });

  save(fixture({ source: "manual.correction", corrects: kept.id, t_start: toLocalIso(at(596)), body: "东边苗床是小禾核对的。" }));
  expect(store.day(date)!.detail.items.map((item: { id: string }) => item.id)).toEqual([separate.id]);
  await round(610);
  expect(materials(polishCalls()[2]!)).toHaveLength(1);
  expect(polishCalls()[2]!.prompt).toContain("东边苗床是小禾核对的");
  covers(610, [kept, separate]);
});

test("模型在途删除使结果失效，未删除成员继续作为草稿", async () => {
  const first = chat(480, "东区苗床", "东边新增了一床豆苗。");
  const second = chat(481, "东区苗床", "已经核对了新种的豆苗。");
  save(first, second);
  beforePolish = () => { ctx.db.delete(first.id); };
  await round(530);
  expect(view(530).detail).toBeNull();
  expect(view(530).drafts[0]).toMatchObject({ record_ids: [second.id] });
  beforePolish = undefined;
  await round(545);
  expect(view(545).detail.items[0]).toMatchObject({ record_ids: [second.id] });
});

test("概述只读已润色正时长段，不随快轮重写，失败也保留段", async () => {
  const closed = chat(480, "东区苗床", "给小禾看了苗床原始排布。");
  const open = chat(535, "西区苗床", "西边搭好了豆苗支架。");
  save(closed, open);
  store.upsertProject({ id: "nursery", name: "虚构苗圃", keys: { hosts: [], repos: [], chats: [] } });
  store.upsertThread({ id: "bed", title: "苗床", status: "active", project_id: "nursery" });
  store.createFrame({ id: "closed", key: "chat:closed", record_ids: [closed.id], t_start_ms: at(480), t_end_ms: at(480),
    chars: closed.body.length, private: 0, status: "new" });
  store.assign("closed", "bed", "rule", 1);

  failOverview = true;
  await round(540, true);
  expect(data(overviewCalls()[0]!)).toEqual([{ start: "07:58", title: "苗圃进展", description: "小禾确认了这处苗床的安排。", project: "虚构苗圃" }]);
  expect(view(540).detail.summary).toBeNull();
  expect(view(540).detail.items).toHaveLength(1);

  failOverview = false;
  await round(555, true);
  expect(view(555).detail.summary).toBe("小禾确认了苗床安排。春苗已经分好。");
  await round(575);
  expect(overviewCalls()).toHaveLength(2);
  await round(615, true);
  expect(overviewCalls()).toHaveLength(3);
  // 2026-11-22：概述把上午的“配对受阻”当成现状，下午已解决。输入按时刻排，提示写明以最晚的段为准。
  expect(data(overviewCalls()[2]!).map((a: { start: string }) => a.start)).toEqual(["07:58", "08:53"]);
  expect(overviewCalls()[2]!.system).toContain("同一件事以最晚的段为准");
  await round(675, true);
  expect(overviewCalls()).toHaveLength(3);
});

// 2026-11-25：概述按码点数 160 字，英文项目名一个就占 27 字，写了 164–208 码点的概述 9 次被丢 6 次，设置页一直挂着 schema_mismatch。
test("概述字数按中文习惯数，英文词和版本号各算 1 字；超长时保留放得下的整句", async () => {
  const project = "garden-planner-from-scratch";
  expect(summaryLength(`${project} 发布 v0.6.4。`)).toBe(5);
  const fits = `${project}：完成苗床排布、浇水计划和育苗日志三项整理，v1.2.3 已发给小禾核对。`.repeat(4);
  expect(Array.from(fits).length).toBeGreaterThan(MAX_DAY_SUMMARY_CHARS);
  expect(summaryLength(fits)).toBeLessThanOrEqual(MAX_DAY_SUMMARY_CHARS);
  expect(summaryProblem(fits)).toBeNull();
  const long = "苗床东侧完成换土并补种了春季豆苗和三排生菜，西侧搭好豆架，北侧育苗盘已经移到棚里晒太阳。".repeat(4);
  expect(summaryProblem(long)).toBe(`summary 约 ${summaryLength(long)} 字，超过 ${MAX_DAY_SUMMARY_CHARS} 字上限，需要删掉至少 ${summaryLength(long) - MAX_DAY_SUMMARY_CHARS} 字`);
  expect(summaryLength(fitSummary(long)!)).toBeLessThanOrEqual(MAX_DAY_SUMMARY_CHARS);
  expect(fitSummary("没有句号".repeat(60))).toBeNull();
  // 截断同时守住 4 句；序号里的点和引号里的句号不另算一句。
  expect(fitSummary("一。二。三。四。五。")).toBe("一。二。三。四。");
  expect(summaryProblem("今天推进三件事：1. 完成苗床。2. 补种豆苗。")).toBeNull();
  expect(fitSummary(`小禾说“苗床排好了。”${"西侧补种了豆苗。".repeat(30)}`)?.startsWith("小禾说“苗床排好了。”")).toBe(true);
  expect(summaryProblem(`一句${"很长".repeat(90)}。`)).toContain("；summary 现在是 1 句");

  const done = chat(480, "东区苗床", "给小禾看了苗床原始排布。");
  save(done);
  overviewText = long;
  await round(540, true);
  expect(overviewCalls()[0]!.recheck?.({ summary: long })).toContain("超过");
  expect(view(540).detail.summary).toBe(fitSummary(long));
});

test.each(["after_segment", "hourly", "nightly"])("润色时机 %s 遵守快轮、整点和跨天收尾", async mode => {
  setModes(mode, "nightly");
  save(chat(480, "东区苗床", "小禾确认了东边苗床的排布。"), chat(481, "东区苗床", "东边苗床已换土。"));
  await round(540);
  expect(polishCalls()).toHaveLength(mode === "after_segment" ? 1 : 0);
  await round(600, true);
  expect(polishCalls()).toHaveLength(mode === "nightly" ? 0 : 1);
  expect(view(600).drafts).toHaveLength(mode === "nightly" ? 1 : 0);
  expect(store.day(date)!.needs_regen).toBe(1);
  expect(overviewCalls()).toHaveLength(0);
  expect(calls.filter(req => req.task === "day")).toHaveLength(0);
  await round(24 * 60 + 60, true);
  expect(calls.filter(req => req.task === "day")).toHaveLength(1);
  expect(store.day(date)!.needs_regen).toBe(0);
  expect(store.day(date)!.detail).not.toHaveProperty("polished_segments");
});

test.each(["hourly", "every_3h", "nightly"])("概述节奏 %s 只在到点且材料变化时调用", async mode => {
  setModes("after_segment", mode);
  save(chat(480, "东区苗床", "东区苗床换上了新土。"));
  await round(540, true);
  expect(overviewCalls()).toHaveLength(mode === "nightly" ? 0 : 1);
  save(chat(550, "西区苗床", "西区苗床贴上了新标签。"));
  await round(600, true);
  await round(660, true);
  expect(overviewCalls()).toHaveLength(mode === "nightly" ? 0 : mode === "every_3h" ? 1 : 2);
  await round(720, true);
  await round(780, true);
  expect(overviewCalls()).toHaveLength(mode === "nightly" ? 0 : 2);
});

test("通用设置读写时间线节奏，旧字段写入保留节奏，无效值用默认值", () => {
  expect(readTimelineSettings(ctx.db)).toEqual({ polish: "after_segment", overview: "hourly" });
  setModes("hourly", "every_3h");
  updateGeneral(ctx.db, { archive_days: 8 });
  expect(readTimelineSettings(ctx.db)).toEqual({ polish: "hourly", overview: "every_3h" });
  updateGeneral(ctx.db, { timeline_polish: "nightly" });
  expect(readTimelineSettings(ctx.db)).toEqual({ polish: "nightly", overview: "every_3h" });
  setModes("sometimes", "sometimes");
  expect(readTimelineSettings(ctx.db)).toEqual({ polish: "after_segment", overview: "hourly" });
});

test("用量冷却保留手动整理的排队状态与实时草稿，调高上限后继续", async () => {
  const now = at(540);
  const record = chat(480, "东区苗床", "东区苗床已经贴标。");
  save(record);
  const requests = new DistillRequests(ctx.db);
  const { request } = requests.create({ kind: "regen_days", from: date, to: date }, now);
  store.writeUsage({ at: toLocalIso(now), task: "assign", tier: "minute", provider: "claude-cli",
    model: "synthetic-model", input_tokens: 90, output_tokens: 10, ms: 1, ok: 1 });
  updateGeneral(ctx.db, { daily_token_limit: 100 });
  const state: LoopState = { lastRound: now, enabledDefault: now };
  await distillTick(deps(now), state, now);
  expect(requests.get(request.id)?.status).toBe("queued");
  expect(calls).toHaveLength(0);
  expect(view(540).drafts.map((item: { id: string }) => item.id)).toEqual([record.id]);

  updateGeneral(ctx.db, { daily_token_limit: 101 });
  await distillTick(deps(now), state, now);
  expect(requests.get(request.id)?.status).toBe("done");
  expect(polishCalls()).toHaveLength(1);
});

test("当天 regen_days 只补已结束的段与概述，排队后已更新即跳过", async () => {
  const done = chat(480, "东区苗床", "东区苗床已经贴标。");
  const open = chat(535, "西区苗床", "西区苗床刚补过水。");
  save(done, open);
  const requests = new DistillRequests(ctx.db), state: LoopState = { lastRound: 0, enabledDefault: at(540) };
  const enqueue = (minute: number) => requests.create({ kind: "regen_days", from: date, to: date }, at(minute)).request;
  const first = enqueue(540);
  await distillTick(deps(at(540)), state);
  expect(calls.map(call => call.task)).toEqual(["day_polish", "day_brief"]);
  expect(requests.get(first.id)?.status).toBe("done");
  expect(view(540).drafts[0]).toMatchObject({ id: open.id });
  let clock = at(580), queued: ReturnType<typeof enqueue> | undefined;
  beforePolish = () => {
    // The view opens during the in-flight regular call, before its results are committed.
    queued = requests.create({ kind: "regen_days", from: date, to: date }, clock + 200).request;
    clock += 400;
  };
  await distillRound({ ...deps(clock), now: () => clock }, { days: "all", enabledDefault: clock });
  beforePolish = undefined;
  expect(polishCalls()).toHaveLength(2);
  const before = calls.length;
  await distillTick(deps(at(581)), state);
  expect(calls).toHaveLength(before);
  expect(requests.get(queued!.id)?.status).toBe("done");
  expect(overviewCalls()).toHaveLength(1);
});

test("合成 20 段比较逐段与全天一次的模型输入字符数", async () => {
  setModes("after_segment", "nightly");
  const records = Array.from({ length: 20 }, (_, i) => [
    chat(180 + i * 45, `苗圃 ${i}`, `小禾核对了第 ${i} 处苗床，已经在东侧地块做了新标记。`),
    chat(181 + i * 45, `苗圃 ${i}`, "新苗床的边界已经画在图上。"),
  ]);
  for (const [i, segment] of records.entries()) {
    save(...segment);
    await round(212 + i * 45);
  }
  expect(polishCalls()).toHaveLength(20);
  for (const req of polishCalls()) expect(materials(req)).toHaveLength(1);
  expect(data(polishCalls().at(-1)!).recent).toHaveLength(5);
  const chars = ({ system, prompt }: LLMRequest) => Array.from(system + prompt).length;
  const incremental = polishCalls().reduce((sum, request) => sum + chars(request), 0);
  await dayStep(deps(at(25 * 60)), store, date, at(25 * 60));
  const full = calls.find(req => req.task === "day")!;
  expect(materials(full)).toHaveLength(20);
  console.info(`合成 20 段模型输入字符数（系统指令和用户提示）：逐段润色 ${incremental}，全天一次 ${chars(full)}`);
});
