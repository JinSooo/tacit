import fs from "node:fs";
import path from "node:path";
import type { Json, Parsed } from "../session-events.ts";

export interface SessionDirectories {
  claudeDir?: string;
  codexDir?: string;
  antigravityDir?: string;
  geminiDir?: string;
}

export interface SessionFile {
  path: string;
  cwd?: string;
  fallbackSessionId?: string;
  session?: { id: string; cwd: string | null; subagent: boolean };
}

export interface SessionAdapter {
  id: string;
  checkpointKey?: string;
  additionalRootFields?: ReadonlySet<string>;
  genaiParts?: "content" | "parts";
  files(directories: SessionDirectories): Iterable<SessionFile>;
  sessionId?(event: Json | null, file: SessionFile): unknown;
  cwd?(event: Json, file: SessionFile): unknown;
  isSubagent?(event: Json): boolean;
  parse(event: Json | null, hasSession: boolean): Parsed;
}

export function* directoriesIn(root: string): Generator<string> {
  if (!fs.lstatSync(root, { throwIfNoEntry: false })?.isDirectory()) return;
  for (const entry of fs.readdirSync(root, { withFileTypes: true })) {
    if (entry.isDirectory()) yield path.join(root, entry.name);
  }
}

export function* walkJsonl(root: string, excludeDirectory?: string): Generator<SessionFile> {
  if (!fs.existsSync(root)) return;
  for (const entry of fs.readdirSync(root, { withFileTypes: true })) {
    const file = path.join(root, entry.name);
    if (entry.isDirectory() && entry.name !== excludeDirectory) yield* walkJsonl(file, excludeDirectory);
    else if (entry.isFile() && /\.jsonl(?:\.zst)?$/.test(entry.name)) yield { path: file };
  }
}
