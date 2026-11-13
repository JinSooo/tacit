import { expect, test } from "bun:test";
import Ajv from "ajv";
import { fixture, setup } from "./helpers.ts";
import { DistillStore } from "../src/distill/store.ts";
import { digestStep, LIMITS, type LLM } from "../src/distill/run.ts";
import type { LLMRequest } from "../src/llm/index.ts";
import type { FrameView, ThreadOutput } from "../src/distill/prompts.ts";
import type { ThreadModelOutput } from "../src/distill/thread-request.ts";
import { assignRequest } from "../src/distill/assign-request.ts";

const now = Date.parse("2026-11-12T12:00:00+09:00");
const detail = { goal: "合成目标", progress: "合成进展", artifacts: { files: [], urls: [], commands: [], people: [] }, quotes: [] };
const frames = (req: LLMRequest): FrameView[] => JSON.parse(/<data>\n([\s\S]*)\n<\/data>/.exec(req.prompt)![1]!);
const output = (): ThreadModelOutput => ({ title: "合成事项", domain: "work", in_project: false, detail, new_facts: [], invalidate: [], status_hint: "active" });

test("实测归属引用回归：拒绝编造片段 ID，短编号还原已有线程和候选线程", () => {
  const fs: FrameView[] = [{ id: "long-frame-id", start: "10:00", end: "10:10", key: "app:synthetic", private: false, records: [] }];
  const req = assignRequest(fs, [
    { id: "long-thread-id", title: "已有事项", brief: "", project: null, status: "active", last: "" },
    { id: "cand:long-candidate-id", title: "候选事项", brief: "", project: null, status: "candidate", last: "" },
  ]);
  const item = { frame_id: "s1", thread_id: "t1", new_thread_title: null, ignore: false, confidence: 0.9 };
  const valid = new Ajv({ strict: false }).compile(req.schema);
  expect(valid({ items: [item] })).toBe(true);
  expect(valid({ items: [{ ...item, frame_id: "100000" }] })).toBe(false);
  expect(valid({ items: [{ ...item, thread_id: "invented" }] })).toBe(false);
  expect(req.decode({ items: [item] }).items[0]).toMatchObject({ frame_id: fs[0]!.id, thread_id: "long-thread-id" });
  expect(req.decode({ items: [{ ...item, thread_id: "t2" }] }).items[0]?.thread_id).toBe("cand:long-candidate-id");
  expect(req.decode({ items: [{ ...item, frame_id: "100000" }] }).items).toEqual([]);
  const empty = assignRequest(fs, []);
  const checkEmpty = new Ajv({ strict: false }).compile(empty.schema);
  expect(checkEmpty({ items: [{ ...item, thread_id: null }] })).toBe(true);
  expect(checkEmpty({ items: [item] })).toBe(false);
});

function seed(bodies: string[]) {
  const ctx = setup(), store = new DistillStore(ctx.db);
  const records = bodies.map((body, i) => fixture({ source: "codex.session", source_ref: `synthetic-${i}`, title: `记录${i}`, body, t_start: new Date(now + i).toISOString() }));
  const ingested = ctx.db.ingest(records);
  if (ingested.accepted !== records.length) { ctx.cleanup(); throw new Error(JSON.stringify(ingested)); }
  store.upsertThread({ id: "t", title: "合成事项", status: "active", needs_regen: 1 });
  store.createFrame({ id: "frame", key: "app:codex", record_ids: records.map(r => r.id), t_start_ms: now, t_end_ms: now + 60_000, chars: bodies.join("").length, private: 0, status: "new" });
  store.assign("frame", "t", "user", 1);
  return { ...ctx, store, records };
}

test("长会话中后段和超过四十条的记录全部进入详细整理，引用落库还原为原记录", async () => {
  const body = "[我] 开头范围\n" + "[AI] 合成调研内容。".repeat(650) + "\n[我] 只接聊天客户端甲，其他以后再说。\n[AI] 按这个范围继续。";
  const ctx = seed([body, ...Array.from({ length: 45 }, (_, i) => `第${i + 1}条独立记录`)]);
  const seen: { title: string; text: string }[] = [];
  const llm: LLM = { async complete<T>(req: LLMRequest) {
    if (req.task !== "thread_digest") return { ok: true, data: { brief: "合成简略" } as T, ms: 1 };
    const records = frames(req).flatMap(f => f.records ?? []), out = output();
    for (const r of records) {
      seen.push({ title: r.title, text: r.excerpt });
      out.new_facts.push({ kind: "open", text: r.title, evidence: [r.id], supports: [{ record_id: r.id, text: r.excerpt }], confidence: 1, reason: null });
    }
    return { ok: true, data: out as T, ms: 1 };
  } };
  try {
    await digestStep({ db: ctx.db, llm }, ctx.store, now);
    expect(seen.filter(r => r.title === "记录0").map(r => r.text).join("")).toBe(body);
    expect(new Set(seen.map(r => r.title)).size).toBe(46);
    const facts = ctx.store.facts("thread_id", "t");
    expect(facts).toHaveLength(46);
    expect(new Set(facts.flatMap(f => f.evidence))).toEqual(new Set(ctx.records.map(r => r.id)));
  } finally { ctx.cleanup(); }
});

test("请求约束证据和原话引用范围，用户事实不在可作废列表中", async () => {
  const ctx = seed(["[我] 决定只接客户端甲。"]);
  ctx.store.writeFact({ id: "user-fact", thread_id: "t", kind: "decision", text: "用户纠正", origin: "user", evidence: [ctx.records[0]!.id], valid_at: new Date(now).toISOString(), created_at: new Date(now).toISOString() });
  const llm: LLM = { async complete<T>(req: LLMRequest) {
    if (req.task !== "thread_digest") return { ok: true, data: { brief: "合成简略" } as T, ms: 1 };
    const id = frames(req)[0]!.records[0]!.id;
    const valid = output();
    valid.new_facts = [{ kind: "decision", text: "只接客户端甲", reason: null, confidence: 1, evidence: [id], supports: [{ record_id: id, text: "决定只接客户端甲。" }] }];
    valid.detail = { ...detail, quotes: [{ text: "决定只接客户端甲。", record_id: id }] };
    const validate = new Ajv({ strict: false }).compile(req.schema);
    expect(validate(valid)).toBe(true);
    for (const wrong of [`record_id:${id}（说明）`, "invented-record", "frame", "f1"]) {
      expect(validate({ ...valid, new_facts: [{ ...valid.new_facts[0], evidence: [wrong] }] })).toBe(false);
      expect(validate({ ...valid, detail: { ...valid.detail, quotes: [{ text: "伪造引用", record_id: wrong }] } })).toBe(false);
    }
    expect(validate({ ...valid, invalidate: [{ fact_id: "f1", replaced_by: null }] })).toBe(false);
    expect(id).toMatch(/^r\d+$/);
    expect(req.prompt).not.toContain(ctx.records[0]!.id);
    return { ok: true, data: valid as T, ms: 1 };
  } };
  try {
    await digestStep({ db: ctx.db, llm }, ctx.store, now);
    expect(ctx.store.facts("thread_id", "t").map(f => f.text)).toContain("用户纠正");
    expect(ctx.store.facts("thread_id", "t").find(f => f.text === "只接客户端甲")?.evidence).toEqual([ctx.records[0]!.id]);
    expect((ctx.store.thread("t")!.detail as ThreadOutput["detail"]).quotes[0]?.record_id).toBe(ctx.records[0]!.id);
  } finally { ctx.cleanup(); }
});

test("超预算会话分段且不中断 Unicode，失败后恢复不重发已成功部分、不跳过末尾", async () => {
  const body = "开头" + '😀"\\\n'.repeat(24_000) + "末尾的用户决定";
  const ctx = seed([body]);
  const completed: string[] = [], requests: LLMRequest[] = [];
  let failOnce = true;
  const llm: LLM = { async complete<T>(req: LLMRequest) {
    if (req.task !== "thread_digest") return { ok: true, data: { brief: "合成简略" } as T, ms: 1 };
    requests.push(req);
    if (requests.length === 2 && failOnce) { failOnce = false; return { ok: false, error: "合成网络失败", ms: 1 }; }
    const data = frames(req);
    expect(JSON.stringify(data).length).toBeLessThanOrEqual(LIMITS.digestChars);
    completed.push(...data.flatMap(f => f.records.map(r => r.excerpt)));
    return { ok: true, data: output() as T, ms: 1 };
  } };
  try {
    expect((await digestStep({ db: ctx.db, llm }, ctx.store, now)).failed).toBe(1);
    const mark = ctx.store.getState<{ frames: string[] }>("digest:t")!;
    expect(mark.frames).not.toContain("frame");
    expect((await digestStep({ db: ctx.db, llm }, new DistillStore(ctx.db), now)).updated).toBe(1);
    expect(completed.join("")).toBe(body);
    expect(ctx.store.getState<{ frames: string[] }>("digest:t")!.frames).toEqual(["frame"]);
    expect(requests.length).toBeGreaterThan(2);
  } finally { ctx.cleanup(); }
});

test("分段途中删除记录，重试不带入已删除记录生成的旧摘要", async () => {
  const ctx = seed(["删除内容".repeat(15_000), "[我] 保留的决定"]);
  let calls = 0;
  const llm: LLM = { async complete<T>(req: LLMRequest) {
    if (req.task !== "thread_digest") return { ok: true, data: { brief: "保留摘要" } as T, ms: 1 };
    calls++;
    if (calls === 2) return { ok: false, error: "合成中断", ms: 1 };
    const out = output();
    if (calls === 1) out.detail = { ...detail, progress: "已删除记录的旧摘要" };
    else {
      expect(req.prompt).not.toContain("已删除记录的旧摘要");
      expect(req.prompt).toContain("保留的决定");
    }
    return { ok: true, data: out as T, ms: 1 };
  } };
  try {
    expect((await digestStep({ db: ctx.db, llm }, ctx.store, now)).failed).toBe(1);
    expect(JSON.stringify(ctx.store.thread("t")!.detail)).toContain("已删除记录的旧摘要");
    expect(ctx.db.delete(ctx.records[0]!.id)).toBe(true);
    expect((await digestStep({ db: ctx.db, llm }, ctx.store, now)).updated).toBe(1);
    expect(JSON.stringify(ctx.store.thread("t")!.detail)).not.toContain("已删除记录的旧摘要");
  } finally { ctx.cleanup(); }
});

test("语义实测回归：用户原话不能来自 AI、另一条记录或跨发言拼接", async () => {
  const ctx = seed([
    "[我] 先接客户端甲，其余以后再说。\n\n[AI] 建议重构模型连接配置。\n\n[我] 先只测试。",
    "[我] 可以开始下载。\n\n[AI] 下载已开始。",
  ]);
  let call = 0;
  const llm: LLM = { async complete<T>(req: LLMRequest) {
    if (req.task !== "thread_digest") return { ok: true, data: { brief: "合成简略" } as T, ms: 1 };
    const rs = frames(req).flatMap(f => f.records);
    const out = output();
    out.detail = { ...detail, quotes: call++ === 0 ? [
      { text: "先接客户端甲，其余以后再说。", record_id: rs[0]!.id },
      { text: "建议重构模型连接配置。", record_id: rs[0]!.id },
      { text: "可以开始下载。", record_id: rs[0]!.id },
    ] : [
      { text: "可以开始下载。\n\n[AI] 下载已开始。", record_id: rs[1]!.id },
      { text: "可以开始下载。", record_id: rs[1]!.id },
    ] };
    return { ok: true, data: out as T, ms: 1 };
  } };
  try {
    await digestStep({ db: ctx.db, llm }, ctx.store, now);
    expect((ctx.store.thread("t")!.detail as ThreadOutput["detail"]).quotes).toEqual([
      { text: "先接客户端甲，其余以后再说。", record_id: ctx.records[0]!.id },
    ]);
    ctx.store.setState("digest:t", null);
    ctx.store.upsertThread({ ...ctx.store.thread("t")!, needs_regen: 1 });
    await digestStep({ db: ctx.db, llm }, ctx.store, now);
    expect((ctx.store.thread("t")!.detail as ThreadOutput["detail"]).quotes).toEqual([
      { text: "可以开始下载。", record_id: ctx.records[1]!.id },
    ]);
  } finally { ctx.cleanup(); }
});

test("已有摘要中的错误原话不再进入下一轮提示，正确原话仍可保留", async () => {
  const ctx = seed(["[我] 暂不发布。\n\n[AI] 构建通过。"]);
  const record_id = ctx.records[0]!.id;
  ctx.store.setState("digest:t", { frames: ["frame"], records: 1, user_facts: [] });
  ctx.store.upsertThread({ ...ctx.store.thread("t")!, detail: { ...detail, quotes: [
    { text: "构建通过。", record_id }, { text: "暂不发布。", record_id },
  ] } });
  ctx.store.writeFact({ id: "correction", thread_id: "t", kind: "decision", text: "保持未发布", evidence: [record_id], origin: "user", valid_at: new Date(now).toISOString(), created_at: new Date(now).toISOString() });
  const llm: LLM = { async complete<T>(req: LLMRequest) {
    if (req.task !== "thread_digest") return { ok: true, data: { brief: "未发布" } as T, ms: 1 };
    expect(req.prompt).not.toContain("构建通过。");
    expect(req.prompt).toContain("暂不发布。");
    const out = output();
    out.detail = { ...detail, quotes: [{ text: "暂不发布。", record_id: "r1" }] };
    return { ok: true, data: out as T, ms: 1 };
  } };
  try {
    await digestStep({ db: ctx.db, llm }, ctx.store, now);
    expect((ctx.store.thread("t")!.detail as ThreadOutput["detail"]).quotes).toEqual([{ text: "暂不发布。", record_id }]);
  } finally { ctx.cleanup(); }
});

test("长用户发言的核对索引计入输入预算，分批仍保留全部正文", async () => {
  const body = "[我] " + "长发言内容😀。".repeat(9_000);
  const ctx = seed([body]), seen: string[] = [];
  const llm: LLM = { async complete<T>(req: LLMRequest) {
    if (req.task !== "thread_digest") return { ok: true, data: { brief: "合成简略" } as T, ms: 1 };
    const data = frames(req);
    expect(JSON.stringify(data).length).toBeLessThanOrEqual(LIMITS.digestChars);
    seen.push(...data.flatMap(f => f.records.map(r => r.excerpt)));
    return { ok: true, data: output() as T, ms: 1 };
  } };
  try {
    expect((await digestStep({ db: ctx.db, llm }, ctx.store, now)).updated).toBe(1);
    expect(seen.length).toBeGreaterThan(1);
    expect(seen.join("")).toBe(body);
  } finally { ctx.cleanup(); }
});

test("事实逐字依据回归：错引记录和仅据 AI 建议的决定不入库，也不能替换旧事实", async () => {
  const ctx = seed(["[我] 本轮只接客户端甲。\n\n[AI] 建议以后重构配置。", "[AI] 客户端乙尚未开始。"]);
  ctx.store.writeFact({ id: "open-old", thread_id: "t", kind: "open", text: "等待用户决定是否重构", evidence: [ctx.records[0]!.id], origin: "llm", valid_at: new Date(now).toISOString(), created_at: new Date(now).toISOString() });
  const llm: LLM = { async complete<T>(req: LLMRequest) {
    if (req.task !== "thread_digest") return { ok: true, data: { brief: "只接甲" } as T, ms: 1 };
    const rs = frames(req).flatMap(f => f.records), a = rs[0]!.id, b = rs[1]!.id;
    const out: any = output();
    out.new_facts = [
      { kind: "decision", text: "只接甲", reason: null, confidence: 1, evidence: [a], supports: [{ record_id: a, text: "本轮只接客户端甲。" }] },
      { kind: "decision", text: "用户决定重构", reason: null, confidence: 1, evidence: [a], supports: [{ record_id: a, text: "建议以后重构配置。" }] },
      { kind: "decision", text: "错引的决定", reason: null, confidence: 1, evidence: [b], supports: [{ record_id: b, text: "本轮只接客户端甲。" }] },
      { kind: "open", text: "不存在的依据", reason: null, confidence: 1, evidence: [a], supports: [{ record_id: a, text: "全体确认上线" }] },
      { kind: "open", text: "混入错误的关键依据", reason: null, confidence: 1, evidence: [a,b], supports: [{ record_id: a, text: "本轮只接客户端甲。" }, { record_id: b, text: "全体确认上线" }] },
    ];
    out.invalidate = [{ fact_id: "f1", replaced_by: 1 }];
    return { ok: true, data: out as T, ms: 1 };
  } };
  try {
    const result = await digestStep({ db: ctx.db, llm }, ctx.store, now);
    expect(ctx.store.facts("thread_id", "t").map(f => f.text).sort()).toEqual(["只接甲", "等待用户决定是否重构"].sort());
    expect(result.dropped_ungrounded).toBe(4);
  } finally { ctx.cleanup(); }
});
