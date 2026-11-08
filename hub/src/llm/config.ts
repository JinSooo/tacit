import { readFile } from "node:fs/promises";
import { execFile } from "node:child_process";
import { join } from "node:path";
import type { ModelConfig, Provider, Tier } from "./types.ts";

const tiers: Tier[] = ["minute", "hour", "day"];
const providers: Provider[] = ["claude-cli", "codex-cli", "anthropic", "openai-compatible"];
function object(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}
export async function loadConfig(dataDir: string): Promise<Record<Tier, ModelConfig>> {
  const file = join(dataDir, "models.json");
  let source: string;
  try { source = await readFile(file, "utf8"); }
  catch (error) {
    if ((error as NodeJS.ErrnoException).code !== "ENOENT") throw new Error("无法读取 models.json");
    return { minute: { provider: "claude-cli", model: "haiku" }, hour: { provider: "claude-cli", model: "sonnet" }, day: { provider: "claude-cli", model: "sonnet" } };
  }
  let value: unknown;
  try { value = JSON.parse(source); } catch { throw new Error("models.json：不是合法 JSON"); }
  if (!object(value) || Object.keys(value).some(k => k !== "tiers") || !object(value.tiers)) throw new Error("models.json：只接受 tiers 对象");
  if (Object.keys(value.tiers).some(k => !tiers.includes(k as Tier))) throw new Error("models.json：tiers 含未知档位");
  const result = {} as Record<Tier, ModelConfig>;
  for (const tier of tiers) {
    const item = value.tiers[tier];
    const prefix = `models.json：tiers.${tier}`;
    if (!object(item)) throw new Error(`${prefix} 必须是对象`);
    if (!providers.includes(item.provider as Provider)) throw new Error(`${prefix}.provider 不支持`);
    if (typeof item.model !== "string" || !item.model.trim()) throw new Error(`${prefix}.model 必须是非空字符串`);
    if (Object.keys(item).some(k => !["provider", "model", "base_url"].includes(k))) throw new Error(`${prefix} 含未知字段（API key 必须放钥匙串）`);
    if (item.base_url !== undefined) {
      if ((item.provider as string).endsWith("-cli")) throw new Error(`${prefix}.base_url 只适用于 HTTP 后端`);
      try {
        if (typeof item.base_url !== "string") throw new Error();
        const url = new URL(item.base_url);
        if (!["http:", "https:"].includes(url.protocol) || url.username || url.password || url.search || url.hash) throw new Error();
      } catch { throw new Error(`${prefix}.base_url 必须是无凭证、查询参数和片段的 HTTP(S) URL`); }
    }
    result[tier] = { provider: item.provider as Provider, model: item.model, ...(item.base_url === undefined ? {} : { base_url: item.base_url as string }) };
  }
  return result;
}

export function readKey(provider: Provider): Promise<string> {
  return new Promise((resolve, reject) => {
    execFile("security", ["find-generic-password", "-s", "record-anything", "-a", `provider:${provider}`, "-w"], { timeout: 10_000 }, (error, stdout) => {
      if (error || !stdout.trim()) reject(new Error(`无法从钥匙串读取 provider:${provider}`));
      else resolve(stdout.trim());
    });
  });
}
