import { afterEach, expect, test, spyOn } from "bun:test";
import { chmodSync, statSync } from "node:fs";
import { HubDB } from "../src/db.ts";
import { DistillStore } from "../src/distill/store.ts";
import { assignStep, withBreaker, type LLM } from "../src/distill/run.ts";
import { fixture, setup } from "./helpers.ts";

const cleanups: (() => void)[] = [];
afterEach(() => { for (const cleanup of cleanups.splice(0)) cleanup(); });
function context() { const ctx = setup(); cleanups.push(ctx.cleanup); return ctx; }

test("数据库创建和重新打开均限制为用户读写", () => {
  const ctx = context();
  expect(statSync(ctx.file).mode & 0o777).toBe(0o600);
  chmodSync(ctx.file, 0o644);
  const second = new HubDB(ctx.file, ctx.config.dbKey); second.close();
  expect(statSync(ctx.file).mode & 0o777).toBe(0o600);
});

test("归属坏批次保留待重试，后续批次仍能处理，日志不带正文", async () => {
  const ctx = context(), store = new DistillStore(ctx.db), logs: string[] = [];
  for (let i = 0; i < 21; i++) {
    const r = fixture(); ctx.db.ingest([r]);
    store.createFrame({ id: `f${String(i).padStart(2, "0")}`, key: `app:${i}`, record_ids: [r.id], t_start_ms: i, t_end_ms: i, chars: 1, private: 0, status: "new" });
  }
  let calls = 0;
  const llm: LLM = { async complete<T>() { calls++;
    return calls === 1 ? { ok: false, error: "模型输出不符合 schema：合成私密正文", ms: 1 }
      : { ok: true, data: { items: [{ frame_id: "s1", thread_id: null, new_thread_title: null, ignore: true, confidence: 1 }] } as T, ms: 1 };
  } };
  const result = await assignStep({ db: ctx.db, llm, log: line => logs.push(line) }, store, Date.now());
  expect(calls).toBe(2); expect(result.failed).toBe(20);
  expect(store.frames().filter(f => f.status === "new")).toHaveLength(20);
  expect(logs.join("\n")).toContain('"category":"output"');
  expect(logs.join("\n")).not.toContain("私密正文");
});

for (const [error, trips] of [
  ["Usage: codex exec [OPTIONS]", false], ["context length exceeded", false], ["output token limit exceeded", false],
  ["request time limit exceeded", false], ["HTTP 429", true], ["rate_limit_exceeded", true],
  ["You've hit your 5-hour limit", true], ["insufficient_quota", true],
] as const) test(`熔断只识别额度：${error}`, async () => {
  let calls = 0, stopped = 0;
  const llm = withBreaker({ async complete() { calls++; return { ok: false, error, ms: 1 }; } }, () => stopped++);
  const request = { tier: "minute" as const, system: "", prompt: "", schema: {} };
  await llm.complete(request); await llm.complete(request);
  expect(calls).toBe(trips ? 1 : 2); expect(stopped).toBe(trips ? 1 : 0);
});

test("HTTP 500 记录诊断位置和代码，不记录正文、检索词或令牌", async () => {
  const { createHandler } = await import("../src/server.ts");
  const ctx = context(), handler = createHandler({ db: ctx.db, token: ctx.config.token });
  const logs = spyOn(console, "error").mockImplementation(() => {});
  const read = spyOn(ctx.db, "list").mockImplementation(() => { throw Object.assign(new Error("合成私密正文"), { code: "SQLITE_CORRUPT" }); });
  try {
    for (const path of ["/v1/records?q=私密搜索", "/v1/agent/search?tool=codex&q=私密搜索"]) {
      const response = await handler(new Request(`http://127.0.0.1:47823${path}`, { headers: { host: "127.0.0.1:47823", authorization: `Bearer ${ctx.config.token}` } }));
      expect(response.status).toBe(500);
      expect(await response.text()).toBe('{"error":"存储操作失败"}');
    }
    const output = JSON.stringify(logs.mock.calls);
    expect(output).toContain("SQLITE_CORRUPT"); expect(output).toContain("server.request"); expect(output).toContain("agent.storage");
    expect(output).not.toContain("私密"); expect(output).not.toContain(ctx.config.token);
  } finally { read.mockRestore(); logs.mockRestore(); }
});

test("修正回到原活动：读最新正文、证据引用修正、旧摘要排队重建，修正不生成新片段", async () => {
  const { frameView, sliceStep, digestStep } = await import("../src/distill/run.ts");
  const ctx = context(), store = new DistillStore(ctx.db);
  const now = Date.now(), original = fixture({ t_start: new Date(now - 3600_000).toISOString(), body: "旧的错误正文" });
  ctx.db.ingest([original]);
  store.upsertThread({ id: "t", title: "事项", status: "active", brief: "旧摘要", needs_regen: 0 });
  store.createFrame({ id: "f", key: "app:test", record_ids: [original.id], t_start_ms: now - 3600_000, t_end_ms: now - 3600_000, chars: 7, private: 0, status: "new" });
  store.assign("f", "t", "user", 1); store.setState("digest:t", { frames: ["f"], records: 1 });
  store.writeFact({ id: "old", thread_id: "t", kind: "decision", text: "旧的错误事实", evidence: [original.id], origin: "llm", valid_at: original.t_start, created_at: original.t_start });
  const correction = fixture({ source: "manual.correction", corrects: original.id, title: "修正标题", body: "用户确认的正确正文", t_start: new Date(now - 1800_000).toISOString(), capture: { method: "manual" } });
  expect(ctx.db.ingest([correction]).accepted).toBe(1);
  expect(ctx.db.get(original.id)!.body).toBe("旧的错误正文");
  expect(store.thread("t")!.needs_regen).toBe(1); expect(store.getState("digest:t")).toBeNull();
  expect(store.facts("thread_id", "t")).toEqual([]);
  sliceStep(ctx.db, false, now, now - 7200_000);
  expect(store.frames().flatMap(f => f.record_ids)).toEqual([original.id]);
  expect(frameView(store, store.frames()[0]!, { maxRecords: Infinity, excerpt: () => Infinity }).records).toEqual([
    { id: correction.id, source: "manual.correction", title: "修正标题", excerpt: "用户确认的正确正文" },
  ]);
  const prompts: string[] = [];
  const llm: LLM = { async complete(req) { prompts.push(req.prompt); return { ok: false, error: "合成连接失败", ms: 1 }; } };
  await digestStep({ db: ctx.db, llm }, store, now);
  expect(prompts).toHaveLength(1); expect(prompts[0]).toContain("用户确认的正确正文"); expect(prompts[0]).not.toContain("旧的错误");
  ctx.db.delete(correction.id);
  expect(ctx.db.effective(original.id)!.body).toBe("旧的错误正文"); expect(store.thread("t")!.needs_regen).toBe(1);
});

test("私密原文或私密修正都不泄漏到整理输入", async () => {
  const { frameView } = await import("../src/distill/run.ts");
  const ctx = context(), store = new DistillStore(ctx.db);
  for (const [a, b] of [["private", "normal"], ["normal", "private"]] as const) {
    const original = fixture({ sensitivity: a }); ctx.db.ingest([original]);
    ctx.db.ingest([fixture({ source: "manual.correction", corrects: original.id, sensitivity: b, body: "合成秘密", capture: { method: "manual" } })]);
    const view = frameView(store, { id: "f", key: "app:test", record_ids: [original.id], t_start_ms: 0, t_end_ms: 1, chars: 1, private: 0, status: "new" }, { maxRecords: 10, excerpt: () => 100 });
    expect(view.private).toBe(true); expect(JSON.stringify(view)).not.toContain("合成秘密");
  }
});

test("真实 HTTP 删除立即清理摘要、日记、待确认和自动带入，模型失败也不恢复旧内容", async () => {
  const { startServer } = await import("../src/server.ts");
  const { digestStep, nowStep } = await import("../src/distill/run.ts");
  const ctx = context(), store = new DistillStore(ctx.db), at = new Date().toISOString(), now = Date.now();
  const a = fixture({ t_start: at, body: "应删除的内容" }), b = fixture({ t_start: at, body: "剩余依据" }); ctx.db.ingest([a, b]);
  store.upsertProject({ id: "p", name: "项目", keys: { repos: [ctx.dir], hosts: [], chats: [] }, brief: "应删除的内容", detail: { goal: "应删除的内容" } });
  store.upsertThread({ id: "t", title: "应删除的内容", project_id: "p", domain: "work", status: "active", first_ms: now, last_ms: now, brief: "应删除的内容", detail: { progress: "应删除的内容" }, needs_regen: 0 });
  store.createFrame({ id: "f", key: "app:test", record_ids: [a.id, b.id], t_start_ms: now, t_end_ms: now, chars: 20, private: 0, status: "new" }); store.assign("f", "t", "user", 1);
  const date = new Date(now).toLocaleDateString("sv-SE");
  store.upsertDay({ date, brief: "应删除的内容", detail: { summary: "应删除的内容" }, needs_regen: 0 });
  store.createPending({ id: "pending", kind: "thread_done", payload: { thread_id: "t", title: "应删除的内容" }, created_at: at }); nowStep(store, now);
  const server = startServer({ db: ctx.db, token: ctx.config.token, port: 0 });
  const request = async (path: string, method = "GET") => {
    const r = await fetch(`http://127.0.0.1:${server.port}/v1/${path}`, { method, headers: { authorization: `Bearer ${ctx.config.token}` } });
    expect(r.ok).toBe(true); return r.text();
  };
  try {
    expect(await request(`records/${a.id}`, "DELETE")).toContain('"deleted":true');
    for (const path of ["now", "threads/t?level=detail", "projects/p?level=detail", `days/${date}`, "pending", `agent/context?tool=codex&event=startup&cwd=${encodeURIComponent(ctx.dir)}`]) {
      expect(await request(path)).not.toContain("应删除的内容");
    }
    expect(ctx.db.get(b.id)?.body).toBe("剩余依据");
    const llm: LLM = { async complete() { return { ok: false, error: "合成离线", ms: 1 }; } };
    await digestStep({ db: ctx.db, llm }, store, now);
    expect(store.thread("t")?.brief).toBeNull(); expect(store.thread("t")?.detail).toBeNull();
  } finally { await server.stop(true); }
});

test("模型等待期间发生删除，迟到的详细版和简略版都不能写回", async () => {
  const { digestStep } = await import("../src/distill/run.ts");
  for (const during of ["thread_digest", "thread_brief"]) {
    const ctx = context(), store = new DistillStore(ctx.db), r = fixture(); ctx.db.ingest([r]);
    store.upsertThread({ id: "t", title: "事项", status: "active", needs_regen: 1 });
    store.createFrame({ id: "f", key: "app:test", record_ids: [r.id], t_start_ms: 0, t_end_ms: 1, chars: 2, private: 0, status: "new" }); store.assign("f", "t", "user", 1);
    const llm: LLM = { async complete<T>(req: import("../src/llm/index.ts").LLMRequest) {
      if (req.task === during) ctx.db.delete(r.id);
      const data = req.task === "thread_brief" ? { brief: "不能写回的旧内容" } : { title: "不能写回的旧内容", domain: "life", in_project: false,
        detail: { goal: "不能写回的旧内容", progress: "", artifacts: { files: [], urls: [], commands: [], people: [] }, quotes: [] }, new_facts: [], invalidate: [], status_hint: "active" };
      return { ok: true, data: data as T, ms: 1 };
    } };
    await digestStep({ db: ctx.db, llm }, store, Date.now());
    expect(JSON.stringify(store.thread("t"))).not.toContain("不能写回"); expect(store.thread("t")?.needs_regen).toBe(1);
  }
});

test("候选、过期候选和明确忽略可区分，旧候选状态安全补全", async () => {
  const ctx=context(),store=new DistillStore(ctx.db),now=Date.now();
  for (const id of ["live","expired","ignored"]) {
    const r=fixture();ctx.db.ingest([r]);
    store.createFrame({id,key:"app:test",record_ids:[r.id],t_start_ms:now,t_end_ms:now,chars:1,private:0,status:"ignored"});
  }
  store.setState("candidates",[
    {id:"live",title:"候选",frame_ids:["live"],minutes:1,last_ms:now,project_id:null},
    {id:"expired",title:"过期",frame_ids:["expired"],minutes:1,last_ms:now-2*86400_000,project_id:null},
  ]);
  const llm:LLM={async complete(){throw new Error("旧候选不应重新调用模型");}};
  await assignStep({db:ctx.db,llm},store,now);
  const states=Object.fromEntries(store.frames().map(f=>[f.id,f.status]));
  expect(states).toEqual({live:"candidate",expired:"candidate_expired",ignored:"ignored"});
  await assignStep({db:ctx.db,llm},store,now+2*86400_000);
  expect(store.frames().find(f=>f.id==="live")?.status).toBe("candidate_expired");
});
