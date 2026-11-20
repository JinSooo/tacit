import { afterEach, beforeEach, expect, test } from "bun:test";
import { toLocalIso } from "../../packages/record/index.ts";
import { withModelCooldown } from "../src/distill/cooldown.ts";
import { DistillStore } from "../src/distill/store.ts";
import { updateGeneral } from "../src/general-settings.ts";
import type { LLMRequest } from "../src/llm/types.ts";
import { modelUsageDayStart, readModelUsage } from "../src/model-usage.ts";
import { hubStatus } from "../src/status.ts";
import { setup } from "./helpers.ts";

const midday = new Date(2026, 10, 20, 12).getTime();
let ctx: ReturnType<typeof setup>, store: DistillStore;
beforeEach(() => { ctx = setup(); store = new DistillStore(ctx.db); });
afterEach(() => ctx.cleanup());

function writeUsage(at: string, task: string | null, input: number | undefined, output: number | undefined) {
  store.writeUsage({ at, task, tier: "day", provider: "claude-cli", model: "synthetic-model",
    input_tokens: input, output_tokens: output, ms: 1, ok: 1 });
}
const start = (offset: number) => modelUsageDayStart(midday, offset);
const status = (now: number) => hubStatus(ctx.db, { port: 47823, now });

test("最近七个本地自然日按有 token 数据的天数平均，排除连接测试与窗口外的调用", () => {
  writeUsage(new Date(start(-6)).toISOString(), "day", 70, 30);
  writeUsage(toLocalIso(start(-6) - 1000), "day", 9_999, 1);
  writeUsage(toLocalIso(start(-2)), "day_polish", 150, undefined);
  writeUsage(toLocalIso(start(-2) + 1000), null, 30, 20);
  writeUsage(new Date(start(0)).toISOString(), "day_brief", 200, 100);
  writeUsage(toLocalIso(start(-1)), "connection_test", 9_999, 1);
  writeUsage(toLocalIso(start(0)), "connection_test", 9_999, 1);
  writeUsage(toLocalIso(start(-4)), "assign", undefined, undefined);
  writeUsage(toLocalIso(start(1)), "day", 9_999, 1);
  expect(readModelUsage(ctx.db, midday)).toEqual({
    days_with_usage: 3, average_daily_tokens: 200, average_daily_timeline_tokens: 550 / 3, today_tokens: 300,
  });
  for (const offset of [-5, -4, -3, -1]) writeUsage(toLocalIso(start(offset)), "assign", 90, 10);
  expect(readModelUsage(ctx.db, midday)).toEqual({
    days_with_usage: 7, average_daily_tokens: 1000 / 7, average_daily_timeline_tokens: 550 / 7, today_tokens: 300,
  });
});

const request: LLMRequest = { tier: "minute", task: "assign", system: "合成样例", prompt: "合成展板", schema: {} };

test("调用用量达到上限后，下一次整理被拦，次日本地零点立即恢复", async () => {
  let now = midday, calls = 0;
  updateGeneral(ctx.db, { daily_token_limit: 100 });
  const llm = withModelCooldown({ async complete<T>(req: LLMRequest) {
    calls++;
    writeUsage(toLocalIso(now), req.task ?? null, 85, 15);
    return { ok: true, data: {} as T, ms: 1 };
  } }, store, () => now);

  expect(await llm.complete(request)).toMatchObject({ ok: true });
  await expect(llm.complete({ ...request, tier: "day", task: "day_polish" })).rejects.toMatchObject({ kind: "budget" });
  expect(calls).toBe(1);
  expect(status(now).distill.cooldown).toEqual({ kind: "budget", until: toLocalIso(start(1)) });
  expect(status(now).llm_today).toMatchObject({ used_tokens: 100, token_limit: 100 });
  now = start(1) - 1;
  await expect(llm.complete(request)).rejects.toMatchObject({ kind: "budget" });
  now = start(1);
  expect(status(now).distill.cooldown).toBeNull();
  expect(status(now).llm_today.used_tokens).toBe(0);
  expect(await llm.complete(request)).toMatchObject({ ok: true });
  expect(calls).toBe(2);
});

test("调高上限和改为不限都立即解除用量冷却，提供商冷却继续生效", async () => {
  let calls = 0;
  const llm = withModelCooldown({ async complete<T>() {
    calls++;
    return { ok: true, data: {} as T, ms: 1 };
  } }, store, () => midday);
  writeUsage(toLocalIso(midday), "classify", 90, 10);
  writeUsage(toLocalIso(midday), "connection_test", 10_000, 10_000);
  updateGeneral(ctx.db, { daily_token_limit: 100 });
  await expect(llm.complete(request)).rejects.toMatchObject({ kind: "budget" });
  updateGeneral(ctx.db, { daily_token_limit: 101 });
  await llm.complete(request);
  expect(status(midday).distill.cooldown).toBeNull();
  updateGeneral(ctx.db, { daily_token_limit: 100 });
  await expect(llm.complete(request)).rejects.toMatchObject({ kind: "budget" });
  updateGeneral(ctx.db, { daily_token_limit: null });
  await llm.complete(request);
  expect(calls).toBe(2);

  const until = new Date(midday + 60_000).toISOString();
  store.setState("llm_cooldown", { kind: "quota", until });
  await expect(llm.complete(request)).rejects.toMatchObject({ kind: "quota" });
  expect(status(midday).distill.cooldown).toEqual({ kind: "quota", until });
});
