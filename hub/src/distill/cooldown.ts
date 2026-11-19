import { toLocalIso } from "../../../packages/record/index.ts";
import { classifyModelError, modelErrorCategory } from "../llm/error-category.ts";
import type { LLMRequest, LLMResult } from "../llm/types.ts";
import type { LLM } from "./run.ts";
import type { DistillStore } from "./store.ts";

const KEY = "llm_cooldown";
const MIN = 60_000;
const MAX_COOLDOWN = 6 * 60 * MIN;
const duration = { rate_limited: 30 * MIN, quota: 120 * MIN, network: 15 * MIN };
export type CooldownKind = keyof typeof duration;
type Cooldown = { until: string; kind: CooldownKind };

export function activeCooldown(store: DistillStore, now: number): Cooldown | null {
  const state = store.getState<Cooldown>(KEY);
  return state && Object.hasOwn(duration, state.kind) && Date.parse(state.until) > now ? state : null;
}

export class ModelCooldown extends Error {
  constructor(readonly kind: CooldownKind) { super(kind); }
}

/** 每次轮次/手动任务独立统计连续失败，同一个库持久化停用时间。 */
export function withModelCooldown(llm: LLM, store: DistillStore, now: () => number): LLM {
  let networkFailures = 0;
  return {
    async complete<T>(req: LLMRequest): Promise<LLMResult<T>> {
      const active = activeCooldown(store, now());
      if (active) throw new ModelCooldown(active.kind);
      let result: LLMResult<T>;
      try { result = await llm.complete<T>(req); }
      catch (error) { result = { ok: false, error: classifyModelError(error), ms: 0 }; }
      if (result.ok) {
        networkFailures = 0;
        // 仅清掉已过期且未被另一个调用延长的冷却。
        const state = store.getState<Cooldown>(KEY);
        if (state && Date.parse(state.until) <= now()) {
          store.hub.db.prepare("DELETE FROM distill_state WHERE k=? AND v=?").run(KEY, JSON.stringify(state));
        }
        return result;
      }
      const error = classifyModelError(result.error), category = modelErrorCategory(error);
      networkFailures = category === "network" || category === "timeout" ? networkFailures + 1 : 0;
      const kind = category === "quota" || category === "rate_limited" ? category : networkFailures >= 2 ? "network" : null;
      if (kind) {
        const clock = now();
        const retry = kind !== "network" && result.retryAfterMs ? result.retryAfterMs : 0;
        const delay = Math.max(duration[kind], Math.min(retry, MAX_COOLDOWN));
        // 本地 ISO 字符串的精度是秒。通常向上取整，且严格遵守 6 小时上限。
        const until = Math.min(Math.ceil((clock + delay) / 1000), Math.floor((clock + MAX_COOLDOWN) / 1000)) * 1000;
        store.hub.db.transaction(() => {
          const existing = activeCooldown(store, clock);
          if (!existing || Date.parse(existing.until) < until) store.setState(KEY, { until: toLocalIso(until), kind });
        }).immediate();
        throw new ModelCooldown(kind);
      }
      return { ...result, error };
    },
  };
}
