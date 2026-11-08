#!/usr/bin/env bun
import { open, access } from "node:fs/promises";
import path from "node:path";
import os from "node:os";
import { clampTitle, emitCheckpoint, emitRecord, parsePluginArgs, readState, toLocalIso, ulid, validateRecord, type RecordV1 } from "../../packages/record/index.ts";

export interface ShellState { offset: number; inode: string | null; device?: string; }
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
}): Promise<ShellState> {
  const log = options.log ?? ((message) => console.error(message));
  let handle;
  try { handle = await open(options.file, "r"); }
  catch (error) { if ((error as NodeJS.ErrnoException).code === "ENOENT") return { offset: 0, inode: null }; throw error; }
  try {
    const stat = await handle.stat({ bigint: true });
    const inode = stat.ino.toString(), device = stat.dev.toString();
    const old = options.state;
    let offset = old?.inode === inode && (!old.device || old.device === device)
      && Number.isSafeInteger(old.offset) && old.offset >= 0 && BigInt(old.offset) <= stat.size ? old.offset : 0;
    const since = options.since?.valueOf() ?? (old?.inode ? -Infinity : Date.now() - 7 * 86400_000);
    if (Number.isNaN(since)) throw new Error("无效的 --since 时间");
    let position = offset, pending = Buffer.alloc(0), bad = 0;
    const chunk = Buffer.alloc(64 * 1024);
    const repoCache = new Map<string, string | null>();
    while (BigInt(position) < stat.size) {
      const length = Number(stat.size - BigInt(position) < BigInt(chunk.length) ? stat.size - BigInt(position) : BigInt(chunk.length));
      const { bytesRead } = await handle.read(chunk, 0, length, position);
      if (!bytesRead) break;
      position += bytesRead;
      pending = Buffer.concat([pending, chunk.subarray(0, bytesRead)]);
      let begin = 0, end: number;
      while ((end = pending.indexOf(10, begin)) !== -1) {
        const line = pending.subarray(begin, end).toString("utf8");
        const lineBytes = end + 1 - begin;
        let value: unknown;
        try { value = JSON.parse(line); } catch { bad++; }
        if (value !== undefined) {
          if (!isEntry(value)) bad++;
          else if (value.start_ms >= since) {
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
        }
        offset += lineBytes;
        begin = end + 1;
      }
      pending = Buffer.from(pending.subarray(begin));
    }
    if (bad) log(`shell：跳过 ${bad} 条坏行`);
    // 尾部未完成的一行留到下一次，偏移始终按原始字节计算。
    return { offset, inode, device };
  } finally { await handle.close(); }
}

if (import.meta.main) {
  try {
    const args = parsePluginArgs();
    const state = await collectShell({ file: process.env.RA_SHELL_LOG ?? path.join(os.homedir(), "Library/Application Support/record-anything/buffer/shell.jsonl"), device: args.device,
      state: readState<ShellState>(args.stateFile, { offset: 0, inode: null }), since: args.since, emit: emitRecord });
    emitCheckpoint(state);
  } catch (error) { console.error(`shell：${(error as Error).message}`); process.exitCode = 1; }
}
