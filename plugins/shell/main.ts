#!/usr/bin/env bun
import { access, stat, rename, readdir } from "node:fs/promises";
import { createReadStream } from "node:fs";
import { createInterface } from "node:readline";
import path from "node:path";
import os from "node:os";
import { clampTitle, emitRecord, parsePluginArgs, toLocalIso, ulid, validateRecord, type RecordV1 } from "../../packages/record/index.ts";

export interface ShellState { version: 2; }
interface ShellEntry { start_ms: number; duration_ms: number; exit_code: number; cwd: string; command: string; pid: number; }

function isEntry(value: unknown): value is ShellEntry {
  if (!value || typeof value !== "object") return false;
  const v = value as ShellEntry;
  return Number.isSafeInteger(v.start_ms) && v.start_ms >= 0 && !Number.isNaN(new Date(v.start_ms).valueOf())
    && Number.isSafeInteger(v.duration_ms) && v.duration_ms >= 0
    && Number.isInteger(v.exit_code) && v.exit_code >= 0 && v.exit_code <= 255
    && Number.isSafeInteger(v.pid) && v.pid > 0 && typeof v.cwd === "string" && path.isAbsolute(v.cwd)
    && typeof v.command === "string" && v.command.trim().length > 0;
}

async function findRepo(cwd: string): Promise<string | null> {
  for (let current = cwd;; current = path.dirname(current)) {
    try { await access(path.join(current, ".git")); return current; } catch {}
    if (path.dirname(current) === current) return null;
  }
}

export async function collectShell(options: {
  file: string; device: string; state?: ShellState; since?: Date | null;
  emit: (record: RecordV1) => void; log?: (message: string) => void;
}): Promise<{ state: ShellState; release: string[] }> {
  const log = options.log ?? ((message) => console.error(message));
  const since = options.since?.valueOf() ?? -Infinity;
  if (Number.isNaN(since)) throw new Error("无效的 --since 时间");
  const file = path.resolve(options.file), dir = path.dirname(file);
  try {
    if ((await stat(file)).size > 0) {
      await rename(file, path.join(dir, `shell.${ulid()}.pending.jsonl`));
      // 等待已经打开旧文件的钩子完成本次追加。
      await Bun.sleep(200);
    }
  } catch (error) { if ((error as NodeJS.ErrnoException).code !== "ENOENT") throw error; }
  let names: string[];
  try { names = await readdir(dir); }
  catch (error) { if ((error as NodeJS.ErrnoException).code === "ENOENT") return { state: { version: 2 }, release: [] }; throw error; }
  const release: string[] = [], repoCache = new Map<string, string | null>();
  let bad = 0;
  for (const name of names.filter((name) => /^shell\..+\.pending\.jsonl$/.test(name)).sort()) {
    const pendingFile = path.join(dir, name);
    const lines = createInterface({ input: createReadStream(pendingFile), crlfDelay: Infinity });
    for await (const line of lines) {
      let value: unknown;
      try { value = JSON.parse(line); } catch { bad++; continue; }
      if (!isEntry(value)) { bad++; continue; }
      if (value.start_ms < since) continue;
      if (!repoCache.has(value.cwd)) repoCache.set(value.cwd, await findRepo(value.cwd));
      const record: RecordV1 = {
        id: ulid(), schema: 1, device: options.device, source: "mac.shell", kind: "event",
        source_ref: `${value.pid}:${value.start_ms}`, t_start: toLocalIso(value.start_ms),
        context: { cwd: value.cwd, repo: repoCache.get(value.cwd) ?? null },
        title: clampTitle(value.command, 120),
        body: `${value.command}\n\n退出码：${value.exit_code}\n耗时：${value.duration_ms} ms`,
        capture: { method: "hook" }, sensitivity: "normal",
      };
      if (validateRecord(record).ok) options.emit(record); else bad++;
    }
    release.push(pendingFile);
  }
  if (bad) log(`shell：跳过 ${bad} 条坏行`);
  return { state: { version: 2 }, release };
}

if (import.meta.main) {
  try {
    const args = parsePluginArgs();
    const result = await collectShell({ file: process.env.RA_SHELL_LOG ?? path.join(os.homedir(), "Library/Application Support/record-anything/buffer/shell.jsonl"), device: args.device,
      since: args.since, emit: emitRecord });
    process.stdout.write(JSON.stringify({ type: "checkpoint", ...result }) + "\n");
  } catch (error) { console.error(`shell：${(error as Error).message}`); process.exitCode = 1; }
}
