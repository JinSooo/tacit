import { cleanUserText } from "./filters.ts";
import type { Message } from "./message-buffer.ts";

export type Json = { [key: string]: any };
export type Parsed = { recognized: boolean; message?: Message };
export const ignored: Parsed = { recognized: true };
export const unknown: Parsed = { recognized: false };
const ignoredRoles = new Set(["system", "developer", "tool"]);
const ignoredBlocks = new Set(["image", "input_image", "document", "tool_use", "tool_result", "thinking", "redacted_thinking", "reasoning", "server_tool_use", "web_search_tool_result", "refusal"]);
const textBlocks = new Set(["text", "input_text", "output_text"]);

export function parseMessage(event: Json, message: Json, hasSession: boolean, cleanText = false): Parsed {
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
    const text = role === "user" || cleanText ? cleanUserText(block.text) : block.text.trim();
    if (text) parts.push(text);
  }
  return { recognized, message: parts.length ? { time, role, text: parts.join("\n") } : undefined };
}
