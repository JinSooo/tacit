import { classifyModelError, ModelError } from "./error-category.ts";
import { parseJSON, run, tokens } from "./process.ts";
import type { BackendContext } from "./types.ts";

export async function claudeCLI(ctx: BackendContext): Promise<unknown> {
  const stdout = await run(ctx, "claude", ["-p", "--no-session-persistence", "--output-format", "json", "--json-schema", JSON.stringify(ctx.req.schema), "--model", ctx.config.model, "--tools", "", "--strict-mcp-config", "--setting-sources", "", "--safe-mode", "--permission-mode", "dontAsk", "--permission-prompts", "none"]);
  ctx.metrics.outputChars = Array.from(stdout).length;
  const outer = parseJSON(stdout) as any;
  const u = outer?.usage ?? {};
  // input_tokens 只是未命中缓存的部分；真实输入量要加上缓存读写。
  ctx.metrics.inputTokens = tokens([u.input_tokens, u.cache_read_input_tokens, u.cache_creation_input_tokens].reduce((n: number, v: unknown) => n + (typeof v === "number" ? v : 0), 0));
  ctx.metrics.outputTokens = tokens(outer?.usage?.output_tokens);
  if (!outer || outer.is_error || outer.subtype !== "success") throw new ModelError(classifyModelError(outer?.result, "cli_failed"));
  if (outer.structured_output === undefined) throw new ModelError("schema_mismatch");
  ctx.metrics.outputChars = Array.from(JSON.stringify(outer.structured_output)).length;
  return outer.structured_output;
}
