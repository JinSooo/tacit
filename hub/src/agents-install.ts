import { chmodSync, copyFileSync, readdirSync, lstatSync, existsSync, mkdirSync, readFileSync, renameSync, statSync, unlinkSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { basename, dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { spawnSync } from "node:child_process";

import { redactString } from "./redact.ts";
import { tools as mcpTools } from "./agent-cli/mcp.ts";

export const AGENT_TOOLS = ["claude-code", "codex", "claude-desktop"] as const;
/** 在 Claude Code、Codex 里登记的服务名。旧版用 record-anything，连接、断开和升级时一并清理或迁移。 */
export const SERVER = "tacit", LEGACY_SERVER = "record-anything";
export type AgentTool = typeof AGENT_TOOLS[number];
type Json = Record<string, any>;
export interface InstallEnvironment {
  home?: string; repo?: string; bun?: string;
  which?: (command: string) => string | null;
  appExists?: (path: string) => boolean;
  run?: (command: string, args: string[], home: string) => { status: number | null; stdout: string; stderr: string };
  print?: (text: string) => void;
}
export const quote = (value: string) => /^[\w/.:=-]+$/.test(value) ? value : `'${value.replaceAll("'", "'\\''")}'`;
/** 只解析本应用生成的简单命令，不执行 shell 或展开变量。 */
export function words(s: string): string[] | null {
  const result: string[] = []; let value = "", active = false, mode = "";
  for (let i = 0; i < s.length; i++) {
    const c = s[i]!;
    if (mode) {
      if (c === mode) mode = "";
      else if (c === "\\" && mode === '"') { if (++i >= s.length) return null; value += s[i]; }
      else value += c;
    } else if (c === "'" || c === '"') { mode = c; active = true; }
    else if (c === "\\") { if (++i >= s.length) return null; value += s[i]; active = true; }
    else if (/\s/.test(c)) { if (active) { result.push(value); value = ""; active = false; } }
    else { if (/[;$`|&<>]/.test(c)) return null; value += c; active = true; }
  }
  if (mode) return null;
  if (active) result.push(value);
  return result;
}
const object = (value: unknown): value is Json => value !== null && typeof value === "object" && !Array.isArray(value);

const desktopConfig = (home: string) => resolve(home, "Library/Application Support/Claude/claude_desktop_config.json");
function desktopInstalled(home: string, env: InstallEnvironment): boolean {
  const exists = env.appExists ?? existsSync;
  return exists("/Applications/Claude.app") || exists(resolve(home, "Applications/Claude.app"));
}
const desktopEntry = (cli: string, bun: string) => ({ command: bun, args: [cli, "mcp", "--tool", "claude-desktop"] });
function ownsDesktopEntry(value: unknown): value is Json {
  return object(value) && Array.isArray(value.args) && value.args.length === 4
    && typeof value.args[0] === "string" && value.args[0].endsWith("/hub/src/cli.ts")
    && value.args.slice(1).join("\n") === "mcp\n--tool\nclaude-desktop";
}
function desktopFile(home: string, install: boolean, cli: string, bun: string) {
  const file = desktopConfig(home), existed = existsSync(file), before = existed ? readFileSync(file, "utf8") : "";
  let data: Json;
  try { data = existed ? JSON.parse(before) : {}; } catch { throw new Error(`${file} 不是合法 JSON，未写入配置`); }
  if (!object(data) || data.mcpServers !== undefined && !object(data.mcpServers)) throw new Error(`${file} 的 mcpServers 结构无效，未写入配置`);
  const current = data.mcpServers?.[SERVER];
  if (Object.hasOwn(data.mcpServers ?? {}, SERVER) && !ownsDesktopEntry(current)) {
    throw new Error(`Claude Desktop 中的 ${SERVER} 名称已被其他配置占用，请先在 Claude Desktop 中检查该配置`);
  }
  const legacy = ownsDesktopEntry(data.mcpServers?.[LEGACY_SERVER]);
  if (!install && current === undefined && !legacy) return { file, existed, before, after: before };
  if (legacy) delete data.mcpServers[LEGACY_SERVER];
  if (install) {
    const entry = desktopEntry(cli, bun);
    if (!legacy && JSON.stringify(current) === JSON.stringify(entry)) return { file, existed, before, after: before };
    data.mcpServers ??= {};
    data.mcpServers[SERVER] = entry;
  } else {
    delete data.mcpServers[SERVER];
    if (!Object.keys(data.mcpServers).length) delete data.mcpServers;
  }
  return { file, existed, before, after: JSON.stringify(data, null, 2) + "\n" };
}

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
  // 按 shell 规则拆开再比，加没加引号都认得（2026-11-19：升级迁移写的全引号命令曾被当成没连接）。
  const ours = (hook: any) => {
    if (!object(hook) || typeof hook.command !== "string") return false;
    const tokens = words(hook.command);
    return !!tokens && tokens[1] === cli && tokens[2] === "hook" && tokens[3] === "session-start";
  };
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
/** 每个配置只留最近一份；只清理本应用命名的普通文件。 */
export function pruneConnectionBackups(file: string): number {
  const prefix = `${basename(file)}.ra-backup-`;
  const backups = readdirSync(dirname(file)).filter(name => name.startsWith(prefix) && /^\d+-[0-9a-f-]+$/.test(name.slice(prefix.length)))
    .map(name => ({ name, path: resolve(dirname(file), name) }))
    .filter(item => lstatSync(item.path).isFile()).sort((a, b) => b.name.localeCompare(a.name));
  for (const item of backups) chmodSync(item.path, 0o600);
  for (const item of backups.slice(1)) unlinkSync(item.path);
  return Math.max(0, backups.length - 1);
}
function backupConnection(file: string) {
  const prefix = `${basename(file)}.ra-backup-`;
  const previous = readdirSync(dirname(file)).filter(n => n.startsWith(prefix)).map(n => Number(n.slice(prefix.length).split("-")[0])).filter(Number.isFinite);
  const stamp = Math.max(Date.now(), ...previous.map(n => n + 1));
  const backup = `${file}.ra-backup-${stamp}-${crypto.randomUUID()}`;
  copyFileSync(file, backup); chmodSync(backup, 0o600);
}
export function saveConnectionPlan(plan: ReturnType<typeof hookFile>) {
  const mode = plan.existed ? statSync(plan.file).mode & 0o7777 : 0o600;
  if (plan.existed) backupConnection(plan.file);
  mkdirSync(dirname(plan.file), { recursive: true });
  const temp = `${plan.file}.ra-tmp-${crypto.randomUUID()}`;
  try {
    writeFileSync(temp, plan.after, { mode, flag: "wx" });
    chmodSync(temp, mode);
    renameSync(temp, plan.file);
    pruneConnectionBackups(plan.file);
  } finally { if (existsSync(temp)) unlinkSync(temp); }
}

// 配置可能包含其他服务的凭据，预览仅展示实际变动的行。
function approvalDiff(plan: ReturnType<typeof codexApprovals>) {
  const before = plan.before.split("\n"), after = plan.after.split("\n");
  let first = 0, tail = 0;
  while (first < Math.min(before.length, after.length) && before[first] === after[first]) first++;
  while (tail < Math.min(before.length, after.length) - first && before[before.length - tail - 1] === after[after.length - tail - 1]) tail++;
  return redactString([`--- ${plan.existed ? plan.file : "/dev/null"}`, `+++ ${plan.file}`,
    `@@ -${first + 1},${before.length - first - tail} +${first + 1},${after.length - first - tail} @@`,
    ...before.slice(first, before.length - tail).map(line => `-${line}`), ...after.slice(first, after.length - tail).map(line => `+${line}`)].join("\n")).text;
}

// 只定位普通 TOML 表；解析表头以兼容引号和空白，不重排其余文本。
function codexApprovals(file: string, install: boolean, preserved: string[] = [], server: string = SERVER) {
  const existed = existsSync(file), before = existed ? readFileSync(file, "utf8") : "";
  const data = Bun.TOML.parse(before) as Json;
  const target = data.mcp_servers?.[server]?.tools ?? {};
  const names = new Set(mcpTools.map(tool => tool.name));
  const sections: { start: number; end: number; path: string[] }[] = [];
  let offset = 0, multiline = "";
  for (const line of before.split(/(?<=\n)/)) {
    const header = !multiline && line.match(/^\s*(\[(?!\[).*?\])\s*(?:#.*)?(?:\r?\n)?$/);
    if (!multiline && /^\s*\[\[/.test(line)) {
      if (sections.length) sections[sections.length - 1]!.end = offset;
      sections.push({ start: offset, end: before.length, path: [] });
    }
    if (header) {
      const parsed = Bun.TOML.parse(`${header[1]}\n__ra_marker = true`);
      const keys: string[] = [];
      let node = parsed as Json;
      while (!("__ra_marker" in node)) { const key = Object.keys(node)[0]!; keys.push(key); node = node[key]; }
      if (sections.length) sections[sections.length - 1]!.end = offset;
      sections.push({ start: offset, end: before.length, path: keys });
    }
    // 多行字符串里的表头是用户数据，不能作为配置段处理。
    const tokens = line.match(/"""|'''|"(?:\\.|[^"\\])*"|'[^']*'|#.*$/g) ?? [];
    for (const token of tokens) {
      if (multiline) { if (token === multiline) multiline = ""; }
      else if (token.startsWith("#")) break;
      else if (token === "'''" || token === '"""') multiline = token;
    }
    offset += line.length;
  }
  const ours = (keys: string[]) => keys.length === 4 && keys[0] === "mcp_servers" && keys[1] === server && keys[2] === "tools" && names.has(keys[3]!);
  let after = before;
  if (install) {
    const missing = mcpTools.filter(tool => !Object.hasOwn(target, tool.name));
    const additions = missing.map(tool => preserved.find(text => {
      const parsed = Bun.TOML.parse(text) as Json;
      const tools = parsed.mcp_servers?.[server]?.tools ?? parsed.mcp_servers?.[LEGACY_SERVER]?.tools ?? {};
      return Object.hasOwn(tools, tool.name);
    // 只读工具默认免确认；写入工具（history_append）每次都要用户在 Codex 里确认。旧服务名下的用户规则改到新名下沿用。
    })?.replace(new RegExp(`^(\\s*\\[\\s*mcp_servers\\s*\\.\\s*)(?:"${LEGACY_SERVER}"|${LEGACY_SERVER})(?=\\s*\\.)`, "m"), `$1${server}`)
      ?? `[mcp_servers.${server}.tools.${tool.name}]\napproval_mode = "${tool.annotations.readOnlyHint ? "approve" : "prompt"}"\n`).join("\n");
    if (additions) {
      const parent = sections.find(section => section.path.join(".") === `mcp_servers.${server}`);
      const at = parent?.end ?? before.length;
      after = before.slice(0, at) + (at && before[at - 1] !== "\n" ? "\n" : "") + "\n" + additions + "\n" + before.slice(at);
    }
  } else {
    for (const section of sections.filter(section => ours(section.path)).reverse()) after = after.slice(0, section.start) + after.slice(section.end);
  }
  Bun.TOML.parse(after);
  return { file, existed, before, after, preserved: sections.filter(section => ours(section.path)).map(section => before.slice(section.start, section.end)) };
}

export function runAgents(argv: string[], env: InstallEnvironment = {}, registerIdentity?: () => Promise<unknown>) {
  const [action, ...flags] = argv;
  if (action !== "install" && action !== "uninstall") throw new Error("用法：agents <install|uninstall> [--tool claude-code|codex|claude-desktop] [--yes]");
  let selected: AgentTool | undefined, yes = false;
  for (let i = 0; i < flags.length; i++) {
    if (flags[i] === "--yes") yes = true;
    else if (flags[i] === "--tool" && !selected && AGENT_TOOLS.includes(flags[i + 1] as AgentTool)) selected = flags[++i] as AgentTool;
    else throw new Error("agents 参数无效");
  }
  const home = resolve(env.home ?? homedir()), repo = resolve(env.repo ?? fileURLToPath(new URL("../../", import.meta.url)));
  const bun = resolve(env.bun ?? process.execPath), cli = resolve(repo, "hub/src/cli.ts");
  const print = env.print ?? console.log, which = env.which ?? (command => Bun.which(command));
  // 只有目标不是真实家目录（测试用临时 HOME）时才覆盖环境变量：对真实用户设置 CLAUDE_CONFIG_DIR
  // 会让 claude 把全局配置写到 ~/.claude/.claude.json，而不是平时用的 ~/.claude.json。
  const run = env.run ?? ((command, args, home) => spawnSync(command, args, { encoding: "utf8", env: home === resolve(homedir()) ? process.env : { ...process.env, HOME: home, CODEX_HOME: resolve(home, ".codex"), CLAUDE_CONFIG_DIR: resolve(home, ".claude") }, timeout: 30000 }));
  const tools: AgentTool[] = selected ? [selected] : ["claude-code", "codex"];
  if (!selected && action === "uninstall" && existsSync(desktopConfig(home))) tools.push("claude-desktop");
  if (action === "install" && tools.includes("claude-desktop") && !desktopInstalled(home, env)) throw new Error("这台 Mac 上没找到 Claude Desktop，安装后再连接");
  // 全部解析成功后才可能写入，防止第二份 JSON 无效时已改第一份。
  const desktopPlan = tools.includes("claude-desktop") ? desktopFile(home, action === "install", cli, bun) : undefined;
  const cliTools = tools.filter(tool => tool !== "claude-desktop");
  const plans = cliTools.map(tool => hookFile(resolve(home, tool === "codex" ? ".codex/hooks.json" : ".claude/settings.json"), action === "install", cli, bun, tool));
  const commands = cliTools.map(tool => ({ tool, command: which(tool === "codex" ? "codex" : "claude") }));
  const codexFile = resolve(home, ".codex/config.toml");
  // 提前校验 TOML，避免改完 MCP 后才发现原配置损坏。
  const approvalPlan = tools.includes("codex") ? codexApprovals(codexFile, action === "install") : undefined;
  const legacyApprovals = tools.includes("codex") ? codexApprovals(codexFile, false, [], LEGACY_SERVER).preserved : [];
  print(yes ? "将执行以下改动：" : "预览（未写入；加 --yes 执行）：");
  for (const plan of plans) {
    if (plan.before !== plan.after) print(diff(plan.file, plan.before, plan.after, plan.existed));
    else print(`${plan.file}：无需改动`);
  }
  // Desktop 配置含其他连接器及用户偏好，预览不输出原文或凭据。
  if (desktopPlan) print(`${desktopPlan.file}：${desktopPlan.before === desktopPlan.after ? "无需改动" : `${action === "install" ? "登记" : "移除"} Tacit 查询服务（保留其他配置）`}`);
  const apply = () => {
    for (const { tool, command } of commands) {
      if (!command) { print(`找不到 ${tool === "codex" ? "codex" : "claude"}，跳过 MCP 注册/移除`); continue; }
      const remove = (name: string) => tool === "codex" ? ["mcp", "remove", name] : ["mcp", "remove", "--scope", "user", name];
      const add = ["mcp", "add", ...(tool === "codex" ? [] : ["--scope", "user"]), SERVER, "--", bun, cli, "mcp", "--tool", tool];
      const get = (name: string) => ["mcp", "get", name];
      print(`$ ${[command, ...get(SERVER)].map(quote).join(" ")}`);
      print(`已注册时执行：${[command, ...remove(SERVER)].map(quote).join(" ")}`);
      print(`旧名称已注册时执行：${[command, ...remove(LEGACY_SERVER)].map(quote).join(" ")}`);
      if (action === "install") print(`$ ${[command, ...add].map(quote).join(" ")}`);
      if (tool === "codex" && !yes && approvalPlan && approvalPlan.before !== approvalPlan.after) print(approvalDiff(approvalPlan));
      if (yes) {
        const registered = (name: string) => {
          const result = run(command, get(name), home);
          if (result.status !== 0 && !/not found|no .*server|does not exist|未找到|不存在/i.test(result.stderr + result.stdout)) throw new Error(`${tool} MCP 查询失败，未继续注册`);
          return result.status === 0;
        };
        const current = registered(SERVER), legacy = registered(LEGACY_SERVER);
        if (tool === "codex" && approvalPlan?.existed) backupConnection(codexFile);
        for (const args of [...(legacy ? [remove(LEGACY_SERVER)] : []), ...(current ? [remove(SERVER)] : []), ...(action === "install" ? [add] : [])]) {
          if (run(command, args, home).status !== 0) throw new Error(`${tool} MCP ${args[1]} 失败，请检查该工具配置后重试`);
        }
        if (tool === "codex") {
          // 依次读取并保存：第二步必须基于第一步写入后的文件。
          for (const next of [() => codexApprovals(codexFile, false, [], LEGACY_SERVER), () => codexApprovals(codexFile, action === "install", [...(approvalPlan?.preserved ?? []), ...legacyApprovals])]) {
            const plan = next();
            if (plan.before !== plan.after) { print(approvalDiff(plan)); saveConnectionPlan(plan); }
          }
          pruneConnectionBackups(codexFile);
        }
      }
    }
    if (yes) for (const plan of plans) if (plan.before !== plan.after) saveConnectionPlan(plan);
    if (yes && desktopPlan && desktopPlan.before !== desktopPlan.after) saveConnectionPlan(desktopPlan);
    if (desktopPlan) print("完全退出并重新打开 Claude Desktop 后生效；连接后可让它查询历史记录。");
    if (action === "install" && tools.includes("codex")) print("Codex 新 hook 需要在 Codex 里批准一次（trusted_hash）才会生效。");
  };
  if (yes && action === "install" && cliTools.length && registerIdentity) return registerIdentity().then(apply);
  apply();
}

export interface AgentState {
  id: AgentTool;
  label: string;
  /** 本机找得到应用或命令行工具。 */
  installed: boolean;
  /** 必要配置已登记；Desktop 只需 MCP，编程工具还需会话开始钩子。 */
  connected: boolean;
  /** 只登记了一半（例如手动删过其中一个），需要重新连接。 */
  partial: boolean;
}

const LABELS: Record<AgentTool, string> = { "claude-code": "Claude Code", codex: "Codex", "claude-desktop": "Claude Desktop" };

/** 只读配置文件判断是否已接入，不调用外部命令：设置页每次打开都会查，不能卡住中枢。 */
export function agentStatus(env: InstallEnvironment = {}): AgentState[] {
  const home = resolve(env.home ?? homedir()), repo = resolve(env.repo ?? fileURLToPath(new URL("../../", import.meta.url)));
  const bun = resolve(env.bun ?? process.execPath), cli = resolve(repo, "hub/src/cli.ts");
  const which = env.which ?? (command => Bun.which(command));
  const read = (file: string) => { try { return readFileSync(file, "utf8"); } catch { return null; } };
  return AGENT_TOOLS.map(id => {
    if (id === "claude-desktop") {
      let connected = false, partial = false;
      try {
        const text = read(desktopConfig(home));
        const data = text ? JSON.parse(text) : {};
        const entry = data?.mcpServers?.[SERVER];
        connected = ownsDesktopEntry(entry) && entry.command === bun && entry.args[0] === cli && entry.disabled !== true;
        partial = (Object.hasOwn(data?.mcpServers ?? {}, SERVER) || ownsDesktopEntry(data?.mcpServers?.[LEGACY_SERVER])) && !connected;
      } catch { partial = true; }
      return { id, label: LABELS[id], installed: desktopInstalled(home, env), connected, partial };
    }
    let hook = false;
    try {
      const file = resolve(home, id === "codex" ? ".codex/hooks.json" : ".claude/settings.json");
      const plan = hookFile(file, false, cli, bun, id);
      hook = plan.before !== plan.after;
    } catch {}
    let mcp = false;
    try {
      if (id === "claude-code") {
        const text = read(resolve(home, ".claude.json"));
        mcp = !!text && object(JSON.parse(text)?.mcpServers?.[SERVER]);
      } else {
        const text = read(resolve(home, ".codex/config.toml"));
        mcp = !!text && object((Bun.TOML.parse(text) as Json).mcp_servers?.[SERVER]);
      }
    } catch {}
    return { id, label: LABELS[id], installed: !!which(id === "codex" ? "codex" : "claude"), connected: hook && mcp, partial: hook !== mcp };
  });
}

/** 设置页的"连接 / 断开"：等同 `agents install|uninstall --tool <id> --yes`，返回执行后的状态。 */
export function connectAgent(id: AgentTool, connect: boolean, env: InstallEnvironment = {}): { states: AgentState[]; note: string | null } {
  const output: string[] = [];
  runAgents([connect ? "install" : "uninstall", "--tool", id, "--yes"], { ...env, print: line => output.push(line) });
  const note = id === "claude-desktop" ? `完全退出并重新打开 Claude Desktop 后生效。${connect ? "连接后可以问它“我昨天下午在做什么”。" : "重启后将停止提供历史记录查询。"}`
    : connect && id === "codex" ? "第一次在 Codex 里开新会话时，它会请你批准一次，批准后才会自动带入。" : null;
  return { states: agentStatus(env), note };
}
