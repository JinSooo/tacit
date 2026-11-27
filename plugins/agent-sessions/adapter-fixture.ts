import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import type { RecordV1 } from "../../packages/record/index.ts";
import { collect, type Options, type State } from "./main.ts";

export const base = Date.parse("2026-11-27T02:00:00Z");
export const at = (minute: number) => new Date(base + minute * 60_000).toISOString();

export function sessionFixture() {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "ra-session-fixture-"));
  const file = (name: string) => {
    const target = path.join(root, name);
    fs.mkdirSync(path.dirname(target), { recursive: true });
    return target;
  };
  const write = (target: string, events: unknown[], append = false) => {
    fs.writeFileSync(target, events.map(event => JSON.stringify(event)).join("\n") + "\n", { flag: append ? "a" : "w" });
    fs.utimesSync(target, base / 1_000, base / 1_000);
  };
  const run = async (options: Partial<Options>, state?: State) => {
    const records: RecordV1[] = [];
    const diagnostics: { unrecognized?: number; damaged?: number }[] = [];
    const next = await collect({
      device: "mac", now: base + 50 * 60_000, state, since: undefined,
      claudeDir: path.join(root, "claude"), codexDir: path.join(root, "codex"), antigravityDir: path.join(root, "gemini"),
      factoryDir: path.join(root, "factory"),
      copilotDir: path.join(root, "copilot"),
      codebuddyDir: path.join(root, "codebuddy"),
      workbuddyDir: path.join(root, "workbuddy"),
      ...options,
      onRecord: record => { records.push(record); },
      onWarning: () => {},
      onDiagnostics: diagnostic => { diagnostics.push(diagnostic); },
    });
    return { records, state: next, diagnostics };
  };
  const claude = (content: string, minute: number) => ({
    type: "user", sessionId: "old", timestamp: at(minute), message: { role: "user", content },
  });
  const oldFile = () => file("claude/projects/demo/old.jsonl");
  const oldCheckpoint = (): State => {
    const target = oldFile();
    write(target, [claude("旧消息", 1)]);
    const stat = fs.statSync(target);
    return {
      version: 2, since: base, replaySince: base,
      files: { [target]: { offset: stat.size, size: stat.size, mtime: stat.mtimeMs, identity: `${stat.dev}:${stat.ino}`, session: "claude:old" } },
      sessions: {
        "claude:old": { provider: "claude", id: "old", cwd: null, mtime: base, seen: {}, buckets: { [base]: { part: 1, messages: [] } } },
      },
    };
  };
  return { file, write, run, oldCheckpoint, appendLegacy: () => write(oldFile(), [claude("旧来源的新消息", 30)], true),
    close: () => fs.rmSync(root, { recursive: true, force: true }) };
}
