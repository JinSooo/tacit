import { mkdir, chmod } from "node:fs/promises";
import { resolve } from "node:path";
import { spawn as nodeSpawn } from "node:child_process";
import Ajv from "ajv";
import Ajv2020 from "ajv/dist/2020.js";
import addFormats from "ajv-formats";
import { ulid, toLocalIso } from "../../../packages/record/index.ts";
import { loadConfig, readKey as defaultReadKey } from "./config.ts";
import { claudeCLI } from "./claude-cli.ts";
import { codexCLI } from "./codex-cli.ts";
import { httpComplete } from "./http.ts";
import { classifyModelError, ModelError } from "./error-category.ts";
import type { RuntimeLog } from "../runtime-log.ts";
import type { BackendContext, LLMRequest, LLMResult, ModelConfig, ReadKey, Spawn, Tier, UsageRow } from "./types.ts";
export type { Tier, LLMRequest, LLMResult, UsageRow, ReadKey, Spawn, ModelConfig } from "./types.ts";

/**
 * 不强制 schema 的 HTTP 服务（MiniMax 等）常见的小偏差，在校验前按 schema 修补（2026-11-18）：
 * 去掉 additionalProperties=false 时多出的字段；枚举不收 "" 但收 null 时把 "" 改成 null；超出 maxItems 的列表截断。
 * 不改文字内容，超长等其他问题仍交给校验和重试。
 */
export function repairToSchema(value: unknown, schema: any): unknown {
  if (!schema || typeof schema !== "object") return value;
  if (value === "" && Array.isArray(schema.enum) && schema.enum.includes(null) && !schema.enum.includes("")) return null;
  if (Array.isArray(value)) {
    const items = schema.items ? value.map(v => repairToSchema(v, schema.items)) : value;
    return typeof schema.maxItems === "number" && items.length > schema.maxItems ? items.slice(0, schema.maxItems) : items;
  }
  if (value && typeof value === "object" && schema.properties && typeof schema.properties === "object") {
    const out: Record<string, unknown> = {};
    for (const [k, v] of Object.entries(value)) {
      if (k in schema.properties) out[k] = repairToSchema(v, schema.properties[k]);
      else if (schema.additionalProperties !== false) out[k] = v;
    }
    return out;
  }
  return value;
}

/** 单次调用上限。默认仍是 180 秒；当天整理输入最长，MiniMax 一次 35–70 秒、偶尔超过 180 秒（2026-11-18），单独放宽到 300 秒。 */
export const MAX_TIMEOUT_MS = 300_000;
// 跨实例共用队列，失败不会堵塞后续调用。
let queue: Promise<unknown> = Promise.resolve();
/** configs：不传时每次调用都重新读 models.json（改完下一次调用即生效）；设置页"测试连接"用它传入未保存的配置。 */
export function createLLM(options: { dataDir: string; recordUsage: (row: UsageRow) => void | Promise<void>; journal?: RuntimeLog; readKey?: ReadKey; spawn?: Spawn; configs?: () => Promise<Record<Tier, ModelConfig>> }) {
  async function execute<T>(req: LLMRequest): Promise<LLMResult<T>> {
    const start = performance.now();
    const row: UsageRow = { id: ulid(), at: toLocalIso(Date.now()), tier: req.tier, task: req.task ?? null, provider: "", model: "", input_chars: Array.from(req.system).length + Array.from(req.prompt).length, output_chars: 0, input_tokens: null, output_tokens: null, ms: 0, ok: 0, error: null };
    const metrics = { outputChars: 0, inputTokens: null as number | null, outputTokens: null as number | null };
    let data: unknown, validated = false, retryAfterMs: number | undefined;
    const identity = options.journal ? { call_id: row.id } : {};
    try {
      const configs = await (options.configs ?? (() => loadConfig(options.dataDir)))();
      const config = configs[req.tier];
      if (!config) throw new Error("不支持的模型档位");
      row.provider = config.provider; row.model = config.model;
      const timeoutMs = req.timeoutMs ?? 180_000;
      if (!Number.isFinite(timeoutMs) || timeoutMs <= 0 || timeoutMs > MAX_TIMEOUT_MS) throw new ModelError("bad_request");
      const ajv = (req.schema as { $schema?: string }).$schema?.includes("2020-12") ? new Ajv2020({ strict: false, allErrors: true }) : new Ajv({ strict: false, allErrors: true });
      (addFormats as unknown as (a: unknown) => void)(ajv);
      let validate;
      try { validate = ajv.compile(req.schema); } catch { throw new Error("请求 schema 无效"); }
      const cwd = resolve(options.dataDir, "distill-work");
      await mkdir(cwd, { recursive: true, mode: 0o700 }); await chmod(cwd, 0o700);
      let observer;
      try { observer = options.journal?.begin(row.id,req,config); }
      catch (error) { throw error instanceof ModelError ? error : new ModelError("usage_record_failed"); }
      const ctx: BackendContext = { req, config, cwd, timeoutMs, metrics, observer, spawn: options.spawn ?? ((cmd, args, opts) => nodeSpawn(cmd, args, opts)) };
      const http = config.provider === "anthropic" || config.provider === "openai-compatible";
      const call = async (c: BackendContext) => {
        const raw = config.provider === "claude-cli" ? await claudeCLI(c) : config.provider === "codex-cli" ? await codexCLI(c) : await httpComplete(c, options.readKey ?? defaultReadKey);
        // 先按任务规整（会把旧字段转成 schema 里的字段），再按 schema 修补。
        const out = req.normalizeOutput ? req.normalizeOutput(raw) : raw;
        return http ? repairToSchema(out, req.schema) : out;
      };
      data = await call(ctx);
      // HTTP 接口（如经 Anthropic 兼容接口接入的 MiniMax）不强制 maxLength 等约束，偶尔超长就整次作废。
      // 把不合格的位置（只有路径和规则，不含内容）告诉模型重试一次；两次的用量合计。CLI 后端自己强制 schema，不重试。
      if (!validate(data) && http) {
        const problems = [...new Set((validate.errors ?? []).map(e => `${e.instancePath || "/"} ${e.message ?? "不符合"}`))].slice(0, 8).join("；");
        const first = { ...metrics };
        data = await call({ ...ctx, req: { ...req, prompt: `${req.prompt}\n\n上一次输出不符合 JSON schema：${problems}。修正这些问题后重新完整输出。` } });
        const sum = (a: number | null, b: number | null) => a === null && b === null ? null : (a ?? 0) + (b ?? 0);
        metrics.inputTokens = sum(first.inputTokens, metrics.inputTokens); metrics.outputTokens = sum(first.outputTokens, metrics.outputTokens);
        metrics.outputChars += first.outputChars;
      }
      if (!validate(data)) throw new ModelError("schema_mismatch");
      validated = true;
      row.ok = 1;
    } catch (error) {
      row.error = classifyModelError(error);
      if (error instanceof ModelError) retryAfterMs = error.retryAfterMs;
    }
    row.ms = Math.round(performance.now() - start);
    row.output_chars = metrics.outputChars; row.input_tokens = metrics.inputTokens; row.output_tokens = metrics.outputTokens;
    try { await options.recordUsage(row); }
    catch { row.ok = 0; row.error = "usage_record_failed"; }
    try { options.journal?.finish(row,validated); }
    catch { return { ok: false, error: "usage_record_failed", ms: row.ms, ...identity }; }
    return row.ok ? { ok: true, data: data as T, ms: row.ms, ...identity } : { ok: false, error: row.error!, ms: row.ms, ...(retryAfterMs === undefined ? {} : { retryAfterMs }), ...identity };
  }
  return { complete<T>(req: LLMRequest): Promise<LLMResult<T>> {
    const result = queue.then(() => execute<T>(req));
    queue = result.catch(() => {});
    return result;
  } };
}
