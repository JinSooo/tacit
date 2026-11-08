import { afterEach, expect, test } from "bun:test";
import { chmodSync, existsSync, mkdirSync, mkdtempSync, readFileSync, readdirSync, rmSync, statSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { spawnSync } from "node:child_process";
import { runAgents, type InstallEnvironment } from "../src/agents-install.ts";
const dirs: string[] = [];
afterEach(() => { for (const dir of dirs.splice(0)) rmSync(dir, { recursive: true, force: true }); });
function setup() {
  const home = mkdtempSync(join(tmpdir(), "ra-agents-")); dirs.push(home);
  const calls: string[][] = [], output: string[] = [];
  let registered = true;
  const env: InstallEnvironment = { home, repo: "/tmp/合成仓库 with 'quote'", bun: "/tmp/bun bin", which: command => `/fake/${command}`, print: line => output.push(line), run: (command, args, passedHome) => {
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
  expect(ctx.output.join("\n")).toContain("--scope user record-anything --");
  expect(ctx.output.join("\n")).toContain("trusted_hash");
});
test("两工具安装幂等，保留用户 hook、字段顺序、权限和逐次备份；卸载往返一致", () => {
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
  expect(readdirSync(dirname(ctx.file)).filter(name => name.includes(".ra-backup-"))).toHaveLength(4);
  expect(ctx.calls.slice(0, 3).map(call => call[2])).toEqual(["get", "remove", "add"]);
  expect(ctx.calls.some(call => call.includes("--scope"))).toBe(true);
  expect(ctx.calls.some(call => call[0] === "/fake/codex" && call.includes("--scope"))).toBe(false);
  // shell 引用实际解析后仍是绝对路径和原始参数，不执行目标命令。
  runAgents(["install", "--tool", "claude-code", "--yes"], ctx.env);
  const command = JSON.parse(readFileSync(ctx.file, "utf8")).hooks.SessionStart[1].hooks[0].command;
  const result = spawnSync("/bin/sh", ["-c", `set -- ${command}; printf '%s\\n' "$@"`], { encoding: "utf8" });
  expect(result.stdout.split("\n").slice(0, 4)).toEqual(["/tmp/bun bin", "/tmp/合成仓库 with 'quote'/hub/src/cli.ts", "hook", "session-start"]);
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
  expect(ctx.calls.map(call => call[2])).toEqual(["get", "add"]);
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
  expect(log).toContain("mcp\nget\nrecord-anything\n");
  expect(log).toContain("mcp\nremove\nrecord-anything\n");
  expect(log).toContain("mcp\nadd\nrecord-anything\n--\n/tmp/bun bin\n/tmp/合成仓库 with 'quote'/hub/src/cli.ts\nmcp\n--tool\ncodex\n");
  expect(readdirSync(join(ctx.home, ".codex")).some(name => name.includes(".ra-tmp-"))).toBe(false);
});

test("Codex 预览只显示缺失工具的追加，不泄露其他配置且不写入", () => {
  const ctx = setup(), file = join(ctx.home, ".codex/config.toml");
  mkdirSync(dirname(file));
  const original = '[mcp_servers.record-anything]\ncommand = "bun"\n[mcp_servers.record-anything.tools.now]\napproval_mode = "prompt"\n[mcp_servers.other]\ncommand = "合成保密配置"\n';
  writeFileSync(file, original);
  runAgents(["install", "--tool", "codex"], ctx.env);
  const output = ctx.output.join("\n");
  expect(output).toContain('+[mcp_servers.record-anything.tools.get]');
  expect(output).toContain('+approval_mode = "approve"');
  expect(output).not.toContain("合成保密配置");
  expect(output).not.toContain('+[mcp_servers.record-anything.tools.now]');
  expect(readFileSync(file, "utf8")).toBe(original);
  expect(ctx.calls).toEqual([]);
});

test("Codex 文本补齐保留现有工具规则、其他服务、权限并备份，重复安装不追加", () => {
  const ctx = setup(), file = join(ctx.home, ".codex/config.toml");
  mkdirSync(dirname(file));
  const original = '# 合成配置\n[mcp_servers.record-anything]\ncommand = "bun"\n[mcp_servers."record-anything".tools."now"] # 保留用户规则\napproval_mode = "prompt"\n[mcp_servers.other]\ncommand = "other"\n';
  writeFileSync(file, original); chmodSync(file, 0o640);
  runAgents(["install", "--tool", "codex", "--yes"], ctx.env);
  const installed = readFileSync(file, "utf8"), data = Bun.TOML.parse(installed) as any;
  expect(data.mcp_servers["record-anything"].tools).toEqual({ now: { approval_mode: "prompt" }, get: { approval_mode: "approve" }, search: { approval_mode: "approve" }, timeline: { approval_mode: "approve" } });
  expect(installed).toContain('[mcp_servers."record-anything".tools."now"] # 保留用户规则\napproval_mode = "prompt"');
  expect(installed).toContain('[mcp_servers.other]\ncommand = "other"\n');
  expect(installed.indexOf("tools.get")).toBeLessThan(installed.indexOf('tools."now"'));
  expect(statSync(file).mode & 0o777).toBe(0o640);
  expect(readdirSync(dirname(file)).filter(name => name.startsWith("config.toml.ra-backup-")).some(name => readFileSync(join(dirname(file), name), "utf8") === original)).toBe(true);
  runAgents(["install", "--tool", "codex", "--yes"], ctx.env);
  expect(readFileSync(file, "utf8")).toBe(installed);
  runAgents(["uninstall", "--tool", "codex", "--yes"], ctx.env);
  const removed = Bun.TOML.parse(readFileSync(file, "utf8")) as any;
  expect(removed.mcp_servers["record-anything"].tools).toBeUndefined();
  expect(removed.mcp_servers.other.command).toBe("other");
});

test("Codex 卸载兜底仅清理四表，保留其他工具、数组表和多行字符串", () => {
  const ctx = setup(), file = join(ctx.home, ".codex/config.toml");
  mkdirSync(dirname(file));
  const literal = 'description = """\n[mcp_servers.record-anything.tools.now]\n这是合成字符串\n"""\n';
  writeFileSync(file, literal + '[mcp_servers.record-anything.tools.now]\napproval_mode = "approve"\n[[custom]]\nname = "保留数组项"\n[mcp_servers.record-anything.tools.other]\napproval_mode = "prompt"\n');
  runAgents(["uninstall", "--tool", "codex", "--yes"], ctx.env);
  const content = readFileSync(file, "utf8"), data = Bun.TOML.parse(content) as any;
  expect(content).toStartWith(literal);
  expect(data.custom).toEqual([{ name: "保留数组项" }]);
  expect(data.mcp_servers["record-anything"].tools).toEqual({ other: { approval_mode: "prompt" } });
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
  expect(Object.keys(data.mcp_servers["record-anything"].tools).sort()).toEqual(["get", "now", "search", "timeline"]);
  writeFileSync(file, readFileSync(file, "utf8").replace('approval_mode = "approve"', 'approval_mode = "prompt"'));
  runAgents(["install", "--tool", "codex", "--yes"], ctx.env);
  data = Bun.TOML.parse(readFileSync(file, "utf8")) as any;
  expect(data.mcp_servers["record-anything"].tools.now.approval_mode).toBe("prompt");
  runAgents(["uninstall", "--tool", "codex", "--yes"], ctx.env);
  data = Bun.TOML.parse(readFileSync(file, "utf8")) as any;
  expect(data.mcp_servers["record-anything"]).toBeUndefined();
  expect(data.mcp_servers.unrelated.command).toBe("/usr/bin/true");
});
