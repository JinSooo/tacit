// 设置页的接口和校验，契约见 docs/contracts.md 第 3.1 节。
import type { Api } from "./distillation.ts";

export type Tier = "minute" | "hour" | "day";
export const tiers: Tier[] = ["minute", "hour", "day"];
export type Provider = "claude-cli" | "codex-cli" | "anthropic" | "openai-compatible";
export type KeyProvider = "anthropic" | "openai-compatible";
export const keyProviders: KeyProvider[] = ["anthropic", "openai-compatible"];
export type ReasoningEffort = "none" | "low" | "medium" | "high";
export interface TierConfig { provider: Provider; model: string; base_url?: string; reasoning_effort?: ReasoningEffort }
export const localPresets = [
  { id: "ollama", label: "本机 Ollama", url: "http://127.0.0.1:11434/v1" },
  { id: "lmstudio", label: "本机 LM Studio", url: "http://127.0.0.1:1234/v1" },
];
export const reasoningOptions = [["", "跟随模型"], ["none", "关闭"], ["low", "低"], ["medium", "中"], ["high", "高"]] as const;
export function isLocalURL(value: string | undefined): boolean {
  try {
    const u = new URL(value ?? ""), h = u.hostname;
    return ["http:", "https:"].includes(u.protocol) && !u.username && !u.password && (h === "localhost" || h === "[::1]" || /^127\.\d+\.\d+\.\d+$/.test(h));
  } catch { return false; }
}
export function providerChoice(c: { provider: Provider; base_url?: string }): string {
  return c.provider === "openai-compatible" ? localPresets.find(p => p.url === c.base_url)?.id ?? c.provider : c.provider;
}
export function needsKey(c: { provider: Provider; base_url?: string }, providers: ProviderInfo[]): boolean {
  return !isLocalURL(c.base_url) && !!providers.find(p => p.id === c.provider)?.needs_key;
}
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
export interface AgentToolState {
  id: string;
  label: string;
  installed: boolean;
  connected: boolean;
  partial: boolean;
  manual?: {
    file: string;
    kind: "mcp" | "session-start";
    action: "create" | "add" | "replace" | "merge";
    section?: string;
    code: string;
  }[];
}
export type GeneralKey = "inject_tokens" | "ask_done_days" | "archive_days";
export const generalKeys: GeneralKey[] = ["inject_tokens", "ask_done_days", "archive_days"];
export type General = Record<GeneralKey, number>;
export interface GeneralData extends General { defaults: General; ranges: Record<GeneralKey, [number, number]> }

export const generalLabels: Record<GeneralKey, { label: string; unit: string; hint: string }> = {
  inject_tokens: { label: "自动带入的长度上限", unit: "token", hint: "新会话开始时，自动带入当前项目的摘要。token 是模型的文字计量单位，800 token 中文通常约数百字；超出上限时先舍弃最早的事项。" },
  ask_done_days: { label: "事项多久没动静就问“做完了吗”", unit: "天", hint: "只算有历史记录的日子，最后活动当天不算。" },
  archive_days: { label: "问了多久没回答就归档", unit: "天", hint: "只算有历史记录的日子，提问当天不算。归档的事项不再自动带入，也不再问，仍然搜得到。" },
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
export function tierPayload(form: Record<Tier, { provider: Provider; model: string; base_url: string; reasoning_effort?: ReasoningEffort | "" }>, providers: ProviderInfo[]): Record<Tier, TierConfig> {
  const result = {} as Record<Tier, TierConfig>;
  for (const tier of tiers) result[tier] = tierConfig(form[tier], providers);
  return result;
}
export function tierConfig(item: { provider: Provider; model: string; base_url: string; reasoning_effort?: ReasoningEffort | "" }, providers: ProviderInfo[]): TierConfig {
  const allowsUrl = providers.find(p => p.id === item.provider)?.base_url ?? false;
  const base_url = item.base_url.trim();
  return { provider: item.provider, model: item.model.trim(), ...(allowsUrl && base_url ? { base_url } : {}), ...(item.provider === "openai-compatible" && item.reasoning_effort ? { reasoning_effort: item.reasoning_effort } : {}) };
}

// The web settings surface only exposes the automatic connect/disconnect controls.
function automaticTools<T extends { tools: AgentToolState[] }>(response: T): T {
  return { ...response, tools: response.tools.filter(tool => !tool.manual) };
}

export function createSettingsApi(api: Api) {
  const json = (method: string, body: unknown) => ({ method, body: JSON.stringify(body) });
  return {
    agents: (signal?: AbortSignal) => api<{ tools: AgentToolState[] }>("/v1/settings/agents", { signal }).then(automaticTools),
    setAgent: (id: AgentToolState["id"], connected: boolean) => api<{ tools: AgentToolState[]; note: string | null }>(`/v1/settings/agents/${id}`, json("PUT", { connected })).then(automaticTools),
    models: (signal?: AbortSignal) => api<ModelSettingsData>("/v1/settings/models", { signal }),
    localModels: (base_url: string, signal?: AbortSignal) => api<{ models: string[] }>("/v1/settings/models/local", { ...json("POST", { base_url }), signal }),
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
