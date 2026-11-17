import { afterEach, beforeEach, expect, test } from "bun:test";
import { createRequire } from "node:module";
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { spawnSync } from "node:child_process";
import { mkdirSync } from "node:fs";
import { HubDB } from "../src/db.ts";
import { DistillStore, type Frame, type Fact } from "../src/distill/store.ts";
import { sliceFrames, frameKey, persistFrames } from "../src/distill/frames.ts";
import { DistillRules } from "../src/distill/rules.ts";
import { sliceStep as distillOnce, frameView } from "../src/distill/run.ts";
import { createHandler } from "../src/server.ts";
import { fixture, setup } from "./helpers.ts";
import { ulid } from "../../packages/record/index.ts";
const Database = createRequire(import.meta.url)("better-sqlite3-multiple-ciphers");
let ctx: ReturnType<typeof setup>, store: DistillStore;
beforeEach(() => { ctx = setup(); store = new DistillStore(ctx.db); });
afterEach(() => ctx.cleanup());
const base = Date.parse("2026-11-08T10:00:00+08:00");
const rec = (minute: number, context = { app: "synthetic.app" }) => fixture({ t_start: new Date(base+minute*60000).toISOString(),context });
function frame(ids: string[], key = "repo:/synthetic/repo"): Frame { return { id: ulid(),key,record_ids: ids,t_start_ms: base,t_end_ms: base,chars: 10,private: 0,status: "new" }; }
function project(id = "p") { store.upsertProject({ id,name: "合成项目",keys: { repos: ["/synthetic/repo"],hosts: ["example.test"],chats: ["chat.app:合成群"] },needs_regen: 0 }); }
function thread(id = "t", last_ms = base) { store.upsertThread({ id,project_id: "p",title: "合成线程",status: "active",last_ms,needs_regen: 0 }); }
function fact(evidence: string[], overrides: Partial<Fact> = {}): Fact { const at = new Date(base).toISOString(); return { id: ulid(),thread_id: "t",project_id: "p",kind: "decision",text: "合成决定",evidence,origin: "llm",valid_at: at,created_at: at,...overrides }; }

test("真实 v1 加密结构升级，备份仍为 v1 且不覆盖，未来版本拒绝", () => {
  const file = join(ctx.dir,"legacy.db"), db = new Database(file);
  db.pragma("cipher='sqlcipher'"); db.pragma("legacy=4"); db.pragma(`key='${ctx.config.dbKey}'`);
  db.exec(`CREATE TABLE records(id TEXT NOT NULL UNIQUE,schema INTEGER NOT NULL,device TEXT NOT NULL,source TEXT NOT NULL,source_ref TEXT,kind TEXT NOT NULL,t_start TEXT NOT NULL,t_end TEXT,context TEXT,people TEXT,title TEXT NOT NULL,body TEXT NOT NULL,media TEXT,capture TEXT NOT NULL,sensitivity TEXT NOT NULL,redactions INTEGER NOT NULL,corrects TEXT,t_received TEXT NOT NULL,t_start_ms INTEGER NOT NULL,UNIQUE(source,source_ref));
  CREATE INDEX records_time ON records(t_start_ms DESC,id DESC);
  CREATE INDEX records_corrects ON records(corrects);
  CREATE TABLE tombstones(id TEXT PRIMARY KEY,source TEXT NOT NULL,source_ref TEXT,content_hash TEXT NOT NULL,deleted_at TEXT NOT NULL,UNIQUE(source,source_ref));
  CREATE VIRTUAL TABLE records_fts USING fts5(title,body,tokenize='unicode61');
  PRAGMA user_version=1;`);
  db.close();
  const upgraded = new HubDB(file,ctx.config.dbKey);
  expect(upgraded.db.pragma("user_version",{ simple: true })).toBe(11);
  expect(upgraded.db.pragma("busy_timeout",{ simple: true })).toBe(5000);
  const r = rec(0); expect(upgraded.ingest([r]).accepted).toBe(1);
  upgraded.close();
  const backupFile = `${file}.migration-v1.bak`;
  expect(existsSync(backupFile)).toBe(false);
  const again = new HubDB(file,ctx.config.dbKey);
  expect(again.get(r.id)?.id).toBe(r.id);
  again.db.pragma("user_version=1"); again.close();
  // 制造迁移失败：保留加密旧版本，失败重试不能覆盖。
  expect(() => new HubDB(file,ctx.config.dbKey)).toThrow();
  const backup = readFileSync(backupFile);
  const old = new Database(backupFile); old.pragma("cipher='sqlcipher'"); old.pragma("legacy=4"); old.pragma(`key='${ctx.config.dbKey}'`);
  expect(old.pragma("user_version",{ simple: true })).toBe(1); old.close();
  expect(() => new HubDB(file,ctx.config.dbKey)).toThrow();
  expect(readFileSync(backupFile)).toEqual(backup);
  const future = new Database(file); future.pragma("cipher='sqlcipher'"); future.pragma("legacy=4"); future.pragma(`key='${ctx.config.dbKey}'`); future.pragma("user_version=12"); future.close();
  expect(() => new HubDB(file,ctx.config.dbKey)).toThrow("版本");
});

test("删除真实联动：保留非空片段、删空片段和指派、删事实、标记所有归属", () => {
  project(); thread(); const a = rec(0), b = rec(1), c = rec(2);
  ctx.db.ingest([a,b,c]);
  const f = frame([a.id,b.id]), empty = frame([c.id]);
  store.createFrame(f); store.createFrame(empty); store.assign(f.id,"t","rule",1); store.assign(empty.id,"t","rule",1);
  store.writeFact(fact([a.id])); store.writeFact(fact([c.id])); store.writeFact(fact([b.id]));
  store.upsertDay({ date: a.t_start.slice(0,10),brief: "合成日记",needs_regen: 0 });
  expect(ctx.db.delete(a.id)).toBe(true); expect(ctx.db.delete(c.id)).toBe(true);
  expect(store.frames().map(f => f.record_ids)).toEqual([[b.id]]);
  expect(ctx.db.db.prepare("SELECT frame_id FROM assignments").all()).toEqual([{ frame_id: f.id }]);
  expect(store.facts("thread_id","t").map(f => f.evidence)).toEqual([[b.id]]);
  expect(store.thread("t")?.needs_regen).toBe(1); expect(store.project("p")?.needs_regen).toBe(1);
  expect(store.day(a.t_start.slice(0,10))?.needs_regen).toBe(1);
});

test("删除联动失败会回滚原记录、片段和墓碑", () => {
  const r = rec(0); ctx.db.ingest([r]); const f = frame([r.id]); store.createFrame(f);
  project(); thread();
  const detail = { quotes: [{ record_id: r.id,text: "回滚保留的合成原话" }] };
  store.upsertThread({ ...store.thread("t")!,detail });
  ctx.db.db.exec("CREATE TRIGGER fail_delete BEFORE DELETE ON records BEGIN SELECT RAISE(ABORT,'合成失败'); END");
  expect(() => ctx.db.delete(r.id)).toThrow(); expect(ctx.db.get(r.id)).not.toBeNull(); expect(store.frames()).toHaveLength(1);
  expect(ctx.db.db.prepare("SELECT * FROM tombstones").all()).toHaveLength(0);
  expect(store.thread("t")?.detail).toEqual(detail);
  expect(ctx.db.db.prepare("SELECT record_id FROM frame_records").all()).toEqual([{ record_id: r.id }]);
});

test("JSON 编解码、事实不可覆盖、用户优先、失败替代回滚、状态和用量", () => {
  project(); thread(); const r = rec(0); ctx.db.ingest([r]);
  const first = fact([r.id],{ origin: "user" }); store.writeFact(first);
  expect(() => store.writeFact({ ...first,text: "改写" })).toThrow();
  expect(() => store.writeFact(fact([r.id]),first.id)).toThrow();
  expect(store.facts("thread_id","t")).toHaveLength(1);
  const replacement = fact([r.id],{ origin: "user" }); store.writeFact(replacement,first.id);
  expect(store.facts("thread_id","t").map(f => f.id)).toEqual([replacement.id]);
  store.setState("now",{ detail: { goal: "合成目标" } }); expect(store.getState("now")).toEqual({ detail: { goal: "合成目标" } });
  store.upsertDay({ date: "2026-11-08",detail: { items: [] } }); expect(store.day("2026-11-08")?.detail).toEqual({ items: [] });
  store.writeUsage({ tier: "minute",provider: "synthetic",model: "synthetic",ms: 1,ok: 1 });
  expect(ctx.db.db.prepare("SELECT count(*) n FROM llm_usage").get()).toEqual({ n: 1 });
});

test("切片键优先级、十分钟边界、两小时边界、剪贴板跟随和 private", () => {
  expect(frameKey(fixture({ context: { repo: "/repo",chat: "群",url: "https://example.test" } }))).toBe("chat:mac.screen:群");
  expect(frameKey(fixture({ source: "codex.session",source_ref: "session-1#hour",context: { cwd: "/cwd" } }))).toBe("session:codex.session:session-1");
  expect(frameKey(fixture({ context: { chat: "群",app: "chat.app" } }))).toBe("chat:chat.app:群");
  expect(frameKey(fixture({ context: { url: "https://example.test/a" } }))).toBe("url:https://example.test/a");
  const records = Array.from({ length: 14 },(_,i) => rec(i*10));
  const clip = { ...rec(5),source: "mac.clipboard",sensitivity: "private" as const };
  const orphan = { ...rec(200),source: "mac.file" };
  const result = sliceFrames([...records,clip,orphan],base-1,base+300*60000);
  expect(result.frames.map(f => f.record_ids.length)).toEqual([14,1,1]);
  expect(result.frames[0]?.private).toBe(1);
  expect(result.frames.every(f => f.t_end_ms-f.t_start_ms <= 7200000)).toBe(true);
  expect(result.frames.at(-1)?.key).toBe("app:synthetic.app");
  const split = sliceFrames([rec(0),rec(10.001)],base-1,base+100*60000);
  expect(split.frames).toHaveLength(2);
});

test("开放片段阻止 cursor 越过它，重复轮次不丢失、不重复，同时间记录一起处理", () => {
  const a = rec(0), b = rec(20), c = rec(20,{ app: "other.app" }); ctx.db.ingest([a,b,c]);
  store.setState("enabled_ms",base-1);
  let result = persistFrames(ctx.db,base-1,base+25*60000);
  expect(result.frames.flatMap(f => f.record_ids)).toEqual([a.id]);
  expect(result.cursor_ms).toBe(base+20*60000-1);
  result = persistFrames(ctx.db,result.cursor_ms,base+31*60000);
  expect(result.frames.flatMap(f => f.record_ids).sort()).toEqual([b.id,c.id].sort());
  expect(persistFrames(ctx.db,result.cursor_ms,base+60*60000).frames).toHaveLength(0);
  expect(() => store.createFrame(frame([a.id]))).toThrow();
});

test("只有明确聊天可规则归属，repo 和 host 只提名项目", () => {
  project(); thread("recent",base); store.upsertThread({ id: "done",title: "已完成",project_id: "p",status: "done",last_ms: base+100 });
  const rules = new DistillRules(store);
  for (const key of ["repo:/synthetic/repo","host:example.test","chat:chat.app:合成群"]) {
    const r = rec(0); ctx.db.ingest([r]); const f = frame([r.id],key); store.createFrame(f);
    expect(rules.assign(f)).toEqual(key.startsWith("chat:") ? { status: "assigned",thread_id: "recent",project_id: "p" } : { status: "unassigned" });
  }
  expect(rules.assign({ ...frame([]),t_start_ms: base + 3 * 3_600_000 })).toEqual({ status: "unassigned" });
  thread("other",base);
  expect(rules.assign(frame([]))).toEqual({ status: "unassigned" });
  expect(rules.assign(frame([],"host:unknown.test"))).toEqual({ status: "unassigned" });
  ctx.db.db.prepare("UPDATE threads SET status='paused'").run();
  expect(rules.assign(frame([]))).toEqual({ status: "unassigned" });
});

test("合成 git 仓库自动建项目和 pending，重复调用复用项目", () => {
  const repo = join(ctx.dir,"synthetic-repo"); mkdirSync(repo); expect(spawnSync("git",["init",repo]).status).toBe(0);
  const rules = new DistillRules(store); const p = rules.projectForRepo(repo)!;
  expect(p.name).toBe("synthetic-repo"); expect(p.confirmed).toBe(0); expect(store.pending()).toHaveLength(1);
  expect(rules.projectForRepo(repo)?.id).toBe(p.id); expect(store.pending()).toHaveLength(1);
  expect(rules.projectForRepo(join(ctx.dir,"missing"))).toBeNull();
});

test("首次增量跳过旧记录，回填按天且只运行一次", () => {
  ctx.db.ingest([rec(-1500),rec(0)]);
  expect(distillOnce(ctx.db,false,base+60000).frames).toBe(0);
  const recent = rec(2); ctx.db.ingest([recent]);
  expect(distillOnce(ctx.db,false,base+20*60000).frames).toBe(1);
  expect(distillOnce(ctx.db,true,base+30*60000).frames).toBe(2);
  expect(store.getState("backfill_done")).toBe(true);
  expect(distillOnce(ctx.db,true,base+40*60000).frames).toBe(0);
});

function api() {
  const handler = createHandler({ db: ctx.db,token: "synthetic-token" });
  return (path: string, body?: unknown, headers: Record<string,string> = {}) => handler(new Request(`http://127.0.0.1:47823/v1/${path}`,{ method: body === undefined ? "GET" : "POST",headers: { host: "127.0.0.1:47823",authorization: "Bearer synthetic-token",...headers },...(body !== undefined ? { body: JSON.stringify(body) } : {}) }));
}
test("提炼接口鉴权、Host、evidence 无正文、有效 facts 和游标", async () => {
  project(); thread(); thread("t2",base+1); const r = rec(0); ctx.db.ingest([r]); const f = frame([r.id]); store.createFrame(f); store.assign(f.id,"t","rule",1); store.writeFact(fact([r.id]));
  store.upsertThread({ ...store.thread("t")!,detail: { goal: "目标",quotes: [{ record_id: r.id,text: "合成摘录" }] } });
  const request = api();
  expect((await request("now",undefined,{ authorization: "" })).status).toBe(401);
  expect((await request("projects",undefined,{ host: "evil.test" })).status).toBe(421);
  expect(await (await request("now")).json()).toEqual({ now: { feedback: "已有活动记录，等待整理出摘要。" } });
  expect(await (await request("threads/t?level=brief")).json()).not.toHaveProperty("detail");
  const evidence = await (await request("threads/t?level=evidence")).json();
  expect(evidence.records).toEqual([{ id: r.id,title: r.title,t_start: r.t_start,source: r.source,relation: "support" }]); expect(evidence.facts).toHaveLength(1);
  expect((await request("threads/t?level=wrong")).status).toBe(400);
  const page = await (await request("threads?limit=1")).json(); expect(page.threads[0].id).toBe("t2");
  const next = await (await request(`threads?limit=1&cursor=${page.next_cursor}`)).json(); expect(next.threads[0].id).toBe("t");
  expect((await request("threads?cursor=bad")).status).toBe(400);
  expect((await request("projects/missing")).status).toBe(404);
  const posted = await (await request("facts",{ kind: "decision",text: "用户决定",evidence: [r.id],thread_id: "t",origin: "llm" })).json();
  expect(posted.origin).toBe("user");
  expect((await request("facts",{ kind: "open",text: "无证据",evidence: [] })).status).toBe(400);
  const replacement = await (await request("facts",{ kind: "decision",text: "修正",evidence: [r.id],supersedes: posted.id })).json();
  expect(store.facts("thread_id","t").map(f => f.id)).not.toContain(posted.id);
  expect(replacement.origin).toBe("user");
  // 回归：网页修正时把原 fact 的 null 字段（如 project_id）原样回传，曾被判为类型无效（2026-11-08 浏览器验收发现）。
  const fromWeb = await request("facts",{ kind: "decision",text: "网页修正",evidence: [r.id],thread_id: "t",project_id: null,reason: null,supersedes: replacement.id });
  expect(fromWeb.status).toBe(200);
  expect((await request("facts",{ kind: "decision",text: "x",evidence: [r.id],thread_id: 1 })).status).toBe(400);
});

test("pending 所有项目操作及线程操作实际落库，合并迁移 keys、线程和 facts", async () => {
  project(); thread(); const r = rec(0); ctx.db.ingest([r]); store.writeFact(fact([r.id]));
  const request = api();
  const pending = (kind: "project" | "thread_done",payload: Record<string,unknown>) => { const id = ulid(); store.createPending({ id,kind,payload,created_at: new Date().toISOString() }); return id; };
  expect((await request(`pending/${pending("project",{ project_id: "p" })}`,{ action: "confirm" })).status).toBe(200); expect(store.project("p")?.confirmed).toBe(1);
  expect((await request(`pending/${pending("project",{ project_id: "p" })}`,{ action: "rename",name: "新名称" })).status).toBe(200); expect(store.project("p")?.name).toBe("新名称");
  store.upsertProject({ id: "target",name: "目标",keys: { repos: ["/target"],hosts: [],chats: ["chat.app:合成 群"] } });
  expect((await request(`pending/${pending("project",{ project_id: "p" })}`,{ action: "merge_into",target: "target" })).status).toBe(200);
  expect(store.project("p")).toBeNull(); expect(store.thread("t")?.project_id).toBe("target"); expect(store.facts("project_id","target")).toHaveLength(1); expect(store.project("target")?.keys.repos).toEqual(["/target","/synthetic/repo"]);
  expect(store.project("target")?.keys.chats).toEqual(["chat.app:合成群"]);
  for (const [action,status] of [["done","done"],["continue","active"],["abandon","abandoned"]] as const) {
    expect((await request(`pending/${pending("thread_done",{ thread_id: "t" })}`,{ action })).status).toBe(200); expect(store.thread("t")?.status).toBe(status);
  }
  expect((await request(`pending/${pending("project",{ project_id: "target" })}`,{ action: "ignore" })).status).toBe(200);
  expect(store.project("target")).toBeNull(); expect(store.thread("t")?.project_id).toBeNull(); expect(store.pending()).toHaveLength(0);
});

// 回归：辅助事件先于同应用的主片段时，不能倒挂进未来片段。
test("较早的孤立辅助事件不会倒挂进未来同应用片段", () => {
  const early = { ...rec(0),source: "mac.clipboard" }, later = rec(30);
  const result = sliceFrames([early,later],base-1,base+60*60000);
  expect(result.frames.map(f => f.record_ids)).toEqual([[early.id],[later.id]]);
  expect(result.frames.map(f => f.t_start_ms)).toEqual([base,base+30*60000]);
});

// 测试不能调用真实模型：子进程测试用 --slice-only。
test("CLI distill --slice-only --backfill 真实子进程处理后退出，未知参数拒绝", () => {
  ctx.db.ingest([rec(0)]);
  const cli = new URL("../src/cli.ts",import.meta.url).pathname;
  const env = { ...process.env,RA_DATA_DIR: ctx.dir,RA_DB_KEY: ctx.config.dbKey };
  const result = spawnSync(process.execPath,[cli,"distill","--slice-only","--backfill"],{ env,encoding: "utf8",timeout: 10000 });
  expect(result.status).toBe(0);
  expect(JSON.parse(result.stdout)).toMatchObject({ frames: 1,assigned: 0,unassigned: 1 });
  expect(store.getState("backfill_done")).toBe(true);
  const bad = spawnSync(process.execPath,[cli,"distill","--unknown"],{ env,encoding: "utf8" });
  expect(bad.status).toBe(1);
});

// 回归：开始时间早于 cursor 的晚到会话和手动补写不能永久漏掉。
test("迟到会话、三天前补写和开放记录均可续切且归属唯一", () => {
  store.setState("enabled_ms",base-4*3600000); store.setState("cursor_ms",base-4*3600000);
  const initial = rec(150,{ app: "same.app" }); ctx.db.ingest([initial]);
  distillOnce(ctx.db,false,base+180*60000);
  const oldFrame = store.frames()[0]!;
  const late = { ...rec(60,{ app: "same.app" }),source: "claude_code.session",source_ref: "synthetic-late-session" };
  const manual = { ...rec(-3*24*60),source: "manual.note" };
  const open = rec(179);
  expect(ctx.db.ingest([late,manual,open]).accepted).toBe(3);
  distillOnce(ctx.db,false,base+180*60000);
  expect(store.frames().flatMap(f => f.record_ids)).toContain(late.id);
  expect(store.frames().flatMap(f => f.record_ids)).toContain(manual.id);
  expect(store.frames().find(f => f.id === oldFrame.id)?.record_ids).toEqual([initial.id]);
  expect(store.frames().flatMap(f => f.record_ids)).not.toContain(open.id);
  distillOnce(ctx.db,false,base+200*60000);
  const ids = store.frames().flatMap(f => f.record_ids);
  expect(ids.sort()).toEqual([initial.id,late.id,manual.id,open.id].sort());
  expect(ctx.db.db.prepare("SELECT count(*) n FROM frame_records").get()).toEqual({ n: 4 });
});

test("删除记录立即撤下所有引用它的线程与项目详细版，剩余依据保留供重建", () => {
  const a = rec(0), b = rec(1); ctx.db.ingest([a,b]); project(); thread();
  const detail = { goal: "合成目标",quotes: [{ record_id: a.id,text: "应删除的合成原话" },{ record_id: b.id,text: "保留的合成原话" }] };
  store.upsertThread({ ...store.thread("t")!,detail });
  store.upsertThread({ id: "unrelated",status: "active",title: "另一线程",detail,needs_regen: 0 });
  store.upsertProject({ ...store.project("p")!,detail });
  expect(JSON.stringify(store.thread("unrelated")?.detail)).toContain("应删除的合成原话");
  ctx.db.delete(a.id);
  for (const entity of [store.thread("t"),store.thread("unrelated"),store.project("p")]) {
    expect(entity?.detail).toBeNull();
    expect(entity?.brief).toBeNull();
    expect(entity?.needs_regen).toBe(1);
  }
});

test("旧开发版 v2 打开时补建归属索引，删除与 JSON 归属保持同步", () => {
  const a = rec(0), b = rec(1); ctx.db.ingest([a,b]); const f = frame([a.id,b.id]); store.createFrame(f);
  ctx.db.db.exec("DROP TABLE frame_records");
  const reopened = new HubDB(ctx.file,ctx.config.dbKey);
  try {
    expect(reopened.db.pragma("user_version",{ simple: true })).toBe(11);
    expect(reopened.db.prepare("SELECT record_id,frame_id FROM frame_records ORDER BY record_id").all()).toEqual([a.id,b.id].sort().map(record_id => ({ record_id,frame_id: f.id })));
    expect(() => new DistillStore(reopened).createFrame(frame([a.id]))).toThrow();
    reopened.delete(a.id);
    expect(reopened.db.prepare("SELECT record_id FROM frame_records").all()).toEqual([{ record_id: b.id }]);
    expect(new DistillStore(reopened).frames()[0]?.record_ids).toEqual([b.id]);
    reopened.delete(b.id);
    expect(reopened.db.prepare("SELECT * FROM frame_records").all()).toHaveLength(0);
    expect(new DistillStore(reopened).frames()).toHaveLength(0);
  } finally { reopened.close(); }
});

test("pending 读取补展示字段但不改 payload，失效项标 stale，项目返回线程数", async () => {
  project();
  for (let i = 0; i < 7; i++) { thread(`thread-${i}`,base+i); store.upsertThread({ ...store.thread(`thread-${i}`)!,brief: `合成摘要${i}` }); }
  const items = [
    { id: "project-pending",kind: "project" as const,payload: { project_id: "p" } },
    { id: "thread-pending",kind: "thread_done" as const,payload: { thread_id: "thread-0" } },
    { id: "stale-project",kind: "project" as const,payload: { project_id: "gone" } },
    { id: "stale-thread",kind: "thread_done" as const,payload: { thread_id: "gone" } },
    { id: "stale-merge",kind: "merge" as const,payload: { a: "p",b: "gone",reason: "合成理由" } },
  ];
  for (const item of items) store.createPending({ ...item,created_at: new Date(base).toISOString() });
  const response = await (await api()("pending")).json();
  expect(response.pending).toHaveLength(1);
  const p = response.pending.find((p: any) => p.id === "project-pending");
  expect(p.payload.name).toBe("合成项目"); expect(p.payload.keys).toEqual(store.project("p")?.keys);
  expect(p.payload.threads.map((t: any) => t.id)).toEqual([6,5,4,3,2].map(i => `thread-${i}`));
  expect(Object.keys(p.payload.threads[0]).sort()).toEqual(["brief","id","title"]);
  expect(store.pending().find(p => p.id === "thread-pending")?.payload).toEqual({ thread_id: "thread-0",title: "合成线程",brief: "合成摘要0" });
  for (const item of items.slice(0,2)) {
    const row = ctx.db.db.prepare("SELECT payload FROM pending WHERE id=?").get(item.id) as { payload: string };
    expect(JSON.parse(row.payload)).toEqual(item.payload);
  }
  const stale = ctx.db.db.prepare("SELECT resolution,resolved_at FROM pending WHERE id LIKE 'stale-%'").all() as { resolution: string; resolved_at: string }[];
  expect(stale).toHaveLength(3); for (const row of stale) { expect(row.resolution).toBe("stale"); expect(row.resolved_at).toBeString(); }
  const projects = await (await api()("projects")).json(); expect(projects.projects[0].thread_count).toBe(7);
});

test("merge pending 合并真实迁移，keep 持久化无序项目对且不再提示", async () => {
  project("a"); project("b");
  thread(); store.upsertThread({ ...store.thread("t")!,project_id: "a" });
  const r = rec(0); ctx.db.ingest([r]); store.writeFact(fact([r.id],{ project_id: "a" }));
  store.createPending({ id: "merge-ab",kind: "merge",payload: { a: "a",b: "b",reason: "同一合成项目" },created_at: new Date(base).toISOString() });
  const request = api();
  const list = await (await request("pending")).json();
  expect(list.pending[0].payload).toMatchObject({ a: "a",b: "b",a_name: "合成项目",b_name: "合成项目",reason: "同一合成项目" });
  expect((await request("pending/merge-ab",{ action: "merge" })).status).toBe(200);
  expect(store.project("a")).toBeNull(); expect(store.thread("t")?.project_id).toBe("b"); expect(store.facts("project_id","b")).toHaveLength(1);
  project("c");
  store.createPending({ id: "keep-bc",kind: "merge",payload: { a: "b",b: "c",reason: "合成理由" },created_at: new Date(base).toISOString() });
  expect((await request("pending/keep-bc",{ action: "keep" })).status).toBe(200);
  expect(store.project("b")).not.toBeNull(); expect(store.project("c")).not.toBeNull(); expect(store.getState("merge_dismissed")).toEqual([["b","c"]]);
  const reopened = new HubDB(ctx.file,ctx.config.dbKey);
  try {
    const nextStore = new DistillStore(reopened);
    nextStore.createPending({ id: "repeat-cb",kind: "merge",payload: { a: "c",b: "b",reason: "反向同一对" },created_at: new Date(base).toISOString() });
    expect(nextStore.pending()).toHaveLength(0);
    expect(reopened.db.prepare("SELECT 1 FROM pending WHERE id='repeat-cb'").get()).toBeUndefined();
  } finally { reopened.close(); }
});


test("git 路径探测在进程内缓存，跨规则实例也不重复 spawn，失败结果同样缓存", () => {
  const count = join(ctx.dir,"git-count"), missing = join(ctx.dir,"not-a-repo");
  const envNames = ["PATH","RA_SYNTHETIC_GIT_COUNT","RA_SYNTHETIC_GIT_MISSING"] as const;
  const previous = envNames.map(name => process.env[name]);
  writeFileSync(join(ctx.dir,"git"),`#!/bin/sh
printf 'call\n' >> "$RA_SYNTHETIC_GIT_COUNT"
if [ "$2" = "$RA_SYNTHETIC_GIT_MISSING" ]; then exit 1; fi
printf '%s\n' "$2"
`,{ mode: 0o755 });
  try {
    process.env.PATH = ctx.dir + ":" + process.env.PATH;
    process.env.RA_SYNTHETIC_GIT_COUNT = count;
    process.env.RA_SYNTHETIC_GIT_MISSING = missing;
    const repo = join(ctx.dir,"cached-repo");
    const first = new DistillRules(store).projectForRepo(repo);
    expect(first).not.toBeNull();
    expect(new DistillRules(store).projectForRepo(repo)?.id).toBe(first?.id);
    expect(new DistillRules(store).projectForRepo(missing)).toBeNull();
    expect(new DistillRules(store).projectForRepo(missing)).toBeNull();
    // 成功路径探测 common-dir 和 toplevel 各一次，失败路径只探测一次。
    expect(readFileSync(count,"utf8").trim().split("\n")).toHaveLength(3);
  } finally {
    envNames.forEach((name,i) => { if (previous[i] === undefined) delete process.env[name]; else process.env[name] = previous[i]; });
  }
});

// 回归：事实的证据其实属于另一个项目，用户只能"修正"文案，证据仍挂在原线程上（2026-11-10 用户报告）。
test("事实不属于这条线程：证据所在片段退回未分配并记下拒绝，作废该事实和全由这些片段支撑的推断", async () => {
  project(); thread(); const a = rec(0), b = rec(1), keep = rec(30);
  ctx.db.ingest([a,b,keep]);
  const wrong = frame([a.id,b.id]), right = frame([keep.id]);
  store.createFrame(wrong); store.createFrame(right); store.assign(wrong.id,"t","llm",0.8); store.assign(right.id,"t","llm",0.8);
  const target = fact([a.id],{ origin: "user",text: "用户修正过的文案" }), sameFrames = fact([b.id]), mixed = fact([b.id,keep.id]), own = fact([keep.id]);
  for (const f of [target,sameFrames,mixed,own]) store.writeFact(f);
  store.upsertDay({ date: a.t_start.slice(0,10),needs_regen: 0 });
  const request = api();
  const res = await request(`facts/${target.id}/detach`,{});
  expect(res.status).toBe(200);
  expect(await res.json()).toEqual({ frames: 1,facts: 2 });
  expect(store.frames().find(f => f.id === wrong.id)?.status).toBe("new");
  expect(ctx.db.db.prepare("SELECT frame_id FROM assignments").all()).toEqual([{ frame_id: right.id }]);
  expect(store.rejectedThreads(wrong.id)).toEqual(["t"]);
  expect(store.facts("thread_id","t").map(f => f.id).sort()).toEqual([mixed.id,own.id].sort());
  expect(store.thread("t")?.needs_regen).toBe(1); expect(store.project("p")?.needs_regen).toBe(1);
  expect(store.day(a.t_start.slice(0,10))?.needs_regen).toBe(1);
  // 规则不会再把它直接归回原线程（项目里只有这一条活跃线程，原本会命中）。
  expect(new DistillRules(store).assign(store.frames().find(f => f.id === wrong.id)!)).toEqual({ status: "unassigned" });
  // 已失效的事实不能再操作。
  expect((await request(`facts/${target.id}/detach`,{})).status).toBe(400);
  // 删除片段里的全部记录时，拒绝记录跟着删。
  ctx.db.delete(a.id); ctx.db.delete(b.id);
  expect(ctx.db.db.prepare("SELECT count(*) AS n FROM frame_rejections").get()).toEqual({ n: 0 });
});

test("微信旧聊天名空白差异合并切片，项目匹配兼容旧键且原记录不改", () => {
  const app = "com.tencent.xinWeChat";
  const names = ["C 王家琪", "C王家琪", "C童文科", "C 童文科", "File Transfer", "FileTransfer"];
  const records = names.map((chat, i) => fixture({ source: "mac.wechat", t_start: new Date(base + i * 60000).toISOString(), context: { app, chat } }));
  ctx.db.ingest(records);
  const result = sliceFrames(records, base - 1, base + 3600000);
  expect(result.frames.map(f => f.record_ids)).toEqual([records.slice(0, 2).map(r => r.id), records.slice(2, 4).map(r => r.id), records.slice(4, 6).map(r => r.id)]);
  expect(records.map(r => ctx.db.get(r.id)?.context?.chat)).toEqual(names);
  store.upsertProject({ id: "p", name: "项目", keys: { repos: [], hosts: [], chats: [`${app}:C 王家琪`] } });
  thread();
  const f = { ...result.frames[0]!, id: ulid() };
  store.createFrame(f);
  expect(new DistillRules(store).assign(f)).toEqual({ status: "assigned", thread_id: "t", project_id: "p" });
  const other = { ...result.frames[1]!, id: ulid() };
  expect(frameView(store, other, { maxRecords: 10, excerpt: () => 100 }).key).toBe(`chat:${app}:C 童文科`);
  // 已持久化、带空格的旧片段同样能匹配不带空格的项目键。
  store.upsertProject({ id: "p", name: "项目", keys: { repos: [], hosts: [], chats: [`${app}:C王家琪`] } });
  expect(new DistillRules(store).assign({ ...f, key: `chat:${app}:C 王家琪` }).status).toBe("assigned");
});
