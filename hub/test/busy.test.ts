import { expect, test } from "bun:test";
import { HubDB } from "../src/db.ts";
import { DistillStore } from "../src/distill/store.ts";
import { createHandler } from "../src/server.ts";
import { fixture, setup } from "./helpers.ts";

function lockedSetup() {
  const ctx = setup();
  const other = new HubDB(ctx.file, ctx.config.dbKey);
  ctx.db.db.pragma("busy_timeout=300");
  const handler = createHandler({ db: ctx.db, token: ctx.config.token });
  const call = (path: string, body?: unknown) => handler(new Request(`http://127.0.0.1:47823${path}`, {
    method: body === undefined ? "GET" : "POST",
    headers: { host: "127.0.0.1:47823", authorization: `Bearer ${ctx.config.token}`, "content-type": "application/json" },
    ...(body === undefined ? {} : { body: JSON.stringify(body) }),
  }));
  return { ...ctx, other, call, cleanup() { if (other.db.inTransaction) other.db.exec("ROLLBACK"); other.close(); ctx.cleanup(); } };
}

test("ingest 撞写锁一秒内返回可重试的 503，解锁后同一请求成功", async () => {
  const ctx = lockedSetup();
  try {
    const body = { device: "mac", records: [fixture()] };
    const before = (await (await ctx.call("/v1/status")).json()).hub.busy;
    expect(before).toMatchObject({ total: 0, by_route: { ingest: 0, agent: 0, web: 0 }, last_at: null });
    ctx.other.db.exec("BEGIN IMMEDIATE");
    const start = performance.now();
    const response = await ctx.call("/v1/ingest", body);
    expect(performance.now() - start).toBeLessThan(1000);
    expect(response.status).toBe(503);
    expect(await response.json()).toEqual({ error: "数据库忙，稍后再试" });
    // WAL 写锁下仍可读状态；不需要写库就能报告此次拒收。
    const busy = (await (await ctx.call("/v1/status")).json()).hub.busy;
    expect(busy).toEqual({ since: before.since, total: 1, by_route: { ingest: 1, agent: 0, web: 0 }, last_at: expect.any(String) });
    expect(Date.parse(busy.last_at)).toBeGreaterThanOrEqual(Date.parse(busy.since));
    ctx.other.db.exec("ROLLBACK");
    const retry = await ctx.call("/v1/ingest", body);
    expect(retry.status).toBe(200);
    expect((await retry.json()).accepted).toBe(1);
    expect((await (await ctx.call("/v1/status")).json()).hub.busy).toEqual(busy);
  } finally { ctx.cleanup(); }
});

test("pending 撞锁仍过滤失效项，解锁后补标 stale，保留有效项与原等锁时间", async () => {
  const ctx = lockedSetup();
  try {
    const store = new DistillStore(ctx.db);
    store.upsertProject({ id: "p", name: "项目", keys: { repos: [], hosts: [], chats: [] } });
    for (const [id, project_id] of [["stale", "missing"], ["valid", "p"]]) store.createPending({ id: id!, kind: "project", payload: { project_id }, created_at: new Date().toISOString() });
    ctx.other.db.exec("BEGIN IMMEDIATE");
    const response = await ctx.call("/v1/pending");
    expect(response.status).toBe(200);
    expect((await response.json()).pending.map((p: { id: string }) => p.id)).toEqual(["valid"]);
    expect(ctx.db.db.prepare("SELECT resolution FROM pending WHERE id='stale'").get()).toEqual({ resolution: null });
    expect(ctx.db.db.pragma("busy_timeout", { simple: true })).toBe(300);
    ctx.other.db.exec("ROLLBACK");
    expect((await ctx.call("/v1/pending")).status).toBe(200);
    expect(ctx.db.db.prepare("SELECT resolution FROM pending WHERE id='stale'").get()).toEqual({ resolution: "stale" });
  } finally { ctx.cleanup(); }
});

test("audio sync 撞锁跳过维护仍可读，解锁后补建声纹待确认", async () => {
  const ctx = lockedSetup();
  try {
    ctx.db.db.prepare("INSERT INTO speakers(id,label,status,centroid,conversations,seconds,created_at) VALUES('s','说话人 A','new',?,3,120,?)").run(Buffer.alloc(512 * 4), new Date().toISOString());
    ctx.other.db.exec("BEGIN IMMEDIATE");
    const response = await ctx.call("/v1/audio/sync?device=mac");
    expect(response.status).toBe(200);
    expect((await response.json()).retention_days).toBe(7);
    expect(ctx.db.db.prepare("SELECT status FROM speakers WHERE id='s'").get()).toEqual({ status: "new" });
    expect(ctx.db.db.pragma("busy_timeout", { simple: true })).toBe(300);
    ctx.other.db.exec("ROLLBACK");
    expect((await ctx.call("/v1/audio/sync?device=mac")).status).toBe(200);
    expect(ctx.db.db.prepare("SELECT status FROM speakers WHERE id='s'").get()).toEqual({ status: "asked" });
  } finally { ctx.cleanup(); }
});

test("Agent 读取的内部 catch 和顶层 catch 都识别扩展忙码，其他异常仍为 500", async () => {
  const ctx = lockedSetup();
  const original = ctx.db.db.prepare;
  try {
    for (const code of ["SQLITE_BUSY", "SQLITE_BUSY_SNAPSHOT", "SQLITE_ERROR"]) {
      ctx.db.db.prepare = (() => { throw Object.assign(new Error("不得出现在响应里的正文"), { code }); }) as typeof original;
      for (const path of ["/v1/records", "/v1/agent/now?tool=codex"]) {
        const response = await ctx.call(path);
        expect(response.status).toBe(code.startsWith("SQLITE_BUSY") ? 503 : 500);
        expect(await response.json()).toEqual({ error: code.startsWith("SQLITE_BUSY") ? "数据库忙，稍后再试" : "存储操作失败" });
      }
    }
  } finally { ctx.db.db.prepare = original; ctx.cleanup(); }
});

test("库忙统计覆盖 Agent 两个内部 catch 和其他接口，其他错误不计数", async () => {
  const ctx = lockedSetup();
  const original = ctx.db.db.prepare;
  try {
    ctx.other.db.exec("BEGIN IMMEDIATE");
    expect((await ctx.call("/v1/agent/append?tool=codex", { title: "合成", body: "合成内容" })).status).toBe(503);
    ctx.other.db.exec("ROLLBACK");
    for (const code of ["SQLITE_BUSY_SNAPSHOT", "SQLITE_ERROR"]) {
      ctx.db.db.prepare = (() => { throw Object.assign(new Error("不得记录正文"), { code }); }) as typeof original;
      for (const path of ["/v1/records", "/v1/agent/now?tool=codex"]) {
        expect((await ctx.call(path)).status).toBe(code === "SQLITE_ERROR" ? 500 : 503);
      }
    }
    ctx.db.db.prepare = original;
    const busy = (await (await ctx.call("/v1/status")).json()).hub.busy;
    expect(busy).toMatchObject({ total: 3, by_route: { ingest: 0, agent: 2, web: 1 } });
    const fresh = createHandler({ db: ctx.db, token: ctx.config.token });
    const response = await fresh(new Request("http://127.0.0.1:47823/v1/status", { headers: { host: "127.0.0.1:47823", authorization: `Bearer ${ctx.config.token}` } }));
    expect((await response.json()).hub.busy).toMatchObject({ total: 0, last_at: null });
  } finally { ctx.db.db.prepare = original; ctx.cleanup(); }
});
