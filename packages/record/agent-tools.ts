export type SessionStartFormat = "claude" | "antigravity" | "cursor" | "copilot";

interface AgentTool {
  id: string;
  source?: string;
  executables?: readonly string[];
  sessionStart?: SessionStartFormat;
  manualConnection?: {
    macApp?: string;
    mcpFile: string;
    mcpType?: "stdio";
    mcpFormat?: "opencode" | "copilot";
    configDirEnv?: string;
    configHomeEnv?: string;
    hook?: { file: string; event: string; timeout: number; matcher?: string; version?: number };
  };
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
  { id: "opencode", executables: ["opencode"], source: "opencode.session", label: "OpenCode", macBundle: "ai.opencode.desktop",
    manualConnection: { macApp: "OpenCode", mcpFile: ".config/opencode/opencode.json", mcpFormat: "opencode" },
  },
  { id: "codebuddy", executables: ["codebuddy", "codebuddy-code", "cbc"], sessionStart: "claude", source: "codebuddy.session", label: "CodeBuddy",
    manualConnection: {
      mcpFile: ".codebuddy.json", mcpType: "stdio", configDirEnv: "CODEBUDDY_CONFIG_DIR",
      hook: { file: ".codebuddy/settings.json", event: "SessionStart", timeout: 5, matcher: "startup|resume|clear|compact" },
    },
  },
  { id: "workbuddy", source: "workbuddy.session", label: "WorkBuddy",
    // https://www.workbuddy.cn/docs/workbuddy/From-Beginner-to-Expert-Guide/Function-Description/MCP-Guide
    manualConnection: { macApp: "WorkBuddy", mcpFile: ".workbuddy/mcp.json" },
  },
  { id: "copilot-cli", executables: ["copilot"], sessionStart: "copilot", source: "copilot_cli.session", label: "Copilot CLI",
    manualConnection: {
      mcpFile: ".copilot/mcp-config.json", mcpFormat: "copilot", configDirEnv: "COPILOT_HOME",
      hook: { file: ".copilot/hooks/tacit.json", event: "sessionStart", timeout: 5, version: 1 },
    },
  },
  { id: "droid", executables: ["droid"], source: "droid.session", label: "Droid",
    manualConnection: { mcpFile: ".factory/mcp.json", configHomeEnv: "FACTORY_HOME_OVERRIDE", mcpType: "stdio" },
  },
  { id: "qwen-code", executables: ["qwen"], sessionStart: "claude", source: "qwen_code.session", label: "Qwen Code",
    manualConnection: {
      mcpFile: ".qwen/settings.json", configDirEnv: "QWEN_HOME",
      hook: { file: ".qwen/settings.json", event: "SessionStart", timeout: 5, matcher: "startup|resume|clear|compact" },
    },
  },
  { id: "gemini-cli", executables: ["gemini"], sessionStart: "claude", source: "gemini_cli.session", label: "Gemini CLI",
    manualConnection: {
      mcpFile: ".gemini/settings.json", configHomeEnv: "GEMINI_CLI_HOME",
      hook: { file: ".gemini/settings.json", event: "SessionStart", timeout: 5000, matcher: "startup|resume|clear" },
    },
  },
  { id: "kimi-cli", executables: ["kimi"], label: "Kimi CLI",
    manualConnection: { mcpFile: ".kimi-code/mcp.json", configDirEnv: "KIMI_CODE_HOME" },
  },
  { id: "cursor", executables: ["cursor"], sessionStart: "cursor", label: "Cursor", macBundle: "com.todesktop.230313mzl4w4u92",
    manualConnection: {
      macApp: "Cursor", mcpFile: ".cursor/mcp.json", mcpType: "stdio",
      hook: { file: ".cursor/hooks.json", event: "sessionStart", timeout: 5, version: 1 },
    },
  },
  { id: "claude-desktop", label: "Claude Desktop", macBundle: "com.anthropic.claudefordesktop", symbol: "asterisk" },
];

export const AGENT_SESSIONS = AGENT_TOOLS.flatMap(tool => tool.source ? [{ ...tool, source: tool.source }] : []);
export const AGENT_SESSION_SOURCES: ReadonlySet<string> = new Set(AGENT_SESSIONS.map(tool => tool.source));
export const AGENT_SESSION_NAMES: Readonly<Record<string, string>> =
  Object.fromEntries(AGENT_SESSIONS.map(({ source, label }) => [source, label]));

export const AGENT_CONFIG_PATH_VARS: ReadonlySet<string> = new Set([
  "OPENCODE_CONFIG", "OPENCODE_CONFIG_DIR", "XDG_CONFIG_HOME",
  ...AGENT_TOOLS.flatMap(({ manualConnection: setup }) =>
    [setup?.configDirEnv, setup?.configHomeEnv].filter(value => value !== undefined)),
]);
