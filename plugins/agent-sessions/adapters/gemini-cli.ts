import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { ignored, unknown, type Json, type Parsed } from "../session-events.ts";
import { parseGenaiParts } from "./genai-parts.ts";
import { directoriesIn, type SessionAdapter } from "./types.ts";

const sessionName = /^session-.+-(?<shortId>[^-]+)\.jsonl$/;
const systemTypes = new Set(["info", "error", "warning"]);
const rootFields = new Set(["id", "kind", "content", "directories", "$patch", "$rewindTo", "$set"]);

function projectPaths(root: string): Map<string, string> {
  const result = new Map<string, string>();
  try {
    const { projects } = JSON.parse(fs.readFileSync(path.join(root, "projects.json"), "utf8"));
    for (const [cwd, slug] of Object.entries(projects)) {
      if (typeof slug === "string" && path.isAbsolute(cwd)) result.set(slug, cwd);
    }
  } catch {
    // A project can still supply its own marker or directories in the transcript.
  }
  return result;
}

function projectMarker(project: string): string | undefined {
  try {
    const cwd = fs.readFileSync(path.join(project, ".project_root"), "utf8").trim();
    if (path.isAbsolute(cwd)) return cwd;
  } catch {}
}

function parseGeminiEvent(event: Json | null, hasSession: boolean): Parsed {
  if (!event) return unknown;
  if (Object.hasOwn(event, "$patch") || Object.hasOwn(event, "$rewindTo") || Object.hasOwn(event, "$set")) return ignored;
  if (event.type === undefined && typeof event.sessionId === "string") return ignored;
  if (systemTypes.has(event.type)) return ignored;
  if (event.type !== "user" && event.type !== "gemini") return unknown;
  if (typeof event.id !== "string" || !event.id) return unknown;
  const parts = Array.isArray(event.content) ? event.content : [event.content];
  return parseGenaiParts(event.type === "user" ? "user" : "assistant", event.timestamp, parts, hasSession);
}

export const geminiCli: SessionAdapter = {
  id: "gemini-cli",
  additionalRootFields: rootFields,
  genaiParts: "content",
  *files({ geminiDir }) {
    const home = process.env.GEMINI_CLI_HOME || os.homedir();
    const override = geminiDir ?? process.env.RA_GEMINI_DIR;
    const root = override ?? path.join(home, ".gemini");
    const runtimes = [path.join(root, "tmp")];
    if (override === undefined) runtimes.push(path.join(home, ".cache", ".gemini", "tmp"));
    const projects = projectPaths(root);
    const scanned = new Set<string>();
    for (const runtime of runtimes) {
      let real: string;
      try { real = fs.realpathSync(runtime); } catch { continue; }
      if (scanned.has(real)) continue;
      scanned.add(real);
      for (const project of directoriesIn(runtime)) {
        const chats = path.join(project, "chats");
        if (!fs.lstatSync(chats, { throwIfNoEntry: false })?.isDirectory()) continue;
        const cwd = projects.get(path.basename(project)) ?? projectMarker(project);
        for (const entry of fs.readdirSync(chats, { withFileTypes: true })) {
          if (!entry.isFile()) continue;
          const fallbackSessionId = sessionName.exec(entry.name)?.groups?.shortId;
          if (fallbackSessionId) yield { path: path.join(chats, entry.name), cwd, fallbackSessionId };
        }
      }
    }
  },
  sessionId(event) { return event?.sessionId; },
  cwd(event, file) {
    const directory = event.directories?.[0];
    return file.cwd ?? (typeof directory === "string" && path.isAbsolute(directory) ? directory : undefined);
  },
  skipSession(event) { return event.kind === "subagent"; },
  parse: parseGeminiEvent,
};
