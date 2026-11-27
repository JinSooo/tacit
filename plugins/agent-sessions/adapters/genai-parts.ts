import { cleanUserText } from "../filters.ts";
import { unknown, type Parsed } from "../session-events.ts";

export function parseGenaiParts(
  role: "user" | "assistant", timestamp: unknown, parts: unknown[], hasSession: boolean,
): Parsed {
  const time = typeof timestamp === "string" ? Date.parse(timestamp) : NaN;
  if (!hasSession || !Number.isFinite(time)) return unknown;
  let recognized = true;
  const texts: string[] = [];
  for (const part of parts) {
    const block = part && typeof part === "object" ? part as Record<string, unknown> : undefined;
    if (block && (
      block.thought === true || "functionCall" in block || "functionResponse" in block
      || "inlineData" in block || "fileData" in block
    )) continue;
    const text = typeof part === "string" ? part : block?.text;
    if (typeof text !== "string") { recognized = false; continue; }
    const cleaned = role === "user" ? cleanUserText(text) : text.trim();
    if (cleaned) texts.push(cleaned);
  }
  return { recognized, message: texts.length ? { role, time, text: texts.join("\n") } : undefined };
}
