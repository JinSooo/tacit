import { expect, test } from "bun:test";
import { toLocalIso } from "../../packages/record/index.ts";
import type { ReviewItem } from "../src/distill/day-review.ts";
import { DistillStore } from "../src/distill/store.ts";
import { startServer } from "../src/server.ts";
import { fixture, setup } from "./helpers.ts";

const day = "2026-06-18", previousDay = "2026-06-17", midnight = Date.parse(`${day}T00:00:00`);
const at = (minutes: number) => toLocalIso(midnight + minutes * 60_000);

function segment(id: string, recordIds: string[], project: string | null = "trail", start = 0): ReviewItem {
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

test("时间线按引用原文的事项归属跨天分页，事项可无项目且与其他筛选互斥", async () => {
  const ctx = timelineFixture();
  try {
    ctx.store.upsertThread({ id: "route", title: "核对入口路线", status: "active" });
    ctx.store.upsertThread({ id: "sign", title: "更新指示牌", status: "active" });
    const updates = [
      { id: "route-today", thread: "route", start: 10 },
      { id: "sign-today", thread: "sign", start: 20 },
      { id: "sign-yesterday", thread: "sign", start: -35 },
      { id: "route-earlier", thread: "route", start: -1470 },
    ].map(({ id, thread, start }) => {
      const raw = fixture({ source: "manual.note", t_start: at(start), title: "合成步道笔记", body: "记录步道入口的标记。" });
      expect(ctx.db.ingest([raw]).accepted).toBe(1);
      ctx.store.createFrame({ id, key: "trail", record_ids: [raw.id], t_start_ms: Date.parse(raw.t_start),
        t_end_ms: Date.parse(raw.t_start), chars: 1, private: 0, status: "new" });
      ctx.store.assign(id, thread, "user", 1);
      return { ...segment(id, [raw.id], null, start),
        evidence: [{ id: raw.id, at: raw.t_start, source: raw.source, title: raw.title }] };
    });
    const earlierDay = "2026-06-16";
    ctx.store.upsertDay({ date: day, detail: { items: updates.slice(0, 2) } });
    ctx.store.upsertDay({ date: previousDay, detail: { items: [updates[2]] } });
    ctx.store.upsertDay({ date: earlierDay, detail: { items: [updates[3]] } });

    const path = "/v1/timeline?thread_id=route&limit=1";
    expect(await (await ctx.send(path)).json()).toEqual({
      days: [{ date: day, items: [{ ...updates[0], thread_id: "route" }] }], next_cursor: day,
    });
    expect(await (await ctx.send(`${path}&before=${day}`)).json()).toEqual({
      days: [{ date: earlierDay, items: [{ ...updates[3], thread_id: "route" }] }], next_cursor: null,
    });
    for (const filters of ["thread_id=route&project_id=trail", "thread_id=route&q=route",
      "project_id=trail&q=route", "thread_id=route&q=", "thread_id=", `thread_id=${"a".repeat(129)}`]) {
      expect((await ctx.send(`/v1/timeline?${filters}`)).status).toBe(400);
    }
  } finally { await ctx.cleanup(); }
});

test("段描述修正跨重整保留，整段确认按成员原子删除并清除跨日结果和修正", async () => {
  const ctx = timelineFixture();
  try {
    const records = Array.from({ length: 101 }, () => fixture({ source: "mac.audio", kind: "span", t_start: at(-2), t_end: at(2) }));
    const device = "android-abcd2345";
    records[0] = { ...records[0]!, device, source: "android.audio" };
    ctx.db.db.prepare("INSERT INTO devices(id,name,platform,public_key,paired_at,last_seen) VALUES(?, '测试手机', 'android', ?, ?, ?)").run(device, Buffer.alloc(32), at(0), at(0));
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
    expect(ctx.db.deviceChanges(device, 0).changes).toMatchObject([{ kind: "delete", id: ids[0] }]);
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

test("旧回顾隐藏采集占位，来源和事项归属取自实际引用，省略记录仍能定位到原文", async () => {
  const ctx = timelineFixture();
  try {
    const raw = fixture({ source: "codex.session", source_ref: "synthetic-route", t_start: at(10), body: "[我] 入口改到北门。",
      context: { app: "org.example.writer" } });
    const window = fixture({ t_start: at(20), title: "合成窗口", context: { app: "org.example.music" } });
    expect(ctx.db.ingest([raw, window]).accepted).toBe(2);
    ctx.store.upsertProject({ id: "trail", name: "合成步道", keys: { repos: [], hosts: [], chats: [] } });
    ctx.store.upsertThread({ id: "route-thread", title: "入口路线", status: "active", project_id: "trail" });
    ctx.store.createFrame({ id: "route-frame", key: "route", record_ids: [raw.id], t_start_ms: Date.parse(raw.t_start),
      t_end_ms: Date.parse(raw.t_start), chars: 1, private: 0, status: "new" });
    ctx.store.assign("route-frame", "route-thread", "user", 1);
    const actual = { ...segment("route", [raw.id, window.id], "trail", 10),
      evidence: [{ id: raw.id, at: raw.t_start, source: raw.source, title: raw.title }],
      apps: [{ source: "mac.screen", app: "org.example.music" }], sources: ["mac.screen"] };
    const capture = { ...segment("capture", [window.id], "trail", 20), title: "Codex 会话", description: "有 Codex 会话记录。" };
    ctx.store.upsertDay({ date: day, brief: capture.title, detail: { summary: capture.title, items: [actual, capture] } });
    const projected = await (await ctx.send(`/v1/days/${day}`)).json();
    expect(projected.detail.summary).toBe(actual.title);
    expect(projected.detail.items).toHaveLength(1);
    expect(projected.detail.items[0]).toMatchObject({ thread_id: "route-thread",
      sources: [raw.source], apps: [{ source: raw.source, app: "org.example.writer" }] });
    expect(projected.detail.omitted_record_ids).toEqual([]); // 原文已由另一条可见段包含，不能标成遗漏。
    expect((await (await ctx.send("/v1/timeline?project_id=trail")).json()).days[0].items).toHaveLength(1);
    expect((await (await ctx.send(`/v1/records/${window.id}`)).json()).id).toBe(window.id);

    ctx.store.upsertDay({ date: day, detail: { summary: "Codex 会话", items: [capture] } });
    const onlyCapture = await (await ctx.send(`/v1/days/${day}`)).json();
    expect(onlyCapture.detail).toMatchObject({ summary: null, items: [], omitted_record_ids: [window.id] });
    expect(await (await ctx.send(`/v1/timeline/record/${window.id}`)).json()).toEqual({ date: day, segment_id: null });
    expect(await (await ctx.send("/v1/timeline?q=Codex")).json()).toEqual({ days: [], next_cursor: null });
    // 用户对描述的有效修正优先；无需重写正式历史。
    expect((await ctx.send(`/v1/days/${day}/segments/capture`, "PATCH", { description: "决定保留北门的绕行路线。" })).status).toBe(200);
    expect((await (await ctx.send(`/v1/days/${day}`)).json()).detail.items[0].description).toBe("决定保留北门的绕行路线。");
    expect(ctx.store.day(day)?.detail.items[0].description).toBe(capture.description);
  } finally { await ctx.cleanup(); }
});

test("阅读投影保留本地午夜 24:00 的时间轴结束边界", async () => {
  const ctx = timelineFixture();
  try {
    const item = { ...segment("midnight", [], "trail", 23 * 60 + 50), t_end: at(24 * 60) };
    ctx.store.upsertDay({ date: day, detail: { items: [item] } });
    const response = await (await ctx.send(`/v1/days/${day}`)).json();
    expect(response.detail.timeline).toEqual([{ start: "23:50", end: "24:00", text: item.title }]);
  } finally { await ctx.cleanup(); }
});

test("旧窗口占位不出现在当天、项目或搜索正文，原文仍在全天记录中", async () => {
  const ctx = timelineFixture();
  try {
    const rows = ["远程工具 · 无标题", "会话工具 · No"].map((title, i) =>
      fixture({ title, t_start: at(12 * 60 + i), context: { app: `org.example.capture${i}` } }));
    expect(ctx.db.ingest(rows).accepted).toBe(2);
    const items = rows.map((raw, i) => ({ ...segment(`window-${i}`, [raw.id], "trail", 12 * 60 + i),
      title: raw.title, description: "有前台窗口记录。", sources: [raw.source],
      evidence: [{ id: raw.id, at: raw.t_start, source: raw.source, title: raw.title }] }));
    ctx.store.upsertDay({ date: day, detail: { summary: items[0]!.title, items } });
    const result = await (await ctx.send(`/v1/days/${day}`)).json();
    expect(result.detail).toMatchObject({ summary: null, items: [] });
    expect(result.detail.omitted_record_ids).toEqual(rows.map(row => row.id));
    for (const suffix of ["project_id=trail", `q=${encodeURIComponent("窗口")}`])
      expect((await (await ctx.send(`/v1/timeline?${suffix}`)).json()).days).toEqual([]);
    for (const row of rows) {
      expect((await (await ctx.send(`/v1/records/${row.id}`)).json()).id).toBe(row.id);
      expect(await (await ctx.send(`/v1/timeline/record/${row.id}`)).json()).toEqual({ date: day, segment_id: null });
    }
  } finally { await ctx.cleanup(); }
});

test("按月查询活跃日期支持原始记录、整理段、跨月边界与非法参数校验", async () => {
  const ctx = timelineFixture();
  try {
    const localMs = (year: number, month: number, dayNum: number, h = 0, m = 0, s = 0, ms = 0) =>
      new Date(year, month - 1, dayNum, h, m, s, ms).getTime();

    const mayEnd = fixture({ t_start: toLocalIso(localMs(2026, 5, 31, 23, 59, 59, 999)) });
    const juneStart = fixture({ t_start: toLocalIso(localMs(2026, 6, 1, 0, 0, 0, 0)) });
    const juneRawOnly = fixture({ t_start: toLocalIso(localMs(2026, 6, 5, 14, 30)) });
    const juneDeleted = fixture({ t_start: toLocalIso(localMs(2026, 6, 7, 9, 0)) });
    const juneEnd = fixture({ t_start: toLocalIso(localMs(2026, 6, 30, 23, 59, 59, 999)) });
    const julyStart = fixture({ t_start: toLocalIso(localMs(2026, 7, 1, 0, 0, 0, 0)) });
    const leapDay = fixture({ t_start: toLocalIso(localMs(2024, 2, 29, 12, 0)) });
    expect(ctx.db.ingest([mayEnd, juneStart, juneRawOnly, juneDeleted, juneEnd, julyStart, leapDay]).accepted).toBe(7);
    expect(ctx.db.delete(juneDeleted.id)).toBe(true);

    // 仅有整理段、仅有 summary、以及只有采集占位（无记录时不应入活跃日期）
    ctx.store.upsertDay({ date: "2026-06-10", detail: { items: [segment("seg-only", [], "trail", 10)] } });
    ctx.store.upsertDay({ date: "2026-06-12", detail: { summary: "整理了虚构项目的文档结构。", items: [] } });
    ctx.store.upsertDay({
      date: "2026-06-14",
      detail: { summary: "有前台窗口记录", items: [{ ...segment("capture-only", [], null, 10), description: "有前台窗口记录。" }] },
    });
    // 与 juneRawOnly 同一天也有整理段：结果应去重
    ctx.store.upsertDay({ date: "2026-06-05", detail: { items: [segment("dup-day", [juneRawOnly.id], "trail", 10)] } });
    // detail 为 NULL 的空记录天
    ctx.store.upsertDay({ date: "2026-06-15", detail: null });

    expect(await (await ctx.send("/v1/days/active?month=2026-05")).json()).toEqual({
      month: "2026-05",
      dates: ["2026-05-31"],
    });
    expect(await (await ctx.send("/v1/days/active?month=2026-06")).json()).toEqual({
      month: "2026-06",
      dates: ["2026-06-01", "2026-06-05", "2026-06-10", "2026-06-12", "2026-06-30"],
    });
    expect(await (await ctx.send("/v1/days/active?month=2026-07")).json()).toEqual({
      month: "2026-07",
      dates: ["2026-07-01"],
    });
    expect(await (await ctx.send("/v1/days/active?month=2026-08")).json()).toEqual({
      month: "2026-08",
      dates: [],
    });
    expect(await (await ctx.send("/v1/days/active?month=2024-02")).json()).toEqual({
      month: "2024-02",
      dates: ["2024-02-29"],
    });

    for (const bad of [
      "/v1/days/active",
      "/v1/days/active?month=",
      "/v1/days/active?month=2026-00",
      "/v1/days/active?month=2026-13",
      "/v1/days/active?month=2026-6",
      "/v1/days/active?month=2026-06-01",
      "/v1/days/active?month=0000-01",
      "/v1/days/active?month=not-a-month",
    ]) {
      expect((await ctx.send(bad)).status).toBe(400);
    }
    expect((await ctx.send("/v1/days/active?month=2026-06", "GET", undefined, ctx.config.agentToken)).status).toBe(403);
  } finally { await ctx.cleanup(); }
});
