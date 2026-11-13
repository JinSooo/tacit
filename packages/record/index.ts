import { capturePrefix } from "./capture-prefix.ts";
// Shared helpers for producers (plugins, collectors) and the hub.
// Contract: docs/contracts.md · Schema: schema/record.schema.json
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import Ajv2020 from "ajv/dist/2020.js";
import addFormats from "ajv-formats";

export type Kind = "span" | "event";
export type CaptureMethod = "ax" | "ocr" | "asr" | "db" | "file" | "hook" | "api" | "manual";
export type Sensitivity = "normal" | "private" | "redacted";

export interface RecordContext {
  app?: string | null;
  window?: string | null;
  url?: string | null;
  repo?: string | null;
  cwd?: string | null;
  chat?: string | null;
  place?: string | null;
  extra?: Record<string, unknown>;
}

export interface RecordV1 {
  id: string;
  schema: 1;
  device: string;
  source: string;
  source_ref?: string | null;
  kind: Kind;
  t_start: string;
  t_end?: string | null;
  context?: RecordContext;
  people?: string[];
  title: string;
  body: string;
  media?: { path: string; kind: "audio"; expires?: string | null }[];
  capture: { method: CaptureMethod; confidence?: number };
  sensitivity: Sensitivity;
  redactions?: number;
  corrects?: string | null;
}

/** Lines a plugin writes to stdout, one JSON object per line. */
export type PluginLine =
  | { type: "record"; record: RecordV1 }
  | { type: "checkpoint"; state: unknown; release?: string[] };

// ---------- ULID ----------
const CROCKFORD = "0123456789ABCDEFGHJKMNPQRSTVWXYZ";
// 同一毫秒内生成的 id 按生成顺序递增（monotonic ULID）：审计、修正等按 id 排序取"最新"时才不会排反。
// 按时间记住最近一次的随机部分：显式传入的旧时间和当前时间交替生成时也能各自递增。
const recent = new Map<number, number[]>();
export function ulid(timeMs: number = Date.now()): string {
  const time = Math.floor(timeMs);
  let rand: number[];
  const last = recent.get(time);
  if (last) {
    rand = [...last];
    let i = rand.length - 1;
    while (i >= 0 && rand[i] === 31) rand[i--] = 0;
    if (i < 0) throw new Error("同一毫秒内的 ULID 用尽");
    rand[i]!++;
  } else {
    rand = Array.from(crypto.getRandomValues(new Uint8Array(16)), (b) => b % 32);
    // 首位留余量，避免同一毫秒内递增时溢出。
    rand[0] = rand[0]! % 16;
  }
  recent.delete(time); recent.set(time, rand);
  if (recent.size > 256) recent.delete(recent.keys().next().value!);
  let t = time;
  let ts = "";
  for (let i = 0; i < 10; i++) { ts = CROCKFORD[t % 32] + ts; t = Math.floor(t / 32); }
  return ts + rand.map((n) => CROCKFORD[n]).join("");
}

// ---------- time ----------
/** RFC 3339 with the local UTC offset, e.g. 2026-11-08T14:02:10+08:00 */
export function toLocalIso(d: Date | number): string {
  const date = typeof d === "number" ? new Date(d) : d;
  const off = -date.getTimezoneOffset();
  const sign = off >= 0 ? "+" : "-";
  const pad = (n: number) => String(Math.floor(Math.abs(n))).padStart(2, "0");
  const local = new Date(date.getTime() + off * 60_000);
  const base = local.toISOString().slice(0, 19);
  return `${base}${sign}${pad(off / 60)}:${pad(off % 60)}`;
}

// ---------- validation ----------
const here = path.dirname(fileURLToPath(import.meta.url));
export const SCHEMA_PATH = path.resolve(here, "../../schema/record.schema.json");
let validator: ReturnType<InstanceType<typeof Ajv2020>["compile"]> | null = null;
export function validateRecord(r: unknown): { ok: true } | { ok: false; errors: string[] } {
  if (!validator) {
    const ajv = new Ajv2020({ allErrors: true, strict: false });
    (addFormats as unknown as (a: unknown) => void)(ajv);
    validator = ajv.compile(JSON.parse(fs.readFileSync(SCHEMA_PATH, "utf8")));
  }
  if (validator(r)) return { ok: true };
  return { ok: false, errors: (validator.errors ?? []).map((e) => `${e.instancePath || "/"} ${e.message}`) };
}

// ---------- plugin side ----------
export interface PluginArgs { device: string; stateFile: string | null; since: Date | null; argv: string[] }

/** Parses the standard plugin flags: --device <name> [--state <file>] [--since <iso>] */
export function parsePluginArgs(argv = process.argv.slice(2)): PluginArgs {
  const get = (flag: string) => { const i = argv.indexOf(flag); return i >= 0 ? argv[i + 1] ?? null : null; };
  const device = get("--device") ?? "mac";
  const since = get("--since");
  return { device, stateFile: get("--state"), since: since ? new Date(since) : null, argv };
}

/** Plugins only READ state. The runner persists the last checkpoint after the hub accepted the batch. */
export function readState<T>(stateFile: string | null, fallback: T): T {
  if (!stateFile || !fs.existsSync(stateFile)) return fallback;
  try { return JSON.parse(fs.readFileSync(stateFile, "utf8")) as T; } catch { return fallback; }
}

export function emitRecord(record: RecordV1): void {
  process.stdout.write(JSON.stringify({ type: "record", record } satisfies PluginLine) + "\n");
}
/** release：已完整读完、hub 接收后可以删除的缓冲文件（绝对路径，必须在数据目录 buffer/ 下）。 */
export function emitCheckpoint(state: unknown, release?: string[]): void {
  const line: PluginLine = release?.length ? { type: "checkpoint", state, release } : { type: "checkpoint", state };
  process.stdout.write(JSON.stringify(line) + "\n");
}

/** Trims to the schema's title limit on a code-point boundary. */
export function clampTitle(s: string, max = 200): string {
  const one = s.replace(/\s+/g, " ").trim() || "(untitled)";
  const cps = Array.from(one);
  return cps.length <= max ? one : capturePrefix(one, cps.slice(0, max - 1).join("").length) + "…";
}
