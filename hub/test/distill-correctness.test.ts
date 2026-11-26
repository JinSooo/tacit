import { updateGeneral } from "../src/general-settings.ts";
import { afterEach, beforeEach, expect, test } from "bun:test";
import { DistillStore } from "../src/distill/store.ts";
import { assignStep, dayStep, digestStep, distillRound, nowStep, projectStep, touchThread, refreshDerivedState, type LLM } from "../src/distill/run.ts";
import { hubStatus } from "../src/status.ts";
import * as P from "../src/distill/prompts.ts";
import type { LLMRequest } from "../src/llm/index.ts";
import { emptyDayOutput, fixture, setup } from "./helpers.ts";

let ctx: ReturnType<typeof setup>, store: DistillStore;
beforeEach(() => { ctx = setup(); updateGeneral(ctx.db, { language: "zh" }); store = new DistillStore(ctx.db); });
afterEach(() => ctx.cleanup());
const date = "2026-11-12", base = new Date(`${date}T10:00:00`).getTime(), MIN = 60_000;
const iso = (n: number) => new Date(n).toISOString();
const detail = { goal: "合成目标", progress: "旧进展", artifacts: { files: [], urls: [], commands: [], people: [] }, quotes: [] };
function thread(id = "t") {
  store.upsertThread({ id, title: "同名事项", project_id: "p", domain: "work", status: "active", brief: "旧摘要", detail, last_ms: base, updated_at: iso(base - 2 * 86400_000), needs_regen: 0 });
}
function frame(id: string, spans: [number, number][], owner = "t", source = "mac.screen") {
  const records = spans.map(([a,b]) => fixture({ source, kind: "span", t_start: iso(base + a * MIN), t_end: iso(base + b * MIN) }));
  ctx.db.ingest(records);
  const f = { id, key: `app:${id}`, record_ids: records.map(r => r.id), t_start_ms: base + Math.min(...spans.map(s => s[0])) * MIN,
    t_end_ms: base + Math.max(...spans.map(s => s[1])) * MIN, chars: 1, private: 0, status: "new" as const };
  store.createFrame(f); store.assign(id, owner, "user", 1); return f;
}
function model() {
  const calls: LLMRequest[] = [];
  const llm: LLM = { async complete<T>(req: LLMRequest) {
    calls.push(req);
    const data = req.task === "day" ? emptyDayOutput : req.task === "project" ? { goal: "目标", status: "最新项目进展", people: [] }
      : req.task === "thread_digest" ? { title: "同名事项", domain: "work", in_project: true, detail: { ...detail, progress: "用户确认已完成" }, new_facts: [], invalidate: [], status_hint: "active" }
      : { brief: "最新简略版" };
    return { ok: true, data: data as T, ms: 1 };
  } };
  return { calls, llm };
}

function noteFor(owner: string, offset: number) {
  const ms = base + offset * MIN, id = `note-${owner}-${offset}`;
  const r = fixture({ source: "manual.note", t_start: iso(ms), body: "确认展板尺寸。" });
  ctx.db.ingest([r]);
  store.createFrame({ id, key: "manual:note", record_ids: [r.id], t_start_ms: ms, t_end_ms: ms,
    chars: r.body.length, private: 0, status: "new" });
  store.assign(id, owner, "user", 1);
}
const reviewModel: LLM = { async complete<T>(req: LLMRequest) {
  const { activities } = JSON.parse(/<data>\n([\s\S]*)\n<\/data>/.exec(req.prompt)![1]!) as {
    activities: { key: string; evidence: { key: string }[] }[];
  };
  return { ok: true, ms: 1, data: { highlight: null, items: activities.map(a => ({
    activity: a.key, title: "同名事项", description: "确认展板尺寸。", refs: [a.evidence[0]!.key],
  })) } as T };
} };

test("时间线按原记录并集计时，同名事项不混合且中途切换另起一段", async () => {
  thread(); thread("other");
  frame("long", [[0,20], [40,60]]); frame("nested", [[5,15]]);
  frame("other", [[25,35]], "other"); frame("tail", [[65,75]]);
  noteFor("t",0); noteFor("other",25); noteFor("t",40);
  await dayStep({ db: ctx.db, llm: reviewModel }, store, date, base + 3 * 3600_000);
  const items = store.day(date)!.detail.items;
  expect(items).toHaveLength(3);
  expect(items[0].active_seconds).toBe(20 * 60);
  expect(Date.parse(items[0].t_start)).toBe(base);
  expect(Date.parse(items[0].t_end)).toBe(base + 20 * MIN);
  expect(items[1].active_seconds).toBe(10 * 60);
  expect(Date.parse(items[1].t_start)).toBe(base + 25 * MIN);
  expect(Date.parse(items[1].t_end)).toBe(base + 35 * MIN);
  expect(items[2].active_seconds).toBe(30 * 60);
  expect(Date.parse(items[2].t_start)).toBe(base + 40 * MIN);
  expect(Date.parse(items[2].t_end)).toBe(base + 75 * MIN);
});

test("此刻时间来自被展示摘要；轮询和新活动都不能把旧摘要变新", () => {
  thread(); nowStep(store, base + MIN);
  expect(store.getState<any>("now").updated_at).toBe(iso(base - 2 * 86400_000));
  store.upsertThread({ ...store.thread("t")!, last_ms: base + 5 * MIN, needs_regen: 1 });
  nowStep(store, base + 10 * MIN);
  expect(store.getState<any>("now").updated_at).toBe(iso(base - 2 * 86400_000));
  store.upsertThread({ ...store.thread("t")!, brief: "真正重写的摘要", updated_at: iso(base + 11 * MIN) });
  nowStep(store, base + 12 * MIN);
  expect(store.getState<any>("now")).toMatchObject({ brief: "真正重写的摘要", updated_at: iso(base + 11 * MIN) });
});

test("运行状态显示本轮整理时间，独立于首页旧摘要的生成时间", async () => {
  thread(); const m=model();
  await distillRound({ db:ctx.db,llm:m.llm,now:()=>base+MIN });
  expect(Date.parse(hubStatus(ctx.db,{port:1,now:base+MIN}).distill.last_round_at!)).toBe(base+MIN);
  expect(store.getState<any>("now").updated_at).toBe(iso(base-2*86400_000));
});

test("线程与项目简略版只读详细版，不额外带入数百条事实", async () => {
  store.upsertProject({ id: "p", name: "项目", keys: { repos: [], hosts: [], chats: [] }, needs_regen: 1 }); thread();
  const f = frame("f", [[0,20]]);
  store.setState("digest:t", { frames: [f.id], records: 1 });
  for (let i = 0; i < 300; i++) store.writeFact({ id: `fact-${i}`, thread_id: "t", project_id: "p", kind: "decision", text: `详细版之外的事实 ${i}`, evidence: f.record_ids, origin: "llm", valid_at: iso(base), created_at: iso(base) });
  store.upsertThread({ ...store.thread("t")!, needs_regen: 1 });
  const m = model(); await digestStep({ db: ctx.db, llm: m.llm }, store, base + MIN); await projectStep({ db: ctx.db, llm: m.llm }, store, base + MIN);
  const briefCalls = m.calls.filter(c => c.system === P.BRIEF_SYSTEM);
  expect(briefCalls).toHaveLength(2);
  for (const c of briefCalls) {
    expect(JSON.parse(c.prompt).detail).toBeTruthy();
    expect(c.prompt).not.toContain("详细版之外的事实");
    expect(Object.keys(JSON.parse(c.prompt)).sort()).toEqual(["detail", "title"]);
    expect(c.prompt.length).toBeLessThan(500);
  }
  expect(m.calls.find(c => c.task === "project")!.prompt).toContain("详细版之外的事实 299");
});

test("没有新活动的用户纠错先更新详细版，再派生简略版", async () => {
  store.upsertProject({ id: "p", name: "项目", keys: { repos: [], hosts: [], chats: [] }, needs_regen: 0 }); thread();
  const f = frame("f", [[0,20]]); store.setState("digest:t", { frames: [f.id], records: 1 });
  store.writeFact({ id: "correction", thread_id: "t", project_id: "p", kind: "decision", text: "用户确认已完成", origin: "user", evidence: f.record_ids, valid_at: iso(base), created_at: iso(base) });
  expect(store.thread("t")!.needs_regen).toBe(1);
  const m = model(); await digestStep({ db: ctx.db, llm: m.llm }, store, base + MIN);
  expect(m.calls.map(c => c.task)).toEqual(["thread_digest", "thread_brief"]);
  expect(m.calls[0]!.prompt).toContain("用户确认已完成");
  expect(JSON.parse(m.calls[1]!.prompt).detail.progress).toBe("用户确认已完成");
  expect(store.thread("t")!.detail).toMatchObject({ progress: "用户确认已完成" });
});

test("线程累计与合并用记录并集计时，重复触达不会增加时长", () => {
  thread(); thread("other");
  const a = frame("a", [[0,20], [40,60]]), b = frame("b", [[5,15]], "other");
  touchThread(store, "t", a); touchThread(store, "t", a); touchThread(store, "other", b);
  expect(store.thread("t")!.active_minutes).toBe(40);
  store.mergeThreads("other", "t");
  expect(store.thread("t")!.active_minutes).toBe(40);
  ctx.db.delete(a.record_ids[0]!);
  expect(store.thread("t")!.active_minutes).toBe(30);
  store.detachRecord(b.record_ids[0]!);
  expect(store.thread("t")!.active_minutes).toBe(20);
});

test("旧派生结果只失效一次，修正此刻时间且保留原文和增量检查点", () => {
  thread(); frame("f", [[0,20]]);
  store.upsertDay({ date, brief: "旧日记", detail: { summary: "旧计时" }, needs_regen: 0 });
  const mark = { frames: ["f"], records: 1 }; store.setState("digest:t", mark);
  expect(refreshDerivedState(store,base+MIN)).toBe(true);
  expect(store.thread("t")).toMatchObject({ active_minutes: 20, needs_regen: 1, detail });
  expect(store.day(date)).toMatchObject({ needs_regen: 1, brief: "旧日记" });
  expect(store.getState("digest:t")).toEqual(mark);
  expect(store.getState<any>("now").updated_at).toBe(iso(base-2*86400_000));
  store.upsertThread({ ...store.thread("t")!, needs_regen: 0 });
  store.upsertDay({ date, needs_regen: 0 });
  expect(refreshDerivedState(store,base+2*MIN)).toBe(false);
  expect(store.thread("t")!.needs_regen).toBe(0); expect(store.day(date)!.needs_regen).toBe(0);
});

test("回顾跨本地午夜裁剪时长，不把前一天或次日的时间算进来", async () => {
  thread();
  frame("start", [[-610,-590]]); // 当天 00:00 前后各十分钟
  frame("end", [[830,850]]); // 当天 24:00 前后各十分钟
  noteFor("t",-600); noteFor("t",830);
  await dayStep({ db: ctx.db, llm: reviewModel }, store, date, base + 16 * 3600_000);
  const { items, timeline } = store.day(date)!.detail;
  expect(items).toHaveLength(2);
  expect(items.map((segment: { active_seconds: number }) => segment.active_seconds)).toEqual([10 * 60, 10 * 60]);
  expect(timeline.map((c: { start: string; end: string }) => [c.start,c.end])).toEqual([["00:00","00:10"],["23:50","24:00"]]);
});

test("生成简略版期间用户再次纠错，保留待更新标记供下轮处理", async () => {
  store.upsertProject({ id: "p", name: "项目", keys: { repos: [], hosts: [], chats: [] } }); thread();
  const f=frame("f",[[0,20]]); store.setState("digest:t",{ frames: [f.id],records: 1 });
  store.upsertThread({ ...store.thread("t")!,needs_regen: 1 });
  const llm: LLM = { async complete<T>() {
    store.writeFact({ id:"late",thread_id:"t",kind:"decision",text:"稍后才收到的纠错",origin:"user",evidence:f.record_ids,valid_at:iso(base),created_at:iso(base) });
    return { ok:true,data:{brief:"先前详细版的简略"} as T,ms:1 };
  } };
  await digestStep({db:ctx.db,llm},store,base+MIN);
  expect(store.thread("t")!.needs_regen).toBe(1);
});

test("候选事项的十五分钟门槛不把片段内空档算作活动", async () => {
  // 纯屏幕片段不能单独发起候选（2026-11-18），这里用有正文的来源。
  thread(); const f=frame("sparse",[[0,2],[9,11],[18,20]],"t","manual.note");
  ctx.db.db.prepare("DELETE FROM assignments WHERE frame_id=?").run(f.id);
  ctx.db.db.prepare("UPDATE frames SET status='new' WHERE id=?").run(f.id);
  const llm: LLM = { async complete<T>(req: LLMRequest) { const input = JSON.parse(/<data>\n([\s\S]*)\n<\/data>/.exec(req.prompt)![1]!); return { ok:true,data:{ items:[{ frame_id:input[0].id,thread_id:null,new_thread_title:"稀疏活动",ignore:false,confidence:0.9 }] } as T,ms:1 }; } };
  const result=await assignStep({db:ctx.db,llm},store,base+60*MIN);
  expect(result.created_threads).toBe(0);
  expect(store.getState<any[]>("candidates")![0].minutes).toBe(6);
});
