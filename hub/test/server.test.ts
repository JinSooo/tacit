import { afterEach, beforeEach, expect, test } from "bun:test";
import { createServer } from "node:net";
import { createHandler, startServer } from "../src/server.ts";
import { fixture, setup } from "./helpers.ts";

let ctx: ReturnType<typeof setup>;
let handler: ReturnType<typeof createHandler>;
const base = "http://127.0.0.1:47823";
beforeEach(() => {
  ctx = setup(); handler = createHandler({ db: ctx.db, token: ctx.config.token });
});
afterEach(() => ctx.cleanup());
function call(path: string, method = "GET", body?: unknown) {
  return handler(new Request(base + path, { method, headers: { host: "127.0.0.1:47823", authorization: `Bearer ${ctx.config.token}`, "content-type": "application/json" }, ...(body === undefined ? {} : { body: JSON.stringify(body) }) }));
}

// 仅在 OS 明确拒绝 bind 时跳过真实网络集成；处理器测试始终执行。
const bindDenied = await new Promise<boolean>((resolve, reject) => {
  const probe = createServer();
  probe.once("error", (error: NodeJS.ErrnoException) => {
    if (error.code === "EPERM" || error.code === "EACCES") resolve(true);
    else reject(error);
  });
  probe.listen(0, "127.0.0.1", () => probe.close(() => resolve(false)));
});
test.skipIf(bindDenied)("真实网络：Bun 只监听 127.0.0.1，缺 token 返回 401", async () => {
  const server = startServer({ db: ctx.db, token: ctx.config.token, port: 0 });
  try {
    expect(server.hostname).toBe("127.0.0.1");
    const url = `http://127.0.0.1:${server.port}`;
    expect((await fetch(url + "/v1/health")).status).toBe(200);
    expect((await fetch(url + "/v1/records")).status).toBe(401);
  } finally { await server.stop(true); }
});

test("处理器：health 公开，其余路由必须 Bearer", async () => {
  expect((await handler(new Request(base + "/v1/health", { headers: { host: "127.0.0.1:47823" } }))).status).toBe(200);
  for (const [method, path] of [["GET", "/v1/records"], ["POST", "/v1/ingest"], ["POST", "/v1/records"], ["GET", "/v1/records/00000000000000000000000000"], ["DELETE", "/v1/records/00000000000000000000000000"]]) {
    expect((await handler(new Request(base + path, { method, headers: { host: "127.0.0.1:47823" } }))).status).toBe(401);
  }
  expect((await handler(new Request(base + "/v1/records", { headers: { host: "127.0.0.1:47823", authorization: "Bearer wrong" } }))).status).toBe(401);
});

test("HTTP 完整写入、读取、分页、修正、删除及墓碑回放", async () => {
  const a = fixture({ source_ref: "synthetic-http-ref", body: "这是接口检索内容" });
  const b = fixture({ source: "manual.note", capture: { method: "manual" } });
  let response = await call("/v1/ingest", "POST", { device: "mac", records: [a, { bad: true }] });
  expect(response.status).toBe(200);
  const ingested = await response.json();
  expect(ingested.accepted).toBe(1);
  expect(ingested.rejected[0].index).toBe(1);
  expect((await (await call("/v1/records", "POST", b)).json()).accepted).toBe(1);
  const page = await (await call("/v1/records?limit=1")).json();
  expect(page.records).toHaveLength(1);
  expect(page.records[0]).not.toHaveProperty("body");
  const next = await (await call(`/v1/records?limit=1&cursor=${page.next_cursor}&body=1`)).json();
  expect(next.records).toHaveLength(1);
  expect(next.records[0]).toHaveProperty("body");
  expect(next.records[0].id).not.toBe(page.records[0].id);
  const matches = await (await call(`/v1/records?q=${encodeURIComponent("接口检索")}&device=mac&source=mac.screen`)).json();
  expect(matches.records.map((r: { id: string }) => r.id)).toEqual([a.id]);
  const correction = fixture({ source: "manual.correction", corrects: a.id, capture: { method: "manual" } });
  expect((await (await call("/v1/records", "POST", correction)).json()).accepted).toBe(1);
  const original = await (await call(`/v1/records/${a.id}`)).json();
  expect(original.body).toBe(a.body);
  expect(original.corrections.map((r: { id: string }) => r.id)).toEqual([correction.id]);
  expect((await call(`/v1/records/${a.id}`, "DELETE")).status).toBe(200);
  expect((await call(`/v1/records/${a.id}`)).status).toBe(404);
  expect((await (await call("/v1/ingest", "POST", { device: "mac", records: [a] })).json()).duplicates).toBe(1);
});

test("HTTP 不接收非 manual 写入、坏 JSON、无效列表参数", async () => {
  expect((await call("/v1/records", "POST", fixture())).status).toBe(400);
  expect((await call("/v1/ingest", "POST", { records: [] })).status).toBe(400);
  expect((await call("/v1/records?cursor=bad")).status).toBe(400);
  const response = await handler(new Request(base + "/v1/ingest", { method: "POST", headers: { host: "127.0.0.1:47823", authorization: `Bearer ${ctx.config.token}` }, body: "{" }));
  expect(response.status).toBe(400);
  const rejected = await (await call("/v1/records", "POST", { source: "manual.note" })).json();
  expect(rejected.rejected).toHaveLength(1);
});
