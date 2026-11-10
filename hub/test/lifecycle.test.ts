import { afterEach, beforeEach, expect, spyOn, test } from "bun:test";
import { DistillStore, type Thread } from "../src/distill/store.ts";
import { lifecycleStep } from "../src/distill/run.ts";
import { createHandler } from "../src/server.ts";
import { setup } from "./helpers.ts";

const now = Date.parse("2026-11-08T12:00:00+08:00"), DAY = 24 * 60 * 60_000;
let ctx: ReturnType<typeof setup>, store: DistillStore;
beforeEach(() => { ctx = setup(); store = new DistillStore(ctx.db); });
afterEach(() => ctx.cleanup());

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

test("超过 7 天的完成确认自动归档，6 天及恰好 7 天不动；重复运行不再提问", async () => {
  pending("old-active", "active", 7 * DAY + 1);
  pending("old-paused", "paused", 7 * DAY + 1);
  pending("six-days", "paused", 6 * DAY);
  pending("boundary", "paused", 7 * DAY);
  // 不同时区的时间也按实际时刻比较，不能用 RFC 3339 字符串排序。
  pending("offset", "paused", 0, "2026-11-01T12:59:59+09:00");
  store.createPending({ id: "unrelated", kind: "project", payload: { project_id: "p" }, created_at: new Date(now - 20 * DAY).toISOString() });
  store.upsertProject({ id: "p", name: "合成项目", keys: { repos: [], hosts: [], chats: [] } });
  expect(lifecycleStep(store, now).archived).toBe(3);
  for (const id of ["old-active", "old-paused", "offset"]) {
    expect(store.thread(id)?.status).toBe("archived");
    expect(resolution(id)).toEqual({ resolved_at: new Date(now).toISOString(), resolution: "expired" });
  }
  for (const id of ["six-days", "boundary"]) {
    expect(store.thread(id)?.status).toBe("paused");
    expect(resolution(id)).toEqual({ resolved_at: null, resolution: null });
  }
  expect((await read("/v1/pending")).pending.map((p: { id: string }) => p.id).sort()).toEqual(["pending-boundary", "pending-six-days", "unrelated"]);
  expect(lifecycleStep(store, now).archived).toBe(0);
  expect(ctx.db.db.prepare("SELECT count(*) n FROM pending WHERE kind='thread_done'").get()).toEqual({ n: 5 });
});

test("已结束线程只结待确认，已处理的确认不参与归档", () => {
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
  pending("rollback", "active", 8 * DAY);
  ctx.db.db.exec("CREATE TRIGGER synthetic_expiry_failure BEFORE UPDATE ON pending BEGIN SELECT RAISE(ABORT,'合成结项失败'); END");
  expect(() => lifecycleStep(store, now)).toThrow("合成结项失败");
  expect(store.thread("rollback")?.status).toBe("active");
  expect(resolution("rollback")).toEqual({ resolved_at: null, resolution: null });
});

test("归档线程不进 context，但仍可通过 get、search 和状态列表查询", async () => {
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
