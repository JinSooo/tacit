import { afterEach, beforeEach, expect, spyOn, test } from "bun:test";
import { spawnSync } from "node:child_process";
import { DistillStore, type Thread } from "../src/distill/store.ts";
import { lifecycleStep } from "../src/distill/run.ts";
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
  updateGeneral(ctx.db, { archive_days: 3 });
  store.upsertThread({ id: "daily", title: "合成线程", status: "paused", last_ms: after });
  recordAt(after);
  recordAt(after + 1000);
  recordAt(new Date(2026, 10, 2, 0, 0).getTime());
  recordAt(new Date(2026, 10, 2, 23, 59).getTime());
  const other = fixture({ device: "phone", source: "manual.note", sensitivity: "private", t_start: new Date(2026, 10, 3, 0, 0).toISOString() });
  expect(ctx.db.ingest([other]).accepted).toBe(1);
  recordAt(end + 1000); // now 之后，即使是同一天也不计。
  expect(lifecycleStep(store, end).archived).toBe(0);
  expect(ctx.db.delete(other.id)).toBe(true);
  recordAt(end);
  expect(lifecycleStep(store, end).archived).toBe(0);
  expect(ctx.db.ingest([fixture({ ...other, id: fixture().id })]).accepted).toBe(1);
  expect(lifecycleStep(store, end)).toMatchObject({ asked: 0, archived: 1, expired: 0 });
});

test("自然日边界按有记录的日期，跨午夜尚不足 24 小时可归档", () => {
  if (runInLocalTimezones("自然日边界")) return;
  updateGeneral(ctx.db, { archive_days: 1 });
  const last = new Date(2026, 10, 1, 23, 59).getTime();
  const current = new Date(2026, 10, 2, 0, 1).getTime();
  store.upsertThread({ id: "midnight", title: "合成线程", status: "active", last_ms: last });
  recordAt(last);
  expect(lifecycleStep(store, current).archived).toBe(0);
  recordAt(current);
  expect(lifecycleStep(store, current)).toEqual({ paused: 0, asked: 0, archived: 1, expired: 0 });
  expect(store.thread("midnight")?.status).toBe("archived");
});

test("事项没有提问也可归档，六个使用天时只暂停，到第七个才归档", () => {
  store.upsertThread({ id: "quiet", title: "合成线程", status: "active", last_ms: now - 10 * DAY });
  for (let days = 1; days <= 6; days++) recordAt(now - days * DAY);
  recordAt(now - DAY + 1000); // 同一天重复记录仍算一天。
  expect(lifecycleStep(store, now)).toEqual({ asked: 0, paused: 1, archived: 0, expired: 0 });
  expect(store.thread("quiet")?.status).toBe("paused");
  recordAt(now);
  expect(lifecycleStep(store, now)).toEqual({ asked: 0, paused: 0, archived: 1, expired: 0 });
  expect(store.thread("quiet")?.status).toBe("archived");
  expect(store.pending()).toEqual([]);
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

test("旧问题立即过期，已处理问题和其它待确认保留，事项内容不改", async () => {
  dailyRecords();
  pending("old-active", "active", 1);
  pending("recent", "paused", 0);
  store.upsertThread({ ...store.thread("recent")!, last_ms: now - 2 * DAY });
  for (const status of ["done", "abandoned", "archived"] as const) pending(status, status, 8 * DAY);
  pending("resolved", "paused", 8 * DAY);
  store.upsertThread({ ...store.thread("resolved")!, last_ms: now - 2 * DAY });
  ctx.db.db.prepare("UPDATE pending SET resolved_at=?,resolution='continue' WHERE id='pending-resolved'").run(new Date(now - DAY).toISOString());
  store.createPending({ id: "unrelated", kind: "project", payload: { project_id: "p" }, created_at: new Date(now - 20 * DAY).toISOString() });
  store.upsertProject({ id: "p", name: "合成项目", keys: { repos: [], hosts: [], chats: [] } });
  const prior=store.thread("old-active")!;
  expect(lifecycleStep(store, now)).toMatchObject({ archived: 1, asked: 0, expired: 5 });
  expect(store.thread("old-active")).toEqual({ ...prior, status: "archived" });
  expect(store.thread("recent")?.status).toBe("paused");
  for (const status of ["done", "abandoned", "archived"] as const) expect(store.thread(status)?.status).toBe(status);
  for (const id of ["old-active", "recent", "done", "abandoned", "archived"])
    expect(resolution(id)).toEqual({ resolved_at: new Date(now).toISOString(), resolution: "expired" });
  expect(resolution("resolved")).toEqual({ resolved_at: new Date(now - DAY).toISOString(), resolution: "continue" });
  expect((await read("/v1/pending")).pending.map((p: { id: string }) => p.id)).toEqual(["unrelated"]);
  expect(lifecycleStep(store, now)).toEqual({ paused: 0, asked: 0, archived: 0, expired: 0 });
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
