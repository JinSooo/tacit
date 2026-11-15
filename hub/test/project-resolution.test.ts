import { expect, test } from "bun:test";
import { fixture, setup } from "./helpers.ts";
import { DistillStore } from "../src/distill/store.ts";
import { projectStep, digestStep, type LLM } from "../src/distill/run.ts";
import { type LLMRequest } from "../src/llm/index.ts";
import { projectRequest } from "../src/distill/project-request.ts";

const at = Date.parse("2026-11-13T12:00:00Z");
const detail = { goal: "固定目录安装", progress: "尚未安装", artifacts: { files: [], urls: [], commands: [], people: [] }, quotes: [] };
function seed(origin: "user" | "llm" = "llm") {
  const ctx = setup(), store = new DistillStore(ctx.db);
  store.upsertProject({ id: "p", name: "合成项目", keys: { repos: [], hosts: [], chats: [] }, needs_regen: 1 });
  const old = fixture({ body: "固定目录安装尚未完成。" }), fresh = fixture({ t_start: new Date(at).toISOString(), body: "应用包内固定目录安装已经完成，重启后验证服务不再依赖源码。" });
  ctx.db.ingest([old, fresh]);
  for (const [id, r] of [["old", old], ["new", fresh]] as const) {
    store.upsertThread({ id, title: id === "old" ? "安装准备" : "安装验收", project_id: "p", project_hint: "p", domain: "work", status: "paused", brief: id === "old" ? "尚未安装" : fresh.body, detail, last_ms: Date.parse(r.t_start), needs_regen: 0 });
    store.createFrame({ id: `frame-${id}`, key: `app:${id}`, record_ids: [r.id], t_start_ms: Date.parse(r.t_start), t_end_ms: Date.parse(r.t_start), chars: r.body.length, private: 0, status: "new" });
    store.assign(`frame-${id}`, id, "llm", 1);
    store.setState(`digest:${id}`, { frames: [`frame-${id}`], records: 1, user_facts: [] });
  }
  store.writeFact({ id: "open", thread_id: "old", project_id: "p", kind: "open", text: old.body, origin, evidence: [old.id], valid_at: old.t_start, created_at: old.t_start });
  store.writeFact({ id: "completed", thread_id: "new", project_id: "p", kind: "decision", text: fresh.body, origin: "llm", evidence: [fresh.id], valid_at: fresh.t_start, created_at: fresh.t_start });
  return { ...ctx, store, old, fresh };
}
function model(ctx: ReturnType<typeof seed>, tamper?: (resolution: any) => void) {
  const calls: LLMRequest[] = [];
  const llm: LLM = { async complete<T>(req: LLMRequest) {
    calls.push(req);
    if (req.task === "project") {
      const input = JSON.parse(/<data>\n([\s\S]*)\n<\/data>/.exec(req.prompt)![1]!);
      const resolution = { open_fact_id: input.facts.find((f: any) => f.kind === "open").id,
        by_fact_id: input.facts.find((f: any) => f.kind === "decision").id,
        record_id: input.completion_evidence?.[0]?.id ?? ctx.fresh.id, quote: ctx.fresh.body, reason: "相同的固定目录安装，后续提供了重启后的实际运行验收。" };
      tamper?.(resolution);
      return { ok: true, data: { goal: "固定目录安装", status: "固定目录安装已经完成", people: [], resolutions: [resolution] } as T, ms: 1 };
    }
    if (req.task === "thread_digest") return { ok: true, data: { title: "安装已验收", detail: { ...detail, progress: req.prompt.includes("后续进展") ? ctx.fresh.body : "尚未安装" }, new_facts: [], invalidate: [], domain: "work", in_project: true, status_hint: "active" } as T, ms: 1 };
    return { ok: true, data: { brief: req.prompt.includes(ctx.fresh.body) ? "安装已完成并重启验收" : "合成项目已更新" } as T, ms: 1 };
  } };
  return { calls, llm };
}

test("跨事项后续证据替代自动未决事实，无新片段仍先更新详细版再写摘要，归属不变", async () => {
  const ctx = seed();
  try {
    const m = model(ctx);
    await projectStep({ db: ctx.db, llm: m.llm }, ctx.store, at + 1);
    expect(ctx.store.facts("thread_id", "old").some(f => f.id === "open")).toBe(false);
    const replacement = ctx.store.facts("thread_id", "old")[0]!;
    expect(replacement.text).toContain("后续进展");
    expect(replacement.evidence).toContain(ctx.fresh.id);
    expect(ctx.store.thread("old")).toMatchObject({ brief: null, needs_regen: 1, status: "paused" });
    await digestStep({ db: ctx.db, llm: m.llm }, ctx.store, at + 2);
    expect(m.calls.some(c => c.task === "thread_digest")).toBe(true);
    expect(ctx.store.thread("old")!.brief).toBe("安装已完成并重启验收");
    expect(ctx.db.db.prepare("SELECT thread_id FROM assignments WHERE frame_id='frame-new'").get()).toEqual({ thread_id: "new" });
    // 删除真实引用的后续原文，跨事项派生内容也必须同事务撤下。
    expect(ctx.db.delete(ctx.fresh.id)).toBe(true);
    expect(ctx.store.thread("old")!.brief).toBeNull();
    expect(ctx.store.thread("old")!.detail).toBeNull();
    expect(ctx.store.facts("thread_id", "old")).toHaveLength(0);
  } finally { ctx.cleanup(); }
});

test("用户事实、伪造引文、错误引用和没有同项目来源的结果不能被自动替换", async () => {
  for (const mode of ["user", "quote", "record", "project"] as const) {
    const ctx = seed(mode === "user" ? "user" : "llm");
    try {
      const m = model(ctx, r => {
        if (mode === "quote") r.quote = "这是原文没有提供的假完成证据，需要拒绝。";
        if (mode === "record") r.record_id = "outside";
        if (mode === "project") ctx.store.upsertThread({ ...ctx.store.thread("new")!, project_id: "other" });
      });
      await projectStep({ db: ctx.db, llm: m.llm }, ctx.store, at + 1);
      expect(ctx.store.facts("thread_id", "old").map(f => f.id)).toEqual(["open"]);
      expect(ctx.store.thread("old")!.brief).toBe("尚未安装");
    } finally { ctx.cleanup(); }
  }
});

test("项目调用失败不生成后续事实，保持旧检查点可重试", async () => {
  const ctx = seed();
  try {
    const llm: LLM = { async complete() { return { ok: false, error: "合成路由故障", ms: 1 }; } };
    expect((await projectStep({ db: ctx.db, llm }, ctx.store, at + 1)).failed).toBe(1);
    expect(ctx.store.facts("thread_id", "old").map(f => f.id)).toEqual(["open"]);
    expect(ctx.store.project("p")!.needs_regen).toBe(1);
  } finally { ctx.cleanup(); }
});

test("未决状态只写在旧摘要里也可补充后续依据，重复证据不再追加", () => {
  const ctx = seed();
  try {
    ctx.db.db.prepare("DELETE FROM facts WHERE id='open'").run();
    const views = [{ id: "old", title: "安装准备", brief: "尚未安装", project: "合成项目", status: "paused", last: "" }];
    const request = projectRequest(ctx.store, "p", "合成项目", views);
    const input = JSON.parse(/<data>\n([\s\S]*)\n<\/data>/.exec(request.prompt)![1]!);
    const out = { goal: "安装", status: "已验收", people: [], resolutions: [{ open_fact_id: input.summary_targets[0].id,
      by_fact_id: input.facts.find((f: any) => f.kind === "decision").id, record_id: input.completion_evidence[0].id,
      quote: ctx.fresh.body, reason: "同一固定目录安装任务已有后续实际重启验收的直接证据。" }] };
    expect(request.apply(out, at + 1)).toBe(1);
    expect(ctx.store.thread("old")).toMatchObject({ brief: null, needs_regen: 1 });
    expect(ctx.store.facts("thread_id", "old")[0]!.evidence).toEqual([ctx.fresh.id]);
    expect(request.apply(out, at + 2)).toBe(0);
  } finally { ctx.cleanup(); }
});

test("跨时段会话按结束时间核对后续依据，多个独立引文都保留", () => {
  const ctx = seed();
  try {
    ctx.db.db.prepare("DELETE FROM facts WHERE id='open'").run();
    ctx.store.upsertThread({ ...ctx.store.thread("old")!, last_ms: at + 600_000 });
    const body = "应用包内固定目录安装已经完成，重启后验证服务不再依赖源码。删除记录后摘要已在实际运行中消失，真实 HTTP 回归验证通过。";
    ctx.db.db.prepare("UPDATE records SET body=?,t_end=? WHERE id=?").run(body, new Date(at + 1200_000).toISOString(), ctx.fresh.id);
    const req = projectRequest(ctx.store, "p", "合成项目", [{ id: "old", title: "安装准备", brief: "尚未安装", project: "合成项目", status: "paused", last: "" }]);
    const input = JSON.parse(/<data>\n([\s\S]*)\n<\/data>/.exec(req.prompt)![1]!);
    const resolutions = body.split("。").filter(Boolean).map(quote => ({ open_fact_id: input.summary_targets[0].id,
      by_fact_id: input.facts.find((f: any) => f.kind === "decision").id, record_id: input.completion_evidence[0].id,
      quote, reason: "同一任务的实际安装及删除结果出现在这场对话后半段。" }));
    expect(req.apply({ goal: "安装", status: "完成", people: [], resolutions }, at + 1300_000)).toBe(2);
    expect(ctx.store.facts("thread_id", "old")).toHaveLength(2);
    expect(req.apply({ goal: "安装", status: "完成", people: [], resolutions }, at + 1400_000)).toBe(0);
  } finally { ctx.cleanup(); }
});
