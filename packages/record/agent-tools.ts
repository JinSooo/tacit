export type SessionStartFormat = "claude" | "antigravity";

interface AgentTool {
  id: string;
  source?: string;
  executables?: readonly string[];
  sessionStart?: SessionStartFormat;
  label: string;
  macBundle?: string;
  androidPackage?: string;
  symbol?: string;
  macAlias?: string;
  macSubstitute?: string;
}

/** Tool IDs used in audit and context.app. Only entries with a source accept session records. */
export const AGENT_TOOLS: readonly AgentTool[] = [
  { id: "claude-code", executables: ["claude"], sessionStart: "claude", source: "claude_code.session", label: "Claude Code", macBundle: "com.anthropic.claudefordesktop", androidPackage: "com.anthropic.claude", symbol: "asterisk", macAlias: "claude" },
  { id: "codex", executables: ["codex"], sessionStart: "claude", source: "codex.session", label: "Codex", macBundle: "com.openai.codex", androidPackage: "com.openai.chatgpt", symbol: "open-ai-logo", macSubstitute: "com.openai.chat" },
  { id: "antigravity", executables: ["agy"], sessionStart: "antigravity", source: "antigravity.session", label: "Antigravity", macBundle: "com.google.antigravity" },
  { id: "opencode", source: "opencode.session", label: "OpenCode", macBundle: "ai.opencode.desktop" },
  { id: "codebuddy", sessionStart: "claude", source: "codebuddy.session", label: "CodeBuddy" },
  { id: "workbuddy", source: "workbuddy.session", label: "WorkBuddy" },
  { id: "copilot-cli", source: "copilot_cli.session", label: "Copilot CLI" },
  { id: "droid", source: "droid.session", label: "Droid" },
  { id: "qwen-code", sessionStart: "claude", source: "qwen_code.session", label: "Qwen Code" },
  { id: "gemini-cli", sessionStart: "claude", source: "gemini_cli.session", label: "Gemini CLI" },
  { id: "kimi-cli", label: "Kimi CLI" },
  { id: "cursor", label: "Cursor", macBundle: "com.todesktop.230313mzl4w4u92" },
  { id: "claude-desktop", label: "Claude Desktop", macBundle: "com.anthropic.claudefordesktop", symbol: "asterisk" },
];

export const AGENT_SESSIONS = AGENT_TOOLS.flatMap(tool => tool.source ? [{ ...tool, source: tool.source }] : []);
export const AGENT_SESSION_SOURCES: ReadonlySet<string> = new Set(AGENT_SESSIONS.map(tool => tool.source));
export const AGENT_SESSION_NAMES: Readonly<Record<string, string>> =
  Object.fromEntries(AGENT_SESSIONS.map(({ source, label }) => [source, label]));
