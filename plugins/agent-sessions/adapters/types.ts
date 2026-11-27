import fs from "node:fs";
import path from "node:path";
import type { Json, Parsed } from "../session-events.ts";

export interface SessionDirectories {
  claudeDir?: string;
  codexDir?: string;
}

export interface SessionFile {
  path: string;
}

export interface SessionAdapter {
  id: string;
  checkpointKey?: string;
  files(directories: SessionDirectories): Iterable<SessionFile>;
  sessionId(event: Json | null, file: SessionFile): unknown;
  cwd(event: Json): unknown;
  parse(event: Json | null, hasSession: boolean): Parsed;
}

export function* walkJsonl(root: string, excludeDirectory?: string): Generator<SessionFile> {
  if (!fs.existsSync(root)) return;
  for (const entry of fs.readdirSync(root, { withFileTypes: true })) {
    const file = path.join(root, entry.name);
    if (entry.isDirectory() && entry.name !== excludeDirectory) yield* walkJsonl(file, excludeDirectory);
    else if (entry.isFile() && /\.jsonl(?:\.zst)?$/.test(entry.name)) yield { path: file };
  }
}
