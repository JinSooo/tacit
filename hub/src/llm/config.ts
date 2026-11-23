import { readFile, rename, rm, writeFile } from "node:fs/promises";
import { randomBytes } from "node:crypto";
import { execFile } from "node:child_process";
import { join } from "node:path";
import { defaultSecretStore, providerAccount, secretBackendOf } from "../secrets/index.ts";
import type { ModelConfig, Provider, ReasoningEffort, Tier } from "./types.ts";

export const TIERS: Tier[] = ["minute", "hour", "day"];
export const PROVIDERS: Provider[] = ["claude-cli", "codex-cli", "anthropic", "openai-compatible"];
/** 需要 API key 的 HTTP 后端；key 只存在钥匙串。 */
export const KEY_PROVIDERS = ["anthropic", "openai-compatible"] as const satisfies readonly Provider[];
export type KeyProvider = typeof KEY_PROVIDERS[number];
export const DEFAULT_TIERS: Record<Tier, ModelConfig> = { minute: { provider: "claude-cli", model: "haiku" }, hour: { provider: "claude-cli", model: "sonnet" }, day: { provider: "claude-cli", model: "sonnet" } };
function object(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

/** 校验一档配置；prefix 是错误信息里的位置前缀，例如 "models.json：tiers.minute"。 */
export function validateTier(item: unknown, prefix: string): ModelConfig {
  if (!object(item)) throw new Error(`${prefix} 必须是对象`);
  if (!PROVIDERS.includes(item.provider as Provider)) throw new Error(`${prefix}.provider 不支持`);
  if (typeof item.model !== "string" || !item.model.trim()) throw new Error(`${prefix}.model 必须是非空字符串`);
  if (item.model.length > 200 || /[\x00-\x1f\x7f]/.test(item.model)) throw new Error(`${prefix}.model 不能超过 200 字符或含控制字符`);
  if (Object.keys(item).some(k => !["provider", "model", "base_url", "reasoning_effort"].includes(k))) throw new Error(`${prefix} 含未知字段（API key 必须放钥匙串）`);
  if (item.reasoning_effort !== undefined) {
    if (item.provider !== "openai-compatible") throw new Error(`${prefix}.reasoning_effort 只适用于 OpenAI 兼容接口`);
    if (!["none", "low", "medium", "high"].includes(item.reasoning_effort as string)) throw new Error(`${prefix}.reasoning_effort 必须为 none、low、medium 或 high`);
  }
  if (item.base_url !== undefined) {
    if ((item.provider as string).endsWith("-cli")) throw new Error(`${prefix}.base_url 只适用于 HTTP 后端`);
    try {
      if (typeof item.base_url !== "string" || item.base_url.length > 2000) throw new Error();
      const url = new URL(item.base_url);
      if (!["http:", "https:"].includes(url.protocol) || url.username || url.password || url.search || url.hash) throw new Error();
    } catch { throw new Error(`${prefix}.base_url 必须是无凭证、查询参数和片段的 HTTP(S) URL`); }
  }
  return { provider: item.provider as Provider, model: item.model, ...(item.base_url === undefined ? {} : { base_url: item.base_url as string }), ...(item.reasoning_effort === undefined ? {} : { reasoning_effort: item.reasoning_effort as ReasoningEffort }) };
}

/** 校验整份 tiers：三档都要有，不接受未知档位。 */
export function validateTiers(value: unknown, prefix = "tiers"): Record<Tier, ModelConfig> {
  if (!object(value)) throw new Error(`${prefix} 必须是对象`);
  if (Object.keys(value).some(k => !TIERS.includes(k as Tier))) throw new Error(`${prefix} 含未知档位`);
  const result = {} as Record<Tier, ModelConfig>;
  for (const tier of TIERS) result[tier] = validateTier(value[tier], `${prefix}.${tier}`);
  return result;
}

export async function loadConfig(dataDir: string): Promise<Record<Tier, ModelConfig>> {
  const file = join(dataDir, "models.json");
  let source: string;
  try { source = await readFile(file, "utf8"); }
  catch (error) {
    if ((error as NodeJS.ErrnoException).code !== "ENOENT") throw new Error("无法读取 models.json");
    return structuredClone(DEFAULT_TIERS);
  }
  let value: unknown;
  try { value = JSON.parse(source); } catch { throw new Error("models.json：不是合法 JSON"); }
  if (!object(value) || Object.keys(value).some(k => k !== "tiers") || !object(value.tiers)) throw new Error("models.json：只接受 tiers 对象");
  return validateTiers(value.tiers, "models.json：tiers");
}

/** 校验后原子写回 models.json（同目录临时文件 + rename），下一次模型调用即生效。 */
export async function saveConfig(dataDir: string, tiers: unknown): Promise<Record<Tier, ModelConfig>> {
  const valid = validateTiers(tiers);
  const file = join(dataDir, "models.json"), temp = `${file}.${randomBytes(6).toString("hex")}.tmp`;
  try {
    await writeFile(temp, JSON.stringify({ tiers: valid }, null, 2) + "\n", { mode: 0o600, flag: "wx" });
    await rename(temp, file);
  } catch (error) { await rm(temp, { force: true }); throw error; }
  return valid;
}

export function readKey(provider: Provider): Promise<string> {
  const account = providerAccount(provider);
  // sealed-file（服务端）直接读 secrets.enc；Mac 默认后端仍异步调用 /usr/bin/security，不阻塞中枢事件循环。
  if (secretBackendOf() !== "keychain") {
    return Promise.resolve().then(() => defaultSecretStore().read(account)).then(
      value => { if (!value) throw new Error(`无法读取 ${account} 的密钥`); return value; },
      () => { throw new Error(`无法读取 ${account} 的密钥`); });
  }
  return new Promise((resolve, reject) => {
    execFile("/usr/bin/security", ["find-generic-password", "-s", "record-anything", "-a", account, "-w"], { timeout: 10_000 }, (error, stdout) => {
      if (error || !stdout.trim()) reject(new Error(`无法从钥匙串读取 ${account}`));
      else resolve(stdout.trim());
    });
  });
}
