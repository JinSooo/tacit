import { parseJSON, run, tokens } from "./process.ts";
import type { BackendContext } from "./types.ts";

export async function claudeCLI(ctx: BackendContext): Promise<unknown> {
  const stdout = await run(ctx, "claude", ["-p", "--no-session-persistence", "--output-format", "json", "--json-schema", JSON.stringify(ctx.req.schema), "--model", ctx.config.model, "--tools", "", "--strict-mcp-config", "--setting-sources", "", "--safe-mode", "--permission-mode", "dontAsk", "--permission-prompts", "none"]);
  ctx.metrics.outputChars = Array.from(stdout).length;
  const outer = parseJSON(stdout) as any;
  ctx.metrics.inputTokens = tokens(outer?.usage?.input_tokens);
  ctx.metrics.outputTokens = tokens(outer?.usage?.output_tokens);
  if (!outer || outer.is_error || outer.subtype !== "success") throw new Error("Claude 未成功生成结构化结果");
  if (outer.structured_output === undefined) throw new Error("Claude 结果缺少 structured_output");
  ctx.metrics.outputChars = Array.from(JSON.stringify(outer.structured_output)).length;
  return outer.structured_output;
}
