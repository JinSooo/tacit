import { afterEach, beforeEach, expect, test } from "bun:test";
import { spawnSync } from "node:child_process";
import { DistillStore } from "../src/distill/store.ts";
import { DistillRequests, defaultBackfillRange, localDayStart } from "../src/distill/requests.ts";
import { backfillRange, distillTick, sliceStep, tickSafely, type LLM, type LoopState } from "../src/distill/run.ts";
import { HubDB } from "../src/db.ts";
import { createHandler } from "../src/server.ts";
import { fixture, setup } from "./helpers.ts";

// 合成数据 + 假模型（一律返回失败），不调用任何真实模型。
let ctx: ReturnType<typeof setup>, store: DistillStore, requests: DistillRequests;
beforeEach(() => { ctx = setup(); store = new DistillStore(ctx.db); requests = new DistillRequests(ctx.db); });
afterEach(() => ctx.cleanup());

const HOUR = 3_600_000, DAY = 24 * HOUR;
const day = (date: string, hour = 10) => localDayStart(date)! + hour * HOUR;
const rec = (ms: number) => fixture({ t_start: new Date(ms).toISOString(), context: { app: "synthetic.app" } });
const failingLLM: LLM = { async complete() { return { ok: false as const, error: "合成失败", ms: 1 }; } };
const deps = (now: number) => ({ db: ctx.db, llm: failingLLM, now: () => now, log: () => {} });

test("当天日记失败不推进慢速检查点，十五分钟重试且不在轮询时连发", async () => {
  const now = day("2026-11-09", 12), r = rec(now - HOUR);
  ctx.db.ingest([r]);
  store.createFrame({ id: "retry", key: "app:synthetic.app", record_ids: [r.id], t_start_ms: now - HOUR, t_end_ms: now - HOUR, chars: r.body.length, private: 0, status: "ignored" });
  store.upsertDay({ date: "2026-11-09", needs_regen: 1 });
  let calls = 0;
  const llm: LLM = { async complete(req) { if (req.task === "day") calls++; return { ok: false, error: "合成路由失败", ms: 1 }; } };
  const state: LoopState = { lastRound: 0, enabledDefault: now - 2 * HOUR };
  await distillTick({ ...deps(now), llm }, state, now);
  expect(calls).toBe(1);
  expect(store.getState("slow_ms")).toBeNull(); expect(store.getState("today_ms")).toBeNull();
  await distillTick({ ...deps(now + 5000), llm }, state, now + 5000);
  expect(calls).toBe(1);
  await distillTick({ ...deps(now + HOUR / 4), llm }, state, now + HOUR / 4);
  expect(calls).toBe(2);
});

function api() {
  const handler = createHandler({ db: ctx.db, token: "synthetic-token" });
  return (method: string, body?: unknown, token = "synthetic-token") => handler(new Request("http://127.0.0.1:47823/v1/distill/requests", {
    method, headers: { host: "127.0.0.1:47823", authorization: `Bearer ${token}` }, ...(body !== undefined ? { body: JSON.stringify(body) } : {}),
  }));
}

test("请求接口：入队 202，同类排队中返回原请求 200，非法参数 400，列表倒序", async () => {
  const call = api();
  expect((await call("GET", undefined, "wrong")).status).toBe(401);
  const first = await call("POST", { kind: "round" });
  expect(first.status).toBe(202);
  const round = await first.json();
  expect(round).toMatchObject({ kind: "round", status: "queued" });
  const again = await call("POST", { kind: "round" });
  expect(again.status).toBe(200);
  expect((await again.json()).id).toBe(round.id);
  const backfill = await (await call("POST", { kind: "backfill" })).json();
  expect({ from: backfill.from, to: backfill.to }).toEqual(defaultBackfillRange());
  for (const bad of [{ kind: "other" }, { kind: "backfill", from: "2026-11-01" }, { kind: "backfill", from: "2026-11-09", to: "2026-11-01" },
    { kind: "backfill", from: "2026-02-30", to: "2026-03-01" }, { kind: "round", from: "2026-11-01", to: "2026-11-02" }, []]) {
    const r = await call("POST", bad);
    expect(r.status).toBe(400);
    expect((await r.json()).error).toBeString();
  }
  const list = await (await call("GET")).json();
  expect(list.requests.map((r: { id: string }) => r.id)).toEqual([backfill.id, round.id]);
});

test("默认范围是含今天的最近 30 天", () => {
  const r = defaultBackfillRange(day("2026-11-09"));
  expect(r).toEqual({ from: "2026-10-11", to: "2026-11-09" });
});

test("按范围整理：只切范围内、启用前的天，可重复执行且不依赖 backfill_done", () => {
  store.setState("enabled_ms", localDayStart("2026-11-08")!);
  const outside = rec(day("2026-11-01")), a = rec(day("2026-11-03")), b = rec(day("2026-11-05", 23)), afterEnabled = rec(day("2026-11-08", 9));
  ctx.db.ingest([outside, a, b, afterEnabled]);
  store.setState("backfill_done", true);
  const progress: [number, number][] = [];
  const r = backfillRange(ctx.db, "2026-11-02", "2026-11-09", { onProgress: (done, total) => progress.push([done, total]) });
  expect(r).toEqual({ days: 2, frames: 2 });
  expect(progress).toEqual([[0, 2], [1, 2], [2, 2]]);
  const sliced = store.frames().flatMap(f => f.record_ids);
  expect(sliced.sort()).toEqual([a.id, b.id].sort());
  expect(store.day("2026-11-03")).not.toBeNull();
  // 同一范围再跑一次：已进片段的记录被排除。
  expect(backfillRange(ctx.db, "2026-11-02", "2026-11-09")).toEqual({ days: 2, frames: 0 });
  // 扩大范围能补上之前范围外的那天。
  expect(backfillRange(ctx.db, "2026-11-01", "2026-11-01").frames).toBe(1);
  expect(() => backfillRange(ctx.db, "2026-11-09", "2026-11-01")).toThrow();
});

test("常驻循环领取 backfill 请求，写进度和心跳，执行完置 done；没请求且未到 15 分钟时空闲", async () => {
  const now = day("2026-11-09", 12);
  store.setState("enabled_ms", localDayStart("2026-11-08")!);
  store.setState("cursor_ms", localDayStart("2026-11-08")!);
  ctx.db.ingest([rec(day("2026-11-03")), rec(day("2026-11-04"))]);
  const { request } = requests.create({ kind: "backfill", from: "2026-11-01", to: "2026-11-07" }, now);
  const state: LoopState = { lastRound: now, enabledDefault: localDayStart("2026-11-09")! };
  expect(await distillTick(deps(now), state, now)).toBe("request");
  const done = requests.get(request.id)!;
  expect(done).toMatchObject({ status: "done", progress: { done: 2, total: 2 } });
  expect(done.started_at).toBeString(); expect(done.finished_at).toBeString();
  expect(store.frames()).toHaveLength(2);
  expect(store.getState<string>("heartbeat_at")).toBeString();
  expect(await distillTick(deps(now + 60_000), state, now + 60_000)).toBe("idle");
  expect(await distillTick(deps(now + 16 * 60_000), state, now + 16 * 60_000)).toBe("round");
  expect(state.lastRound).toBe(now + 16 * 60_000);
});

test("round 请求立即跑一轮；执行出错置 failed；进程中断留下的 running 标为失败", async () => {
  const now = day("2026-11-09", 12);
  const state: LoopState = { lastRound: now, enabledDefault: localDayStart("2026-11-09")! };
  const { request: round } = requests.create({ kind: "round" }, now);
  expect(await distillTick(deps(now), state, now)).toBe("request");
  expect(requests.get(round.id)!.status).toBe("done");
  expect(store.getState("cursor_ms")).not.toBeNull();
  // 范围在库里被改坏时，执行失败要如实标出，不影响后续请求。
  const { request: bad } = requests.create({ kind: "backfill", from: "2026-11-01", to: "2026-11-02" }, now);
  ctx.db.db.prepare("UPDATE distill_requests SET date_from='bad' WHERE id=?").run(bad.id);
  expect(await distillTick(deps(now), state, now)).toBe("request");
  expect(requests.get(bad.id)).toMatchObject({ status: "failed", error: "日期范围无效" });
  const { request: stuck } = requests.create({ kind: "round" }, now);
  requests.claim(now);
  expect(requests.recoverInterrupted(now)).toBe(1);
  expect(requests.get(stuck.id)).toMatchObject({ status: "failed", error: "整理进程中断了" });
  // 失败后同类可以重新入队。
  expect(requests.create({ kind: "round" }, now).created).toBe(true);
});

test("一次性 --backfill 不受按范围整理影响，仍只跑一次", () => {
  store.setState("enabled_ms", localDayStart("2026-11-08")!);
  ctx.db.ingest([rec(day("2026-11-03")), rec(day("2026-11-05"))]);
  backfillRange(ctx.db, "2026-11-03", "2026-11-03");
  const now = day("2026-11-09", 12);
  expect(sliceStep(ctx.db, true, now).frames).toBe(1);
  expect(store.getState("backfill_done")).toBe(true);
  expect(sliceStep(ctx.db, true, now + DAY).frames).toBe(0);
});

test("CLI distill --slice-only --backfill --from --to 按范围切片，参数不全拒绝", () => {
  store.setState("enabled_ms", localDayStart("2026-11-08")!);
  ctx.db.ingest([rec(day("2026-11-03")), rec(day("2026-11-05"))]);
  const cli = new URL("../src/cli.ts", import.meta.url).pathname;
  const env = { ...process.env, RA_DATA_DIR: ctx.dir, RA_DB_KEY: ctx.config.dbKey };
  const run = (...args: string[]) => spawnSync(process.execPath, [cli, "distill", ...args], { env, encoding: "utf8", timeout: 10000 });
  const ok = run("--slice-only", "--backfill", "--from", "2026-11-05", "--to", "2026-11-06");
  expect(ok.status).toBe(0);
  expect(JSON.parse(ok.stdout).backfill).toEqual({ days: 1, frames: 1 });
  expect(store.getState("backfill_done")).toBeNull();
  expect(run("--slice-only", "--backfill", "--from", "2026-11-05").status).toBe(1);
  expect(run("--slice-only", "--from", "2026-11-05", "--to", "2026-11-06").status).toBe(1);
  expect(run("--slice-only", "--backfill", "--from", "2026-13-01", "--to", "2026-11-06").status).toBe(1);
});

// 2026-11-12：导入全部历史时 hub 连续写入，心跳写入等锁超过 5 秒抛 SQLITE_BUSY，常驻提炼进程整个退出。
test("库被另一连接占着写锁时这一次跳过，锁放开后照常领取请求；其他错误照旧抛出", async () => {
  const now = day("2026-11-09", 12);
  const state: LoopState = { lastRound: now, enabledDefault: localDayStart("2026-11-09")! };
  const { request } = requests.create({ kind: "round" }, now);
  const hub = new HubDB(ctx.file, ctx.config.dbKey);
  ctx.db.db.pragma("busy_timeout=50");
  hub.db.exec("BEGIN IMMEDIATE");
  await expect(distillTick(deps(now), state, now)).rejects.toMatchObject({ code: "SQLITE_BUSY" });
  expect(await tickSafely(deps(now), state, now)).toBe("busy");
  expect(requests.get(request.id)!.status).toBe("queued");
  hub.db.exec("COMMIT"); hub.close();
  expect(await tickSafely(deps(now), state, now)).toBe("request");
  expect(requests.get(request.id)!.status).toBe("done");
  const closed = new HubDB(ctx.file, ctx.config.dbKey); closed.close();
  await expect(tickSafely({ ...deps(now), db: closed }, state, now)).rejects.toThrow();
});

// 结束状态撞上库忙时不能把做完的请求标成失败，也不能一直留在 running 挡住新请求。
test("请求做完后写结束状态时库忙，下一次补写原来的结果", async () => {
  const now = day("2026-11-09", 12);
  store.setState("slow_ms", now); store.setState("today_ms", now);
  const state: LoopState = { lastRound: now, enabledDefault: localDayStart("2026-11-09")! };
  const { request } = requests.create({ kind: "round" }, now);
  const hub = new HubDB(ctx.file, ctx.config.dbKey);
  ctx.db.db.pragma("busy_timeout=50");
  // 这一轮整理写完日志后，另一个连接占住写锁，结束状态写不进去。
  let locked = false;
  const log = () => { if (!locked) { hub.db.exec("BEGIN IMMEDIATE"); locked = true; } };
  expect(await tickSafely({ ...deps(now), log }, state, now)).toBe("busy");
  expect(requests.get(request.id)!.status).toBe("running");
  expect(state.unfinished).toMatchObject({ id: request.id, error: undefined });
  hub.db.exec("COMMIT"); hub.close();
  expect(await tickSafely(deps(now + 5000), state, now + 5000)).toBe("idle");
  const done = requests.get(request.id)!;
  expect(done.status).toBe("done"); expect(done.error).toBeUndefined();
  expect(state.unfinished).toBeUndefined();
  expect(requests.create({ kind: "round" }, now + 6000).created).toBe(true);
});
