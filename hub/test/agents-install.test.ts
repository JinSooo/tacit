import { afterEach, expect, test } from "bun:test";
import { chmodSync, existsSync, mkdirSync, mkdtempSync, readFileSync, readdirSync, rmSync, statSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { spawnSync } from "node:child_process";
import { agentStatus, connectAgent, runAgents, sessionStartCommand, type InstallEnvironment } from "../src/agents-install.ts";
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
  const write = (data: unknown, target = file) => { mkdirSync(dirname(target), { recursive: true }); writeFileSync(target, JSON.stringify(data, null, 2) + "\n"); };
  return { home, calls, output, env, file, original, write, missing: () => { registered = false; } };
}
test("预览给出 unified diff 和外部命令，既不写文件也不调用外部程序", () => {
  const ctx = setup(); ctx.write(ctx.original);
  const before = readFileSync(ctx.file, "utf8");
  runAgents(["install"], ctx.env);
  expect(readFileSync(ctx.file, "utf8")).toBe(before);
  expect(readdirSync(join(ctx.home, ".claude"))).toEqual(["settings.json"]);
  expect(existsSync(join(ctx.home, ".codex"))).toBe(false);
  expect(ctx.calls).toEqual([]);
  expect(ctx.output.join("\n")).toContain("@@ -1,");
  expect(ctx.output.join("\n")).toContain("--scope user tacit --");
  expect(ctx.output.join("\n")).toContain("trusted_hash");
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
test("两工具安装幂等，保留用户 hook、字段顺序、权限和最近一份备份；卸载往返一致", () => {
  const ctx = setup(); ctx.write(ctx.original); chmodSync(ctx.file, 0o640);
  const codexFile = join(ctx.home, ".codex/hooks.json"); ctx.write(ctx.original, codexFile);
  const before = readFileSync(ctx.file, "utf8");
  for (let round = 0; round < 2; round++) {
    runAgents(["install", "--yes"], ctx.env);
    const installed = readFileSync(ctx.file, "utf8");
    const data = JSON.parse(installed);
    expect(data.hooks.SessionStart).toHaveLength(2);
    expect(data.hooks.SessionStart[0]).toEqual(ctx.original.hooks.SessionStart[0]);
    expect(data.hooks.SessionStart[1].hooks[0]).toMatchObject({ timeout: 5, type: "command" });
    expect(Object.keys(data)).toEqual(Object.keys(ctx.original));
    const backupCount = readdirSync(dirname(ctx.file)).length;
    runAgents(["install", "--yes"], ctx.env);
    expect(readFileSync(ctx.file, "utf8")).toBe(installed);
    expect(readdirSync(dirname(ctx.file))).toHaveLength(backupCount);
    runAgents(["uninstall", "--yes"], ctx.env);
    expect(readFileSync(ctx.file, "utf8")).toBe(before);
    expect(readFileSync(codexFile, "utf8")).toBe(before);
  }
  expect(statSync(ctx.file).mode & 0o777).toBe(0o640);
  expect(readdirSync(dirname(ctx.file)).filter(name => name.includes(".ra-backup-"))).toHaveLength(1);
  // 新旧两个名字都查；旧名称和当前名称已注册时先移除再登记。
  expect(ctx.calls.slice(0, 5).map(call => `${call[2]} ${call.includes("record-anything") ? "record-anything" : "tacit"}`)).toEqual(["get tacit", "get record-anything", "remove record-anything", "remove tacit", "add tacit"]);
  expect(ctx.calls.some(call => call.includes("--scope"))).toBe(true);
  expect(ctx.calls.some(call => call[0] === "/fake/codex" && call.includes("--scope"))).toBe(false);
  // shell 引用实际解析后仍是绝对路径和原始参数，不执行目标命令。
  runAgents(["install", "--tool", "claude-code", "--yes"], ctx.env);
  const command = JSON.parse(readFileSync(ctx.file, "utf8")).hooks.SessionStart[1].hooks[0].command;
  const result = spawnSync("/bin/sh", ["-c", `set -- ${command}; printf '%s\\n' "$@"`], { encoding: "utf8" });
  expect(result.stdout.split("\n").slice(0, 4)).toEqual(["/tmp/bun bin", "/tmp/合成仓库 with 'quote'/hub/src/cli.ts", "hook", "session-start"]);
});
test("中枢没在运行时登记设备身份失败，命令行接入照常完成并提示退回本机令牌", async () => {
  const ctx = setup(); const output: string[] = []; ctx.env.print = line => output.push(line);
  await runAgents(["install", "--tool", "claude-code", "--yes"], ctx.env, async () => { throw new Error("当前无法连接 Tacit 中枢"); });
  expect(ctx.calls.some(call => call[2] === "add")).toBe(true);
  expect(JSON.parse(readFileSync(ctx.file, "utf8")).hooks.SessionStart.length).toBeGreaterThan(0);
  expect(output.some(line => line.includes("先用本机令牌接入"))).toBe(true);
});
test("无配置时卸载不创建文件；新配置卸载清理空的 hooks", () => {
  const ctx = setup(); ctx.env.which = () => null;
  runAgents(["uninstall", "--yes"], ctx.env);
  expect(readdirSync(ctx.home)).toEqual([]);
  runAgents(["install", "--yes"], ctx.env);
  runAgents(["uninstall", "--yes"], ctx.env);
  expect(JSON.parse(readFileSync(ctx.file, "utf8"))).toEqual({});
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
test("混合条目卸载只移除本仓库命令，并清理重复注册", () => {
  const ctx = setup(); ctx.env.repo = "/tmp/synthetic";
  const own = { type: "command", command: "/bin/bun /tmp/synthetic/hub/src/cli.ts hook session-start --tool claude-code" };
  const other = { type: "command", command: "/bin/bun /other/hub/src/cli.ts hook session-start" };
  ctx.write({ hooks: { SessionStart: [{ matcher: "startup", custom: true, hooks: [own, other] }, { hooks: [own] }] } });
  runAgents(["install", "--tool", "claude-code", "--yes"], ctx.env);
  expect(JSON.parse(readFileSync(ctx.file, "utf8")).hooks.SessionStart).toHaveLength(2);
  runAgents(["uninstall", "--tool", "claude-code", "--yes"], ctx.env);
  expect(JSON.parse(readFileSync(ctx.file, "utf8"))).toEqual({ hooks: { SessionStart: [{ matcher: "startup", custom: true, hooks: [other] }] } });
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
  expect(data.mcp_servers["tacit"].tools).toEqual({ now: { approval_mode: "prompt" }, get: { approval_mode: "approve" }, search: { approval_mode: "approve" }, timeline: { approval_mode: "approve" }, history_append: { approval_mode: "prompt" } });
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
  expect(Object.keys(data.mcp_servers["tacit"].tools).sort()).toEqual(["get", "history_append", "now", "search", "timeline"]);
  expect(data.mcp_servers["tacit"].tools.history_append.approval_mode).toBe("prompt");
  writeFileSync(file, readFileSync(file, "utf8").replace('approval_mode = "approve"', 'approval_mode = "prompt"'));
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
  ctx.write(groups, hooks);
  const before = [mcp, hooks].map(file => readFileSync(file, "utf8"));
  runAgents(["install", "--tool", "antigravity"], ctx.env);
  expect([mcp, hooks].map(file => readFileSync(file, "utf8"))).toEqual(before);
  const preview = ctx.output.join("\n");
  expect(preview).toContain(`--- ${mcp}`);
  expect(preview).toContain(`+++ ${hooks}`);
  expect(preview).toContain("hook session-start --tool antigravity");
  expect(preview).not.toContain("synthetic-private-do-not-print");
  const getStatus = () => agentStatus(ctx.env).find(t => t.id === "antigravity");
  expect(getStatus()).toMatchObject({ installed: true, connected: false, partial: false });
  connectAgent("antigravity", true, ctx.env);
  expect(getStatus()).toMatchObject({ connected: true, partial: false });
  expect(JSON.parse(readFileSync(mcp, "utf8"))).toEqual({
    mcpServers: { ...servers.mcpServers, tacit: { command: ctx.env.bun, args: [ctx.env.repo + "/hub/src/cli.ts", "mcp", "--tool", "antigravity"] } },
  });
  expect(JSON.parse(readFileSync(hooks, "utf8"))).toEqual({
    ...groups, tacit: { SessionStart: [{ type: "command", command: expect.stringContaining("hook session-start --tool antigravity"), timeout: 5 }] },
  });
  const backup = (file: string) => readdirSync(dirname(file)).filter(name => name.startsWith(file.split("/").at(-1) + ".ra-backup-"));
  const connected = [mcp, hooks].map(file => readFileSync(file, "utf8"));
  const firstBackups = [mcp, hooks].map(backup);
  connectAgent("antigravity", true, ctx.env);
  expect([mcp, hooks].map(backup)).toEqual(firstBackups);
  expect([mcp, hooks].map(file => readFileSync(file, "utf8"))).toEqual(connected);
  expect(firstBackups.map(names => names.length)).toEqual([1, 1]);
  connectAgent("antigravity", false, ctx.env);
  expect(getStatus()).toMatchObject({ connected: false, partial: false });
  expect([mcp, hooks].map(file => readFileSync(file, "utf8"))).toEqual(before);
  expect([mcp, hooks].map(backup).map(names => names.length)).toEqual([1, 1]);
  expect([mcp, hooks].map(file => readFileSync(join(dirname(file), backup(file)[0]!), "utf8"))).toEqual(connected);
  expect(ctx.calls).toEqual([]);
});

test("Antigravity 遇到同名 MCP 或钩子组冲突时不改任何文件", () => {
  const ctx = setup();
  const mcp = join(ctx.home, ".gemini/config/mcp_config.json"), hooks = join(ctx.home, ".gemini/config/hooks.json");
  for (const [servers, groups] of [
    [{ mcpServers: { tacit: { command: "other" } } }, {}],
    [{}, { tacit: { SessionStart: [{ command: "echo other" }] } }],
  ]) {
    ctx.write(servers, mcp);
    ctx.write(groups, hooks);
    const before = [mcp, hooks].map(file => readFileSync(file, "utf8"));
    for (const on of [true, false]) expect(() => connectAgent("antigravity", on, ctx.env)).toThrow("已被其他配置占用");
    expect([mcp, hooks].map(file => readFileSync(file, "utf8"))).toEqual(before);
    expect(readdirSync(dirname(mcp)).sort()).toEqual(["hooks.json", "mcp_config.json"]);
  }
});

test("Cursor 和 Gemini CLI 片段使用实际安装路径，只读检测两个配置，兼容 Cursor 省略 stdio", () => {
  const ctx = setup(), cli = ctx.env.repo + "/hub/src/cli.ts";
  ctx.env.which = command => command === "gemini" ? "/synthetic/gemini" : null;
  ctx.env.appExists = path => path === join(ctx.home, "Applications/Cursor.app");
  const cursorMcp = join(ctx.home, ".cursor/mcp.json"), cursorHook = join(ctx.home, ".cursor/hooks.json");
  const gemini = join(ctx.home, ".gemini/settings.json");
  const manual = (id: string) => agentStatus(ctx.env).find(tool => tool.id === id)!;
  const cursor = manual("cursor"), gem = manual("gemini-cli");
  expect(cursor).toMatchObject({ installed: true, connected: false, partial: false });
  expect(gem).toMatchObject({ installed: true, connected: false, partial: false });
  expect(readdirSync(ctx.home)).toEqual([]);

  const cursorDocs = cursor.manual!;
  expect(cursorDocs.map(({ file, action }) => [file, action])).toEqual([["~/.cursor/mcp.json", "create"], ["~/.cursor/hooks.json", "create"]]);
  const cursorServer = JSON.parse(cursorDocs[0]!.code), cursorHooks = JSON.parse(cursorDocs[1]!.code);
  expect(cursorServer).toEqual({ mcpServers: { tacit: { type: "stdio", command: ctx.env.bun, args: [cli, "mcp", "--tool", "cursor"] } } });
  expect(cursorHooks).toEqual({ version: 1, hooks: { sessionStart: [{ command: expect.stringContaining("hook session-start --tool cursor"), timeout: 5 }] } });
  delete cursorServer.mcpServers.tacit.type;
  ctx.write(cursorServer, cursorMcp);
  expect(manual("cursor")).toMatchObject({ connected: false, partial: true });
  ctx.write(cursorHooks, cursorHook);
  expect(manual("cursor")).toMatchObject({ connected: true, partial: false });
  expect(manual("cursor").manual![1]).toMatchObject({ action: "replace", section: "hooks.sessionStart[0]" });

  const [gemMcp, gemHook] = gem.manual!;
  expect(gemMcp).toMatchObject({ file: "~/.gemini/settings.json", action: "create" });
  expect(gemHook).toMatchObject({ file: gemMcp!.file, action: "add", section: undefined });
  const geminiConfig = { ...JSON.parse(gemMcp!.code), ...JSON.parse(`{${gemHook!.code}}`) };
  expect(geminiConfig.mcpServers.tacit).toEqual({ command: ctx.env.bun, args: [cli, "mcp", "--tool", "gemini-cli"] });
  expect(geminiConfig.hooks.SessionStart).toEqual([{ matcher: "startup|resume|clear", hooks: [
    { name: "tacit-session-start", type: "command", command: expect.stringContaining("hook session-start --tool gemini-cli"), timeout: 5000 },
  ] }]);
  ctx.write(geminiConfig, gemini);
  expect(manual("gemini-cli")).toMatchObject({ connected: true, partial: false });
  const before = [cursorMcp, cursorHook, gemini].map(file => readFileSync(file, "utf8"));
  for (const id of ["cursor", "gemini-cli"]) for (const action of ["install", "uninstall"]) {
    expect(() => runAgents([action, "--tool", id, "--yes"], ctx.env)).toThrow();
  }
  expect([cursorMcp, cursorHook, gemini].map(file => readFileSync(file, "utf8"))).toEqual(before);
  expect(ctx.calls).toEqual([]);

  ctx.write({ mcpServers: { another: { command: "synthetic" } }, hooks: { SessionStart: [{ matcher: "startup", hooks: [] }] } }, gemini);
  const existing = manual("gemini-cli").manual!;
  expect(existing[0]).toMatchObject({ action: "add", section: "mcpServers" });
  expect(Object.keys(JSON.parse(`{${existing[0]!.code}}`))).toEqual(["tacit"]);
  expect(existing[1]).toMatchObject({ action: "add", section: "hooks.SessionStart" });
  expect(JSON.parse(existing[1]!.code).hooks[0].timeout).toBe(5000);
});

test.each([
  ["opencode", "opencode", ".config/opencode/opencode.json", "mcp", { type: "local", enabled: true }, null],
  ["qwen-code", "qwen", ".qwen/settings.json", "mcpServers", {}, ".qwen/settings.json"],
  ["droid", "droid", ".factory/mcp.json", "mcpServers", { type: "stdio" }, null],
  ["copilot-cli", "copilot", ".copilot/mcp-config.json", "mcpServers", { type: "local", tools: ["*"] }, ".copilot/hooks/tacit.json"],
  ["codebuddy", "cbc", ".codebuddy.json", "mcpServers", { type: "stdio" }, ".codebuddy/settings.json"],
  ["workbuddy", null, ".workbuddy/mcp.json", "mcpServers", {}, null],
  ["kimi-cli", "kimi", ".kimi-code/mcp.json", "mcpServers", {}, null],
] as const)("%s 的手动配置可直接贴用，状态只读", (id, executable, file, section, extra, hookFile) => {
  const ctx = setup(), cli = ctx.env.repo + "/hub/src/cli.ts";
  const status = () => agentStatus(ctx.env).find(tool => tool.id === id)!;
  ctx.env.which = () => null;
  expect(status().installed).toBe(false);
  ctx.env.which = command => command === executable ? "/synthetic/" + command : null;
  ctx.env.appExists = path => id === "workbuddy" && path === join(ctx.home, "Applications/WorkBuddy.app");
  const initial = status();
  expect(initial).toMatchObject({ installed: true, connected: false, partial: false });
  expect(readdirSync(ctx.home)).toEqual([]);
  const [mcp, hook] = initial.manual!;
  expect(initial.manual).toHaveLength(hookFile ? 2 : 1);
  expect(mcp).toMatchObject({ file: `~/${file}`, kind: "mcp", action: "create" });
  const args = [cli, "mcp", "--tool", id];
  const server = { ...extra, ...(section === "mcp" ? { command: [ctx.env.bun, ...args] } : { command: ctx.env.bun, args }) };
  const mcpData = JSON.parse(mcp!.code);
  expect(mcpData).toEqual({ [section]: { tacit: server } });
  const target = join(ctx.home, file);
  ctx.write(mcpData, target);
  if (hookFile) {
    expect(status()).toMatchObject({ connected: false, partial: true });
    expect(hook).toMatchObject({ file: `~/${hookFile}`, kind: "session-start", action: hookFile === file ? "add" : "create" });
    const command = "'/tmp/bun bin' '/tmp/合成仓库 with '\\''quote'\\''/hub/src/cli.ts' hook session-start --tool " + id;
    const config = JSON.parse(hookFile === file ? `{${hook!.code}}` : hook!.code);
    if (id === "copilot-cli") {
      expect(config).toEqual({ version: 1, hooks: { sessionStart: [{ type: "command", bash: command, timeoutSec: 5 }] } });
    } else {
      expect(config).toEqual({ hooks: { SessionStart: [{ matcher: "startup|resume|clear|compact",
        hooks: [{ type: "command", command, timeout: 5 }],
      }] } });
    }
    ctx.write(hookFile === file ? { ...mcpData, ...config } : config, join(ctx.home, hookFile));
  }
  const files = [...new Set([target, ...(hookFile ? [join(ctx.home, hookFile)] : [])])];
  const before = files.map(path => readFileSync(path, "utf8"));
  expect(status()).toMatchObject({ connected: true, partial: false });
  for (const action of ["install", "uninstall"]) {
    expect(() => runAgents([action, "--tool", id, "--yes"], ctx.env)).toThrow();
  }
  expect(ctx.calls).toEqual([]);
  expect(files.map(path => readFileSync(path, "utf8"))).toEqual(before);
});

test("OpenCode 读取带注释和尾逗号的 JSONC，保留用户配置并提示替换禁用的条目", () => {
  const ctx = setup();
  const status = () => agentStatus(ctx.env).find(tool => tool.id === "opencode")!;
  const entry = JSON.parse(status().manual![0]!.code).mcp.tacit;
  const plain = join(ctx.home, ".config/opencode/opencode.json");
  const comments = plain + "c";
  ctx.write({ mcp: {} }, plain);
  const content = (enabled: boolean) => `{ /* test */ "mcp": { "tacit": {
    "type": "local", "command": [${entry.command.map((part: string) => JSON.stringify(part)).join(",")},],
    "environment": { "TEST_URL": "https://example.invalid//path" },
    "enabled": ${enabled}, // keep this comment
  }, }, }\n`;
  writeFileSync(comments, content(true));
  expect(status()).toMatchObject({ connected: true, partial: false });
  writeFileSync(comments, content(false));
  expect(status()).toMatchObject({ connected: false, partial: true });
  expect(status().manual![0]).toMatchObject({ file: "~/.config/opencode/opencode.jsonc", action: "replace", section: "mcp.tacit" });
  expect(readFileSync(comments, "utf8")).toBe(content(false));
});

test.each([
  ["copilot-cli", "COPILOT_HOME", ".copilot/mcp-config.json", "mcp-config.json", "hooks/tacit.json"],
  ["qwen-code", "QWEN_HOME", ".qwen/settings.json", "settings.json", "settings.json"],
  ["codebuddy", "CODEBUDDY_CONFIG_DIR", ".codebuddy.json", ".codebuddy.json", "settings.json"],
  ["kimi-cli", "KIMI_CODE_HOME", ".kimi-code/mcp.json", "mcp.json", null],
] as const)("%s 的目录覆盖同时用于片段和只读检测", (id, variable, defaultFile, filename, hookFile) => {
  const ctx = setup();
  const status = () => agentStatus(ctx.env).find(tool => tool.id === id)!;
  const defaultMcp = JSON.parse(status().manual![0]!.code);
  ctx.write(defaultMcp, join(ctx.home, defaultFile));
  ctx.env.variables![variable] = "~/custom config";
  const dir = join(ctx.home, "custom config");
  const [mcp, hook] = status().manual!;
  expect(status()).toMatchObject({ connected: false, partial: false });
  expect(mcp!.file).toBe(join(dir, filename));
  const mcpData = JSON.parse(mcp!.code);
  ctx.write(mcpData, mcp!.file);
  if (hookFile) {
    expect(hook!.file).toBe(join(dir, hookFile));
    if (id === "copilot-cli") {
      const otherFile = join(dir, "hooks/custom.json");
      ctx.write(JSON.parse(hook!.code), otherFile);
      expect(status().manual![1]!.file).toBe(otherFile);
      expect(existsSync(hook!.file)).toBe(false);
    } else if (hookFile === filename) {
      ctx.write({ ...mcpData, ...JSON.parse(`{${hook!.code}}`) }, hook!.file);
    } else {
      ctx.write(JSON.parse(hook!.code), hook!.file);
    }
  }
  expect(status()).toMatchObject({ connected: true, partial: false });
});


test("受限 PATH 仍能发现常见用户目录里的 CLI，并用 agy 接入 Antigravity", () => {
  const ctx = setup();
  delete ctx.env.which;
  ctx.env.variables!.PATH = "/usr/bin:/bin";
  for (const [bin, commands] of [
    [".local/bin", ["agy", "opencode", "droid"]],
    [".bun/bin", ["gemini", "qwen", "copilot"]],
    [".npm-global/bin", ["kimi", "cbc"]],
  ] as const) {
    mkdirSync(join(ctx.home, bin), { recursive: true });
    for (const cmd of commands) writeFileSync(join(ctx.home, bin, cmd), "#!/bin/sh\n", { mode: 0o700 });
  }
  const installed = agentStatus(ctx.env).filter(t => t.installed).map(t => t.id);
  expect(installed).toEqual(expect.arrayContaining(["antigravity", "opencode", "droid", "gemini-cli", "qwen-code", "copilot-cli", "kimi-cli", "codebuddy"]));
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
  expect(JSON.parse(readFileSync(ctx.file, "utf8")).hooks).toBeUndefined();
  expect(JSON.parse(readFileSync(join(ctx.home, ".codex/hooks.json"), "utf8")).hooks).toBeUndefined();
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

test.each([
  ["gemini-cli", "GEMINI_CLI_HOME", ".gemini/settings.json"],
  ["droid", "FACTORY_HOME_OVERRIDE", ".factory/mcp.json"],
] as const)("%s 的环境变量覆盖家目录，保留配置子目录", (id, variable, relative) => {
  const ctx = setup(), cli = ctx.env.repo + "/hub/src/cli.ts";
  ctx.env.variables![variable] = "~/custom home";
  const file = join(ctx.home, "custom home", relative);
  const config = {
    mcpServers: { tacit: { command: ctx.env.bun, args: [cli, "mcp", "--tool", id] } },
    ...(id === "gemini-cli" && { hooks: { SessionStart: [{
      hooks: [{ type: "command", command: sessionStartCommand(ctx.env.bun!, cli, id) }],
    }] } }),
  };
  ctx.write(config, file);
  const status = agentStatus(ctx.env).find(t => t.id === id)!;
  expect(status).toMatchObject({ connected: true, partial: false });
  expect(status.manual!.map(s => s.file)).toEqual(id === "gemini-cli" ? [file, file] : [file]);
});

test("OpenCode 读取配置文件覆盖、额外目录与 XDG 用户配置", () => {
  const ctx = setup();
  const status = () => agentStatus(ctx.env).find(t => t.id === "opencode")!;
  const entry = JSON.parse(status().manual![0]!.code).mcp.tacit;
  ctx.env.variables!.XDG_CONFIG_HOME = "~/xdg";
  const xdg = join(ctx.home, "xdg/opencode/config.json");
  ctx.write({ mcp: { tacit: entry } }, xdg);
  expect(status()).toMatchObject({ connected: true, manual: [{ file: xdg }] });

  ctx.env.variables!.OPENCODE_CONFIG_DIR = "~/extra";
  const extra = join(ctx.home, "extra/opencode.jsonc");
  ctx.write({ mcp: {} }, extra);
  expect(status()).toMatchObject({ connected: true, manual: [{ file: xdg }] });
  ctx.write({ mcp: { tacit: { ...entry, enabled: false } } }, extra);
  expect(status()).toMatchObject({ connected: false, partial: true, manual: [{ file: extra }] });

  ctx.env.variables!.OPENCODE_CONFIG = "~/custom/settings.jsonc";
  const explicit = join(ctx.home, "custom/settings.jsonc");
  ctx.write({ mcp: { tacit: entry } }, explicit);
  writeFileSync(explicit, "// synthetic config\n" + readFileSync(explicit, "utf8"));
  expect(status()).toMatchObject({ connected: true, partial: false, manual: [{ file: explicit }] });
});

test("OpenCode 片段优先指向用户指定的新配置文件或额外目录", () => {
  const ctx = setup();
  const snippet = () => agentStatus(ctx.env).find(t => t.id === "opencode")!.manual![0]!;
  ctx.env.variables!.OPENCODE_CONFIG_DIR = "~/extra";
  expect(snippet()).toMatchObject({ file: join(ctx.home, "extra/opencode.json"), action: "create" });
  ctx.env.variables!.OPENCODE_CONFIG = "~/custom/settings.jsonc";
  expect(snippet()).toMatchObject({ file: join(ctx.home, "custom/settings.jsonc"), action: "create" });
});

test.each([
  ["gemini-cli", ".gemini/settings.json", ".gemini/settings.json"],
  ["qwen-code", ".qwen/settings.json", ".qwen/settings.json"],
  ["codebuddy", ".codebuddy.json", ".codebuddy/settings.json"],
] as const)("%s 的 Claude 风格钩子只有 command 类型才生效", (id, mcpPath, hooksPath) => {
  const ctx = setup(), cli = ctx.env.repo + "/hub/src/cli.ts";
  const mcp = { mcpServers: { tacit: { command: ctx.env.bun, args: [cli, "mcp", "--tool", id] } } };
  const status = () => agentStatus(ctx.env).find(t => t.id === id)!;
  if (mcpPath !== hooksPath) ctx.write(mcp, join(ctx.home, mcpPath));
  for (const type of [undefined, "prompt", "command"]) {
    ctx.write({
      ...(mcpPath === hooksPath ? mcp : {}),
      hooks: { SessionStart: [{ hooks: [{ type, command: sessionStartCommand(ctx.env.bun!, cli, id) }] }] },
    }, join(ctx.home, hooksPath));
    expect(status()).toMatchObject({ connected: type === "command", partial: type !== "command" });
    expect(status().manual![1]).toMatchObject({ action: "replace", section: "hooks.SessionStart[0].hooks[0]" });
  }
});
