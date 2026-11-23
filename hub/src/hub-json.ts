// 中枢端口和数据目录的唯一来源。Agent 侧薄进程（MCP、钩子）也会引用，只能依赖 node 内置模块。
import { readFileSync, renameSync, writeFileSync, rmSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";
import { randomBytes } from "node:crypto";

export const DEFAULT_PORT = 47823;
export const DEFAULT_LAN_PORT = 47824;
/** hub.json 里允许的端口：避开需要特权的 0–1023。 */
export const PORT_MIN = 1024, PORT_MAX = 65535;
export type PortSource = "env" | "file" | "default";
export type HubMode = "mac" | "server";
export type TimezoneSource = "env" | "file" | "unset";

export const UTC_TIMEZONE_WARNING = "当前服务端时区为 UTC 且未显式配置时区，请设置 TZ 环境变量或在 hub.json 中配置 timezone，以免时间线和自然日错位。";

export function hubModeOf(env: NodeJS.ProcessEnv = process.env, platform: string = process.platform): HubMode {
  const value = env.RA_HUB_MODE?.trim();
  if (!value) return platform === "darwin" ? "mac" : "server";
  if (value === "mac" || value === "server") return value;
  throw new Error("RA_HUB_MODE 必须是 mac 或 server");
}

export function dataDirOf(env: NodeJS.ProcessEnv = process.env): string {
  return env.RA_DATA_DIR ?? join(homedir(), "Library/Application Support/record-anything");
}

function readHubFile(dataDir: string): Record<string, unknown> | null {
  let text: string;
  try { text = readFileSync(join(dataDir, "hub.json"), "utf8"); }
  catch (error) {
    if ((error as NodeJS.ErrnoException).code === "ENOENT") return null;
    throw new Error("无法读取 hub.json");
  }
  let value: unknown;
  try { value = JSON.parse(text); } catch { throw new Error("hub.json 不是合法 JSON"); }
  if (!value || typeof value !== "object" || Array.isArray(value)) throw new Error("hub.json 必须是对象");
  return value as Record<string, unknown>;
}

/** 优先级：环境变量 RA_PORT > 数据目录 hub.json 的 port > 47823。RA_PORT 允许 0（测试用随机端口）。 */
export function resolvePort(env: NodeJS.ProcessEnv = process.env, dataDir = dataDirOf(env)): { port: number; source: PortSource } {
  if (env.RA_PORT !== undefined) {
    const port = Number(env.RA_PORT);
    if (!env.RA_PORT.trim() || !Number.isInteger(port) || port < 0 || port > 65535) throw new Error("RA_PORT 必须是 0–65535 的整数");
    return { port, source: "env" };
  }
  const file = readHubFile(dataDir);
  if (file?.port !== undefined) {
    const port = file.port;
    if (typeof port !== "number" || !Number.isInteger(port) || port < PORT_MIN || port > PORT_MAX) throw new Error(`hub.json 的 port 必须是 ${PORT_MIN}–${PORT_MAX} 的整数`);
    return { port, source: "file" };
  }
  return { port: DEFAULT_PORT, source: "default" };
}

/** 优先级：环境变量 RA_LAN_PORT > 数据目录 hub.json 的 lan_port > 47824。RA_LAN_PORT 允许 0（测试用随机端口）。 */
export function resolveLanPort(dataDir: string, env: NodeJS.ProcessEnv = process.env): number {
  if (env.RA_LAN_PORT !== undefined) {
    const port = Number(env.RA_LAN_PORT);
    if (!env.RA_LAN_PORT.trim() || !Number.isInteger(port) || port < 0 || port > 65535) throw new Error("RA_LAN_PORT 必须是 0–65535 的整数");
    return port;
  }
  const port = readHubFile(dataDir)?.lan_port;
  if (port === undefined) return DEFAULT_LAN_PORT;
  if (typeof port !== "number" || !Number.isInteger(port) || port < PORT_MIN || port > PORT_MAX) {
    throw new Error(`hub.json 的 lan_port 必须是 ${PORT_MIN}–${PORT_MAX} 的整数`);
  }
  return port;
}

const IANA_TIMEZONE = /^[A-Za-z][A-Za-z0-9_+-]*(?:\/[A-Za-z0-9_+-]+)*$/;
const UTC_ZONES = new Set([
  "UTC", "Etc/UTC", "Etc/GMT", "Etc/GMT+0", "Etc/GMT-0", "Etc/GMT0",
  "GMT", "GMT0", "GMT+0", "GMT-0", "Etc/UCT", "UCT",
  "Etc/Universal", "Universal", "Etc/Zulu", "Zulu", "Etc/Greenwich", "Greenwich",
]);

export function isValidTimeZone(value: unknown): value is string {
  if (typeof value !== "string" || !value || value.length > 100 || !IANA_TIMEZONE.test(value)) return false;
  try {
    new Intl.DateTimeFormat("en-US", { timeZone: value });
    return true;
  } catch {
    return false;
  }
}

export function isUtcTimezone(tz: string): boolean {
  return UTC_ZONES.has(tz);
}

export function resolveTimezone(env: NodeJS.ProcessEnv = process.env, dataDir = dataDirOf(env)): { timezone: string | null; source: TimezoneSource } {
  const fromEnv = env.TZ?.trim();
  if (fromEnv) return { timezone: fromEnv, source: "env" };
  const file = readHubFile(dataDir);
  if (file?.timezone !== undefined) {
    if (!isValidTimeZone(file.timezone)) throw new Error("hub.json 的 timezone 必须是合法的 IANA 时区名");
    return { timezone: file.timezone, source: "file" };
  }
  return { timezone: null, source: "unset" };
}

/** 未设 TZ 且 hub.json 配了 timezone 时，写入 env.TZ 让当前进程与子进程采用该时区。 */
export function applyTimezone(env: NodeJS.ProcessEnv = process.env, dataDir = dataDirOf(env)): { timezone: string | null; source: TimezoneSource } {
  const resolved = resolveTimezone(env, dataDir);
  if (resolved.source === "file" && resolved.timezone) env.TZ = resolved.timezone;
  return resolved;
}

export interface TimezoneStatus {
  current: string;
  configured: string | null;
  source: TimezoneSource;
  warning: string | null;
}

export function timezoneStatus(options: { env?: NodeJS.ProcessEnv; dataDir?: string; mode?: HubMode; processTimezone?: string } = {}): TimezoneStatus {
  const env = options.env ?? process.env;
  const dataDir = options.dataDir ?? dataDirOf(env);
  const mode = options.mode ?? hubModeOf(env);
  let resolved: { timezone: string | null; source: TimezoneSource } = { timezone: null, source: "unset" };
  try { resolved = resolveTimezone(env, dataDir); } catch { /* 状态页不因损坏的 hub.json 崩溃 */ }
  const current = options.processTimezone ?? (Intl.DateTimeFormat().resolvedOptions().timeZone || "UTC");
  const warning = mode === "server" && resolved.source === "unset" && isUtcTimezone(current) ? UTC_TIMEZONE_WARNING : null;
  return { current, configured: resolved.timezone, source: resolved.source, warning };
}

/** 原子写入 hub.json 的 port，保留文件里的其他字段。 */
export function writeHubPort(dataDir: string, port: number): void {
  if (!Number.isInteger(port) || port < PORT_MIN || port > PORT_MAX) throw new Error(`端口必须是 ${PORT_MIN}–${PORT_MAX} 的整数`);
  const current = readHubFile(dataDir) ?? {};
  const file = join(dataDir, "hub.json"), temp = `${file}.${randomBytes(6).toString("hex")}.tmp`;
  try {
    writeFileSync(temp, JSON.stringify({ ...current, port }, null, 2) + "\n", { mode: 0o600, flag: "wx" });
    renameSync(temp, file);
  } catch (error) { rmSync(temp, { force: true }); throw error; }
}
