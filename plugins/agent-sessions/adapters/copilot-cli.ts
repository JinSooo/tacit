import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { capturePrefix } from "../../../packages/record/capture-prefix.ts";
import { readEvents } from "../json-lines.ts";
import { ignored, parseMessage, unknown, type Json } from "../session-events.ts";
import { directoryEntries, type SessionAdapter } from "./types.ts";

const fields = new Set(["data"]);
const metadata = new Set([
  "session.start", "session.compaction_start", "session.compaction_summarized", "session.compaction_complete",
  "session.info", "session.usage_info", "session.idle", "session.shutdown", "session.snapshot_rewind",
  "subagent.started", "subagent.completed", "tool.execution_start", "tool.execution_complete",
]);

function workspaceCwd(file: string): string | undefined {
  const stat = fs.lstatSync(file, { throwIfNoEntry: false });
  if (!stat?.isFile() || stat.size > 64 * 1024) return;
  const line = /^cwd:[ \t]*(.*)$/m.exec(fs.readFileSync(file, "utf8"))?.[1]?.trim();
  if (!line) return;
  const doubleQuoted = /^("(?:[^"\\]|\\.)*")(?:\s+#.*)?$/.exec(line);
  const singleQuoted = /^'((?:[^']|'')*)'(?:\s+#.*)?$/.exec(line);
  let cwd: string;
  try {
    if (doubleQuoted) cwd = JSON.parse(doubleQuoted[1]!);
    else if (singleQuoted) cwd = singleQuoted[1]!.replaceAll("''", "'");
    else cwd = line.replace(/\s+#.*$/, "").trimEnd();
  } catch { return; }
  if ((path.isAbsolute(cwd) || path.win32.isAbsolute(cwd)) && !/[\0\r\n]/.test(cwd)) return cwd;
}

function isInjected(event: Json): boolean {
  const data = event.data;
  return !!(data?.parentAgentTaskId || data?.parentToolCallId
    || (event.type === "user.message" && (data?.isAutopilotContinuation === true || data?.causalDependencies?.length)));
}

function parseCopilotEvent(event: Json | null, hasSession: boolean) {
  if (!event) return unknown;
  if (metadata.has(event.type)) return ignored;
  if (event.type !== "user.message" && event.type !== "assistant.message") return unknown;
  if (isInjected(event)) return ignored;
  if (typeof event.data?.content !== "string") return unknown;
  const role = event.type === "user.message" ? "user" : "assistant";
  return parseMessage(event, { role, content: event.data.content }, hasSession, true);
}

type Line = { event: Json | null | undefined; damaged: boolean; end: number };
const maxText = 150_000;
async function* readCopilotEvents(file: string, offset: number, size: number): AsyncGenerator<Line> {
  let start = offset;
  let pending: { event: Json; offset: number; id: string; lastIndex: number; count: number; end: number; text: string } | undefined;
  for await (const line of readEvents(file, offset, size, fields)) {
    const lineStart = start;
    start = line.end;
    const event = line.event;
    if (line.damaged || !event || isInjected(event)) {
      yield line;
      continue;
    }
    const data = event.data;
    const chunk = event.type === "assistant.message" && data?.chunkCount > 1;
    if (chunk && (typeof data.apiCallId !== "string" || !data.apiCallId || !Number.isSafeInteger(data.chunkCount)
      || !Number.isSafeInteger(data.chunkIndex) || data.chunkIndex < 0 || data.chunkIndex > data.chunkCount
      || typeof data.content !== "string" || typeof event.timestamp !== "string" || !Number.isFinite(Date.parse(event.timestamp)))) {
      yield { ...line, event: null };
      continue;
    }
    if (pending && (chunk ? data.apiCallId !== pending.id || data.chunkIndex !== pending.lastIndex + 1
      : ["user.message", "assistant.message", "session.idle", "session.shutdown"].includes(event.type))) {
      yield { event: pending.event, end: pending.end, damaged: false };
      pending = undefined;
    }
    if (!chunk) {
      yield line;
      continue;
    }
    pending ??= { event, offset: lineStart, id: data.apiCallId, lastIndex: data.chunkIndex, count: 0, end: line.end, text: "" };
    if (pending.text.length <= maxText) {
      const combined = pending.text + data.content;
      pending.text = combined.length > maxText ? capturePrefix(combined, maxText) + "…[已截断]" : combined;
    }
    pending.event.data.content = pending.text;
    pending.lastIndex = data.chunkIndex;
    pending.end = line.end;
    if (++pending.count === data.chunkCount) {
      yield { ...line, event: pending.event };
      pending = undefined;
    }
  }
  // 活跃调用可能在下一轮才写完；下次从第一片续读，再按完整回复去重。
  if (pending) yield { event: undefined, end: pending.offset, damaged: false };
}

export const copilotCli: SessionAdapter = {
  id: "copilot-cli",
  *files({ copilotDir }) {
    const root = path.join(copilotDir ?? process.env.RA_COPILOT_DIR ?? (process.env.COPILOT_HOME || path.join(os.homedir(), ".copilot")), "session-state");
    for (const entry of directoryEntries(root)) {
      if (!entry.isDirectory()) continue;
      const directory = path.join(root, entry.name);
      const file = path.join(directory, "events.jsonl");
      if (!fs.lstatSync(file, { throwIfNoEntry: false })?.isFile()) continue;
      yield { path: file, session: { id: entry.name, cwd: workspaceCwd(path.join(directory, "workspace.yaml")), subagent: false } };
    }
  },
  readEvents: readCopilotEvents,
  skipSession(event) { return event.type === "session.start" && !!event.data?.detachedFromSpawningParentSessionId; },
  cwd(event, file) { return event.type === "session.start" ? file.session?.cwd ?? event.data?.context?.cwd : null; },
  parse: parseCopilotEvent,
};
