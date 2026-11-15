import { afterEach, beforeEach, expect, test } from "bun:test";
import { AgentReads } from "../src/agent.ts";
import { fixture, setup } from "./helpers.ts";

let ctx: ReturnType<typeof setup>;
beforeEach(() => { ctx = setup(); });
afterEach(() => ctx.cleanup());
const get = (id: string, level = "detail", cursor?: string) => new AgentReads(ctx.db).handle("get", new URLSearchParams({ tool: "codex", id, level, ...(cursor ? { cursor } : {}) }));

test("依据记录可按 ID 读取并续读完整 Unicode 原文，brief 不复制正文", async () => {
  const record = fixture({ body: "第一段：中文🙂\n".repeat(9000) });
  ctx.db.ingest([record]);
  const brief = await get(record.id, "brief");
  expect(brief.status).toBe(200);
  expect((await brief.json()).item.body).toBeUndefined();
  let text = "", cursor: string | undefined, pages = 0;
  do {
    const response = await get(record.id, "detail", cursor);
    expect(response.status).toBe(200);
    const json = await response.text();
    expect(json.length).toBeLessThanOrEqual(40000);
    const page = JSON.parse(json);
    expect(page.kind).toBe("record");
    text += page.item.body;
    cursor = page.next_cursor ?? undefined;
    pages++;
    expect(pages).toBeLessThan(100);
  } while (cursor);
  expect(pages).toBeGreaterThan(1);
  expect(text).toBe(record.body);
});

test("主动查询标出 private；修正返回有效版本且旧游标失效；删除后不可读", async () => {
  const record = fixture({ body: "待修正".repeat(18000), sensitivity: "private" });
  ctx.db.ingest([record]);
  const first = await (await get(record.id)).json();
  expect(first.item.private).toBe(true);
  expect(first.next_cursor).toBeTruthy();
  const correction = fixture({ source: "manual.correction", corrects: record.id, body: "用户修正后的正文", sensitivity: "private", t_start: "2026-11-14T12:00:00+09:00" });
  ctx.db.ingest([correction]);
  const updated = await (await get(record.id)).json();
  expect(updated.item).toMatchObject({ id: record.id, version_id: correction.id, body: correction.body });
  expect((await get(record.id, "detail", first.next_cursor)).status).toBe(409);
  ctx.db.deleteMany([record.id]);
  expect((await get(record.id)).status).toBe(404);
});

test("记录游标不能跨对象或变成任意偏移读取", async () => {
  const one = fixture({ body: "a".repeat(80000) }), two = fixture();
  ctx.db.ingest([one, two]);
  const first = await (await get(one.id)).json();
  await expect(get(two.id, "detail", first.next_cursor)).rejects.toThrow("cursor");
  await expect(get(one.id, "detail", "bad-cursor")).rejects.toThrow("cursor");
});
