import { afterEach, expect, test } from "bun:test";
import { cpSync, existsSync, mkdirSync, mkdtempSync, readFileSync, readdirSync, rmSync, writeFileSync } from "node:fs";
import { join, dirname, resolve } from "node:path";
import { tmpdir } from "node:os";
import { spawnSync } from "node:child_process";
import { stageRuntime } from "../../scripts/stage-runtime.ts";
import { relocateInstall } from "../src/relocate-install.ts";
import { agentStatus } from "../src/agents-install.ts";

const dirs: string[] = [];
afterEach(() => { for (const d of dirs.splice(0)) rmSync(d, { recursive: true, force: true }); });
function temp() { const d = mkdtempSync(join(tmpdir(), "ra-runtime-")); dirs.push(d); return d; }
function write(file: string, data: unknown) { mkdirSync(dirname(file), { recursive: true }); writeFileSync(file, typeof data === "string" ? data : JSON.stringify(data)); }

test("已连接工具与 zsh 迁移固定路径：保留用户配置、权限选择，幂等且不新建连接", () => {
  const home = temp(), runtime = join(home, "Tacit runtime's"), bun = process.execPath, old = "/old/repo/hub/src/cli.ts";
  const mcp = (tool: string) => ({ command: "/old/bun", args: [old, "mcp", "--tool", tool], disabled: true });
  const hook = (tool: string) => ({ type: "command", command: `/old/bun ${old} hook session-start --tool ${tool}`, timeout: 5 });
  write(join(home, ".claude/settings.json"), { unrelated: 2, hooks: { SessionStart: [{ hooks: [hook("claude-code"), { command: "echo unchanged" }] }] } });
  write(join(home, ".claude.json"), { mcpServers: { "record-anything": mcp("claude-code"), other: { command: "untouched" } } });
  write(join(home, ".codex/hooks.json"), { hooks: { SessionStart: [{ hooks: [hook("codex")] }] } });
  write(join(home, ".codex/config.toml"), `# keep comment\nmodel = "synthetic"\n[mcp_servers.record-anything]\ncommand = "/old/bun"\nargs = [\n "${old}",\n "mcp", "--tool", "codex"\n]\nenabled = false\n[mcp_servers.record-anything.tools.history_append]\napproval_mode = "prompt"\n[mcp_servers.other]\ncommand = "untouched"\n`);
  write(join(home, "Library/Application Support/Claude/claude_desktop_config.json"), { preferences: { theme: "dark" }, mcpServers: { "record-anything": mcp("claude-desktop") } });
  write(join(home, ".zshrc"), '# my config\nsource "/old/repo/plugins/shell/hook.zsh"\nexport OTHER=1\n');
  expect(relocateInstall(runtime, bun, home)).toHaveLength(6);
  const toml = readFileSync(join(home, ".codex/config.toml"), "utf8");
  expect(toml).toStartWith('# keep comment\nmodel = "synthetic"');
  const parsed = Bun.TOML.parse(toml) as any;
  expect(parsed.mcp_servers["record-anything"].args[0]).toBe(join(runtime, "hub/src/cli.ts"));
  expect(parsed.mcp_servers["record-anything"].enabled).toBe(false);
  expect(parsed.mcp_servers["record-anything"].tools.history_append.approval_mode).toBe("prompt");
  expect(parsed.mcp_servers.other.command).toBe("untouched");
  expect(JSON.parse(readFileSync(join(home, ".claude.json"), "utf8")).mcpServers["record-anything"].disabled).toBe(true);
  expect(readFileSync(join(home, ".zshrc"), "utf8")).toContain("export OTHER=1");
  expect(relocateInstall(runtime, bun, home)).toEqual([]);
  const empty = temp(); expect(relocateInstall(runtime, bun, empty)).toEqual([]); expect(readdirSync(empty)).toEqual([]);
});

test("配置预检失败时不迁移任何文件；不覆盖同名非本应用 MCP", () => {
  const home = temp(), file = join(home, ".claude/settings.json");
  write(file, { hooks: { SessionStart: [{ hooks: [{ command: "/bun /old/hub/src/cli.ts hook session-start --tool claude-code" }] }] } });
  const before = readFileSync(file, "utf8");
  write(join(home, ".codex/config.toml"), "broken = [");
  expect(() => relocateInstall("/runtime", "/bun", home)).toThrow(); expect(readFileSync(file, "utf8")).toBe(before);
  write(join(home, ".codex/config.toml"), '[mcp_servers.record-anything]\ncommand="other"\nargs=["custom"]\n');
  relocateInstall("/runtime", "/bun", home);
  expect(readFileSync(join(home, ".codex/config.toml"), "utf8")).toContain('command="other"');
});

test("打包运行目录独立启动真实数据库与 MCP，修改源码副本不影响安装快照", () => {
  const root = temp(), source = join(root, "source"), runtime = join(root, "installed runtime");
  const repo = resolve(import.meta.dir, "../..");
  // 先打包真实运行代码，再从这个隔离的源码副本安装，随后破坏源码入口。
  stageRuntime(repo, source);
  stageRuntime(source, runtime);
  writeFileSync(join(source, "hub/src/cli.ts"), 'throw new Error("工作区已被修改");');
  const data = join(root, "data"), env = { ...process.env, RA_DATA_DIR: data, RA_DB_KEY: "synthetic-runtime-key", RA_PORT: "0" };
  const init = spawnSync(process.execPath, [join(runtime, "hub/src/cli.ts"), "init"], { cwd: runtime, env, encoding: "utf8" });
  expect(init.status).toBe(0); expect(init.stderr).toBe(""); expect(existsSync(join(data, "history.db"))).toBe(true);
  const mcp = spawnSync(process.execPath, [join(runtime, "hub/src/cli.ts"), "mcp", "--tool", "codex"], { cwd: runtime, env,
    input: JSON.stringify({ jsonrpc: "2.0", id: 1, method: "tools/list" }) + "\n", encoding: "utf8" });
  expect(mcp.status).toBe(0); expect(mcp.stdout).toContain("history_append");
  expect(existsSync(join(runtime, "node_modules/vite"))).toBe(false);
  expect(existsSync(join(runtime, "web/dist/index.html"))).toBe(true);
}, 30_000);
