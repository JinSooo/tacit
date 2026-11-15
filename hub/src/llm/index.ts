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
import { safeError } from "./process.ts";
import type { RuntimeLog } from "../runtime-log.ts";
import type { BackendContext, LLMRequest, LLMResult, ModelConfig, ReadKey, Spawn, Tier, UsageRow } from "./types.ts";
export type { Tier, LLMRequest, LLMResult, UsageRow, ReadKey, Spawn, ModelConfig } from "./types.ts";

// 跨实例共用队列，失败不会堵塞后续调用。
let queue: Promise<unknown> = Promise.resolve();
/** configs：不传时每次调用都重新读 models.json（改完下一次调用即生效）；设置页"测试连接"用它传入未保存的配置。 */
export function createLLM(options: { dataDir: string; recordUsage: (row: UsageRow) => void | Promise<void>; journal?: RuntimeLog; readKey?: ReadKey; spawn?: Spawn; configs?: () => Promise<Record<Tier, ModelConfig>> }) {
  async function execute<T>(req: LLMRequest): Promise<LLMResult<T>> {
    const start = performance.now();
    const row: UsageRow = { id: ulid(), at: toLocalIso(Date.now()), tier: req.tier, task: req.task ?? null, provider: "", model: "", input_chars: Array.from(req.system).length + Array.from(req.prompt).length, output_chars: 0, input_tokens: null, output_tokens: null, ms: 0, ok: 0, error: null };
    const metrics = { outputChars: 0, inputTokens: null as number | null, outputTokens: null as number | null };
    let data: unknown, validated = false;
    const identity = options.journal ? { call_id: row.id } : {};
    try {
      const configs = await (options.configs ?? (() => loadConfig(options.dataDir)))();
      const config = configs[req.tier];
      if (!config) throw new Error("不支持的模型档位");
      row.provider = config.provider; row.model = config.model;
      const timeoutMs = req.timeoutMs ?? 180_000;
      if (!Number.isFinite(timeoutMs) || timeoutMs <= 0 || timeoutMs > 180_000) throw new Error("timeoutMs 必须在 0 到 180000 之间");
      const ajv = (req.schema as { $schema?: string }).$schema?.includes("2020-12") ? new Ajv2020({ strict: false, allErrors: true }) : new Ajv({ strict: false, allErrors: true });
      (addFormats as unknown as (a: unknown) => void)(ajv);
      let validate;
      try { validate = ajv.compile(req.schema); } catch { throw new Error("请求 schema 无效"); }
      const cwd = resolve(options.dataDir, "distill-work");
      await mkdir(cwd, { recursive: true, mode: 0o700 }); await chmod(cwd, 0o700);
      let observer;
      try { observer = options.journal?.begin(row.id,req,config); }
      catch (error) { throw new Error(error instanceof Error && error.message === "记录已变化，等待重新整理" ? error.message : "调用记录保存失败，本次未发送"); }
      const ctx: BackendContext = { req, config, cwd, timeoutMs, metrics, observer, spawn: options.spawn ?? ((cmd, args, opts) => nodeSpawn(cmd, args, opts)) };
      data = config.provider === "claude-cli" ? await claudeCLI(ctx) : config.provider === "codex-cli" ? await codexCLI(ctx) : await httpComplete(ctx, options.readKey ?? defaultReadKey);
      if (!validate(data)) throw new Error("模型输出不符合 schema");
      validated = true;
      row.ok = 1;
    } catch (error) {
      row.error = safeError(error instanceof Error ? error.message : "模型调用失败", [req.system, req.prompt]);
    }
    row.ms = Math.round(performance.now() - start);
    row.output_chars = metrics.outputChars; row.input_tokens = metrics.inputTokens; row.output_tokens = metrics.outputTokens;
    try { await options.recordUsage(row); }
    catch { row.ok = 0; row.error = "模型用量记录失败"; }
    try { options.journal?.finish(row,validated); }
    catch { return { ok: false, error: "调用结果记录失败，结果未采用", ms: row.ms, ...identity }; }
    return row.ok ? { ok: true, data: data as T, ms: row.ms, ...identity } : { ok: false, error: row.error!, ms: row.ms, ...identity };
  }
  return { complete<T>(req: LLMRequest): Promise<LLMResult<T>> {
    const result = queue.then(() => execute<T>(req));
    queue = result.catch(() => {});
    return result;
  } };
}
