import { chmodSync, copyFileSync, existsSync, mkdirSync, readFileSync, renameSync, statSync, unlinkSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { spawnSync } from "node:child_process";

export type AgentTool = "claude-code" | "codex";
type Json = Record<string, any>;
export interface InstallEnvironment {
  home?: string; repo?: string; bun?: string;
  which?: (command: string) => string | null;
  run?: (command: string, args: string[], home: string) => { status: number | null; stdout: string; stderr: string };
  print?: (text: string) => void;
}
const quote = (value: string) => /^[\w/.:=-]+$/.test(value) ? value : `'${value.replaceAll("'", "'\\''")}'`;
const object = (value: unknown): value is Json => value !== null && typeof value === "object" && !Array.isArray(value);

// 用一整个 hunk 展示原文和目标，预览本身不创建临时文件。
function diff(file: string, before: string, after: string, existed: boolean) {
  const lines = (text: string) => text ? text.replace(/\n$/, "").split("\n") : [];
  const a = lines(before), b = lines(after);
  return [`--- ${existed ? file : "/dev/null"}`, `+++ ${file}`, `@@ -${a.length ? 1 : 0},${a.length} +${b.length ? 1 : 0},${b.length} @@`,
    ...a.map(line => `-${line}`), ...(before && !before.endsWith("\n") ? ["\\ No newline at end of file"] : []), ...b.map(line => `+${line}`)].join("\n");
}
function hookFile(file: string, install: boolean, cli: string, bun: string, tool: AgentTool) {
  const existed = existsSync(file), before = existed ? readFileSync(file, "utf8") : "";
  let data: Json;
  try { data = existed ? JSON.parse(before) : {}; } catch { throw new Error(`${file} 不是合法 JSON，未写入配置`); }
  if (!object(data) || data.hooks !== undefined && !object(data.hooks) || data.hooks?.SessionStart !== undefined && !Array.isArray(data.hooks.SessionStart)) throw new Error(`${file} 的 hooks 结构无效，未写入配置`);
  const marker = `${cli} hook session-start`;
  // 带空格的路径会被 shell 引用；同时识别未引用和本模块生成的命令。
  const ours = (hook: any) => object(hook) && typeof hook.command === "string" && (hook.command.includes(marker) || hook.command.includes(`${quote(cli)} hook session-start`));
  let found = false;
  if (!install && !(data.hooks?.SessionStart ?? []).some((row: any) => object(row) && Array.isArray(row.hooks) && row.hooks.some(ours))) return { file, existed, before, after: before };
  const entry = { matcher: "startup|resume|clear|compact", hooks: [{ type: "command", command: `${quote(bun)} ${quote(cli)} hook session-start --tool ${tool}`, timeout: 5 }] };
  const rows: any[] = [];
  for (const row of data.hooks?.SessionStart ?? []) {
    if (!object(row) || !Array.isArray(row.hooks) || !row.hooks.some(ours)) { rows.push(row); continue; }
    const remaining = row.hooks.filter((hook: any) => !ours(hook));
    if (remaining.length) rows.push({ ...row, hooks: remaining });
    if (install && !found) { rows.push(entry); found = true; }
  }
  if (install && !found) rows.push(entry);
  if (rows.length) { data.hooks ??= {}; data.hooks.SessionStart = rows; }
  else if (data.hooks) { delete data.hooks.SessionStart; if (!Object.keys(data.hooks).length) delete data.hooks; }
  const after = JSON.stringify(data, null, 2) + "\n";
  // 没有目标条目时卸载不重排、不创建文件。
  return { file, existed, before, after: !install && !found && JSON.stringify(data) === JSON.stringify(existed ? JSON.parse(before) : {}) ? before : after };
}
function save(plan: ReturnType<typeof hookFile>) {
  const mode = plan.existed ? statSync(plan.file).mode & 0o7777 : 0o600;
  if (plan.existed) copyFileSync(plan.file, `${plan.file}.ra-backup-${Date.now()}-${crypto.randomUUID()}`);
  mkdirSync(dirname(plan.file), { recursive: true });
  const temp = `${plan.file}.ra-tmp-${crypto.randomUUID()}`;
  try {
    writeFileSync(temp, plan.after, { mode, flag: "wx" });
    chmodSync(temp, mode);
    renameSync(temp, plan.file);
  } finally { if (existsSync(temp)) unlinkSync(temp); }
}

export function runAgents(argv: string[], env: InstallEnvironment = {}) {
  const [action, ...flags] = argv;
  if (action !== "install" && action !== "uninstall") throw new Error("用法：agents <install|uninstall> [--tool claude-code|codex] [--yes]");
  let selected: AgentTool | undefined, yes = false;
  for (let i = 0; i < flags.length; i++) {
    if (flags[i] === "--yes") yes = true;
    else if (flags[i] === "--tool" && !selected && ["claude-code", "codex"].includes(flags[i + 1] ?? "")) selected = flags[++i] as AgentTool;
    else throw new Error("agents 参数无效");
  }
  const home = resolve(env.home ?? homedir()), repo = resolve(env.repo ?? fileURLToPath(new URL("../../", import.meta.url)));
  const bun = resolve(env.bun ?? process.execPath), cli = resolve(repo, "hub/src/cli.ts");
  const print = env.print ?? console.log, which = env.which ?? (command => Bun.which(command));
  // 只有目标不是真实家目录（测试用临时 HOME）时才覆盖环境变量：对真实用户设置 CLAUDE_CONFIG_DIR
  // 会让 claude 把全局配置写到 ~/.claude/.claude.json，而不是平时用的 ~/.claude.json。
  const run = env.run ?? ((command, args, home) => spawnSync(command, args, { encoding: "utf8", env: home === resolve(homedir()) ? process.env : { ...process.env, HOME: home, CODEX_HOME: resolve(home, ".codex"), CLAUDE_CONFIG_DIR: resolve(home, ".claude") }, timeout: 30000 }));
  const tools: AgentTool[] = selected ? [selected] : ["claude-code", "codex"];
  // 全部解析成功后才可能写入，防止第二份 JSON 无效时已改第一份。
  const plans = tools.map(tool => hookFile(resolve(home, tool === "codex" ? ".codex/hooks.json" : ".claude/settings.json"), action === "install", cli, bun, tool));
  const commands = tools.map(tool => ({ tool, command: which(tool === "codex" ? "codex" : "claude") }));
  print(yes ? "将执行以下改动：" : "预览（未写入；加 --yes 执行）：");
  for (const plan of plans) {
    if (plan.before !== plan.after) print(diff(plan.file, plan.before, plan.after, plan.existed));
    else print(`${plan.file}：无需改动`);
  }
  for (const { tool, command } of commands) {
    if (!command) { print(`找不到 ${tool === "codex" ? "codex" : "claude"}，跳过 MCP 注册/移除`); continue; }
    const remove = tool === "codex" ? ["mcp", "remove", "record-anything"] : ["mcp", "remove", "--scope", "user", "record-anything"];
    const add = ["mcp", "add", ...(tool === "codex" ? [] : ["--scope", "user"]), "record-anything", "--", bun, cli, "mcp", "--tool", tool];
    const get = ["mcp", "get", "record-anything"];
    print(`$ ${[command, ...get].map(quote).join(" ")}`);
    print(`已注册时执行：${[command, ...remove].map(quote).join(" ")}`);
    if (action === "install") print(`$ ${[command, ...add].map(quote).join(" ")}`);
    if (yes) {
      const registered = run(command, get, home);
      if (registered.status !== 0 && !/not found|no .*server|does not exist|未找到|不存在/i.test(registered.stderr + registered.stdout)) throw new Error(`${tool} MCP 查询失败，未继续注册`);
      for (const args of [...(registered.status === 0 ? [remove] : []), ...(action === "install" ? [add] : [])]) {
        if (run(command, args, home).status !== 0) throw new Error(`${tool} MCP ${args[1]} 失败，请检查该工具配置后重试`);
      }
    }
  }
  if (yes) for (const plan of plans) if (plan.before !== plan.after) save(plan);
  if (action === "install" && tools.includes("codex")) print("Codex 新 hook 需要在 Codex 里批准一次（trusted_hash）才会生效。");
}
