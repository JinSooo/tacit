import { expect, test } from "bun:test";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { delimiter, join } from "node:path";

test("评测用 Codex 作答，沿用默认模型且不加载用户其他配置", async () => {
  const dir = mkdtempSync(join(tmpdir(), "tacit-accuracy-config-"));
  try {
    const model = "synthetic-codex-model";
    writeFileSync(join(dir, "config.toml"), `model = "${model}"\nmodel_reasoning_effort = "low"\n\n[mcp_servers.personal]\ncommand = "ignored"\n`);
    writeFileSync(join(dir, "codex"), `#!${process.execPath}
const args = process.argv.slice(2);
const value = flag => args[args.indexOf(flag) + 1];
const configs = args.flatMap((arg, i) => arg === "-c" ? [args[i + 1]] : []);
if (args[0] !== "exec" || value("-m") !== ${JSON.stringify(model)} || !args.includes("--ignore-user-config")
    || !args.includes("--ephemeral") || value("-s") !== "read-only" || value("--disable") !== "shell_tool"
    || !configs.includes('model_reasoning_effort="low"') || !configs.some(c => c.startsWith("mcp_servers.tacit_eval.enabled_tools="))
    || configs.some(c => c.includes("personal"))) process.exit(2);
const emit = item => console.log(JSON.stringify({ type: "item.completed", item }));
emit({ id: "i1", type: "mcp_tool_call", server: "tacit_eval", tool: "now", arguments: {}, result: { content: [{ type: "text", text: "{}" }] }, error: null });
emit({ id: "i2", type: "agent_message", text: JSON.stringify({ facts: { 颜色: "铅笔是蓝色的", 分组: "可能是文具组、画材组、办公组、收纳组、礼品组、耗材组、教具组、工具组、杂项组、样品组、赠品组、备用组、展示组、包装组、试用组、旧品组、新品组、外借组" }, evidence_ids: [] }) });
`, { mode: 0o700 });

    const child = Bun.spawn([process.execPath, join(import.meta.dir, "agent-accuracy.ts"),
      join(import.meta.dir, "fixtures/agent-accuracy.example.json")], {
      env: { ...process.env, PATH: dir + delimiter + process.env.PATH, CODEX_HOME: dir, RA_PORT: "47823" },
      stdout: "pipe",
    });
    const [output, status] = await Promise.all([new Response(child.stdout).text(), child.exited]);
    expect(status).toBe(0);
    const result = JSON.parse(output.split("\n")[0]!);
    expect(result).toMatchObject({ id: "q-example", model, error: null });
    // 换个说法但包含可接受答案算对；把多种说法堆成长答案不算对；原答案留在结果里供核对。
    expect(result.facts).toEqual({ 颜色: true, 分组: false });
    expect(result.answers.颜色).toBe("铅笔是蓝色的");
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});
