// 诊断采样：只读模型计量列，不读取 History 正文，不修改加密数据库。
// 同 hub/src/db.ts：依赖的 exports 缺 types，类型从声明文件读取。
import type DatabaseTypes from "../node_modules/better-sqlite3-multiple-ciphers/index.d.ts";
import { createRequire } from "node:module";
const Database: typeof DatabaseTypes = createRequire(import.meta.url)("better-sqlite3-multiple-ciphers");
import { spawnSync } from "node:child_process";
import { join } from "node:path";
import { homedir } from "node:os";

const root = process.argv[2] ?? join(homedir(), "Library/Application Support/record-anything");
const result = spawnSync("/usr/bin/security", ["find-generic-password", "-s", "record-anything", "-a", "db-key", "-w"], { encoding: "utf8" });
if (result.status !== 0 || !result.stdout.trim()) throw new Error("database key unavailable");
const db = new Database(join(root, "history.db"), { readonly: true });
try {
  db.pragma("cipher='sqlcipher'"); db.pragma("legacy=4");
  db.pragma("key='" + result.stdout.trim().replaceAll("'", "''") + "'");
  db.pragma("query_only=ON");
  const now = new Date(), start = new Date(now);
  start.setHours(0, 0, 0, 0); start.setDate(start.getDate() - 1);
  const dateOf = (d: Date) => `${d.getFullYear()}-${String(d.getMonth()+1).padStart(2,"0")}-${String(d.getDate()).padStart(2,"0")}`;
  type Row = { at: string; task: string | null; tier: string; provider: string; model: string; ok: number; input_tokens: number | null; output_tokens: number | null; ms: number };
  const rows = db.prepare("SELECT at,task,tier,provider,model,ok,input_tokens,output_tokens,ms FROM llm_usage WHERE julianday(at)>=julianday(?) AND julianday(at)<=julianday(?)").all(start.toISOString(), now.toISOString()) as Row[];
  const days: Record<string, Record<string, unknown>[]> = { [dateOf(start)]: [], [dateOf(now)]: [] };
  const groups = new Map<string, { date: string; task: string | null; tier: string; provider: string; model: string; calls: number; failed: number; input_tokens: number; output_tokens: number; missing_input: number; missing_output: number; ms: number }>();
  for (const row of rows) {
    const date = dateOf(new Date(row.at));
    const key = JSON.stringify([date, row.task, row.tier, row.provider, row.model]);
    const value = groups.get(key) ?? { date, task: row.task, tier: row.tier, provider: row.provider, model: row.model, calls: 0, failed: 0, input_tokens: 0, output_tokens: 0, missing_input: 0, missing_output: 0, ms: 0 };
    value.calls++; value.failed += row.ok ? 0 : 1;
    value.input_tokens += row.input_tokens ?? 0; value.output_tokens += row.output_tokens ?? 0;
    value.missing_input += Number(row.input_tokens == null); value.missing_output += Number(row.output_tokens == null);
    value.ms += row.ms ?? 0; groups.set(key, value);
  }
  for (const { date, ...value } of groups.values()) (days[date] ??= []).push(value);
  console.log(JSON.stringify({ at: now.toISOString(), timezone: Intl.DateTimeFormat().resolvedOptions().timeZone, days }));
} finally { db.close(); }
