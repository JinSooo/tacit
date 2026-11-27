import fs from "node:fs";
import path from "node:path";
import type { Json, Parsed } from "../session-events.ts";

export interface SessionDirectories {
  claudeDir?: string;
  codexDir?: string;
  antigravityDir?: string;
  factoryDir?: string;
  copilotDir?: string;
  codebuddyDir?: string;
  workbuddyDir?: string;
  geminiDir?: string;
  qwenDir?: string;
  opencodeDir?: string;
}

export interface SessionFile {
  path: string;
  cwd?: string;
  fallbackSessionId?: string;
  session?: { id: string; cwd?: string | null; subagent: boolean };
}

export interface SessionAdapter {
  id: string;
  checkpointKey?: string;
  additionalRootFields?: ReadonlySet<string>;
  additionalMessageFields?: ReadonlySet<string>;
  genaiParts?: "content" | "parts";
  files(directories: SessionDirectories, deferDirectory?: (directory: string) => void): Iterable<SessionFile>;
  /** Readers with pending fragments are retried at the quiet boundary even when the file is unchanged. */
  readEvents?(file: string, offset: number, size: number, quiet: boolean):
    AsyncIterable<{ event: Json | null | undefined; damaged: boolean; end: number }>;
  skipSessionVersion?: number;
  sessionId?(event: Json | null, file: SessionFile): unknown;
  /** 子 Agent、分叉等不属于用户直接参与的会话：返回 true 时整段跳过。 */
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

export interface DatabaseProgress {
  identity: string;
  updated: number;
  boundary: string[];
}

export interface DatabaseSessionAdapter {
  id: string;
  checkpointKey?: string;
  database(directories: SessionDirectories): string | null;
  readDatabase(file: string, previous: DatabaseProgress | undefined, floor: number, rescan: boolean): {
    progress: DatabaseProgress;
    rows: { sessionId: string; cwd: string | null; mtime: number; result: Parsed }[];
  } | null;
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
