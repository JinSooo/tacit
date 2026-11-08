import { chmodSync, closeSync, existsSync, mkdirSync, openSync, readFileSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";
import { randomBytes } from "node:crypto";
import { spawnSync } from "node:child_process";

export interface HubConfig { dataDir: string; dbKey: string; token: string; port: number }

export function loadConfig(env: NodeJS.ProcessEnv = process.env): HubConfig {
  const dataDir = env.RA_DATA_DIR ?? join(homedir(), "Library/Application Support/record-anything");
  const port = Number(env.RA_PORT ?? 47823);
  if (!Number.isInteger(port) || port < 0 || port > 65535) throw new Error("RA_PORT 必须是 0–65535 的整数");
  mkdirSync(dataDir, { recursive: true, mode: 0o700 });
  let dbKey = env.RA_DB_KEY;
  if (dbKey === undefined) {
    if (process.platform !== "darwin") throw new Error("此平台请设置 RA_DB_KEY");
    const found = spawnSync("security", ["find-generic-password", "-s", "record-anything", "-a", "db-key", "-w"], { encoding: "utf8" });
    if (found.status === 0) dbKey = found.stdout.trim();
    else if (found.status === 44) {
      const candidate = randomBytes(32).toString("hex");
      const added = spawnSync("security", ["add-generic-password", "-s", "record-anything", "-a", "db-key", "-w", candidate]);
      if (added.status !== 0) throw new Error("无法保存数据库密钥到钥匙串");
      dbKey = candidate;
    } else throw new Error("无法读取数据库钥匙串（不会覆盖已有密钥）");
  }
  if (!dbKey) throw new Error("数据库密钥不能为空");
  const tokenFile = join(dataDir, "token");
  if (!existsSync(tokenFile)) {
    try {
      const fd = openSync(tokenFile, "wx", 0o600);
      try { writeFileSync(fd, randomBytes(32).toString("hex") + "\n"); } finally { closeSync(fd); }
    } catch (e) { if ((e as NodeJS.ErrnoException).code !== "EEXIST") throw e; }
  }
  chmodSync(tokenFile, 0o600);
  const token = readFileSync(tokenFile, "utf8").trim();
  if (!token) throw new Error("本地 token 文件为空");
  return { dataDir, dbKey, token, port };
}
