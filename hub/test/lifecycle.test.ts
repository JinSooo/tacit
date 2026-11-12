import { afterEach, beforeEach, expect, spyOn, test } from "bun:test";
import { spawnSync } from "node:child_process";
import { DistillStore, type Thread } from "../src/distill/store.ts";
import { lifecycleStep, usageDaysSince } from "../src/distill/run.ts";
import { updateGeneral } from "../src/general-settings.ts";
import { createHandler } from "../src/server.ts";
import { fixture, setup } from "./helpers.ts";

const now = Date.parse("2026-11-08T12:00:00+08:00"), DAY = 24 * 60 * 60_000;
let ctx: ReturnType<typeof setup>, store: DistillStore;
beforeEach(() => { ctx = setup(); store = new DistillStore(ctx.db); });
afterEach(() => ctx.cleanup());

function runInLocalTimezones(name: string): boolean {
  if (process.env.RA_LIFECYCLE_TZ_TEST) return false;
  // Bun 的运行时 TZ 修改不会更新原生 SQLite 的时区，必须在子进程启动前设置。
  for (const TZ of ["Asia/Shanghai", "America/New_York"]) {
    const result = spawnSync(process.execPath, ["test", import.meta.path, "--test-name-pattern", name], {
      env: { ...process.env, TZ, RA_LIFECYCLE_TZ_TEST: "1" }, encoding: "utf8",
    });
    expect(result.status, `${TZ}: ${result.stdout}\n${result.stderr}`).toBe(0);
  }
  return true;
}

function recordAt(ms: number) {
  expect(ctx.db.ingest([fixture({ t_start: new Date(ms).toISOString() })]).accepted).toBe(1);
}

function dailyRecords() {
  for (let days = 0; days < 7; days++) recordAt(now - days * DAY);
}

test("使用天按本地自然日去重，排除起始当天、未来记录和墓碑，包含任意设备来源和私密记录", () => {
  if (runInLocalTimezones("使用天按本地")) return;
  const after = new Date(2026, 10, 1, 0, 30).getTime();
  const end = new Date(2026, 10, 4, 0, 30).getTime();
  recordAt(after - DAY);
  recordAt(after + 1000); // 起始当天虽晚于 after，仍不计。
  recordAt(new Date(2026, 10, 2, 0, 0).getTime());
  recordAt(new Date(2026, 10, 2, 23, 59).getTime());
  const other = fixture({ device: "phone", source: "manual.note", sensitivity: "private", t_start: new Date(2026, 10, 3, 0, 0).toISOString() });
  expect(ctx.db.ingest([other]).accepted).toBe(1);
  recordAt(end + 1000); // now 之后，即使是同一天也不计。
  expect(usageDaysSince(store, after, end)).toBe(2);
  expect(ctx.db.delete(other.id)).toBe(true);
  expect(ctx.db.db.prepare("SELECT count(*) n FROM tombstones").get()).toEqual({ n: 1 });
  expect(usageDaysSince(store, after, end)).toBe(1);
  recordAt(end);
  expect(usageDaysSince(store, after, end)).toBe(2);
  expect(usageDaysSince(store, end, end)).toBe(0);
  expect(usageDaysSince(store, end + DAY, end)).toBe(0);
});

test("自然日粗筛不过滤跨午夜尚不足 24 小时的提问和归档", () => {
  if (runInLocalTimezones("自然日粗筛")) return;
  updateGeneral(ctx.db, { ask_done_days: 1, archive_days: 1 });
  const last = new Date(2026, 10, 1, 23, 59).getTime();
  const askedAt = new Date(2026, 10, 2, 0, 1).getTime();
  store.upsertThread({ id: "midnight", title: "合成线程", status: "active", last_ms: last });
  recordAt(askedAt);
  expect(lifecycleStep(store, askedAt).asked).toBe(1);
  const archiveAt = new Date(2026, 10, 3, 0, 0).getTime();
  recordAt(archiveAt);
  expect(lifecycleStep(store, archiveAt).archived).toBe(1);
  expect(store.thread("midnight")?.status).toBe("archived");
});

test("使用天数：离开十天但只有两天有记录不提问，第三个使用天才问", () => {
  store.upsertThread({ id: "quiet", title: "合成线程", status: "active", last_ms: now - 10 * DAY });
  recordAt(now - 8 * DAY);
  recordAt(now - 4 * DAY);
  recordAt(now - 4 * DAY + 1000); // 同一天多条也只算一天。
  expect(lifecycleStep(store, now)).toMatchObject({ asked: 0, paused: 1 });
  expect(store.pending()).toEqual([]);
  recordAt(now - DAY);
  expect(lifecycleStep(store, now).asked).toBe(1);
  expect(store.pending().map(p => p.kind)).toEqual(["thread_done"]);
});

test("使用天数：提问十天但只有六天有记录不归档，第七个使用天才归档", () => {
  pending("holiday", "paused", 10 * DAY);
  for (let days = 1; days <= 6; days++) recordAt(now - days * DAY);
  expect(lifecycleStep(store, now).archived).toBe(0);
  expect(store.thread("holiday")?.status).toBe("paused");
  expect(resolution("holiday")).toEqual({ resolved_at: null, resolution: null });
  recordAt(now);
  expect(lifecycleStep(store, now).archived).toBe(1);
  expect(store.thread("holiday")?.status).toBe("archived");
  expect(resolution("holiday")).toEqual({ resolved_at: new Date(now).toISOString(), resolution: "expired" });
});

function pending(id: string, status: Thread["status"], age: number, createdAt = new Date(now - age).toISOString()) {
  store.upsertThread({ id, status, title: `合成归档线程${id}`, brief: "合成摘要", project_id: "p", last_ms: now - 10 * DAY });
  store.createPending({ id: `pending-${id}`, kind: "thread_done", payload: { thread_id: id }, created_at: createdAt });
}
function resolution(id: string) {
  return ctx.db.db.prepare("SELECT resolved_at,resolution FROM pending WHERE id=?").get(`pending-${id}`);
}
async function read(path: string) {
  const handler = createHandler({ db: ctx.db, token: ctx.config.token });
  const response = await handler(new Request(`http://127.0.0.1:47823${path}`, {
    headers: { host: "127.0.0.1:47823", authorization: `Bearer ${ctx.config.token}` },
  }));
  expect(response.status).toBe(200);
  return response.json();
}

test("满 7 个使用天的完成确认自动归档，6 个使用天不动；重复运行不再提问", async () => {
  dailyRecords();
  pending("old-active", "active", 7 * DAY + 1);
  pending("old-paused", "paused", 7 * DAY + 1);
  pending("six-days", "paused", 6 * DAY);
  pending("boundary", "paused", 7 * DAY);
  // 不同时区的时间也按实际时刻比较，不能用 RFC 3339 字符串排序。
  pending("offset", "paused", 0, "2026-11-01T12:59:59+09:00");
  store.createPending({ id: "unrelated", kind: "project", payload: { project_id: "p" }, created_at: new Date(now - 20 * DAY).toISOString() });
  store.upsertProject({ id: "p", name: "合成项目", keys: { repos: [], hosts: [], chats: [] } });
  expect(lifecycleStep(store, now).archived).toBe(4);
  for (const id of ["old-active", "old-paused", "offset", "boundary"]) {
    expect(store.thread(id)?.status).toBe("archived");
    expect(resolution(id)).toEqual({ resolved_at: new Date(now).toISOString(), resolution: "expired" });
  }
  for (const id of ["six-days"]) {
    expect(store.thread(id)?.status).toBe("paused");
    expect(resolution(id)).toEqual({ resolved_at: null, resolution: null });
  }
  expect((await read("/v1/pending")).pending.map((p: { id: string }) => p.id).sort()).toEqual(["pending-six-days", "unrelated"]);
  expect(lifecycleStep(store, now).archived).toBe(0);
  expect(ctx.db.db.prepare("SELECT count(*) n FROM pending WHERE kind='thread_done'").get()).toEqual({ n: 5 });
});

test("已结束线程只结待确认，已处理的确认不参与归档", () => {
  dailyRecords();
  for (const status of ["done", "abandoned", "archived"] as const) pending(status, status, 8 * DAY);
  pending("resolved", "paused", 8 * DAY);
  ctx.db.db.prepare("UPDATE pending SET resolved_at=?,resolution='continue' WHERE id='pending-resolved'").run(new Date(now - DAY).toISOString());
  // 已问过的时间晚于最后活动，继续处理也不重复询问。
  expect(lifecycleStep(store, now).archived).toBe(0);
  for (const status of ["done", "abandoned", "archived"] as const) {
    expect(store.thread(status)?.status).toBe(status);
    expect(resolution(status)).toEqual({ resolved_at: new Date(now).toISOString(), resolution: "expired" });
  }
  expect(store.thread("resolved")?.status).toBe("paused");
  expect(resolution("resolved")).toEqual({ resolved_at: new Date(now - DAY).toISOString(), resolution: "continue" });
  expect(store.pending()).toEqual([]);
});

test("归档与结待确认在同一事务，结项失败时线程状态回滚", () => {
  dailyRecords();
  pending("rollback", "active", 8 * DAY);
  ctx.db.db.exec("CREATE TRIGGER synthetic_expiry_failure BEFORE UPDATE ON pending BEGIN SELECT RAISE(ABORT,'合成结项失败'); END");
  expect(() => lifecycleStep(store, now)).toThrow("合成结项失败");
  expect(store.thread("rollback")?.status).toBe("active");
  expect(resolution("rollback")).toEqual({ resolved_at: null, resolution: null });
});

test("归档线程不进 context，但仍可通过 get、search 和状态列表查询", async () => {
  dailyRecords();
  const clock = spyOn(Date, "now").mockReturnValue(now);
  try {
    store.upsertProject({ id: "p", name: "合成项目", brief: "合成项目摘要", keys: { repos: ["/synthetic/archive"], hosts: [], chats: [] } });
    pending("history", "active", 8 * DAY);
    lifecycleStep(store, now);
    // 归档后有最近活动时间也不能注入，避免只靠暂停线程的时间过滤通过测试。
    ctx.db.db.prepare("UPDATE threads SET last_ms=? WHERE id='history'").run(now);
    const context = await read("/v1/agent/context?tool=codex&event=startup&cwd=/synthetic/archive");
    expect(context.project_id).toBe("p");
    expect(context.text).toContain("合成项目摘要");
    expect(context.text).not.toContain("合成归档线程history");
    expect((await read("/v1/agent/get?tool=codex&id=history")).item.status).toBe("archived");
    expect((await read("/v1/agent/search?tool=codex&q=合成归档线程")).threads.map((t: { id: string }) => t.id)).toEqual(["history"]);
    expect((await read("/v1/threads?status=archived")).threads.map((t: { id: string }) => t.id)).toEqual(["history"]);
  } finally { clock.mockRestore(); }
});
