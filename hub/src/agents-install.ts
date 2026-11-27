import { cliText } from "./agent-cli/locale.ts";
import type { Lang } from "./i18n/language.ts";
import { chmodSync, copyFileSync, readdirSync, lstatSync, existsSync, mkdirSync, readFileSync, renameSync, statSync, unlinkSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { basename, dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { spawnSync } from "node:child_process";

import { agentBinDirectories } from "./agent-path.ts";
import { redactString } from "./redact.ts";
import { tools as mcpTools } from "./agent-cli/mcp.ts";

export const AGENT_TOOLS = ["claude-code", "codex", "claude-desktop", "antigravity"] as const;
/** 在 Claude Code、Codex 里登记的服务名。旧版用 record-anything，连接、断开和升级时一并清理或迁移。 */
export const SERVER = "tacit", LEGACY_SERVER = "record-anything";
export type AgentTool = typeof AGENT_TOOLS[number];

/** 失败只带固定类别给日志和诊断（code），界面另给大白话，不显示原文。 */
export class AgentCommandError extends Error {
  override name = "AgentCommandError";
  constructor(message: string, readonly code: "agent_spawn_failed" | "agent_mcp_get_failed" | "agent_mcp_update_failed") { super(message); }
}
export class AgentConfigError extends Error {
  override name = "AgentConfigError";
  constructor(message: string, readonly code: "agent_config_invalid_json" | "agent_config_invalid_schema" | "agent_config_conflict") { super(message); }
}

type Json = Record<string, any>;
export interface InstallEnvironment {
  lang?: Lang;
  home?: string; repo?: string; bun?: string;
  variables?: NodeJS.ProcessEnv;
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
export const antigravityConfig = ".gemini/config/mcp_config.json";
export const antigravityHooks = ".gemini/config/hooks.json";

function appInstalled(app: string, home: string, env: InstallEnvironment): boolean {
  const exists = env.appExists ?? existsSync;
  return exists(`/Applications/${app}.app`) || exists(resolve(home, `Applications/${app}.app`));
}
function findAgentExecutable(command: string, home: string, env: InstallEnvironment): string | null {
  if (env.which) return env.which(command);
  const path = (env.variables ?? process.env).PATH;
  return Bun.which(command, { PATH: path }) ?? Bun.which(command, { PATH: agentBinDirectories(home).join(":") });
}

const desktopInstalled = (home: string, env: InstallEnvironment) => appInstalled("Claude", home, env);
const antigravityInstalled = (home: string, env: InstallEnvironment) =>
  !!findAgentExecutable("agy", home, env) || appInstalled("Antigravity", home, env);

const mcpEntry = (cli: string, bun: string, tool: string) => ({ command: bun, args: [cli, "mcp", "--tool", tool] });
function agentRuntime(env: InstallEnvironment) {
  const repo = resolve(env.repo ?? fileURLToPath(new URL("../../", import.meta.url)));
  return { bun: resolve(env.bun ?? process.execPath), cli: resolve(repo, "hub/src/cli.ts") };
}

export function otherMcpConfig(env: InstallEnvironment = {}) {
  const { cli, bun } = agentRuntime(env);
  return mcpEntry(cli, bun, "mcp");
}

export function ownsMcpEntry(value: unknown, tool: string): value is Json {
  return object(value) && typeof value.command === "string" && Array.isArray(value.args) && value.args.length === 4
    && typeof value.args[0] === "string" && value.args[0].endsWith("/hub/src/cli.ts")
    && value.args.slice(1).join("\n") === `mcp\n--tool\n${tool}`;
}

/** 认出旧版写入的会话开始钩子（2026-11-27 起不再写入，连接、断开和升级时删掉）。 */
export function sessionStartCommandPaths(command: unknown, tool: string): string[] | null {
  const tokens = typeof command === "string" ? words(command) : null;
  return tokens?.length === 6 && tokens[1]?.endsWith("/hub/src/cli.ts")
    && tokens.slice(2).join("\n") === `hook\nsession-start\n--tool\n${tool}` ? tokens : null;
}

function jsonFile(file: string, lang: Lang) {
  const existed = existsSync(file), before = existed ? readFileSync(file, "utf8") : "";
  let data: unknown;
  try { data = existed ? JSON.parse(before) : {}; }
  catch { throw new AgentConfigError(cliText(`${file} 不是合法 JSON，未写入配置`, `${file} contains invalid JSON. The configuration was not saved.`, lang), "agent_config_invalid_json"); }
  if (!object(data)) throw new AgentConfigError(cliText(`${file} 的配置结构无效，未写入配置`, `The configuration in ${file} has an invalid structure and was not saved.`, lang), "agent_config_invalid_schema");
  return { file, existed, before, data };
}

function mcpFile(file: string, tool: "claude-desktop" | "antigravity", install: boolean, cli: string, bun: string, lang: Lang) {
  const { data, ...plan } = jsonFile(file, lang);
  if (data.mcpServers !== undefined && !object(data.mcpServers)) throw new AgentConfigError(cliText(`${file} 的 mcpServers 结构无效，未写入配置`, `The mcpServers section in ${file} is invalid. The configuration was not saved.`, lang), "agent_config_invalid_schema");
  const current = data.mcpServers?.[SERVER];
  if (Object.hasOwn(data.mcpServers ?? {}, SERVER) && !ownsMcpEntry(current, tool)) {
    const name = LABELS[tool];
    throw new AgentConfigError(cliText(`${name} 中的 ${SERVER} 名称已被其他配置占用，请先在 ${name} 中检查该配置`, `Another ${name} connection already uses the name ${SERVER}. Check that connection first.`, lang), "agent_config_conflict");
  }
  const legacy = ownsMcpEntry(data.mcpServers?.[LEGACY_SERVER], tool);
  if (!install && current === undefined && !legacy) return { ...plan, after: plan.before };
  if (legacy) delete data.mcpServers[LEGACY_SERVER];
  if (install) {
    const entry: Json = tool === "antigravity"
      ? { ...(ownsMcpEntry(current, tool) ? current : {}), ...mcpEntry(cli, bun, tool) }
      : mcpEntry(cli, bun, tool);
    if (entry.disabled === true) delete entry.disabled;
    if (!legacy && JSON.stringify(current) === JSON.stringify(entry)) return { ...plan, after: plan.before };
    data.mcpServers ??= {};
    data.mcpServers[SERVER] = entry;
  } else {
    delete data.mcpServers[SERVER];
    if (!Object.keys(data.mcpServers).length) delete data.mcpServers;
  }
  return { ...plan, after: JSON.stringify(data, null, 2) + "\n" };
}

function antigravityHookFile(file: string, lang: Lang) {
  const { data, ...plan } = jsonFile(file, lang);
  const group = data[SERVER];
  const ours = (hook: unknown) => object(hook) && sessionStartCommandPaths(hook.command, "antigravity") !== null;
  // 同名但不是本应用写的钩子组不归我们管，原样留着。
  if (!object(group) || !Array.isArray(group.SessionStart) || !group.SessionStart.some(ours)) return { ...plan, after: plan.before };
  const before = group.SessionStart;
  const next = before.filter((hook: unknown) => !ours(hook));
  if (JSON.stringify(before) === JSON.stringify(next)) return { ...plan, after: plan.before };
  if (next.length) data[SERVER] = { ...group, SessionStart: next };
  else {
    delete group.SessionStart;
    if (!Object.keys(group).some(key => key !== "enabled")) delete data[SERVER];
  }
  return { ...plan, after: JSON.stringify(data, null, 2) + "\n" };
}

// 预览只展示 Tacit 管理的字段，其他服务器与钩子可能含凭据。
function antigravityDiff(plan: ReturnType<typeof antigravityHookFile>, isHook: boolean) {
  const selection = (text: string) => {
    const data = text ? JSON.parse(text) : {};
    if (isHook) {
      const hooks = (data[SERVER]?.SessionStart ?? []).flatMap((hook: Json) => {
        const command = sessionStartCommandPaths(hook?.command, "antigravity");
        return command ? [{ type: hook.type, command: hook.command, timeout: hook.timeout }] : [];
      });
      return hooks.length ? JSON.stringify({ [SERVER]: { SessionStart: hooks } }, null, 2) : "";
    }
    const servers = Object.fromEntries([SERVER, LEGACY_SERVER].flatMap(name => {
      const entry = data.mcpServers?.[name];
      return ownsMcpEntry(entry, "antigravity") ? [[name, { command: entry.command, args: entry.args }]] : [];
    }));
    return Object.keys(servers).length ? JSON.stringify({ mcpServers: servers }, null, 2) : "";
  };
  return redactString(diff(plan.file, selection(plan.before), selection(plan.after), plan.existed)).text;
}

// 用一整个 hunk 展示原文和目标，预览本身不创建临时文件。
function diff(file: string, before: string, after: string, existed: boolean) {
  const lines = (text: string) => text ? text.replace(/\n$/, "").split("\n") : [];
  const a = lines(before), b = lines(after);
  return [`--- ${existed ? file : "/dev/null"}`, `+++ ${file}`, `@@ -${a.length ? 1 : 0},${a.length} +${b.length ? 1 : 0},${b.length} @@`,
    ...a.map(line => `-${line}`), ...(before && !before.endsWith("\n") ? ["\\ No newline at end of file"] : []), ...b.map(line => `+${line}`)].join("\n");
}
/** 删掉旧版写入的会话开始钩子，其他钩子原样保留；没有时不改、不建文件。 */
function hookFile(file: string, lang: Lang = "zh") {
  const existed = existsSync(file), before = existed ? readFileSync(file, "utf8") : "";
  let data: Json;
  try { data = existed ? JSON.parse(before) : {}; } catch { throw new AgentConfigError(cliText("配置文件不是合法 JSON，未写入配置。", "The configuration contains invalid JSON and was not saved.", lang), "agent_config_invalid_json"); }
  if (!object(data) || data.hooks !== undefined && !object(data.hooks) || data.hooks?.SessionStart !== undefined && !Array.isArray(data.hooks.SessionStart)) throw new AgentConfigError(cliText("配置文件结构无效，未写入配置。", "The configuration has an invalid structure and was not saved.", lang), "agent_config_invalid_schema");
  // 按 shell 规则拆开再比，加没加引号都认得（2026-11-19：升级迁移写的全引号命令曾被当成没连接）。
  const ours = (hook: any) => {
    if (!object(hook) || typeof hook.command !== "string") return false;
    const tokens = words(hook.command);
    // 任何一份 Tacit 的旧钩子都删：这个功能已经撤下，留着只会在会话开始时空跑一次。
    return !!tokens && !!tokens[1]?.endsWith("/hub/src/cli.ts") && tokens[2] === "hook" && tokens[3] === "session-start";
  };
  if (!(data.hooks?.SessionStart ?? []).some((row: any) => object(row) && Array.isArray(row.hooks) && row.hooks.some(ours))) return { file, existed, before, after: before };
  const rows: any[] = [];
  for (const row of data.hooks.SessionStart) {
    if (!object(row) || !Array.isArray(row.hooks) || !row.hooks.some(ours)) { rows.push(row); continue; }
    const remaining = row.hooks.filter((hook: any) => !ours(hook));
    if (remaining.length) rows.push({ ...row, hooks: remaining });
  }
  if (rows.length) data.hooks.SessionStart = rows;
  else { delete data.hooks.SessionStart; if (!Object.keys(data.hooks).length) delete data.hooks; }
  return { file, existed, before, after: JSON.stringify(data, null, 2) + "\n" };
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
/** `only` 限定只补这些工具的规则（升级时只补新加的工具，不把用户删掉的规则加回来）。 */
export function codexApprovals(file: string, install: boolean, preserved: string[] = [], server: string = SERVER, text?: string, only?: string[]) {
  const existed = text !== undefined || existsSync(file), before = text ?? (existed ? readFileSync(file, "utf8") : "");
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
    const missing = mcpTools.filter(tool => !Object.hasOwn(target, tool.name) && (!only || only.includes(tool.name)));
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
  const lang = env.lang ?? "zh";
  const t = (zh: string, en: string) => cliText(zh, en, lang);
  const [action, ...flags] = argv;
  if (action !== "install" && action !== "uninstall") throw new Error(t("用法：agents <install|uninstall> [--tool claude-code|codex|claude-desktop|antigravity] [--yes]", "Usage: agents <install|uninstall> [--tool claude-code|codex|claude-desktop|antigravity] [--yes]"));
  let selected: AgentTool | undefined, yes = false;
  for (let i = 0; i < flags.length; i++) {
    if (flags[i] === "--yes") yes = true;
    else if (flags[i] === "--tool" && !selected && AGENT_TOOLS.includes(flags[i + 1] as AgentTool)) selected = flags[++i] as AgentTool;
    else throw new Error(t("agents 参数无效", "Invalid agents arguments"));
  }
  const home = resolve(env.home ?? homedir());
  const { bun, cli } = agentRuntime(env);
  const print = env.print ?? console.log;
  // 只有目标不是真实家目录（测试用临时 HOME）时才覆盖环境变量：对真实用户设置 CLAUDE_CONFIG_DIR
  // 会让 claude 把全局配置写到 ~/.claude/.claude.json，而不是平时用的 ~/.claude.json。
  const run = env.run ?? ((command, args, home) => spawnSync(command, args, { encoding: "utf8", env: home === resolve(homedir()) ? process.env : { ...process.env, HOME: home, CODEX_HOME: resolve(home, ".codex"), CLAUDE_CONFIG_DIR: resolve(home, ".claude") }, timeout: 30000 }));
  const tools: AgentTool[] = selected ? [selected] : ["claude-code", "codex"];
  if (!selected && action === "uninstall" && existsSync(desktopConfig(home))) tools.push("claude-desktop");
  if (action === "install" && tools.includes("claude-desktop") && !desktopInstalled(home, env)) throw new Error(t("这台 Mac 上没找到 Claude Desktop，安装后再连接。", "Claude Desktop was not found on this Mac. Install it before connecting."));
  if (!selected && action === "uninstall" && [antigravityConfig, antigravityHooks].some(file => existsSync(resolve(home, file)))) tools.push("antigravity");
  if (action === "install" && tools.includes("antigravity") && !antigravityInstalled(home, env)) throw new Error(t("这台 Mac 上没找到 Antigravity，安装后再连接。", "Antigravity was not found on this Mac. Install it before connecting."));
  // 先预检配置；显式断开 Antigravity 时两份文件都必须能安全更新。
  const desktopPlan = tools.includes("claude-desktop") ? mcpFile(desktopConfig(home), "claude-desktop", action === "install", cli, bun, lang) : undefined;
  const planAntigravity = () => [
    mcpFile(resolve(home, antigravityConfig), "antigravity", action === "install", cli, bun, lang),
    antigravityHookFile(resolve(home, antigravityHooks), lang),
  ];
  let antigravityPlans: ReturnType<typeof planAntigravity> = [];
  if (tools.includes("antigravity")) {
    if (selected) antigravityPlans = planAntigravity();
    else {
      try {
        const plans = planAntigravity();
        if (plans.some(plan => plan.before !== plan.after)) antigravityPlans = plans;
        else print(t("跳过 Antigravity：没有 Tacit 的连接配置。", "Skipping Antigravity. No Tacit connection was found."));
      } catch {
        print(t("跳过 Antigravity：无法安全清理连接配置。", "Skipping Antigravity. Its connection settings could not be safely cleaned up."));
      }
    }
  }
  const cliTools = tools.filter(tool => tool === "claude-code" || tool === "codex");
  // 连接和断开都清掉旧版的会话开始钩子：上下文改由 AI 调用 MCP 的 project 自己查（2026-11-27）。
  const plans = cliTools.map(tool => hookFile(resolve(home, tool === "codex" ? ".codex/hooks.json" : ".claude/settings.json"), lang));
  const commands = cliTools.map(tool => ({ tool, command: findAgentExecutable(tool === "codex" ? "codex" : "claude", home, env) }));
  const codexFile = resolve(home, ".codex/config.toml");
  // 提前校验 TOML，避免改完 MCP 后才发现原配置损坏。
  const approvalPlan = tools.includes("codex") ? codexApprovals(codexFile, action === "install") : undefined;
  const legacyApprovals = tools.includes("codex") ? codexApprovals(codexFile, false, [], LEGACY_SERVER).preserved : [];
  print(yes ? t("将执行以下改动：", "The following changes will be applied:") : t("预览（未写入；加 --yes 执行）：", "Preview. Add --yes to apply these changes."));
  for (const plan of plans) {
    if (plan.before !== plan.after) print(diff(plan.file, plan.before, plan.after, plan.existed));
    else print(t(`${plan.file}：无需改动`, `${plan.file}: No changes needed`));
  }
  // Desktop 配置含其他连接器及用户偏好，预览不输出原文或凭据。
  if (desktopPlan) {
    const unchanged = desktopPlan.before === desktopPlan.after;
    const zh = unchanged ? "无需改动" : `${action === "install" ? "登记" : "移除"} Tacit 查询服务（保留其他配置）`;
    const en = unchanged ? "No changes needed" : `${action === "install" ? "Connect" : "Disconnect"} Tacit, keeping other settings`;
    print(t(`${desktopPlan.file}：${zh}`, `${desktopPlan.file}: ${en}`));
  }
  for (const [index, plan] of antigravityPlans.entries()) {
    print(plan.before === plan.after ? t(`${plan.file}：无需改动`, `${plan.file}: No changes needed`) : antigravityDiff(plan, index === 1));
  }
  const apply = () => {
    for (const { tool, command } of commands) {
      if (!command) {
        const name = tool === "codex" ? "codex" : "claude";
        print(t(`找不到 ${name}，跳过 MCP 注册/移除`, `Could not find ${name}. Skipping MCP setup.`));
        continue;
      }
      const remove = (name: string) => tool === "codex" ? ["mcp", "remove", name] : ["mcp", "remove", "--scope", "user", name];
      const add = ["mcp", "add", ...(tool === "codex" ? [] : ["--scope", "user"]), SERVER, "--", bun, cli, "mcp", "--tool", tool];
      const get = (name: string) => ["mcp", "get", name];
      print(`$ ${[command, ...get(SERVER)].map(quote).join(" ")}`);
      print(t("已注册时执行：", "If registered: ") + [command, ...remove(SERVER)].map(quote).join(" "));
      print(t("旧名称已注册时执行：", "If the old name is registered: ") + [command, ...remove(LEGACY_SERVER)].map(quote).join(" "));
      if (action === "install") print(`$ ${[command, ...add].map(quote).join(" ")}`);
      if (tool === "codex" && !yes && approvalPlan && approvalPlan.before !== approvalPlan.after) print(approvalDiff(approvalPlan));
      if (yes) {
        const execute = (args: string[]) => {
          try { return run(command, args, home); }
          catch { throw new AgentCommandError(t("无法启动 AI 工具。", "Could not start the AI tool."), "agent_spawn_failed"); }
        };
        const registered = (name: string) => {
          const result = execute(get(name));
          if (result.status !== 0 && !/not found|no .*server|does not exist|未找到|不存在/i.test(result.stderr + result.stdout)) throw new AgentCommandError(t(`查询失败，未继续${action === "install" ? "连接" : "断开"}。`, "Could not check the current MCP registration. No connection changes were made."), "agent_mcp_get_failed");
          return result.status === 0;
        };
        const current = registered(SERVER), legacy = registered(LEGACY_SERVER);
        if (tool === "codex" && approvalPlan?.existed) backupConnection(codexFile);
        for (const args of [...(legacy ? [remove(LEGACY_SERVER)] : []), ...(current ? [remove(SERVER)] : []), ...(action === "install" ? [add] : [])]) {
          if (execute(args).status !== 0) throw new AgentCommandError(t("无法更新 AI 工具的连接。", "Could not update the AI tool connection."), "agent_mcp_update_failed");
        }
        if (tool === "codex") {
          // 依次读取并保存：第二步必须基于第一步写入后的文件。
          for (const next of [() => codexApprovals(codexFile, false, [], LEGACY_SERVER), () => codexApprovals(codexFile, action === "install", [...(approvalPlan?.preserved ?? []), ...legacyApprovals])]) {
            const plan = next();
            if (plan.before !== plan.after) { print(approvalDiff(plan)); saveConnectionPlan(plan); }
          }
          if (existsSync(dirname(codexFile))) pruneConnectionBackups(codexFile);
        }
      }
    }
    if (yes) for (const plan of [...plans, ...antigravityPlans]) if (plan.before !== plan.after) saveConnectionPlan(plan);
    if (yes && desktopPlan && desktopPlan.before !== desktopPlan.after) saveConnectionPlan(desktopPlan);
    if (desktopPlan) print(t("完全退出并重新打开 Claude Desktop 后生效；连接后可让它查询历史记录。", "Quit and reopen Claude Desktop to apply the change."));
  };
  if (yes && action === "install" && (cliTools.length || antigravityPlans.length) && registerIdentity) {
    // 登记失败（中枢没在运行等）不挡接入：没有身份时 agent-cli 退回本机令牌（6.10.6 双栈），之后再接入一次即可补上。
    return registerIdentity().catch(error => print(t(
      `暂未登记 AI 工具的设备身份（${error instanceof Error ? error.message : "原因未知"}），先用本机令牌接入。`,
      "AI tool identity registration failed. Using the local token for this connection.",
    ))).then(apply);
  }
  apply();
}

export interface AgentState {
  id: string;
  label: string;
  /** 本机找得到应用或命令行工具。 */
  installed: boolean;
  /** 已登记 Tacit 的 MCP 查询服务。 */
  connected: boolean;
  /** 只登记了一半（例如手动删过其中一个），需要重新连接。 */
  partial: boolean;
}

const LABELS: Record<AgentTool, string> = { "claude-code": "Claude Code", codex: "Codex", "claude-desktop": "Claude Desktop", antigravity: "Antigravity" };

/** 只读配置文件判断是否已接入，不调用外部命令：设置页每次打开都会查，不能卡住中枢。 */
export function agentStatus(env: InstallEnvironment = {}): AgentState[] {
  const home = resolve(env.home ?? homedir());
  const { bun, cli } = agentRuntime(env);
  const read = (file: string) => { try { return readFileSync(file, "utf8"); } catch { return null; } };
  return AGENT_TOOLS.map(id => {
    if (id === "claude-desktop") {
      let connected = false, partial = false;
      try {
        const text = read(desktopConfig(home));
        const data = text ? JSON.parse(text) : {};
        const entry = data?.mcpServers?.[SERVER];
        connected = ownsMcpEntry(entry, id) && entry.command === bun && entry.args[0] === cli && entry.disabled !== true;
        partial = (Object.hasOwn(data?.mcpServers ?? {}, SERVER) || ownsMcpEntry(data?.mcpServers?.[LEGACY_SERVER], id)) && !connected;
      } catch { partial = true; }
      return { id, label: LABELS[id], installed: desktopInstalled(home, env), connected, partial };
    }
    if (id === "antigravity") {
      let mcp = false, configured = false;
      try {
        const data = JSON.parse(read(resolve(home, antigravityConfig)) ?? "{}");
        const entry = data?.mcpServers?.[SERVER];
        mcp = ownsMcpEntry(entry, id) && entry.command === bun && entry.args[0] === cli && entry.disabled !== true;
        configured = Object.hasOwn(data?.mcpServers ?? {}, SERVER) || ownsMcpEntry(data?.mcpServers?.[LEGACY_SERVER], id);
      } catch { configured = true; }
      return { id, label: LABELS[id], installed: antigravityInstalled(home, env), connected: mcp, partial: configured && !mcp };
    }
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
    return { id, label: LABELS[id], installed: !!findAgentExecutable(id === "codex" ? "codex" : "claude", home, env), connected: mcp, partial: false };
  });
}

/** 设置页的"连接 / 断开"：等同 `agents install|uninstall --tool <id> --yes`，返回执行后的状态。 */
export function connectAgent(id: AgentTool, connect: boolean, env: InstallEnvironment = {}): { states: AgentState[]; note: string | null } {
  const output: string[] = [];
  runAgents([connect ? "install" : "uninstall", "--tool", id, "--yes"], { ...env, print: line => output.push(line) });
  const note = id === "antigravity" ? (connect ? "重开 Antigravity 后生效，它会在首次调用 Tacit 查询时请你批准。" : "重开 Antigravity 后生效。")
    : id === "claude-desktop" ? `完全退出并重新打开 Claude Desktop 后生效。${connect ? "连接后可以问它“我昨天下午在做什么”。" : "重启后将停止提供历史记录查询。"}`
    : null;
  return { states: agentStatus(env), note };
}
