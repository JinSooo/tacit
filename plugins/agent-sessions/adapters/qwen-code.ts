import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { ignored, unknown, type Json, type Parsed } from "../session-events.ts";
import { parseGenaiParts } from "./genai-parts.ts";
import { directoriesIn, type SessionAdapter } from "./types.ts";

const nonUserSubtypes = new Set([
  "agent_mention", "agent_message", "notification", "background_task_completed", "cron",
  "agent_bootstrap", "agent_launch_prompt", "agent_retry",
]);

function expandHome(value: string): string {
  return value === "~" || value.startsWith("~/") ? path.join(os.homedir(), value.slice(1)) : value;
}

function qwenRoot(): string {
  if (process.env.QWEN_RUNTIME_DIR) return expandHome(process.env.QWEN_RUNTIME_DIR);
  const home = expandHome(process.env.QWEN_HOME || path.join(os.homedir(), ".qwen"));
  try {
    const { runtimeOutputDir } = JSON.parse(fs.readFileSync(path.join(home, "settings.json"), "utf8"));
    if (typeof runtimeOutputDir === "string" && runtimeOutputDir) return expandHome(runtimeOutputDir);
  } catch {
    // A missing or invalid setting leaves the default runtime directory in effect.
  }
  return home;
}

function isSidechain(event: Json): boolean {
  return event.isSidechain === true || (typeof event.agentId === "string" && event.agentId !== "");
}

function parseQwenEvent(event: Json | null, hasSession: boolean): Parsed {
  if (!event) return unknown;
  if (isSidechain(event) || event.type === "system" || event.type === "tool_result") return ignored;
  if (event.type !== "user" && event.type !== "assistant") return unknown;
  if (event.type === "user" && (
    nonUserSubtypes.has(event.subtype) || event.backgroundTurn
    || event.externalInputKind === "notification" || event.clientInitiatedSkills === true
  )) return ignored;
  if (event.message?.role !== (event.type === "user" ? "user" : "model") || !Array.isArray(event.message.parts)) return unknown;
  return parseGenaiParts(event.type, event.timestamp, event.message.parts, hasSession);
}

export const qwenCode: SessionAdapter = {
  id: "qwen-code",
  additionalRootFields: new Set(["subtype", "agentId", "backgroundTurn", "externalInputKind", "clientInitiatedSkills"]),
  genaiParts: "parts",
  *files({ qwenDir }) {
    const root = qwenDir ?? process.env.RA_QWEN_DIR ?? qwenRoot();
    for (const project of directoriesIn(path.join(root, "projects"))) {
      const chats = path.join(project, "chats");
      if (!fs.lstatSync(chats, { throwIfNoEntry: false })?.isDirectory()) continue;
      for (const entry of fs.readdirSync(chats, { withFileTypes: true })) {
        if (entry.isFile() && entry.name.endsWith(".jsonl")) yield { path: path.join(chats, entry.name) };
      }
    }
  },
  sessionId(event) { return event && !isSidechain(event) ? event.sessionId : undefined; },
  cwd(event) { return !isSidechain(event) ? event.cwd : undefined; },
  parse: parseQwenEvent,
};
