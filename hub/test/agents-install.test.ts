import { afterEach, expect, test } from "bun:test";
import { chmodSync, existsSync, mkdirSync, mkdtempSync, readFileSync, readdirSync, rmSync, statSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { spawnSync } from "node:child_process";
import { agentStatus, connectAgent, runAgents, type InstallEnvironment } from "../src/agents-install.ts";
const dirs: string[] = [];
afterEach(() => { for (const dir of dirs.splice(0)) rmSync(dir, { recursive: true, force: true }); });
function setup() {
  const home = mkdtempSync(join(tmpdir(), "ra-agents-")); dirs.push(home);
  const calls: string[][] = [], output: string[] = [];
  let registered = true;
  const env: InstallEnvironment = { home, repo: "/tmp/合成仓库 with 'quote'", bun: "/tmp/bun bin", variables: {}, appExists: () => false, which: command => `/fake/${command}`, print: line => output.push(line), run: (command, args, passedHome) => {
    expect(passedHome).toBe(home); calls.push([command, ...args]);
    if (args[1] === "get") return { status: registered ? 0 : 1, stdout: "", stderr: registered ? "" : "No MCP server found" };
    return { status: 0, stdout: "", stderr: "" };
  } };
  const file = join(home, ".claude/settings.json");
  const original = { custom: { enabled: true }, hooks: { SessionStart: [{ matcher: "startup", hooks: [{ type: "command", command: "echo 合成用户钩子" }] }], Stop: [{ hooks: [] }] }, tail: 2 };
  // 旧版写入的会话开始钩子（2026-11-27 撤下）：连接、断开和升级时都要删掉。
  const oldHook = (tool: string, repo = "/tmp/合成仓库 with 'quote'") => ({ type: "command", command: `'/tmp/bun bin' '${repo.replaceAll("'", "'\\''")}/hub/src/cli.ts' hook session-start --tool ${tool}`, timeout: 5 });
  const withOldHook = (tool: string) => ({ ...original, hooks: { ...original.hooks, SessionStart: [...original.hooks.SessionStart, { matcher: "startup|resume|clear|compact", hooks: [oldHook(tool)] }] } });
  const write = (data: unknown, target = file) => { mkdirSync(dirname(target), { recursive: true }); writeFileSync(target, JSON.stringify(data, null, 2) + "\n"); };
  return { home, calls, output, env, file, original, oldHook, withOldHook, write, missing: () => { registered = false; } };
}
test("预览给出 unified diff 和外部命令，既不写文件也不调用外部程序", () => {
  const ctx = setup(); ctx.write(ctx.original);
  const before = readFileSync(ctx.file, "utf8");
  runAgents(["install"], ctx.env);
  expect(readFileSync(ctx.file, "utf8")).toBe(before);
  expect(readdirSync(join(ctx.home, ".claude"))).toEqual(["settings.json"]);
  expect(existsSync(join(ctx.home, ".codex"))).toBe(false);
  expect(ctx.calls).toEqual([]);
  expect(ctx.output.join("\n")).toContain(`${ctx.file}：无需改动`);
  expect(ctx.output.join("\n")).toContain("--scope user tacit --");
  expect(ctx.output.join("\n")).not.toContain("hook session-start");
});

test("Desktop 不依赖 CLI 或 hook：预览不泄密，连接幂等并保留其他配置，断开只删自身", () => {
  const ctx = setup();
  ctx.env.which = () => null;
  ctx.env.appExists = path => path === join(ctx.home, "Applications/Claude.app");
  const file = join(ctx.home, "Library/Application Support/Claude/claude_desktop_config.json");
  const original = { preferences: { theme: "dark" }, mcpServers: { unrelated: { command: "other", env: { TOKEN: "synthetic-private-do-not-print" } } } };
  ctx.write(original, file); chmodSync(file, 0o600);
  const before = readFileSync(file, "utf8");
  runAgents(["install", "--tool", "claude-desktop"], ctx.env);
  expect(readFileSync(file, "utf8")).toBe(before);
  expect(ctx.output.join("\n")).not.toContain("synthetic-private-do-not-print");
  expect(ctx.calls).toEqual([]);
  expect(agentStatus(ctx.env).find(t => t.id === "claude-desktop")).toMatchObject({ installed: true, connected: false, partial: false });
  const result = connectAgent("claude-desktop", true, ctx.env);
  expect(result.note).toContain("完全退出");
  expect(result.states.find(t => t.id === "claude-desktop")).toMatchObject({ installed: true, connected: true, partial: false });
  const data = JSON.parse(readFileSync(file, "utf8"));
  expect(data.preferences).toEqual(original.preferences);
  expect(data.mcpServers.unrelated).toEqual(original.mcpServers.unrelated);
  expect(data.mcpServers["tacit"]).toEqual({ command: ctx.env.bun, args: [ctx.env.repo + "/hub/src/cli.ts", "mcp", "--tool", "claude-desktop"] });
  expect(statSync(file).mode & 0o777).toBe(0o600);
  const files = readdirSync(dirname(file));
  expect(files.some(name => name.includes(".ra-backup-") && readFileSync(join(dirname(file), name), "utf8") === before)).toBe(true);
  connectAgent("claude-desktop", true, ctx.env);
  expect(readdirSync(dirname(file))).toEqual(files);
  expect(existsSync(join(ctx.home, ".claude"))).toBe(false);
  expect(existsSync(join(ctx.home, ".codex"))).toBe(false);
  ctx.env.appExists = () => false;
  const removed = connectAgent("claude-desktop", false, ctx.env);
  expect(removed.note).toContain("重新打开");
  expect(removed.states.find(t => t.id === "claude-desktop")).toMatchObject({ installed: false, connected: false, partial: false });
  expect(JSON.parse(readFileSync(file, "utf8"))).toEqual(original);
  expect(ctx.calls).toEqual([]);
});

test("Desktop 损坏配置和同名冲突不覆盖；路径过期可重新连接", () => {
  const ctx = setup(); ctx.env.appExists = () => true;
  const file = join(ctx.home, "Library/Application Support/Claude/claude_desktop_config.json");
  ctx.write({}, file);
  for (const text of ["{broken", "null", "[]", '{"mcpServers":[]}', '{"mcpServers":{"tacit":{"command":"unrelated"}}}']) {
    writeFileSync(file, text);
    expect(() => connectAgent("claude-desktop", true, ctx.env)).toThrow();
    expect(readFileSync(file, "utf8")).toBe(text);
    expect(readdirSync(dirname(file))).toEqual(["claude_desktop_config.json"]);
  }
  ctx.write({ mcpServers: { "tacit": { command: "/old/bun", args: ["/old/repo/hub/src/cli.ts", "mcp", "--tool", "claude-desktop"] } } }, file);
  expect(agentStatus(ctx.env).find(t => t.id === "claude-desktop")).toMatchObject({ connected: false, partial: true });
  expect(connectAgent("claude-desktop", true, ctx.env).states.find(t => t.id === "claude-desktop")).toMatchObject({ connected: true, partial: false });
  // 旧名称下的本应用条目：显示需要重新连接，连接后换成新名称，旧条目移除；别人的同名旧条目不动。
  ctx.write({ mcpServers: { "record-anything": { command: "/old/bun", args: ["/old/repo/hub/src/cli.ts", "mcp", "--tool", "claude-desktop"] } } }, file);
  expect(agentStatus(ctx.env).find(t => t.id === "claude-desktop")).toMatchObject({ connected: false, partial: true });
  connectAgent("claude-desktop", true, ctx.env);
  expect(Object.keys(JSON.parse(readFileSync(file, "utf8")).mcpServers)).toEqual(["tacit"]);
  ctx.write({ mcpServers: { "record-anything": { command: "someone-else" } } }, file);
  connectAgent("claude-desktop", true, ctx.env);
  expect(Object.keys(JSON.parse(readFileSync(file, "utf8")).mcpServers).sort()).toEqual(["record-anything", "tacit"]);
});

test("默认安装不连接 Desktop；默认卸载包含卸载应用后留下的 Desktop 配置", () => {
  const ctx = setup();
  expect(() => connectAgent("claude-desktop", true, ctx.env)).toThrow("没找到 Claude Desktop");
  connectAgent("claude-desktop", false, ctx.env);
  expect(readdirSync(ctx.home)).toEqual([]);
  ctx.env.appExists = () => true;
  runAgents(["install", "--yes"], ctx.env);
  expect(agentStatus(ctx.env).find(t => t.id === "claude-desktop")?.connected).toBe(false);
  connectAgent("claude-desktop", true, ctx.env);
  expect(agentStatus(ctx.env).find(t => t.id === "claude-desktop")?.connected).toBe(true);
  ctx.env.appExists = () => false;
  runAgents(["uninstall", "--yes"], ctx.env);
  expect(agentStatus(ctx.env).find(t => t.id === "claude-desktop")?.connected).toBe(false);
});
test("两工具连接只登记 MCP：删掉旧版会话开始钩子，保留用户 hook、字段顺序、权限和最近一份备份；断开不再改动", () => {
  const ctx = setup(); ctx.write(ctx.withOldHook("claude-code")); chmodSync(ctx.file, 0o640);
  const codexFile = join(ctx.home, ".codex/hooks.json"); ctx.write(ctx.withOldHook("codex"), codexFile);
  const clean = JSON.stringify(ctx.original, null, 2) + "\n";
  for (let round = 0; round < 2; round++) {
    runAgents(["install", "--yes"], ctx.env);
    expect(readFileSync(ctx.file, "utf8")).toBe(clean);
    expect(readFileSync(codexFile, "utf8")).toBe(clean);
    const backupCount = readdirSync(dirname(ctx.file)).length;
    runAgents(["install", "--yes"], ctx.env);
    expect(readdirSync(dirname(ctx.file))).toHaveLength(backupCount);
    runAgents(["uninstall", "--yes"], ctx.env);
    expect(readFileSync(ctx.file, "utf8")).toBe(clean);
    expect(readFileSync(codexFile, "utf8")).toBe(clean);
  }
  expect(statSync(ctx.file).mode & 0o777).toBe(0o640);
  expect(readdirSync(dirname(ctx.file)).filter(name => name.includes(".ra-backup-"))).toHaveLength(1);
  // 新旧两个名字都查；旧名称和当前名称已注册时先移除再登记。
  expect(ctx.calls.slice(0, 5).map(call => `${call[2]} ${call.includes("record-anything") ? "record-anything" : "tacit"}`)).toEqual(["get tacit", "get record-anything", "remove record-anything", "remove tacit", "add tacit"]);
  expect(ctx.calls.some(call => call.includes("--scope"))).toBe(true);
  expect(ctx.calls.some(call => call[0] === "/fake/codex" && call.includes("--scope"))).toBe(false);
  expect(agentStatus(ctx.env).filter(t => t.id === "claude-code" || t.id === "codex")).toMatchObject([{ connected: false, partial: false }, { connected: false, partial: false }]);
});
test("中枢没在运行时登记设备身份失败，命令行接入照常完成并提示退回本机令牌", async () => {
  const ctx = setup(); const output: string[] = []; ctx.env.print = line => output.push(line);
  await runAgents(["install", "--tool", "claude-code", "--yes"], ctx.env, async () => { throw new Error("当前无法连接 Tacit 中枢"); });
  expect(ctx.calls.some(call => call[2] === "add")).toBe(true);
  expect(existsSync(ctx.file)).toBe(false);
  expect(output.some(line => line.includes("先用本机令牌接入"))).toBe(true);
});
test("无配置时连接和断开都不创建钩子文件", () => {
  const ctx = setup(); ctx.env.which = () => null;
  runAgents(["uninstall", "--yes"], ctx.env);
  expect(readdirSync(ctx.home)).toEqual([]);
  runAgents(["install", "--yes"], ctx.env);
  runAgents(["uninstall", "--yes"], ctx.env);
  expect(readdirSync(ctx.home)).toEqual([]);
  expect(ctx.calls).toEqual([]);
  expect(ctx.output.join("\n")).toContain("跳过 MCP");
});
test("Codex 已安装但从未配置时，默认卸载不会创建配置目录", () => {
  const ctx = setup();
  ctx.missing();
  runAgents(["uninstall", "--yes"], ctx.env);
  expect(ctx.calls).toContainEqual(["/fake/codex", "mcp", "get", "tacit"]);
  expect(readdirSync(ctx.home)).toEqual([]);
});

test("任一 JSON 损坏或结构不合法时，所有文件和外部配置均不变", () => {
  const ctx = setup(); ctx.write(ctx.original);
  const file = join(ctx.home, ".codex/hooks.json"); mkdirSync(dirname(file)); writeFileSync(file, "{损坏");
  expect(() => runAgents(["install", "--yes"], ctx.env)).toThrow("不是合法 JSON");
  expect(JSON.parse(readFileSync(ctx.file, "utf8"))).toEqual(ctx.original); expect(ctx.calls).toEqual([]);
  for (const data of [[], null, { hooks: [] }, { hooks: { SessionStart: {} } }]) {
    writeFileSync(file, JSON.stringify(data));
    expect(() => runAgents(["install", "--yes"], ctx.env)).toThrow("结构无效");
  }
});
test("任何一份 Tacit 的旧会话开始钩子都删掉，同组的用户钩子保留", () => {
  const ctx = setup(); ctx.env.repo = "/tmp/synthetic";
  const own = { type: "command", command: "/bin/bun /tmp/synthetic/hub/src/cli.ts hook session-start --tool claude-code" };
  const other = { type: "command", command: "/bin/bun /other/hub/src/cli.ts hook session-start" };
  const user = { type: "command", command: "echo 合成用户钩子" };
  ctx.write({ hooks: { SessionStart: [{ matcher: "startup", custom: true, hooks: [own, user, other] }, { hooks: [own] }] } });
  runAgents(["install", "--tool", "claude-code", "--yes"], ctx.env);
  expect(JSON.parse(readFileSync(ctx.file, "utf8"))).toEqual({ hooks: { SessionStart: [{ matcher: "startup", custom: true, hooks: [user] }] } });
});
test("未注册不 remove，命令失败中止，非法参数不触发操作", () => {
  const ctx = setup(); ctx.missing();
  runAgents(["install", "--tool", "codex", "--yes"], ctx.env);
  expect(ctx.calls.map(call => call[2])).toEqual(["get", "get", "add"]);
  ctx.env.run = () => ({ status: 1, stdout: "", stderr: "configuration parse error" });
  expect(() => runAgents(["uninstall", "--yes"], ctx.env)).toThrow("查询失败");
  for (const args of [[], ["install", "--tool"], ["install", "--tool", "other"], ["install", "--unknown"]]) expect(() => runAgents(args, ctx.env)).toThrow();
});
test("卸载不存在的目标不能删除用户原本的空 hooks 字段", () => {
  const ctx = setup(); ctx.write({ hooks: {} });
  const before = readFileSync(ctx.file, "utf8");
  runAgents(["uninstall", "--tool", "claude-code", "--yes"], ctx.env);
  expect(readFileSync(ctx.file, "utf8")).toBe(before);
});
test("默认子进程执行器只运行临时假命令，并隔离 HOME 和工具配置目录", () => {
  const ctx = setup(); ctx.write(ctx.original);
  const executable = join(ctx.home, "fake recorder");
  writeFileSync(executable, '#!/bin/sh\nprintf "%s\\n" "$HOME" "$CODEX_HOME" "$CLAUDE_CONFIG_DIR" "$@" >> "$HOME/commands.log"\n');
  chmodSync(executable, 0o700);
  ctx.env.run = undefined; ctx.env.which = () => executable;
  runAgents(["install", "--tool", "codex", "--yes"], ctx.env);
  const log = readFileSync(join(ctx.home, "commands.log"), "utf8");
  expect(log).toContain(`${ctx.home}\n${join(ctx.home, ".codex")}\n${join(ctx.home, ".claude")}\n`);
  expect(log).toContain("mcp\nget\ntacit\n");
  expect(log).toContain("mcp\nremove\ntacit\n");
  expect(log).toContain("mcp\nadd\ntacit\n--\n/tmp/bun bin\n/tmp/合成仓库 with 'quote'/hub/src/cli.ts\nmcp\n--tool\ncodex\n");
  expect(readdirSync(join(ctx.home, ".codex")).some(name => name.includes(".ra-tmp-"))).toBe(false);
});

test("Codex 预览只显示缺失工具的追加，不泄露其他配置且不写入", () => {
  const ctx = setup(), file = join(ctx.home, ".codex/config.toml");
  mkdirSync(dirname(file));
  const original = '[mcp_servers.tacit]\ncommand = "bun"\n[mcp_servers.tacit.tools.now]\napproval_mode = "prompt"\n[mcp_servers.other]\ncommand = "合成保密配置"\n';
  writeFileSync(file, original);
  runAgents(["install", "--tool", "codex"], ctx.env);
  const output = ctx.output.join("\n");
  expect(output).toContain('+[mcp_servers.tacit.tools.get]');
  expect(output).toContain('+approval_mode = "approve"');
  expect(output).not.toContain("合成保密配置");
  expect(output).not.toContain('+[mcp_servers.tacit.tools.now]');
  expect(readFileSync(file, "utf8")).toBe(original);
  expect(ctx.calls).toEqual([]);
});

test("Codex 文本补齐保留现有工具规则、其他服务、权限并备份，重复安装不追加", () => {
  const ctx = setup(), file = join(ctx.home, ".codex/config.toml");
  mkdirSync(dirname(file));
  const original = '# 合成配置\n[mcp_servers.tacit]\ncommand = "bun"\n[mcp_servers."tacit".tools."now"] # 保留用户规则\napproval_mode = "prompt"\n[mcp_servers.other]\ncommand = "other"\n';
  writeFileSync(file, original); chmodSync(file, 0o640);
  runAgents(["install", "--tool", "codex", "--yes"], ctx.env);
  const installed = readFileSync(file, "utf8"), data = Bun.TOML.parse(installed) as any;
  expect(data.mcp_servers["tacit"].tools).toEqual({ now: { approval_mode: "prompt" }, project: { approval_mode: "approve" }, get: { approval_mode: "approve" }, search: { approval_mode: "approve" }, timeline: { approval_mode: "approve" }, history_append: { approval_mode: "prompt" } });
  expect(installed).toContain('[mcp_servers."tacit".tools."now"] # 保留用户规则\napproval_mode = "prompt"');
  expect(installed).toContain('[mcp_servers.other]\ncommand = "other"\n');
  expect(installed.indexOf("tools.get")).toBeLessThan(installed.indexOf('tools."now"'));
  expect(statSync(file).mode & 0o777).toBe(0o640);
  expect(readdirSync(dirname(file)).filter(name => name.startsWith("config.toml.ra-backup-")).some(name => readFileSync(join(dirname(file), name), "utf8") === original)).toBe(true);
  runAgents(["install", "--tool", "codex", "--yes"], ctx.env);
  expect(readFileSync(file, "utf8")).toBe(installed);
  runAgents(["uninstall", "--tool", "codex", "--yes"], ctx.env);
  const removed = Bun.TOML.parse(readFileSync(file, "utf8")) as any;
  expect(removed.mcp_servers["tacit"].tools).toBeUndefined();
  expect(removed.mcp_servers.other.command).toBe("other");
});

test("Codex 卸载兜底仅清理四表，保留其他工具、数组表和多行字符串", () => {
  const ctx = setup(), file = join(ctx.home, ".codex/config.toml");
  mkdirSync(dirname(file));
  const literal = 'description = """\n[mcp_servers.tacit.tools.now]\n这是合成字符串\n"""\n';
  writeFileSync(file, literal + '[mcp_servers.tacit.tools.now]\napproval_mode = "approve"\n[[custom]]\nname = "保留数组项"\n[mcp_servers.tacit.tools.other]\napproval_mode = "prompt"\n');
  runAgents(["uninstall", "--tool", "codex", "--yes"], ctx.env);
  const content = readFileSync(file, "utf8"), data = Bun.TOML.parse(content) as any;
  expect(content).toStartWith(literal);
  expect(data.custom).toEqual([{ name: "保留数组项" }]);
  expect(data.mcp_servers["tacit"].tools).toEqual({ other: { approval_mode: "prompt" } });
});

test.skipIf(!Bun.which("codex"))("真实 Codex 在临时 HOME 安装、重装保留既有工具规则，卸载连带移除子表", () => {
  const command = Bun.which("codex");
  if (!command) throw new Error("本回归需要本机 codex CLI");
  const ctx = setup(), file = join(ctx.home, ".codex/config.toml");
  mkdirSync(dirname(file));
  writeFileSync(file, '# 合成配置\n[mcp_servers.unrelated]\ncommand = "/usr/bin/true"\n');
  ctx.env.which = () => command;
  ctx.env.run = undefined;
  runAgents(["install", "--tool", "codex", "--yes"], ctx.env);
  let data = Bun.TOML.parse(readFileSync(file, "utf8")) as any;
  expect(Object.keys(data.mcp_servers["tacit"].tools).sort()).toEqual(["get", "history_append", "now", "project", "search", "timeline"]);
  expect(data.mcp_servers["tacit"].tools.history_append.approval_mode).toBe("prompt");
  writeFileSync(file, readFileSync(file, "utf8").replace('[mcp_servers.tacit.tools.now]\napproval_mode = "approve"', '[mcp_servers.tacit.tools.now]\napproval_mode = "prompt"'));
  runAgents(["install", "--tool", "codex", "--yes"], ctx.env);
  data = Bun.TOML.parse(readFileSync(file, "utf8")) as any;
  expect(data.mcp_servers["tacit"].tools.now.approval_mode).toBe("prompt");
  runAgents(["uninstall", "--tool", "codex", "--yes"], ctx.env);
  data = Bun.TOML.parse(readFileSync(file, "utf8")) as any;
  expect(data.mcp_servers["tacit"]).toBeUndefined();
  expect(data.mcp_servers.unrelated.command).toBe("/usr/bin/true");
});

test("Codex 从旧服务名改连：旧名称下的用户工具规则沿用到新名称，旧的工具子表移除", () => {
  const ctx = setup(), file = join(ctx.home, ".codex/config.toml");
  mkdirSync(dirname(file));
  writeFileSync(file, '[mcp_servers.record-anything]\ncommand = "bun"\n[mcp_servers."record-anything".tools."now"] # 用户规则\napproval_mode = "prompt"\n[mcp_servers.other]\ncommand = "other"\n');
  runAgents(["install", "--tool", "codex", "--yes"], ctx.env);
  const content = readFileSync(file, "utf8"), data = Bun.TOML.parse(content) as any;
  expect(data.mcp_servers.tacit.tools.now.approval_mode).toBe("prompt");
  expect(data.mcp_servers.tacit.tools.get.approval_mode).toBe("approve");
  expect(data.mcp_servers["record-anything"]?.tools).toBeUndefined();
  expect(content).toContain('[mcp_servers.tacit.tools."now"] # 用户规则');
  expect(data.mcp_servers.other.command).toBe("other");
  expect(ctx.calls.some(call => call[2] === "remove" && call[3] === "record-anything")).toBe(true);
});

test("Antigravity 预览、连接、重复连接和断开保留其他条目，每个文件只留一份备份", () => {
  const ctx = setup();
  ctx.env.which = () => null;
  ctx.env.appExists = path => path === join(ctx.home, "Applications/Antigravity.app");
  const mcp = join(ctx.home, ".gemini/config/mcp_config.json"), hooks = join(ctx.home, ".gemini/config/hooks.json");
  const servers = { mcpServers: { other: { command: "other", env: { TOKEN: "synthetic-private-do-not-print" } } } };
  const groups = { other: { SessionStart: [{ type: "command", command: "echo other" }] } };
  ctx.write(servers, mcp);
  ctx.write({ ...groups, tacit: { SessionStart: [ctx.oldHook("antigravity")] } }, hooks);
  const before = [mcp, hooks].map(file => readFileSync(file, "utf8"));
  runAgents(["install", "--tool", "antigravity"], ctx.env);
  expect([mcp, hooks].map(file => readFileSync(file, "utf8"))).toEqual(before);
  const preview = ctx.output.join("\n");
  expect(preview).toContain(`--- ${mcp}`);
  expect(preview).toContain(`+++ ${hooks}`);
  expect(preview).toMatch(/^-.*hook session-start --tool antigravity/m);
  expect(preview).not.toContain("synthetic-private-do-not-print");
  const getStatus = () => agentStatus(ctx.env).find(t => t.id === "antigravity");
  expect(getStatus()).toMatchObject({ installed: true, connected: false, partial: false });
  connectAgent("antigravity", true, ctx.env);
  expect(getStatus()).toMatchObject({ connected: true, partial: false });
  expect(JSON.parse(readFileSync(mcp, "utf8"))).toEqual({
    mcpServers: { ...servers.mcpServers, tacit: { command: ctx.env.bun, args: [ctx.env.repo + "/hub/src/cli.ts", "mcp", "--tool", "antigravity"] } },
  });
  // 连接只写 MCP，旧版会话开始钩子组整组删掉，其他组不动。
  expect(JSON.parse(readFileSync(hooks, "utf8"))).toEqual(groups);
  const backup = (file: string) => readdirSync(dirname(file)).filter(name => name.startsWith(file.split("/").at(-1) + ".ra-backup-"));
  const connected = [mcp, hooks].map(file => readFileSync(file, "utf8"));
  const firstBackups = [mcp, hooks].map(backup);
  connectAgent("antigravity", true, ctx.env);
  expect([mcp, hooks].map(backup)).toEqual(firstBackups);
  expect([mcp, hooks].map(file => readFileSync(file, "utf8"))).toEqual(connected);
  expect(firstBackups.map(names => names.length)).toEqual([1, 1]);
  connectAgent("antigravity", false, ctx.env);
  expect(getStatus()).toMatchObject({ connected: false, partial: false });
  expect(readFileSync(mcp, "utf8")).toBe(before[0]);
  expect(readFileSync(hooks, "utf8")).toBe(connected[1]);
  expect([mcp, hooks].map(backup).map(names => names.length)).toEqual([1, 1]);
  expect(readFileSync(join(dirname(mcp), backup(mcp)[0]!), "utf8")).toBe(connected[0]);
  expect(ctx.calls).toEqual([]);
});

test("Antigravity 遇到同名 MCP 冲突时不改任何文件；同名但不是本应用的钩子组原样保留", () => {
  const ctx = setup(); ctx.env.appExists = () => true;
  const mcp = join(ctx.home, ".gemini/config/mcp_config.json"), hooks = join(ctx.home, ".gemini/config/hooks.json");
  ctx.write({ mcpServers: { tacit: { command: "other" } } }, mcp);
  ctx.write({ tacit: { SessionStart: [ctx.oldHook("antigravity")] } }, hooks);
  const before = [mcp, hooks].map(file => readFileSync(file, "utf8"));
  for (const on of [true, false]) expect(() => connectAgent("antigravity", on, ctx.env)).toThrow("已被其他配置占用");
  expect([mcp, hooks].map(file => readFileSync(file, "utf8"))).toEqual(before);
  expect(readdirSync(dirname(mcp)).sort()).toEqual(["hooks.json", "mcp_config.json"]);
  ctx.write({}, mcp);
  ctx.write({ tacit: { SessionStart: [{ command: "echo other" }] } }, hooks);
  const groups = readFileSync(hooks, "utf8");
  connectAgent("antigravity", true, ctx.env);
  expect(readFileSync(hooks, "utf8")).toBe(groups);
});

test("受限 PATH 仍能发现常见用户目录里的 CLI，并用 agy 接入 Antigravity", () => {
  const ctx = setup();
  delete ctx.env.which;
  ctx.env.variables!.PATH = "/usr/bin:/bin";
  for (const [bin, commands] of [
    [".local/bin", ["agy", "opencode"]],
    [".bun/bin", ["claude"]],
    [".npm-global/bin", ["codex"]],
  ] as const) {
    mkdirSync(join(ctx.home, bin), { recursive: true });
    for (const cmd of commands) writeFileSync(join(ctx.home, bin, cmd), "#!/bin/sh\n", { mode: 0o700 });
  }
  const installed = agentStatus(ctx.env).filter(t => t.installed).map(t => t.id);
  expect(installed).toEqual(["claude-code", "codex", "antigravity"]);
  expect(connectAgent("antigravity", true, ctx.env).states.find(t => t.id === "antigravity")?.connected).toBe(true);
});

test.each([
  [".gemini/config/hooks.json", '{"tacit":{"PreToolUse":[]}}'],
  [".gemini/config/mcp_config.json", '{"mcpServers":{"tacit":{"command":"other"}}}'],
  [".gemini/config/mcp_config.json", "{// synthetic invalid configuration"],
  [".gemini/config/hooks.json", '{"other":{"SessionStart":[]}}'],
])("默认卸载跳过不相关或损坏的 Antigravity 配置 %s", (relative, contents) => {
  const ctx = setup();
  ctx.env.appExists = () => true;
  runAgents(["install", "--yes"], ctx.env);
  connectAgent("claude-desktop", true, ctx.env);
  ctx.calls.length = 0;
  const file = join(ctx.home, relative);
  mkdirSync(dirname(file), { recursive: true });
  writeFileSync(file, contents);

  runAgents(["uninstall", "--yes"], ctx.env);
  expect(ctx.calls.filter(call => call[2] === "remove" && call.at(-1) === "tacit").map(call => call[0])).toEqual(["/fake/claude", "/fake/codex"]);
  expect(existsSync(ctx.file)).toBe(false);
  expect(existsSync(join(ctx.home, ".codex/hooks.json"))).toBe(false);
  expect(agentStatus(ctx.env).find(t => t.id === "claude-desktop")?.connected).toBe(false);
  expect(readFileSync(file, "utf8")).toBe(contents);
  expect(ctx.output.join("\n")).toContain("跳过 Antigravity");
});

test("Antigravity 重连保留 MCP 自定义字段，重复连接不再写入", () => {
  const ctx = setup();
  const file = join(ctx.home, ".gemini/config/mcp_config.json");
  const preferences = { timeoutSeconds: 60, disabledTools: ["history_append"], env: { SAMPLE: "synthetic-do-not-print" } };
  ctx.write({ mcpServers: { tacit: {
    command: "/old/bun", args: ["/old/hub/src/cli.ts", "mcp", "--tool", "antigravity"], disabled: true, ...preferences,
  } } }, file);
  runAgents(["install", "--tool", "antigravity", "--yes"], ctx.env);
  const connected = readFileSync(file, "utf8");
  expect(JSON.parse(connected).mcpServers.tacit).toEqual({
    command: ctx.env.bun, args: [ctx.env.repo + "/hub/src/cli.ts", "mcp", "--tool", "antigravity"], ...preferences,
  });
  expect(ctx.output.join("\n")).not.toContain("synthetic-do-not-print");
  const files = readdirSync(dirname(file));
  runAgents(["install", "--tool", "antigravity", "--yes"], ctx.env);
  expect(readdirSync(dirname(file))).toEqual(files);
  expect(readFileSync(file, "utf8")).toBe(connected);
});
