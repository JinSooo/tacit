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

function readSummaries(root: string): Map<string, Summary> | null {
  const file = path.join(root, "conversation_summaries.db");
  let db: Database | undefined;
  try {
    const stat = fs.lstatSync(file, { throwIfNoEntry: false });
    if (!stat) return new Map();
    if (!stat.isFile()) return null;
    const hasUncheckpointedWal = () => (fs.statSync(file + "-wal", { throwIfNoEntry: false })?.size ?? 0) > 0;
    const activeWal = hasUncheckpointedWal();
    // SQLite 可能为只读连接创建 sidecar。缺少共享内存时等待写入端恢复或写回。
    if (activeWal && !fs.existsSync(file + "-shm")) return null;
    const header = Buffer.alloc(20);
    const fd = fs.openSync(file, "r");
    try { fs.readSync(fd, header, 0, header.length, 0); } finally { fs.closeSync(fd); }
    // 有 -shm 说明写入端可能还开着库，只能走带锁的 mode=ro；immutable 只给已完全关闭的库。
    const immutable = !activeWal && !fs.existsSync(file + "-shm") && (header[18] === 2 || header[19] === 2);
    const uri = pathToFileURL(path.resolve(file));
    uri.search = immutable ? "mode=ro&immutable=1" : "mode=ro";
    db = new Database(uri.href, { readonly: true });
    db.exec("PRAGMA busy_timeout = 1000");
    const rows = db.query<Summary, []>(`
      SELECT conversation_id, workspace_uris, parent_conversation_id, nesting_depth
      FROM conversation_summaries
    `).all();
    if (immutable && hasUncheckpointedWal()) return null;
    return new Map(rows.map(row => [row.conversation_id, row]));
  } catch {
    return null;
  } finally {
    db?.close();
  }
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

// 桌面版把用户原话包在 <USER_REQUEST> 里，后面附带当前时间、设置变更等系统信息（2026-11-27 真机样本），只取原话。
function userRequest(content: string): string {
  const open = "<USER_REQUEST>", close = "</USER_REQUEST>";
  const value = content.trimStart();
  const end = value.lastIndexOf(close);
  return value.startsWith(open) && end >= open.length ? value.slice(open.length, end) : content;
}

function parseAntigravityEvent(event: Json | null, hasSession: boolean): Parsed {
  if (!event || typeof event.type !== "string" || !event.type) return unknown;
  if (event.type === "GENERIC") return ignored;
  if (event.type !== "USER_INPUT" && event.type !== "PLANNER_RESPONSE") {
    return typeof event.source === "string" && event.source ? ignored : unknown;
  }
  const role = event.type === "USER_INPUT" ? "user" : "assistant";
  if (role === "user" && event.source !== "USER_EXPLICIT") return ignored;
  if (role === "assistant" && event.content == null) return ignored;
  const time = typeof event.created_at === "string" ? Date.parse(event.created_at) : NaN;
  if (!hasSession || !Number.isFinite(time) || typeof event.content !== "string") return unknown;
  const text = role === "user" ? cleanUserText(userRequest(event.content)) : event.content.trim();
  return text ? { recognized: true, message: { role, time, text } } : ignored;
}

export const antigravity: SessionAdapter = {
  id: "antigravity",
  additionalRootFields: new Set(["source", "created_at", "content"]),
  *files({ antigravityDir }, deferDirectory) {
    const gemini = antigravityDir ?? process.env.RA_ANTIGRAVITY_DIR ?? path.join(os.homedir(), ".gemini");
    for (const name of ["antigravity", "antigravity-cli", "antigravity-ide"]) {
      const root = path.join(gemini, name);
      if (!fs.lstatSync(root, { throwIfNoEntry: false })?.isDirectory()) continue;
      const brain = path.join(root, "brain");
      if (!fs.lstatSync(brain, { throwIfNoEntry: false })?.isDirectory()) continue;
      const summaries = readSummaries(root);
      if (!summaries) {
        deferDirectory?.(brain);
        continue;
      }
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
