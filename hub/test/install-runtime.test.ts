import { afterEach, expect, test } from "bun:test";
import { cpSync, existsSync, lstatSync, mkdirSync, mkdtempSync, readFileSync, readdirSync, realpathSync, rmSync, statSync, symlinkSync, writeFileSync } from "node:fs";
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

test("已连接工具迁移固定路径：保留用户配置、权限选择，幂等且不新建连接", () => {
  const home = temp(), runtime = join(home, "Tacit runtime's"), bun = process.execPath, old = "/old/repo/hub/src/cli.ts";
  const mcp = (tool: string) => ({ command: "/old/bun", args: [old, "mcp", "--tool", tool], disabled: true });
  const hook = (tool: string) => ({ type: "command", command: `/old/bun ${old} hook session-start --tool ${tool}`, timeout: 5 });
  write(join(home, ".claude/settings.json"), { unrelated: 2, permissions: { allow: ["mcp__record-anything__search", "mcp__record-anything", "mcp__tacit", "Bash(ls)"] }, hooks: { SessionStart: [{ hooks: [hook("claude-code"), { command: "echo unchanged" }] }] } });
  write(join(home, ".claude.json"), { mcpServers: { "record-anything": mcp("claude-code"), other: { command: "untouched" } } });
  write(join(home, ".codex/hooks.json"), { hooks: { SessionStart: [{ hooks: [hook("codex")] }] } });
  write(join(home, ".codex/config.toml"), `# keep comment\nmodel = "synthetic"\n[mcp_servers.record-anything]\ncommand = "/old/bun"\nargs = [\n "${old}",\n "mcp", "--tool", "codex"\n]\nenabled = false\n[mcp_servers.record-anything.tools.history_append]\napproval_mode = "prompt"\n[mcp_servers.other]\ncommand = "untouched"\n`);
  write(join(home, "Library/Application Support/Claude/claude_desktop_config.json"), { preferences: { theme: "dark" }, mcpServers: { "record-anything": mcp("claude-desktop") } });
  expect(relocateInstall(runtime, bun, home)).toHaveLength(5);
  const toml = readFileSync(join(home, ".codex/config.toml"), "utf8");
  expect(toml).toStartWith('# keep comment\nmodel = "synthetic"');
  const parsed = Bun.TOML.parse(toml) as any;
  // 服务名从 record-anything 改成 tacit：位置、用户选择和工具规则都保留。
  expect(parsed.mcp_servers["record-anything"]).toBeUndefined();
  expect(parsed.mcp_servers.tacit.args[0]).toBe(join(runtime, "hub/src/cli.ts"));
  expect(parsed.mcp_servers.tacit.enabled).toBe(false);
  expect(parsed.mcp_servers.tacit.tools.history_append.approval_mode).toBe("prompt");
  expect(toml).toContain("[mcp_servers.tacit.tools.history_append]");
  expect(parsed.mcp_servers.other.command).toBe("untouched");
  const claude = JSON.parse(readFileSync(join(home, ".claude.json"), "utf8"));
  expect(Object.keys(claude.mcpServers)).toEqual(["tacit", "other"]);
  expect(claude.mcpServers.tacit.disabled).toBe(true);
  expect(JSON.parse(readFileSync(join(home, ".claude/settings.json"), "utf8")).permissions.allow).toEqual(["mcp__tacit__search", "mcp__tacit", "Bash(ls)"]);
  expect(Object.keys(JSON.parse(readFileSync(join(home, "Library/Application Support/Claude/claude_desktop_config.json"), "utf8")).mcpServers)).toEqual(["tacit"]);
  expect(relocateInstall(runtime, bun, home)).toEqual([]);
  const empty = temp(); expect(relocateInstall(runtime, bun, empty)).toEqual([]); expect(readdirSync(empty)).toEqual([]);
});

// 回归：v0.2.0 迁移把钩子写成全引号命令，设置页按未加引号的形式识别，已连接的工具显示成需要重新连接（2026-11-19 实测）。
test("迁移后的连接在设置页显示为已连接（路径不含需要引号的字符）", () => {
  const home = temp(), runtime = join(home, "runtime"), bun = join(home, "bin/bun"), old = "/old/repo/hub/src/cli.ts";
  const hook = (tool: string) => ({ type: "command", command: `/old/bun ${old} hook session-start --tool ${tool}`, timeout: 5 });
  write(join(home, ".claude/settings.json"), { hooks: { SessionStart: [{ hooks: [hook("claude-code")] }] } });
  write(join(home, ".claude.json"), { mcpServers: { tacit: { command: "/old/bun", args: [old, "mcp", "--tool", "claude-code"] } } });
  write(join(home, ".codex/hooks.json"), { hooks: { SessionStart: [{ hooks: [hook("codex")] }] } });
  write(join(home, ".codex/config.toml"), `[mcp_servers.tacit]\ncommand = "/old/bun"\nargs = ["${old}", "mcp", "--tool", "codex"]\n`);
  relocateInstall(runtime, bun, home);
  const states = agentStatus({ home, repo: runtime, bun, which: c => `/fake/${c}`, appExists: () => false });
  expect(states.filter(s => s.id === "claude-code" || s.id === "codex").map(s => [s.id, s.connected, s.partial])).toEqual([["claude-code", true, false], ["codex", true, false]]);
});

test("升级迁移 Antigravity 的 MCP 和会话开始命令，其他配置原样保留", () => {
  const home = temp(), runtime = join(home, "Tacit runtime's"), bun = join(home, "bin/bun");
  const mcp = join(home, ".gemini/config/mcp_config.json"), hooks = join(home, ".gemini/config/hooks.json");
  const original = { type: "command", command: "/old/bun /old/runtime/hub/src/cli.ts hook session-start --tool antigravity", timeout: 5 };
  const unrelated = { SessionStart: [{ command: "echo other" }] };
  write(mcp, { mcpServers: { tacit: { command: "/old/bun", args: ["/old/runtime/hub/src/cli.ts", "mcp", "--tool", "antigravity"] }, other: { command: "other" } } });
  write(hooks, { tacit: { SessionStart: [original] }, other: unrelated });
  expect(relocateInstall(runtime, bun, home)).toEqual([mcp, hooks]);
  expect(JSON.parse(readFileSync(mcp, "utf8")).mcpServers).toEqual({
    tacit: { command: bun, args: [join(runtime, "hub/src/cli.ts"), "mcp", "--tool", "antigravity"] },
    other: { command: "other" },
  });
  expect(JSON.parse(readFileSync(hooks, "utf8")).other).toEqual(unrelated);
  expect(agentStatus({ home, repo: runtime, bun, which: () => null, appExists: () => true }).find(t => t.id === "antigravity"))
    .toMatchObject({ connected: true, partial: false });
  expect(relocateInstall(runtime, bun, home)).toEqual([]);
});

test("迁移跳过损坏文件与非本应用条目，其他文件继续迁移", () => {
  const home = temp(), file = join(home, ".claude/settings.json");
  write(file, { hooks: { SessionStart: [{ hooks: [{ command: "/bun /old/hub/src/cli.ts hook session-start --tool claude-code" }] }] } });
  const codex = join(home, ".codex/config.toml"), hooks = join(home, ".gemini/config/hooks.json");
  const agMcp = join(home, ".gemini/config/mcp_config.json");
  const desktop = join(home, "Library/Application Support/Claude/claude_desktop_config.json");
  const entry = (tool: string) => ({ command: "/old/bun", args: ["/old/hub/src/cli.ts", "mcp", "--tool", tool] });
  write(codex, "synthetic-private-value = [");
  write(hooks, "{synthetic-private-value");
  write(agMcp, { mcpServers: { tacit: { command: "synthetic unrelated MCP" } } });
  write(desktop, { mcpServers: { tacit: entry("claude-desktop") } });
  const before = [codex, hooks, agMcp].map(path => readFileSync(path, "utf8"));
  const messages: string[] = [];
  expect(relocateInstall("/runtime", "/bun", home, message => messages.push(message))).toEqual([file, desktop]);
  expect([codex, hooks, agMcp].map(path => readFileSync(path, "utf8"))).toEqual(before);
  expect(readFileSync(file, "utf8")).toContain("/runtime/hub/src/cli.ts");
  expect(readFileSync(desktop, "utf8")).toContain("/runtime/hub/src/cli.ts");
  expect(messages).toEqual(["agent_config_no_tacit_entry", "agent_config_invalid_json", "agent_config_invalid_toml"]);
  write(join(home, ".codex/config.toml"), '[mcp_servers.record-anything]\ncommand="other"\nargs=["custom"]\n');
  write(join(home, ".claude.json"), { mcpServers: { "record-anything": { command: "other" } } });
  relocateInstall("/runtime", "/bun", home);
  expect(readFileSync(join(home, ".codex/config.toml"), "utf8")).toBe('[mcp_servers.record-anything]\ncommand="other"\nargs=["custom"]\n');
  expect(Object.keys(JSON.parse(readFileSync(join(home, ".claude.json"), "utf8")).mcpServers)).toEqual(["record-anything"]);
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
  const sqliteDir = join(runtime, "node_modules/better-sqlite3-multiple-ciphers");
  expect(readdirSync(join(sqliteDir, "prebuilds"))).toEqual([`${process.platform}-${process.arch}.node`]);
  expect(existsSync(join(sqliteDir, "deps"))).toBe(false);
  expect(existsSync(join(sqliteDir, "src"))).toBe(false);
  expect(existsSync(join(sqliteDir, "binding.gyp"))).toBe(false);
}, 30_000);

test("缺少当前平台 SQLite 原生模块时打包失败", () => {
  const root = temp(), source = join(root, "source"), runtime = join(root, "runtime");
  const repo = resolve(import.meta.dir, "../..");
  stageRuntime(repo, source);
  rmSync(join(source, "node_modules/better-sqlite3-multiple-ciphers/prebuilds", `${process.platform}-${process.arch}.node`));
  expect(() => stageRuntime(source, runtime)).toThrow(/prebuilds/);
}, 30_000);
