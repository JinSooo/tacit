import { Database } from "bun:sqlite";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { cleanUserText } from "../filters.ts";
import { ignored, unknown, type Json, type Parsed } from "../session-events.ts";
import type { SessionAdapter } from "./types.ts";

interface Summary {
  conversation_id: string;
  workspace_uris: string | null;
  parent_conversation_id: string | null;
  nesting_depth: number | null;
}

function readSummaries(root: string): Map<string, Summary> {
  const file = path.join(root, "conversation_summaries.db");
  if (!fs.lstatSync(file, { throwIfNoEntry: false })?.isFile()) return new Map();
  const uri = pathToFileURL(path.resolve(file));
  // 有现成的 WAL 和共享内存文件时读最新数据。归档数据库不创建 sidecar。
  const modes = fs.existsSync(file + "-shm") && fs.existsSync(file + "-wal")
    ? ["mode=ro", "mode=ro&immutable=1"] : ["mode=ro&immutable=1"];
  for (const mode of modes) {
    let db: Database | undefined;
    try {
      uri.search = mode;
      db = new Database(uri.href, { readonly: true });
      const rows = db.query<Summary, []>(`
        SELECT conversation_id, workspace_uris, parent_conversation_id, nesting_depth
        FROM conversation_summaries
      `).all();
      return new Map(rows.map(row => [row.conversation_id, row]));
    } catch {
      // 普通只读打开失败时，仍尝试从已写回的数据库读取。
    } finally {
      db?.close();
    }
  }
  return new Map();
}

function workspaceCwd(workspaceUris: string | null | undefined): string | null {
  const value = workspaceUris?.trim();
  if (!value) return null;
  let candidates: unknown[] = value.split(/[\s,;]+(?=file:\/\/|\/)/);
  if (value.startsWith("[") || value.startsWith('"')) {
    try {
      const parsed: unknown = JSON.parse(value);
      candidates = Array.isArray(parsed) ? parsed : [parsed];
    } catch { return null; }
  }
  for (const item of candidates) {
    if (typeof item !== "string") continue;
    const candidate = item.trim();
    if (path.isAbsolute(candidate)) return candidate;
    if (candidate.startsWith("file://")) {
      try { return fileURLToPath(candidate); } catch { continue; }
    }
  }
  return null;
}

function parseAntigravityEvent(event: Json | null, hasSession: boolean): Parsed {
  if (!event || typeof event.type !== "string" || !event.type) return unknown;
  if (event.type === "GENERIC") return ignored;
  if (event.type !== "USER_INPUT" && event.type !== "PLANNER_RESPONSE") {
    return typeof event.source === "string" && event.source ? ignored : unknown;
  }
  const role = event.type === "USER_INPUT" ? "user" : "assistant";
  if (role === "user" && event.source !== "USER_EXPLICIT") return unknown;
  if (role === "assistant" && event.content === undefined) return ignored;
  const time = typeof event.created_at === "string" ? Date.parse(event.created_at) : NaN;
  if (!hasSession || !Number.isFinite(time) || typeof event.content !== "string") return unknown;
  const text = role === "user" ? cleanUserText(event.content) : event.content.trim();
  return text ? { recognized: true, message: { role, time, text } } : ignored;
}

export const antigravity: SessionAdapter = {
  id: "antigravity",
  additionalRootFields: new Set(["source", "created_at", "content"]),
  *files({ antigravityDir }) {
    const gemini = antigravityDir ?? process.env.RA_ANTIGRAVITY_DIR ?? path.join(os.homedir(), ".gemini");
    for (const name of ["antigravity", "antigravity-cli", "antigravity-ide"]) {
      const root = path.join(gemini, name);
      if (!fs.lstatSync(root, { throwIfNoEntry: false })?.isDirectory()) continue;
      const brain = path.join(root, "brain");
      if (!fs.lstatSync(brain, { throwIfNoEntry: false })?.isDirectory()) continue;
      const summaries = readSummaries(root);
      for (const entry of fs.readdirSync(brain, { withFileTypes: true })) {
        if (!entry.isDirectory()) continue;
        const generated = path.join(brain, entry.name, ".system_generated");
        if (!fs.lstatSync(generated, { throwIfNoEntry: false })?.isDirectory()) continue;
        const logs = path.join(generated, "logs");
        if (!fs.lstatSync(logs, { throwIfNoEntry: false })?.isDirectory()) continue;
        const transcript = ["transcript_full.jsonl", "transcript.jsonl"]
          .map(name => path.join(logs, name))
          .find(file => fs.lstatSync(file, { throwIfNoEntry: false })?.isFile());
        if (!transcript) continue;
        const summary = summaries.get(entry.name);
        yield {
          path: transcript,
          session: {
            id: entry.name,
            cwd: workspaceCwd(summary?.workspace_uris),
            subagent: !!summary?.parent_conversation_id || (summary?.nesting_depth ?? 0) > 0,
          },
        };
      }
    }
  },
  parse: parseAntigravityEvent,
};
