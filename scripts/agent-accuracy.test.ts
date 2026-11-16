import { expect, test } from "bun:test";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { delimiter, join } from "node:path";

test("评测沿用 Claude Code 的模型及提供方，保持工具隔离", async () => {
  const dir = mkdtempSync(join(tmpdir(), "tacit-accuracy-config-"));
  try {
    const model = "synthetic/claude-model";
    const route = "https://evaluation.example.invalid";
    const token = "synthetic-provider-token";
    writeFileSync(join(dir, "settings.json"), JSON.stringify({
      model, env: { ANTHROPIC_BASE_URL: route, ANTHROPIC_AUTH_TOKEN: token, SYNTHETIC_HOOK_ENV: "ignored" },
    }));
    writeFileSync(join(dir, "claude"), `#!${process.execPath}
const args = process.argv.slice(2);
const value = flag => args[args.indexOf(flag) + 1];
if (value("--model") !== ${JSON.stringify(model)} || process.env.ANTHROPIC_BASE_URL !== ${JSON.stringify(route)}
    || process.env.ANTHROPIC_AUTH_TOKEN !== ${JSON.stringify(token)} || process.env.SYNTHETIC_HOOK_ENV
    || args.includes(process.env.ANTHROPIC_AUTH_TOKEN) || !args.includes("--restricted") || !args.includes("--strict-mcp-config")
    || value("--setting-sources") !== "" || value("--tools") !== "") process.exit(2);
console.log(JSON.stringify({ type: "system", subtype: "init", model: value("--model"), tools: value("--allowedTools").split(",") }));
console.log(JSON.stringify({ type: "result", subtype: "success", structured_output: { facts: {}, evidence_ids: [] } }));
`, { mode: 0o700 });

    const child = Bun.spawn([process.execPath, join(import.meta.dir, "agent-accuracy.ts"),
      join(import.meta.dir, "fixtures/agent-accuracy.example.json")], {
      env: { ...process.env, PATH: dir + delimiter + process.env.PATH, CLAUDE_CONFIG_DIR: dir, RA_PORT: "47823",
        ANTHROPIC_MODEL: undefined, SYNTHETIC_HOOK_ENV: undefined },
      stdout: "pipe",
    });
    const [output, status] = await Promise.all([new Response(child.stdout).text(), child.exited]);
    expect(status).toBe(0);
    expect(output).not.toContain(token);
    expect(JSON.parse(output.split("\n")[0]!)).toMatchObject({ id: "q-example", model, error: null });
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});
