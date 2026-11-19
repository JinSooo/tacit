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

export function resolveLanPort(dataDir: string): number {
  const port = readHubFile(dataDir)?.lan_port;
  if (port === undefined) return DEFAULT_LAN_PORT;
  if (typeof port !== "number" || !Number.isInteger(port) || port < PORT_MIN || port > PORT_MAX) {
    throw new Error(`hub.json 的 lan_port 必须是 ${PORT_MIN}–${PORT_MAX} 的整数`);
  }
  return port;
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
