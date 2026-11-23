import { readFileSync } from "node:fs";
import { readFile, rename, rm, writeFile } from "node:fs/promises";
import { randomBytes } from "node:crypto";
import { execFile } from "node:child_process";
import { join } from "node:path";
import { hubModeOf, type HubMode } from "../hub-json.ts";
import { defaultSecretStore, providerAccount, secretBackendOf } from "../secrets/index.ts";
import type { ModelConfig, Provider, ReasoningEffort, Tier } from "./types.ts";

export const TIERS: Tier[] = ["minute", "hour", "day"];
export const PROVIDERS: Provider[] = ["claude-cli", "codex-cli", "anthropic", "openai-compatible"];
/** 需要 API key 的 HTTP 后端；key 只存在钥匙串。 */
export const KEY_PROVIDERS = ["anthropic", "openai-compatible"] as const satisfies readonly Provider[];
export type KeyProvider = typeof KEY_PROVIDERS[number];
export const DEFAULT_TIERS: Record<Tier, ModelConfig> = { minute: { provider: "claude-cli", model: "haiku" }, hour: { provider: "claude-cli", model: "sonnet" }, day: { provider: "claude-cli", model: "sonnet" } };
export const SERVER_CLI_ERROR = "服务端中枢仅支持 API 模型";
export const SERVER_NO_MODELS_ERROR = "服务端中枢尚未配置 API 模型，请先在设置中配置 models.json 和对应 API key";

export class ModelConfigError extends Error {
  readonly code = "config_error";
  constructor(message: string) {
    super(message);
    this.name = "ModelConfigError";
  }
}

export function isCliProvider(provider: unknown): boolean {
  return provider === "claude-cli" || provider === "codex-cli";
}

function object(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

export interface ModelModeOptions {
  mode?: HubMode;
  env?: NodeJS.ProcessEnv;
}

function resolveMode(opts?: ModelModeOptions): HubMode {
  return opts?.mode ?? hubModeOf(opts?.env);
}

/** 校验一档配置；prefix 是错误信息里的位置前缀，例如 "models.json：tiers.minute"。 */
export function validateTier(item: unknown, prefix: string, opts?: ModelModeOptions): ModelConfig {
  if (!object(item)) throw new ModelConfigError(`${prefix} 必须是对象`);
  if (!PROVIDERS.includes(item.provider as Provider)) throw new ModelConfigError(`${prefix}.provider 不支持`);
  if (resolveMode(opts) === "server" && isCliProvider(item.provider)) throw new ModelConfigError(SERVER_CLI_ERROR);
  if (typeof item.model !== "string" || !item.model.trim()) throw new ModelConfigError(`${prefix}.model 必须是非空字符串`);
  if (item.model.length > 200 || /[\x00-\x1f\x7f]/.test(item.model)) throw new ModelConfigError(`${prefix}.model 不能超过 200 字符或含控制字符`);
  if (Object.keys(item).some(k => !["provider", "model", "base_url", "reasoning_effort"].includes(k))) throw new ModelConfigError(`${prefix} 含未知字段（API key 必须放钥匙串）`);
  if (item.reasoning_effort !== undefined) {
    if (item.provider !== "openai-compatible") throw new ModelConfigError(`${prefix}.reasoning_effort 只适用于 OpenAI 兼容接口`);
    if (!["none", "low", "medium", "high"].includes(item.reasoning_effort as string)) throw new ModelConfigError(`${prefix}.reasoning_effort 必须为 none、low、medium 或 high`);
  }
  if (item.base_url !== undefined) {
    if ((item.provider as string).endsWith("-cli")) throw new ModelConfigError(`${prefix}.base_url 只适用于 HTTP 后端`);
    try {
      if (typeof item.base_url !== "string" || item.base_url.length > 2000) throw new Error();
      const url = new URL(item.base_url);
      if (!["http:", "https:"].includes(url.protocol) || url.username || url.password || url.search || url.hash) throw new Error();
    } catch { throw new ModelConfigError(`${prefix}.base_url 必须是无凭证、查询参数和片段的 HTTP(S) URL`); }
  }
  return { provider: item.provider as Provider, model: item.model, ...(item.base_url === undefined ? {} : { base_url: item.base_url as string }), ...(item.reasoning_effort === undefined ? {} : { reasoning_effort: item.reasoning_effort as ReasoningEffort }) };
}

/** 校验整份 tiers：三档都要有，不接受未知档位。 */
export function validateTiers(value: unknown, prefix = "tiers", opts?: ModelModeOptions): Record<Tier, ModelConfig> {
  if (!object(value)) throw new ModelConfigError(`${prefix} 必须是对象`);
  if (Object.keys(value).some(k => !TIERS.includes(k as Tier))) throw new ModelConfigError(`${prefix} 含未知档位`);
  const result = {} as Record<Tier, ModelConfig>;
  for (const tier of TIERS) result[tier] = validateTier(value[tier], `${prefix}.${tier}`, opts);
  return result;
}

function parseModelsFile(source: string, opts?: ModelModeOptions): Record<Tier, ModelConfig> {
  let value: unknown;
  try { value = JSON.parse(source); } catch { throw new ModelConfigError("models.json：不是合法 JSON"); }
  if (!object(value) || Object.keys(value).some(k => k !== "tiers") || !object(value.tiers)) throw new ModelConfigError("models.json：只接受 tiers 对象");
  return validateTiers(value.tiers, "models.json：tiers", opts);
}

export async function loadConfig(dataDir: string, opts?: ModelModeOptions): Promise<Record<Tier, ModelConfig>> {
  const mode = resolveMode(opts);
  const file = join(dataDir, "models.json");
  let source: string;
  try { source = await readFile(file, "utf8"); }
  catch (error) {
    if ((error as NodeJS.ErrnoException).code !== "ENOENT") throw new ModelConfigError("无法读取 models.json");
    if (mode === "server") throw new ModelConfigError(SERVER_NO_MODELS_ERROR);
    return structuredClone(DEFAULT_TIERS);
  }
  return parseModelsFile(source, { mode });
}

export function loadConfigSync(dataDir: string, opts?: ModelModeOptions): Record<Tier, ModelConfig> {
  const mode = resolveMode(opts);
  const file = join(dataDir, "models.json");
  let source: string;
  try { source = readFileSync(file, "utf8"); }
  catch (error) {
    if ((error as NodeJS.ErrnoException).code !== "ENOENT") throw new ModelConfigError("无法读取 models.json");
    if (mode === "server") throw new ModelConfigError(SERVER_NO_MODELS_ERROR);
    return structuredClone(DEFAULT_TIERS);
  }
  return parseModelsFile(source, { mode });
}

export function inspectModelConfig(dataDir: string, opts?: ModelModeOptions): { ok: true; tiers: Record<Tier, ModelConfig> } | { ok: false; error: string } {
  try { return { ok: true, tiers: loadConfigSync(dataDir, opts) }; }
  catch (error) { return { ok: false, error: error instanceof Error ? error.message : "models.json 无效" }; }
}

/** 校验后原子写回 models.json（同目录临时文件 + rename），下一次模型调用即生效。 */
export async function saveConfig(dataDir: string, tiers: unknown, opts?: ModelModeOptions): Promise<Record<Tier, ModelConfig>> {
  const valid = validateTiers(tiers, "tiers", opts);
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
