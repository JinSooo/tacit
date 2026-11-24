import { afterEach, expect, test } from "bun:test";
import { flushProjectionDraft, projectionHead, scheduleProjectionDraft } from "../src/devices/projection-store.ts";
import { setup } from "./helpers.ts";

let ctx: ReturnType<typeof setup>;
afterEach(() => ctx?.cleanup());

test("只有草稿变化时，给查看端推当天最多每 5 分钟一次", () => {
  ctx = setup();
  const sql = ctx.db.db, date = "2026-11-24", t0 = 1_800_000_000_000;
  const head = () => projectionHead(sql).seq;

  scheduleProjectionDraft(sql, t0);
  flushProjectionDraft(sql, t0 + 29_000, date);
  const before = head();
  flushProjectionDraft(sql, t0 + 30_000, date);
  expect(head()).toBeGreaterThan(before);

  // 推过一次后，紧接着的新记录要等到上次推送 5 分钟后才再推。
  const first = head();
  scheduleProjectionDraft(sql, t0 + 60_000);
  flushProjectionDraft(sql, t0 + 90_000, date);
  flushProjectionDraft(sql, t0 + 329_000, date);
  expect(head()).toBe(first);
  flushProjectionDraft(sql, t0 + 330_000, date);
  expect(head()).toBeGreaterThan(first);

  // 隔了很久的新记录照旧 30 秒后推。
  const second = head();
  scheduleProjectionDraft(sql, t0 + 3_600_000);
  flushProjectionDraft(sql, t0 + 3_630_000, date);
  expect(head()).toBeGreaterThan(second);
});
