import { afterEach, beforeEach, expect, spyOn, test } from "bun:test";
import { mkdirSync, readFileSync, readdirSync, symlinkSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { createLLM } from "../src/llm/index.ts";
import type { LLMRequest, ModelConfig } from "../src/llm/types.ts";
import { RuntimeLog, appliedCall, backgroundLog, contentRevision, expireSnapshots } from "../src/runtime-log.ts";
import { DistillStore } from "../src/distill/store.ts";
import { HubDB } from "../src/db.ts";
import { createHandler } from "../src/server.ts";
import { AgentReads } from "../src/agent.ts";
import { ulid } from "../../packages/record/index.ts";
import { fixture, reviewEvidence, setup, removeProjectionSchema } from "./helpers.ts";

let ctx: ReturnType<typeof setup>, log: RuntimeLog;
const req: LLMRequest = { tier: "minute", task: "synthetic", system: "只返回 JSON", prompt: "合成私人内容，仅供回归", schema: { type: "object", required: ["ok"], properties: { ok: { type: "boolean" } }, additionalProperties: false } };
beforeEach(() => { ctx = setup(); log = new RuntimeLog(ctx.db); });
afterEach(() => ctx.cleanup());
const config: ModelConfig = { provider: "openai-compatible", model: "synthetic" };
const usage = (id: string) => ({ id, at: new Date().toISOString(), tier: "minute" as const, task: "synthetic", provider: config.provider, model: config.model, input_chars: 10, output_chars: 10, input_tokens: 3, output_tokens: 4, ms: 12, ok: 1 as const, error: null });

test("v10 加密文件真实迁移到 v11，旧记录保留，完整性通过后移除迁移备份", () => {
  const record = fixture(); ctx.db.ingest([record]);
  removeProjectionSchema(ctx.db.db);
  ctx.db.db.exec("DROP TABLE runtime_calls; PRAGMA user_version=10;"); ctx.db.close();
  ctx.db = new HubDB(ctx.file,ctx.config.dbKey); log = new RuntimeLog(ctx.db);
  expect(ctx.db.get(record.id)?.body).toBe(record.body);
  expect(ctx.db.db.pragma("user_version",{simple:true})).toBe(19);
  expect(ctx.db.db.pragma("integrity_check",{simple:true})).toBe("ok");
  expect(readdirSync(ctx.config.dataDir).filter(p=>p.includes("migration-v"))).toEqual([]);
  const id=ulid(); log.begin(id,req,config);
  expect(log.detail(id)!.request.prompt).toBe(req.prompt);
});

test("快照存真实请求/schema/短编号，脱敏加密；返回、校验、采用分别记录", () => {
  const id = ulid(), secret = "sk-" + "SyntheticKey0123456789abcdef";
  const observer = log.begin(id,{ ...req, prompt: `${req.prompt} ${secret}`, refs: { r1: "record-id" } },config);
  observer.request("api",{ messages: [{ content: `${req.prompt} ${secret}` }], response_format: req.schema });
  observer.response(JSON.stringify({ ok: true, echo: secret }));
  log.finish(usage(id),true);
  const detail = log.detail(id)!;
  expect(detail).toMatchObject({ provider_state: "returned", validation_state: "passed", application_state: "pending", content_state: "available" });
  expect(detail.request.refs).toEqual({ r1: "record-id" });
  expect(JSON.stringify(detail)).toContain(req.prompt);
  expect(JSON.stringify(detail)).not.toContain(secret);
  expect(detail.redactions).toBe(2);
  appliedCall(ctx.db,id);
  expect(log.detail(id)!.application_state).toBe("applied");
  expect(readFileSync(ctx.file).includes(Buffer.from(req.prompt))).toBe(false);
  expect(readFileSync(ctx.file).includes(Buffer.from(secret))).toBe(false);
});

test("删除任意记录清空模型和自动带入正文，在途返回不能写回；修正保留历史快照", async () => {
  const record = fixture(); ctx.db.ingest([record]);
  const id = ulid(), observer = log.begin(id,req,config);
  observer.request("api",{ prompt: req.prompt });
  const contextId = ulid(); log.context(contextId,"合成自动带入",[],contentRevision(ctx.db));
  const correction = fixture({ source: "manual.correction", corrects: record.id }); ctx.db.ingest([correction]);
  expect(log.detail(id)!.request).not.toBeNull();
  expect(log.detail(contextId)!.request.text).toBe("合成自动带入");
  const searchAudit = ulid();
  ctx.db.db.prepare("INSERT INTO agent_reads(id,at,tool,kind,args,result_ids,bytes,ok) VALUES(?,?,?,?,?,?,?,?)")
    .run(searchAudit,new Date().toISOString(),"codex","search",JSON.stringify({ q_length: 4, q: "合成检索", session: "s" }),"[]",2,1);
  ctx.db.deleteMany([record.id]);
  expect(JSON.parse((ctx.db.db.prepare("SELECT args FROM agent_reads WHERE id=?").get(searchAudit) as { args: string }).args)).toEqual({ q_length: 4, session: "s" });
  observer.response("已删除内容的迟到回复"); log.finish(usage(id),true);
  for (const target of [id,contextId]) {
    expect(log.detail(target)).toMatchObject({ content_state: "deleted", request: null, response: null });
  }
  expect(log.detail(id)!.application_state).toBe("discarded");
  expect(() => appliedCall(ctx.db,id)).toThrow("记录已变化");
  ctx.db.close(); ctx.db = new HubDB(ctx.file,ctx.config.dbKey); log = new RuntimeLog(ctx.db);
  expect(log.detail(id)!.response).toBeNull();
  expect(log.detail(contextId)!.request).toBeNull();
});

test("删除与快照清空原子提交，清空失败不能假装已删除", () => {
  const record = fixture(); ctx.db.ingest([record]);
  const id = ulid(); log.begin(id,req,config);
  ctx.db.db.exec("CREATE TRIGGER reject_snapshot_delete BEFORE UPDATE ON runtime_calls BEGIN SELECT RAISE(ABORT,'synthetic'); END");
  expect(() => ctx.db.deleteMany([record.id])).toThrow();
  expect(ctx.db.get(record.id)).not.toBeNull();
  ctx.db.db.exec("DROP TRIGGER reject_snapshot_delete");
  expect(log.detail(id)!.request).not.toBeNull();
  ctx.db.deleteMany([record.id]);
  expect(log.detail(id)!.request).toBeNull();
});

test("7 天保留边界、读取时过期和正文大小限制；列表无正文", () => {
  const id = ulid(), observer = log.begin(id,req,config);
  observer.response("合成".repeat(100000));
  expect(log.detail(id)!.response!.length).toBe(128000);
  expect(log.detail(id)!.response_truncated).toBe(1);
  expect(JSON.stringify(log.models(new URLSearchParams()))).not.toContain(req.prompt);
  ctx.db.db.prepare("UPDATE runtime_calls SET at_ms=? WHERE id=?").run(Date.now()-7*86400_000,id);
  const insertAudit = ctx.db.db.prepare("INSERT INTO agent_reads(id,at,tool,kind,args,result_ids,bytes,ok) VALUES(?,?,?,?,?,?,?,?)");
  const oldAudit = ulid(), freshAudit = ulid();
  insertAudit.run(oldAudit,new Date(Date.now()-7*86400_000).toISOString(),"codex","search",'{"q_length":2,"q":"旧词"}',"[]",2,1);
  insertAudit.run(freshAudit,new Date().toISOString(),"codex","search",'{"q_length":2,"q":"新词"}',"[]",2,1);
  expect(log.detail(id)).toMatchObject({ content_state: "expired", request: null, response: null });
  const auditArgs = (auditId: string) => (ctx.db.db.prepare("SELECT args FROM agent_reads WHERE id=?").get(auditId) as { args: string }).args;
  expect(auditArgs(oldAudit)).toBe('{"q_length":2}'); expect(auditArgs(freshAudit)).toBe('{"q_length":2,"q":"新词"}');
  observer.response("迟到回复");
  expect(log.detail(id)!.response).toBeNull();
});

test("新旧调用统一分页；旧调用不伪造快照；受限 Agent 令牌不能读运行日志", async () => {
  new DistillStore(ctx.db).writeUsage({ ...usage(ulid(Date.now()-1000)), error: undefined });
  const id = ulid(); log.begin(id,req,config);
  const one = log.models(new URLSearchParams({ limit: "1" }));
  expect(one.calls).toHaveLength(1); expect(one.next_cursor).toBeTruthy();
  const two = log.models(new URLSearchParams({ cursor: one.next_cursor! }));
  expect(two.calls[0].content_state).toBe("not_recorded");
  expect(log.detail(two.calls[0].id)).toBeNull();
  const handler = createHandler({ db: ctx.db, token: "admin-test", agentToken: "agent-test" });
  for (const path of ["models","background",`calls/${id}`]) {
    const result = await handler(new Request(`http://127.0.0.1:47823/v1/runtime/${path}`,{ headers: { host: "127.0.0.1:47823", authorization: "Bearer agent-test" } }));
    expect(result.status).toBe(403);
  }
});

test("真实 HTTP：写快照失败不发送，发送的 JSON 和记录一致，校验失败单独展示", async () => {
  const received: unknown[] = [];
  const server = Bun.serve({ hostname: "127.0.0.1", port: 0, async fetch(r) { received.push(await r.json()); return Response.json({ choices: [{ finish_reason: "stop", message: { content: '{"ok":true}' } }] }); } });
  const llm = createLLM({ dataDir: ctx.config.dataDir, journal: log, recordUsage: () => {}, configs: async () => {
    const c = { ...config, base_url: `http://127.0.0.1:${server.port}/v1` }; return { minute:c,hour:c,day:c };
  } });
  try {
    ctx.db.db.exec("CREATE TRIGGER reject_snapshot BEFORE INSERT ON runtime_calls BEGIN SELECT RAISE(ABORT,'synthetic'); END");
    const blocked = await llm.complete(req);
    expect(blocked.ok).toBe(false); expect(received).toHaveLength(0);
    ctx.db.db.exec("DROP TRIGGER reject_snapshot");
    const ok = await llm.complete(req);
    expect(ok.ok).toBe(true); expect(received).toHaveLength(1);
    expect(log.detail(ok.call_id!)!.request.request).toEqual(received[0]);
    expect(log.detail(ok.call_id!)!.validation_state).toBe("passed");
    const bad = await llm.complete({ ...req, schema: { type: "object", required: ["missing"] } });
    expect(bad.ok).toBe(false);
    expect(log.detail(bad.call_id!)).toMatchObject({ provider_state: "returned", validation_state: "failed", application_state: "not_applied" });
  } finally { server.stop(true); }
});

test("排队期间删除使待发送调用失效；在途调用只保留无正文元数据", async () => {
  const record = fixture(); ctx.db.ingest([record]);
  let announce!: () => void, release!: () => void, calls = 0;
  const entered = new Promise<void>(r => announce=r), gate = new Promise<void>(r => release=r);
  const server = Bun.serve({ hostname:"127.0.0.1",port:0, async fetch() { calls++; announce(); await gate; return Response.json({ choices:[{finish_reason:"stop",message:{content:'{"ok":true}'}}] }); } });
  const llm = createLLM({ dataDir:ctx.config.dataDir,journal:log,recordUsage:()=>{},configs:async()=> {
    const c = { ...config,base_url:`http://127.0.0.1:${server.port}` }; return {minute:c,hour:c,day:c};
  } });
  try {
    const revision = contentRevision(ctx.db);
    const first = llm.complete({ ...req,contentRevision:revision });
    await entered;
    const queued = llm.complete({ ...req,contentRevision:revision });
    ctx.db.deleteMany([record.id]); release();
    const [a,b] = await Promise.all([first,queued]);
    expect(calls).toBe(1); expect(b.ok).toBe(false);
    expect(log.detail(a.call_id!)).toMatchObject({ content_state:"deleted",response:null,request:null,application_state:"discarded" });
  } finally { release(); server.stop(true); }
});

test("后台日志只读固定文件的结构化状态，不暴露错误原文或跟随符号链接", () => {
  const directory = join(ctx.config.dataDir,"logs"); mkdirSync(directory,{recursive:true});
  writeFileSync(join(directory,"hub.log"),'private plaintext\n'+JSON.stringify({location:"collector.save",category:"storage",error:"个人秘密",records:12})+'\n'
    // 回归：带时区的时间被通用字符串规则整条丢掉，页面看不到事件发生在何时；at 只放行时间格式。
    +JSON.stringify({at:"2026-11-23T20:55:54+09:00",code:"started"})+'\n'+JSON.stringify({at:"昨天 个人秘密",code:"started"})+'\n');
  const result = backgroundLog(ctx.config.dataDir,"hub");
  expect(result.events).toEqual([{ code:"started" },{ at:"2026-11-23T20:55:54+09:00",code:"started" },{ location:"collector.save",category:"storage",records:12 }]);
  expect(result.skipped).toBe(1);
  expect(() => backgroundLog(ctx.config.dataDir,"../../token")).toThrow();
  symlinkSync(join(directory,"hub.log"),join(directory,"collector.log"));
  expect(() => backgroundLog(ctx.config.dataDir,"collector")).toThrow();
});

test("自动带入保存实际返回快照，锁冲突不阻塞查询且留下缺失标记", async () => {
  const store = new DistillStore(ctx.db);
  store.upsertProject({id:"p",name:"合成项目",keys:{repos:["/synthetic/runtime"],hosts:[],chats:[]}});
  store.upsertThread({id:"t",title:"合成事项",brief:"合成旧进展",project_id:"p",domain:"work",status:"active",needs_regen:1});
  reviewEvidence(store,"t");
  const response = await new AgentReads(ctx.db).handle("context",new URLSearchParams({tool:"codex",cwd:"/synthetic/runtime",event:"startup"}));
  const body = await response.json();
  expect(body.text).toContain("有新活动待整理");
  expect(body.text).toContain("合成旧进展");
  const audit = new AgentReads(ctx.db).audit(new URLSearchParams()).reads[0];
  expect(log.detail(audit.id)!.request.text).toBe(body.text);
  const other = new HubDB(ctx.file,ctx.config.dbKey);
  try {
    other.db.exec("BEGIN IMMEDIATE"); const start = performance.now();
    expect((await new AgentReads(ctx.db).handle("context",new URLSearchParams({tool:"codex",cwd:"/synthetic/runtime",event:"startup"}))).status).toBe(200);
    expect(performance.now()-start).toBeLessThan(1000);
    other.db.exec("ROLLBACK");
    expect(new AgentReads(ctx.db).audit(new URLSearchParams()).reads[0].args.snapshot_state).toBe("unavailable");
  } finally { if(other.db.inTransaction) other.db.exec("ROLLBACK"); other.close(); }
});

test("打开旧库时三个错误字段改写为固定类别，可重复打开", () => {
  const id = ulid();
  const legacy = "模型 HTTP 请求失败（502） 合成私密正文 sk-SyntheticExample0123456789abcdef";
  log.begin(id, req, config);
  ctx.db.db.prepare("UPDATE runtime_calls SET error=? WHERE id=?").run(legacy, id);
  ctx.db.db.prepare("INSERT INTO llm_usage(id,at,tier,provider,model,input_chars,output_chars,ms,ok,error) VALUES(?,?,?,?,?,?,?,?,?,?)")
    .run(id, new Date().toISOString(), "minute", config.provider, config.model, 0, 0, 5, 0, legacy);
  const requestId = ulid();
  ctx.db.db.prepare("INSERT INTO distill_requests(id,kind,status,created_at,error) VALUES(?,'round','failed',?,?)")
    .run(requestId, new Date().toISOString(), "合成私密正文 sk-SyntheticExample0123456789abcdef");
  const errors = () => ["runtime_calls", "llm_usage", "distill_requests"].map(table =>
    (ctx.db.db.prepare(`SELECT error FROM ${table}`).get() as { error: string }).error);
  expect(errors()).toEqual([legacy, legacy, "合成私密正文 sk-SyntheticExample0123456789abcdef"]);
  for (let i = 0; i < 2; i++) {
    ctx.db.close();
    ctx.db = new HubDB(ctx.file, ctx.config.dbKey);
    expect(errors()).toEqual(["server_error:502", "server_error:502", "unknown"]);
  }
});

test("运行日志错误字段跟随过期和真删，迟到结果也不回填", () => {
  const record = fixture(); ctx.db.ingest([record]);
  const legacy = "合成私密正文 sk-SyntheticExample0123456789abcdef";
  const expired = ulid(), deleted = ulid();
  for (const id of [expired, deleted]) {
    log.begin(id, req, config);
    ctx.db.db.prepare("UPDATE runtime_calls SET error=? WHERE id=?").run(legacy, id);
  }
  const now = Date.now();
  ctx.db.db.prepare("UPDATE runtime_calls SET at_ms=? WHERE id=?").run(now - 7 * 86400_000, expired);
  expireSnapshots(ctx.db, now);
  expect(log.detail(expired)).toMatchObject({ content_state: "expired", request: null, response: null, error: null });
  ctx.db.delete(record.id);
  log.finish({ ...usage(deleted), ok: 0, error: "network" }, false);
  expect(log.detail(deleted)).toMatchObject({ content_state: "deleted", request: null, response: null, error: null });
});

test("HTTP 200 业务错误的短正文只进入加密快照，元数据和用量只留类别", async () => {
  const key = "sk-Synth123", text = `preview client text ${key}`;
  const fetch = spyOn(globalThis, "fetch").mockResolvedValue(Response.json({ base_resp: { status_code: 9999, status_msg: text } }));
  const rows: Array<{ error: string | null }> = [];
  const llm = createLLM({ dataDir: ctx.dir, journal: log, readKey: () => key, recordUsage: row => { rows.push(row); }, configs: async () => {
    const c = { ...config, base_url: "https://synthetic.invalid" }; return { minute: c, hour: c, day: c };
  } });
  try {
    const result = await llm.complete(req);
    expect(result).toMatchObject({ ok: false, error: "unknown:200" });
    expect(rows[0]?.error).toBe("unknown:200");
    expect(log.models(new URLSearchParams()).calls[0]?.error).toBe("unknown:200");
    expect(log.detail(result.call_id!)!.response).toContain("preview client text [已脱敏:API key]");
    expect(log.detail(result.call_id!)!.response).not.toContain(key);
    expect(readFileSync(ctx.file).includes(Buffer.from("preview client text"))).toBe(false);
  } finally { fetch.mockRestore(); }
});
