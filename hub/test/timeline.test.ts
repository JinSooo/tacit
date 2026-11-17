import { expect, test } from "bun:test";
import { toLocalIso } from "../../packages/record/index.ts";
import type { ReviewItem } from "../src/distill/day-review.ts";
import { DistillStore } from "../src/distill/store.ts";
import { startServer } from "../src/server.ts";
import { fixture, setup } from "./helpers.ts";

const day = "2026-06-18", previousDay = "2026-06-17", midnight = Date.parse(`${day}T00:00:00`);
const at = (minutes: number) => toLocalIso(midnight + minutes * 60_000);

function segment(id: string, recordIds: string[], project = "trail", start = 0): ReviewItem {
  return {
    id, title: "校对步道地图", description: "核对石桥到林场的路线。", t_start: at(start), t_end: at(start + 4),
    active_seconds: 240, sources: ["manual.note"], apps: [{ source: "manual.note", app: null }], record_ids: recordIds,
    project_id: project, evidence: [],
  };
}

function timelineFixture() {
  const ctx = setup();
  const store = new DistillStore(ctx.db);
  const server = startServer({ db: ctx.db, token: ctx.config.token, agentToken: ctx.config.agentToken, port: 0 });
  const send = (path: string, method = "GET", body?: unknown, token = ctx.config.token) => fetch(`http://127.0.0.1:${server.port}${path}`, {
    method, headers: { Authorization: `Bearer ${token}`, "Content-Type": "application/json" },
    ...(body === undefined ? {} : { body: JSON.stringify(body) }),
  });
  return { ...ctx, store, send, async cleanup() { await server.stop(true); ctx.cleanup(); } };
}

test("时间线按项目和搜索词分页，按记录编号定位跨午夜段或全天原文", async () => {
  const ctx = timelineFixture();
  try {
    const crosses = fixture({ source: "mac.audio", kind: "span", t_start: at(-2), t_end: at(2) });
    const older = fixture({ t_start: at(-70) });
    const raw = fixture({ t_start: at(-60) });
    expect(ctx.db.ingest([crosses,older,raw]).accepted).toBe(3);
    const newer = segment("segment-new", [crosses.id]), earlier = segment("segment-old", [older.id], "trail", -70);
    ctx.store.upsertDay({ date: day, detail: { items: [newer, segment("other", [crosses.id], "garden", 20)] } });
    ctx.store.upsertDay({ date: previousDay, detail: { items: [earlier, { id: "old-diary", title: "旧回顾" }], omitted_record_ids: [raw.id] } });

    const project = "/v1/timeline?project_id=trail&limit=1";
    expect(await (await ctx.send(project)).json()).toEqual({ days: [{ date: day, items: [newer] }], next_cursor: day });
    expect(await (await ctx.send(`${project}&before=${day}`)).json()).toEqual({ days: [{ date: previousDay, items: [earlier] }], next_cursor: null });
    const query = (text: string) => `/v1/timeline?q=${encodeURIComponent(text)}`;
    const matches = await (await ctx.send(query("路线 地图"))).json();
    expect(matches.days.map((row: {date: string}) => row.date)).toEqual([day, previousDay]);
    expect(await (await ctx.send(query("旧回顾"))).json()).toEqual({ days: [], next_cursor: null });
    expect(await (await ctx.send(`/v1/timeline/record/${crosses.id}`)).json()).toEqual({ date: day, segment_id: newer.id });
    expect(await (await ctx.send(`/v1/timeline/record/${raw.id}`)).json()).toEqual({ date: previousDay, segment_id: null });
    expect((await ctx.send(project, "GET", undefined, ctx.config.agentToken)).status).toBe(403);
    const rawDay = await (await ctx.send(`/v1/days/${previousDay}`)).json();
    expect(rawDay.detail.omitted_record_ids).toEqual([raw.id]);
    const mcp = await (await ctx.send(`/v1/agent/get?tool=codex&id=${previousDay}&level=detail`, "GET", undefined, ctx.config.agentToken)).json();
    expect(mcp.item.detail.items[0]).not.toHaveProperty("record_ids");
    expect(mcp.item.detail).not.toHaveProperty("omitted_record_ids");
  } finally { await ctx.cleanup(); }
});

test("段描述修正跨重整保留，整段确认按成员原子删除并清除跨日结果和修正", async () => {
  const ctx = timelineFixture();
  try {
    const records = Array.from({ length: 101 }, () => fixture({ source: "mac.audio", kind: "span", t_start: at(-2), t_end: at(2) }));
    const unaffected = fixture({ t_start: at(-30) });
    expect(ctx.db.ingest([...records,unaffected]).accepted).toBe(102);
    const ids = records.map(record => record.id), item = segment("segment:trail", ids);
    ctx.store.upsertDay({ date: day, detail: { items: [item] } });
    ctx.store.upsertDay({ date: previousDay, detail: { items: [segment("earlier", [ids[0]!], "trail", -2)] } });
    const path = `/v1/days/${day}/segments/${encodeURIComponent(item.id)}`;
    const corrected = "把东侧的石桥标为绕行起点。";
    expect((await (await ctx.send(path, "PATCH", { description: corrected })).json()).item.description).toBe(corrected);
    ctx.store.upsertDay({ date: day, detail: { items: [{ ...item, description: "重新整理的地图。" }] } });
    expect((await (await ctx.send(`/v1/days/${day}`)).json()).detail.items[0].description).toBe(corrected);
    expect((await (await ctx.send(`/v1/timeline?q=${encodeURIComponent("绕行")}`)).json()).days[0].items[0].description).toBe(corrected);
    expect(ctx.db.get(ids[0]!)?.body).toBe(records[0]!.body);

    expect((await ctx.send(path, "DELETE", { record_ids: ids.slice(1) })).status).toBe(409);
    expect(ctx.db.get(ids[0]!)).not.toBeNull();
    expect(await (await ctx.send(path, "DELETE", { record_ids: ids })).json()).toEqual({ deleted: records.length });
    expect(records.every(record => ctx.db.get(record.id) === null)).toBe(true);
    expect(ctx.db.get(unaffected.id)).not.toBeNull();
    expect(ctx.store.day(day)?.detail).toBeNull();
    expect(ctx.store.day(previousDay)?.detail).toBeNull();
    expect(ctx.store.getState(`timeline_corrections:${day}`)).toBeNull();
  } finally { await ctx.cleanup(); }
});

test("项目带入预览沿用会话带入筛选，读取预览不写 Agent 审计", async () => {
  const ctx = timelineFixture();
  try {
    const now = Date.now(), working = { project_id: "trail", domain: "work" as const, title: "绘制地图", brief: "补齐了步道图例。" };
    ctx.store.upsertProject({ id: "trail", name: "青石步道", keys: { repos: ["/tmp/trail"], hosts: [], chats: [] } });
    ctx.store.upsertThread({ ...working, id: "active", status: "active", last_ms: now });
    ctx.store.upsertThread({ ...working, id: "recent", status: "paused", last_ms: now - 60_000 });
    ctx.store.upsertThread({ ...working, id: "old", status: "paused", last_ms: now - 4 * 86_400_000 });
    ctx.store.upsertThread({ ...working, id: "life", status: "active", last_ms: now, domain: "life" });
    const data = await (await ctx.send("/v1/projects/trail/context")).json();
    expect(data.threads.map((thread: {id: string}) => thread.id)).toEqual(["active", "recent"]);
    expect(ctx.db.db.prepare("SELECT count(*) AS n FROM agent_reads").get()).toEqual({ n: 0 });
  } finally { await ctx.cleanup(); }
});
