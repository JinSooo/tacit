import { mkdtemp, writeFile, readFile, rm } from "node:fs/promises";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { parseJSON, run, tokens } from "./process.ts";
import type { BackendContext } from "./types.ts";

export async function codexCLI(ctx: BackendContext): Promise<unknown> {
  const dir = await mkdtemp(join(tmpdir(), "record-anything-llm-"));
  try {
    const schema = join(dir, "schema.json"), output = join(dir, "result.json");
    await writeFile(schema, JSON.stringify(ctx.req.schema), { mode: 0o600 });
    const stdout = await run(ctx, "codex", ["exec", "--ephemeral", "--sandbox", "read-only", "--skip-git-repo-check", "-C", ctx.cwd, "--output-schema", schema, "-o", output, "-m", ctx.config.model,
      "--ignore-user-config", "--ignore-rules", "--json", "-c", 'approval_policy="never"', "-c", "project_doc_max_bytes=0", "-c", 'web_search="disabled"',
      "-c", "features.shell_tool=false", "-c", "features.unified_exec=false", "-c", "features.view_image=false", "-c", "features.image_generation=false", "-c", "features.apps=false", "-c", "features.memories=false", "-c", "features.multi_agent=false", "-c", "features.multi_agent_v2=false", "-c", "features.sleep_tool=false", "-c", "features.tool_suggest=false", "-c", "features.plugins=false", "-c", "features.hooks=false", "-"]);
    // JSONL 事件只取用量，不把事件正文写入日志。
    for (const line of stdout.split("\n").filter(Boolean)) {
      try {
        const event = JSON.parse(line);
        if (event.type === "turn.completed") {
          ctx.metrics.inputTokens = tokens(event.usage?.input_tokens);
          ctx.metrics.outputTokens = tokens(event.usage?.output_tokens);
        }
      } catch { /* CLI 诊断行不属于模型结果。 */ }
    }
    let text: string;
    try { text = await readFile(output, "utf8"); } catch { throw new Error("Codex 未写入结果文件"); }
    ctx.metrics.outputChars = Array.from(text).length;
    return parseJSON(text);
  } finally { await rm(dir, { recursive: true, force: true }); }
}
