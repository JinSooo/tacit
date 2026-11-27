import os from "node:os";
import path from "node:path";
import { ignored, parseMessage, unknown, type Json, type Parsed } from "../session-events.ts";
import { walkJsonl, type SessionAdapter } from "./types.ts";

const codexMetadata = new Set(["event_msg", "turn_context", "compacted"]);
const codexItems = new Set(["reasoning", "function_call", "function_call_output", "custom_tool_call", "custom_tool_call_output", "local_shell_call", "web_search_call", "image_generation_call", "compaction", "compaction_trigger", "item_completed", "ghost_snapshot", "encrypted_content"]);

function parseCodexEvent(event: Json | null, hasSession: boolean): Parsed {
  if (!event) return unknown;
  if (event.type === "session_meta") return typeof event.payload?.id === "string" && event.payload.id ? ignored : unknown;
  if (codexMetadata.has(event.type)) return ignored;
  if (event.type !== "response_item") return unknown;
  if (codexItems.has(event.payload?.type)) return ignored;
  if (event.payload?.type !== "message") return unknown;
  const message = event.payload;
  if (message.role === "assistant" && (message.channel === "analysis" || (message.recipient && message.recipient !== "all"))) return ignored;
  return parseMessage(event, message, hasSession);
}

export const codex: SessionAdapter = {
  id: "codex",
  *files({ codexDir }) {
    const root = codexDir ?? process.env.RA_CODEX_DIR ?? path.join(os.homedir(), ".codex");
    yield* walkJsonl(path.join(root, "sessions"));
    yield* walkJsonl(path.join(root, "archived_sessions"));
  },
  sessionId(event) { return event?.type === "session_meta" ? event.payload?.id : null; },
  cwd(event) { return event.type === "session_meta" ? event.payload?.cwd : null; },
  parse: parseCodexEvent,
};
