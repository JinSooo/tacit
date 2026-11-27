import { readFileSync } from "node:fs";
import { homedir } from "node:os";
import { join, resolve } from "node:path";
import { antigravityConfig, antigravityHooks, LEGACY_SERVER, SERVER, ownsMcpEntry as owns, saveConnectionPlan, sessionStartCommand, sessionStartCommandPaths } from "./agents-install.ts";

const tomlKey = (key: string) => /^[A-Za-z0-9_-]+$/.test(key) ? key : JSON.stringify(key);
/** 把 Codex 配置里 [mcp_servers.record-anything…] 各段的表头改成 tacit，其余文本原样保留；多行字符串里的同形文字不动。 */
function renameCodexServer(text: string, parsed: any): string {
  const legacy = parsed.mcp_servers?.[LEGACY_SERVER];
  // 只改本应用登记的条目；同名的其他服务原样保留。
  if (!owns(legacy, "codex")) return text;
  if (parsed.mcp_servers?.[SERVER] !== undefined) throw new Error(`Codex 配置里已有名为 ${SERVER} 的其他服务，未迁移`);
  let multiline = "", out = "";
  for (const line of text.split(/(?<=\n)/)) {
    const header = !multiline && line.match(/^(\s*)(\[(?!\[).*?\])(.*)$/s);
    let next = line;
    if (header) {
      try {
        let node = Bun.TOML.parse(`${header[2]}\n__ra = true`) as any; const keys: string[] = [];
        while (!("__ra" in node)) { const key = Object.keys(node)[0]!; keys.push(key); node = node[key]; }
        if (keys[0] === "mcp_servers" && keys[1] === LEGACY_SERVER) next = `${header[1]}[${["mcp_servers", SERVER, ...keys.slice(2)].map(tomlKey).join(".")}]${header[3]}`;
      } catch {}
    }
    for (const token of line.match(/"""|'''|"(?:\\.|[^"\\])*"|'[^']*'|#.*$/g) ?? []) {
      if (multiline) { if (token === multiline) multiline = ""; }
      else if (token.startsWith("#")) break;
      else if (token === "'''" || token === '"""') multiline = token;
    }
    out += next;
  }
  const after = Bun.TOML.parse(out) as any;
  if (after.mcp_servers?.[LEGACY_SERVER] !== undefined || JSON.stringify(after.mcp_servers?.[SERVER]) !== JSON.stringify(legacy)) {
    throw new Error("Codex 的连接配置格式无法安全改名，请在设置中重新连接");
  }
  return out;
}

function updateHook(hook: any, tool: string, cli: string, bun: string): boolean {
  const tokens = sessionStartCommandPaths(hook?.command, tool);
  if (!tokens || tokens[0] === bun && tokens[1] === cli) return false;
  hook.command = sessionStartCommand(bun, cli, tool);
  // 新路径的命令由宿主重新确认，不伪造旧 trusted_hash。
  delete hook.trusted_hash;
  return true;
}

type MigrationCategory = "agent_config_read_failed" | "agent_config_invalid_json" | "agent_config_invalid_toml"
  | "agent_config_migration_failed" | "agent_config_write_failed" | "agent_config_no_tacit_entry";

function parseToml(text: string) {
  return Bun.TOML.parse(text) as any;
}

/** 仅迁移本应用已有的 AI 连接。同一工具的几份配置要么全部迁移、要么都不动（避免半迁移，例如权限规则已改名而 MCP 登记还是旧名）；工具之间互不影响。 */
export function relocateInstall(
  runtime: string, bun: string, home = homedir(), log: (category: MigrationCategory) => void = console.warn,
) {
  const cli = join(resolve(runtime), "hub/src/cli.ts"), updated: string[] = [];
  const plans = new Map<string, { file: string; before: string; after: string }[]>(), failed = new Set<string>();
  const migrate = (group: string, relative: string, parse: (text: string) => any, update: (data: any, before: string) => string | undefined) => {
    const file = join(home, relative);
    const fail = (category: MigrationCategory) => { log(category); failed.add(group); };
    let before: string, data: any, after: string | undefined;
    try { before = readFileSync(file, "utf8"); }
    catch (error) {
      if ((error as NodeJS.ErrnoException).code !== "ENOENT") fail("agent_config_read_failed");
      return;
    }
    try { data = parse(before); }
    catch { return fail(parse === parseToml ? "agent_config_invalid_toml" : "agent_config_invalid_json"); }
    try { after = update(data, before); }
    catch { return fail("agent_config_migration_failed"); }
    if (after === undefined) { log("agent_config_no_tacit_entry"); return; }
    if (before === after) return;
    if (!plans.has(group)) plans.set(group, []);
    plans.get(group)!.push({ file, before, after });
  };
  for (const [relative, tool, mcp] of [
    [".claude/settings.json", "claude-code", false], [".codex/hooks.json", "codex", false],
    [".claude.json", "claude-code", true], [antigravityConfig, "antigravity", true], ["Library/Application Support/Claude/claude_desktop_config.json", "claude-desktop", true],
  ] as const) {
    migrate(tool, relative, JSON.parse, (data, before) => {
      let changed = false;
      if (mcp) {
        // 旧服务名 record-anything 改成 tacit，保留在原来的位置。
        if (owns(data?.mcpServers?.[LEGACY_SERVER], tool)) {
          if (Object.hasOwn(data.mcpServers, SERVER)) throw new Error("Tacit MCP name already in use");
          data.mcpServers = Object.fromEntries(Object.entries(data.mcpServers).map(([k, v]) => [k === LEGACY_SERVER ? SERVER : k, v]));
          changed = true;
        }
        const entry = data?.mcpServers?.[SERVER];
        if (owns(entry, tool)) {
          if (entry.args[0] !== cli || entry.command !== bun) {
            entry.args[0] = cli; entry.command = bun; changed = true;
          }
        } else if (tool === "antigravity") return undefined;
      } else {
        // Claude Code 里按工具名允许过的规则跟着改名，不必重新允许。
        for (const kind of ["allow", "deny", "ask"]) {
          const rules = data?.permissions?.[kind];
          if (!Array.isArray(rules)) continue;
          const legacy = `mcp__${LEGACY_SERVER}`;
          const renamed = rules.map((r: unknown) => typeof r === "string" && (r === legacy || r.startsWith(`${legacy}__`)) ? `mcp__${SERVER}${r.slice(legacy.length)}` : r);
          if (renamed.some((r: unknown, i: number) => r !== rules[i])) { data.permissions[kind] = [...new Set(renamed)]; changed = true; }
        }
        for (const row of data?.hooks?.SessionStart ?? []) for (const hook of row.hooks ?? []) {
          if (updateHook(hook, tool, cli, bun)) changed = true;
        }
      }
      return changed ? JSON.stringify(data, null, 2) + "\n" : before;
    });
  }
  migrate("antigravity", antigravityHooks, JSON.parse, (data, before) => {
    const hooks = data?.[SERVER]?.SessionStart;
    let found = false, changed = false;
    if (Array.isArray(hooks)) for (const hook of hooks) {
      if (!sessionStartCommandPaths(hook?.command, "antigravity")) continue;
      found = true;
      if (updateHook(hook, "antigravity", cli, bun)) changed = true;
    }
    return changed ? JSON.stringify(data, null, 2) + "\n" : found ? before : undefined;
  });
  migrate("codex", ".codex/config.toml", parseToml, (existing, original) => {
    const before = renameCodexServer(original, existing), data = before === original ? existing : parseToml(before);
    const entry = data.mcp_servers?.[SERVER];
    if (owns(entry, "codex") && (entry.args[0] !== cli || entry.command !== bun)) {
      const sections = [...before.matchAll(/^[ \t]*(\[(?!\[)[^\n]+\])[ \t]*(?:#.*)?$/gm)];
      const index = sections.findIndex(s => {
        try { return !!(Bun.TOML.parse(`${s[1]}\n__ra = true`) as any).mcp_servers?.[SERVER]?.__ra; } catch { return false; }
      });
      if (index < 0) throw new Error("Codex 的连接配置格式无法安全迁移，请在设置中重新连接");
      const start = sections[index]!.index!, end = sections[index + 1]?.index ?? before.length;
      let block = before.slice(start, end), changes = 0;
      block = block.replace(/(^[ \t]*command[ \t]*=[ \t]*)(?:"(?:\\.|[^"\\])*"|'[^']*')/gm, (_, prefix) => { changes++; return prefix + JSON.stringify(bun); });
      block = block.replace(/(^[ \t]*args[ \t]*=[ \t]*)\[(?:[^\]"']|"(?:\\.|[^"\\])*"|'[^']*')*\]/gm, (_, prefix) => { changes++; return prefix + JSON.stringify([cli, "mcp", "--tool", "codex"]); });
      const after = before.slice(0, start) + block + before.slice(end);
      entry.command = bun; entry.args[0] = cli;
      if (changes !== 2 || JSON.stringify(Bun.TOML.parse(after)) !== JSON.stringify(data)) throw new Error("Codex 连接配置校验失败，未迁移");
      return after;
    }
    return before;
  });
  for (const [group, files] of plans) {
    if (failed.has(group)) continue;
    for (const plan of files) {
      try { saveConnectionPlan({ ...plan, existed: true }); }
      catch { log("agent_config_write_failed"); break; }
      updated.push(plan.file);
    }
  }
  return updated;
}
if (import.meta.main) {
  if (process.argv.length !== 4) throw new Error("用法：relocate-install <固定运行目录> <bun>");
  console.log(`已更新 ${relocateInstall(process.argv[2]!, process.argv[3]!).length} 份连接配置。`);
}
