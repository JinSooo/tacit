// 设置页的接口和校验，契约见 docs/contracts.md 第 3.1 节。
import type { Api } from "./distillation.ts";

export type Tier = "minute" | "hour" | "day";
export const tiers: Tier[] = ["minute", "hour", "day"];
export type Provider = "claude-cli" | "codex-cli" | "anthropic" | "openai-compatible";
export type KeyProvider = "anthropic" | "openai-compatible";
export const keyProviders: KeyProvider[] = ["anthropic", "openai-compatible"];
export interface TierConfig { provider: Provider; model: string; base_url?: string }
export interface ProviderInfo { id: Provider; label: string; needs_key: boolean; base_url: boolean }
export interface ModelSettingsData {
  tiers: Record<Tier, TierConfig>;
  config_error: string | null;
  keys: Record<KeyProvider, boolean | null>;
  providers: ProviderInfo[];
  tier_info: Record<Tier, { label: string; description: string }>;
}
export interface TestResult { ok: boolean; ms: number; provider: string; model: string; error: string | null }
export interface HubSettings { port: number; listen: string; lan: boolean; locked: boolean }
export type GeneralKey = "inject_tokens" | "ask_done_days" | "archive_days";
export const generalKeys: GeneralKey[] = ["inject_tokens", "ask_done_days", "archive_days"];
export type General = Record<GeneralKey, number>;
export interface GeneralData extends General { defaults: General; ranges: Record<GeneralKey, [number, number]> }

export const generalLabels: Record<GeneralKey, { label: string; unit: string; hint: string }> = {
  inject_tokens: { label: "自动注入上限", unit: "token", hint: "编程会话开始时注入的当前项目简略版，超出时先舍弃最旧的线程。" },
  ask_done_days: { label: "多久没动静就问“做完了吗”", unit: "天", hint: "线程这么多天没有新活动，就放进待确认问一次。" },
  archive_days: { label: "问了没人处理多久后归档", unit: "天", hint: "归档的线程不再注入、不再提问，仍可查询。" },
};
export const fallbackRanges: Record<GeneralKey, [number, number]> = { inject_tokens: [200, 4000], ask_done_days: [1, 30], archive_days: [1, 90] };

/** 和中枢同一套范围；空串、小数、越界都拒绝。 */
export function integerIn(value: string | number, [min, max]: [number, number], label: string): number {
  const n = typeof value === "string" && !value.trim() ? NaN : Number(value);
  if (!Number.isInteger(n) || n < min || n > max) throw new Error(`${label}须为 ${min}–${max} 的整数`);
  return n;
}
export const hubPort = (value: string | number) => integerIn(value, [1024, 65535], "端口");

/** 表单值整理成接口要的 tiers：去掉首尾空白，账号登录类后端和空的 base_url 不发。 */
export function tierPayload(form: Record<Tier, { provider: Provider; model: string; base_url: string }>, providers: ProviderInfo[]): Record<Tier, TierConfig> {
  const result = {} as Record<Tier, TierConfig>;
  for (const tier of tiers) result[tier] = tierConfig(form[tier], providers);
  return result;
}
export function tierConfig(item: { provider: Provider; model: string; base_url: string }, providers: ProviderInfo[]): TierConfig {
  const allowsUrl = providers.find(p => p.id === item.provider)?.base_url ?? false;
  const base_url = item.base_url.trim();
  return { provider: item.provider, model: item.model.trim(), ...(allowsUrl && base_url ? { base_url } : {}) };
}

export function createSettingsApi(api: Api) {
  const json = (method: string, body: unknown) => ({ method, body: JSON.stringify(body) });
  return {
    models: (signal?: AbortSignal) => api<ModelSettingsData>("/v1/settings/models", { signal }),
    saveModels: (value: Record<Tier, TierConfig>) => api<ModelSettingsData>("/v1/settings/models", json("PUT", { tiers: value })),
    test: (tier: Tier, config?: TierConfig) => api<TestResult>("/v1/settings/models/test", json("POST", config ? { tier, config } : { tier })),
    setKey: (provider: KeyProvider, key: string) => api<{ provider: KeyProvider; set: boolean }>(`/v1/settings/keys/${provider}`, json("PUT", { key: key.trim() })),
    deleteKey: (provider: KeyProvider) => api<{ provider: KeyProvider; deleted: boolean }>(`/v1/settings/keys/${provider}`, { method: "DELETE" }),
    general: (signal?: AbortSignal) => api<GeneralData>("/v1/settings/general", { signal }),
    saveGeneral: (value: Record<GeneralKey, string | number>, ranges = fallbackRanges) => api<GeneralData>("/v1/settings/general", json("PUT",
      Object.fromEntries(generalKeys.map(k => [k, integerIn(value[k], ranges[k], generalLabels[k].label)])))),
    hub: (signal?: AbortSignal) => api<HubSettings>("/v1/settings/hub", { signal }),
    saveHub: (port: string | number) => api<{ port: number; restarting: boolean }>("/v1/settings/hub", json("PUT", { port: hubPort(port) })),
  };
}
export type SettingsApi = ReturnType<typeof createSettingsApi>;
