import { existsSync, readFileSync } from "node:fs";
import { homedir } from "node:os";
import { join, resolve } from "node:path";
import { saveConnectionPlan } from "./agents-install.ts";

const quote = (s: string) => `'${s.replaceAll("'", "'\\''")}'`;
/** 只解析本应用生成的简单命令，不执行 shell 或展开变量。 */
function words(s: string): string[] | null {
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
const owns = (entry: any, tool: string) => entry && typeof entry.command === "string" && Array.isArray(entry.args)
  && entry.args.length === 4 && typeof entry.args[0] === "string" && entry.args[0].endsWith("/hub/src/cli.ts")
  && entry.args.slice(1).join("\n") === `mcp\n--tool\n${tool}`;

/** 仅迁移已经存在且由本应用拥有的连接，不开启未连接的工具或终端采集。全部预检后才写入。 */
export function relocateInstall(runtime: string, bun: string, home = homedir()) {
  const cli = join(resolve(runtime), "hub/src/cli.ts"), plans: Parameters<typeof saveConnectionPlan>[0][] = [];
  const add = (file: string, before: string, after: string) => { if (before !== after) plans.push({ file, existed: true, before, after }); };
  for (const [relative, tool, mcp] of [
    [".claude/settings.json", "claude-code", false], [".codex/hooks.json", "codex", false],
    [".claude.json", "claude-code", true], ["Library/Application Support/Claude/claude_desktop_config.json", "claude-desktop", true],
  ] as const) {
    const file = join(home, relative); if (!existsSync(file)) continue;
    const before = readFileSync(file, "utf8"), data = JSON.parse(before); let changed = false;
    if (mcp) {
      const entry = data?.mcpServers?.["record-anything"];
      if (owns(entry, tool) && (entry.args[0] !== cli || entry.command !== bun)) {
        entry.args[0] = cli; entry.command = bun; changed = true;
      }
    } else {
      for (const row of data?.hooks?.SessionStart ?? []) for (const hook of row.hooks ?? []) {
        if (typeof hook.command !== "string") continue;
        const tokens = words(hook.command);
        if (tokens?.length === 6 && tokens[1]?.endsWith("/hub/src/cli.ts") && tokens.slice(2).join("\n") === `hook\nsession-start\n--tool\n${tool}`) {
          if (tokens[0] === bun && tokens[1] === cli) continue;
          hook.command = `${quote(bun)} ${quote(cli)} hook session-start --tool ${tool}`;
          // 新路径的命令由宿主重新确认，不伪造旧 trusted_hash。
          delete hook.trusted_hash; changed = true;
        }
      }
    }
    if (changed) add(file, before, JSON.stringify(data, null, 2) + "\n");
  }
  const file = join(home, ".codex/config.toml");
  if (existsSync(file)) {
    const before = readFileSync(file, "utf8"), data = Bun.TOML.parse(before) as any;
    const entry = data.mcp_servers?.["record-anything"];
    if (owns(entry, "codex") && (entry.args[0] !== cli || entry.command !== bun)) {
      const sections = [...before.matchAll(/^[ \t]*(\[(?!\[)[^\n]+\])[ \t]*(?:#.*)?$/gm)];
      const index = sections.findIndex(s => {
        try { return !!(Bun.TOML.parse(`${s[1]}\n__ra = true`) as any).mcp_servers?.["record-anything"]?.__ra; } catch { return false; }
      });
      if (index < 0) throw new Error("Codex 的连接配置格式无法安全迁移，请在设置中重新连接");
      const start = sections[index]!.index!, end = sections[index + 1]?.index ?? before.length;
      let block = before.slice(start, end), changes = 0;
      block = block.replace(/(^[ \t]*command[ \t]*=[ \t]*)(?:"(?:\\.|[^"\\])*"|'[^']*')/gm, (_, prefix) => { changes++; return prefix + JSON.stringify(bun); });
      block = block.replace(/(^[ \t]*args[ \t]*=[ \t]*)\[(?:[^\]"']|"(?:\\.|[^"\\])*"|'[^']*')*\]/gm, (_, prefix) => { changes++; return prefix + JSON.stringify([cli, "mcp", "--tool", "codex"]); });
      const after = before.slice(0, start) + block + before.slice(end);
      entry.command = bun; entry.args[0] = cli;
      if (changes !== 2 || JSON.stringify(Bun.TOML.parse(after)) !== JSON.stringify(data)) throw new Error("Codex 连接配置校验失败，未迁移");
      add(file, before, after);
    }
  }
  const zshrc = join(home, ".zshrc");
  if (existsSync(zshrc)) {
    const before = readFileSync(zshrc, "utf8");
    const after = before.split("\n").map(line => {
      const trimmed = line.trim(); if (trimmed.startsWith("#") || !trimmed.includes("plugins/shell/hook.zsh")) return line;
      const command = trimmed.includes("&& source ") ? trimmed.slice(trimmed.lastIndexOf("&& source ") + 3) : trimmed;
      const parts = words(command);
      if (parts?.length !== 2 || !["source", "."].includes(parts[0]!) || !parts[1]!.endsWith("/plugins/shell/hook.zsh")) return line;
      const wanted = join(runtime, "plugins/shell/hook.zsh");
      return parts[1] === wanted ? line : `source ${quote(wanted)}`;
    }).join("\n");
    add(zshrc, before, after);
  }
  for (const plan of plans) saveConnectionPlan(plan);
  return plans.map(p => p.file);
}
if (import.meta.main) {
  if (process.argv.length !== 4) throw new Error("用法：relocate-install <固定运行目录> <bun>");
  console.log(`已更新 ${relocateInstall(process.argv[2]!, process.argv[3]!).length} 份连接配置。`);
}
