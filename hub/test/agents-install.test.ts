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
