import os from "node:os";
import path from "node:path";
import { cleanLegacyUserText } from "../filters.ts";
import { ignored, parseMessage, unknown, type Json, type Parsed } from "../session-events.ts";
import { walkJsonl, type SessionAdapter } from "./types.ts";

const claudeMetadata = new Set(["system", "summary", "file-history-snapshot", "progress", "queue-operation", "attribution-snapshot", "custom-title", "agent-name", "last-prompt", "pr-link", "tag", "permission-mode"]);

function parseClaudeEvent(event: Json | null, hasSession: boolean): Parsed {
  if (!event) return unknown;
  if (claudeMetadata.has(event.type)) return ignored;
  if (event.type !== "user" && event.type !== "assistant") return unknown;
  if (event.isSidechain || event.isMeta || event.isCompactSummary) return ignored;
  if (event.type === "user" && (event.promptSource === "system" || ["task_notification", "hook"].includes(event.turnOrigin) || /task-notification|hook/.test(event.origin?.kind ?? ""))) return ignored;
  return parseMessage(event, event.message ?? {}, hasSession, cleanLegacyUserText);
}

export const claudeCode: SessionAdapter = {
  id: "claude-code",
  checkpointKey: "claude",
  *files({ claudeDir }) {
    const root = path.join(claudeDir ?? process.env.RA_CLAUDE_DIR ?? path.join(os.homedir(), ".claude"), "projects");
    if (!root.split(path.sep).includes("subagents")) yield* walkJsonl(root, "subagents");
  },
  sessionId(event, file) { return event ? event.sessionId ?? path.basename(file.path, ".jsonl") : null; },
  cwd(event) { return event.cwd; },
  parse: parseClaudeEvent,
};
