import { cleanUserText } from "./filters.ts";
import type { Message } from "./message-buffer.ts";

export type Provider = "claude" | "codex";
type Json = { [key: string]: any };
type Parsed = { recognized: boolean; message?: Message };
const ignored: Parsed = { recognized: true };
const unknown: Parsed = { recognized: false };
const claudeMetadata = new Set(["system", "summary", "file-history-snapshot", "progress", "queue-operation", "attribution-snapshot", "custom-title", "agent-name", "last-prompt", "pr-link", "tag", "permission-mode"]);
const codexMetadata = new Set(["event_msg", "turn_context", "compacted"]);
const codexItems = new Set(["reasoning", "function_call", "function_call_output", "custom_tool_call", "custom_tool_call_output", "local_shell_call", "web_search_call", "image_generation_call", "compaction", "compaction_trigger", "item_completed", "ghost_snapshot", "encrypted_content"]);
const ignoredRoles = new Set(["system", "developer", "tool"]);
const ignoredBlocks = new Set(["image", "input_image", "document", "tool_use", "tool_result", "thinking", "redacted_thinking", "reasoning", "server_tool_use", "web_search_tool_result", "refusal"]);
const textBlocks = new Set(["text", "input_text", "output_text"]);

export function parseSessionEvent(event: Json | null, provider: Provider, hasSession: boolean): Parsed {
  if (!event) return unknown;
  let message: Json;
  if (provider === "claude") {
    if (claudeMetadata.has(event.type)) return ignored;
    if (event.type !== "user" && event.type !== "assistant") return unknown;
    if (event.isSidechain || event.isMeta || event.isCompactSummary) return ignored;
    if (event.type === "user" && (event.promptSource === "system" || ["task_notification", "hook"].includes(event.turnOrigin) || /task-notification|hook/.test(event.origin?.kind ?? ""))) return ignored;
    message = event.message ?? {};
  } else {
    if (event.type === "session_meta") return typeof event.payload?.id === "string" && event.payload.id ? ignored : unknown;
    if (codexMetadata.has(event.type)) return ignored;
    if (event.type !== "response_item") return unknown;
    if (codexItems.has(event.payload?.type)) return ignored;
    if (event.payload?.type !== "message") return unknown;
    message = event.payload;
    if (message.role === "assistant" && (message.channel === "analysis" || (message.recipient && message.recipient !== "all"))) return ignored;
  }
  const role = message.role ?? event.type;
  if (ignoredRoles.has(role)) return ignored;
  if (role !== "user" && role !== "assistant") return unknown;
  const time = typeof event.timestamp === "string" ? Date.parse(event.timestamp) : NaN;
  if (!hasSession || !Number.isFinite(time)) return unknown;
  const content = typeof message.content === "string" ? [{ type: "text", text: message.content }] : message.content;
  if (!Array.isArray(content)) return unknown;
  let recognized = true;
  const parts: string[] = [];
  for (const block of content) {
    if (ignoredBlocks.has(block?.type)) continue;
    if (!textBlocks.has(block?.type) || typeof block.text !== "string") { recognized = false; continue; }
    const text = role === "user" ? cleanUserText(block.text) : block.text.trim();
    if (text) parts.push(text);
  }
  return { recognized, message: parts.length ? { time, role, text: parts.join("\n") } : undefined };
}
