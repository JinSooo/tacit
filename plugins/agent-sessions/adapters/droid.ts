import os from "node:os";
import path from "node:path";
import { ignored, parseMessage, unknown, type Json } from "../session-events.ts";
import { directoryEntries, jsonlFiles, type SessionAdapter } from "./types.ts";

const linkedSessionFields = [
  "callingSessionId", "callingToolUseId", "parent", "decompSessionType", "decompMissionId", "forkedAtMessageId",
];
const metadata = new Set(["session_start", "compaction_state", "todo_state", "queued_messages_discarded", "tool_call"]);
const internalPrefix = /^(?:__internal__system-reminder__|injected-summary-|---BEGIN TASK FROM PARENT AGENT---)/;
const internal = (value: unknown) => typeof value === "string" && internalPrefix.test(value.trimStart());

export const droid: SessionAdapter = {
  id: "droid",
  additionalRootFields: new Set(["id", "lastCwd", "tags", ...linkedSessionFields]),
  additionalMessageFields: new Set(["visibility", "systemNotice", "hiddenFromUserViews", "isUserVisible", "hookEventName"]),
  *files({ factoryDir }) {
    const home = process.env.FACTORY_HOME_OVERRIDE || os.homedir();
    const root = path.join(factoryDir ?? process.env.RA_FACTORY_DIR ?? path.join(home, ".factory"), "sessions");
    yield* jsonlFiles(root);
    for (const entry of directoryEntries(root)) {
      if (entry.isDirectory()) yield* jsonlFiles(path.join(root, entry.name));
    }
  },
  sessionId(event) { return event?.type === "session_start" ? event.id : null; },
  cwd(event) { return event.type === "session_start" ? event.lastCwd || event.cwd : null; },
  skipSession(event) {
    if (event.type !== "session_start") return false;
    return linkedSessionFields.some(field => typeof event[field] === "string" && event[field].length > 0)
      || (Array.isArray(event.tags) && event.tags.some(tag => typeof tag === "string"
        && /(?:^|[^a-z0-9])(?:subagent|automation|exec|evaluation)(?:$|[^a-z0-9])/i.test(tag)));
  },
  parse(event, hasSession) {
    if (!event) return unknown;
    if (metadata.has(event.type)) return ignored;
    if (event.type !== "message" || !event.message?.role) return unknown;
    const message = event.message;
    if (message.systemNotice === true || message.visibility === "user_only" || message.visibility === "llm_only"
      || message.hiddenFromUserViews === true || message.isUserVisible === false
      || typeof message.hookEventName === "string" || internal(event.id) || internal(message.id)) return ignored;
    const content = Array.isArray(message.content)
      ? message.content.filter((block: Json | null) => block?.type !== "text" || !internal(block.text))
      : internal(message.content) ? "" : message.content;
    let timestamp = event.timestamp;
    if (typeof timestamp === "number") {
      const date = new Date(timestamp);
      if (!Number.isFinite(date.getTime())) return unknown;
      timestamp = date.toISOString();
    }
    return parseMessage({ timestamp }, { role: message.role, content }, hasSession, true);
  },
};
