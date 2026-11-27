import os from "node:os";
import path from "node:path";
import { ignored, parseMessage, unknown, type Json } from "../session-events.ts";
import { directoryEntries, jsonlFiles, type SessionAdapter, type SessionFile } from "./types.ts";

const metadata = new Set([
  "summary", "topic", "resend-fork-notice", "function_call", "function_call_output", "function_call_result", "reasoning", "thinking",
]);

export function* buddyFiles(home: string) {
  const root = path.join(home, "projects");
  for (const entry of directoryEntries(root)) {
    if (entry.isDirectory() && entry.name !== "subagents") yield* jsonlFiles(path.join(root, entry.name));
  }
}

export const buddyTranscript = {
  additionalRootFields: new Set(["role", "content", "__timestamp", "providerData", "interactionType", "status"]),
  sessionId(_event: Json | null, file: SessionFile) { return path.basename(file.path, ".jsonl"); },
  cwd(event: Json) { return event.isSidechain === true ? undefined : event.cwd; },
  parse(event: Json | null, hasSession: boolean) {
    if (!event) return unknown;
    if (event.isSidechain === true || metadata.has(event.type)) return ignored;
    if (event.type !== "message") return unknown;
    const provider = event.providerData;
    if (event.isMeta === true || provider?.isMeta === true
      || event.interactionType === "notification" || provider?.interactionType === "notification"
      || (provider && Object.entries(provider).some(([key, value]) => /initiator$/i.test(key) && value === "agent"))) return ignored;
    if (event.role === "assistant" && event.status !== undefined && event.status !== "completed") return ignored;
    // 上游打包代码确认到的扁平字段；未知包装交由格式诊断。
    const timestamp = event.timestamp ?? event.__timestamp;
    return parseMessage({ timestamp }, { role: event.role, content: event.content }, hasSession);
  },
} satisfies Omit<SessionAdapter, "id" | "files">;

export const codeBuddy: SessionAdapter = {
  ...buddyTranscript,
  id: "codebuddy",
  files({ codebuddyDir }) {
    return buddyFiles(codebuddyDir ?? process.env.RA_CODEBUDDY_DIR ?? (process.env.CODEBUDDY_CONFIG_DIR || path.join(os.homedir(), ".codebuddy")));
  },
};
