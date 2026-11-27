import fs from "node:fs";
import path from "node:path";
import type { readEvents } from "../json-lines.ts";
import type { Json, Parsed } from "../session-events.ts";

export interface SessionDirectories {
  claudeDir?: string;
  codexDir?: string;
  antigravityDir?: string;
  factoryDir?: string;
  copilotDir?: string;
  codebuddyDir?: string;
}

export interface SessionFile {
  path: string;
  session?: { id: string; cwd?: string | null; subagent: boolean };
}

export interface SessionAdapter {
  id: string;
  checkpointKey?: string;
  additionalRootFields?: ReadonlySet<string>;
  additionalMessageFields?: ReadonlySet<string>;
  files(directories: SessionDirectories): Iterable<SessionFile>;
  readEvents?: typeof readEvents;
  sessionId?(event: Json | null, file: SessionFile): unknown;
  skipSession?(event: Json): boolean;
  cwd?(event: Json, file: SessionFile): unknown;
  parse(event: Json | null, hasSession: boolean): Parsed;
}

export function directoryEntries(root: string): fs.Dirent[] {
  if (!fs.statSync(root, { throwIfNoEntry: false })?.isDirectory()) return [];
  return fs.readdirSync(root, { withFileTypes: true });
}

export function* jsonlFiles(root: string): Generator<SessionFile> {
  for (const entry of directoryEntries(root)) {
    if (entry.isFile() && entry.name.endsWith(".jsonl")) yield { path: path.join(root, entry.name) };
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
