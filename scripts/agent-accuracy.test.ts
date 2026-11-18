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
const emit = item => console.log(JSON.stringify({ type: "item.completed", item }));
if (!configs.some(c => c.startsWith("mcp_servers."))) {
  // 判分调用：不带任何 MCP；答案里有“天空”算意思一致，其余不一致。
  const input = require("node:fs").readFileSync(0, "utf8");
  if (!input.includes("可接受说法") || value("-m") !== ${JSON.stringify(model)}) process.exit(3);
  const same = /答案：“[^”]*天空/.test(input);
  emit({ id: "j1", type: "agent_message", text: JSON.stringify({ same, reason: same ? "同一颜色" : "罗列多种分组碰运气" }) });
  process.exit(0);
}
if (args[0] !== "exec" || value("-m") !== ${JSON.stringify(model)} || !args.includes("--ignore-user-config")
    || !args.includes("--ephemeral") || value("-s") !== "read-only" || value("--disable") !== "shell_tool"
    || !configs.includes('model_reasoning_effort="low"') || !configs.some(c => c.startsWith("mcp_servers.tacit_eval.enabled_tools="))
    || configs.some(c => c.includes("personal"))) process.exit(2);
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
    // 原话命中不再判；没命中的交给判分模型，理由留在结果里。
    expect(result.judged).toEqual({ 分组: { same: false, reason: "罗列多种分组碰运气" } });

    // 意思一致就算对（2026-11-18 用户确认）：按现行规则重判已保存的答案。
    const saved = join(dir, "saved.jsonl");
    writeFileSync(saved, JSON.stringify({ ...result, answers: { 颜色: "和晴天的天空一个颜色", 分组: "文具组" },
      verified_evidence: ["01ARZ3NDEKTSV4RRFFQ69G5FAV"] }) + "\n");
    const again = Bun.spawn([process.execPath, join(import.meta.dir, "agent-accuracy.ts"),
      join(import.meta.dir, "fixtures/agent-accuracy.example.json"), "--regrade", saved], {
      env: { ...process.env, PATH: dir + delimiter + process.env.PATH, CODEX_HOME: dir, RA_PORT: "47823" }, stdout: "pipe",
    });
    const [regraded] = await Promise.all([new Response(again.stdout).text(), again.exited]);
    const row = JSON.parse(regraded.split("\n")[0]!);
    expect(row.facts).toEqual({ 颜色: true, 分组: true });
    expect(row.judged.颜色).toEqual({ same: true, reason: "同一颜色" });
    expect(row.correct).toBe(true);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});
