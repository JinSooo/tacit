import { chmodSync, closeSync, existsSync, mkdirSync, openSync, readdirSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { randomBytes } from "node:crypto";
import { spawnSync } from "node:child_process";
import { dataDirOf, resolvePort } from "./hub-json.ts";

export interface HubConfig { dataDir: string; dbKey: string; token: string; agentToken: string; port: number }

const unreadableKey = () => Object.assign(new Error("无法读取或保存数据库密钥"), { code: "db_key_unreadable" });

function runSecurity(args: string[]) {
  if (process.platform !== "darwin") throw unreadableKey();
  return spawnSync("security", args, { encoding: "utf8", timeout: 15_000, killSignal: "SIGKILL", stdio: ["ignore", "pipe", "ignore"] });
}

export function loadConfig(
  env: NodeJS.ProcessEnv = process.env,
  security: (args: string[]) => Pick<ReturnType<typeof runSecurity>, "status" | "stdout" | "error"> = runSecurity,
): HubConfig {
  const dataDir = dataDirOf(env);
  const { port } = resolvePort(env, dataDir);
  mkdirSync(dataDir, { recursive: true, mode: 0o700 });
  let dbKey = env.RA_DB_KEY;
  if (dbKey === undefined) {
    const keyArgs = ["-s", "record-anything", "-a", "db-key", "-w"];
    const found = security(["find-generic-password", ...keyArgs]);
    if (found.error) throw unreadableKey();
    if (found.status === 0) dbKey = found.stdout.trim();
    else if (found.status === 44) {
      // 主库、SQLite 附属文件及迁移副本都可能是唯一可恢复的加密数据。
      if (readdirSync(dataDir).some(name => /\.(?:db|sqlite3?)(?:$|[-.])/i.test(name))) {
        throw Object.assign(new Error("钥匙串里找不到数据库密钥，但已有记录库"), { code: "db_key_missing" });
      }
      const candidate = randomBytes(32).toString("hex");
      const added = security(["add-generic-password", ...keyArgs, candidate]);
      if (added.error || added.status !== 0) throw unreadableKey();
      dbKey = candidate;
    } else throw unreadableKey();
  }
  if (!dbKey) throw unreadableKey();
  const token = localToken(dataDir, "token"), agentToken = localToken(dataDir, "agent-token");
  return { dataDir, dbKey, token, agentToken, port };
}
function localToken(dataDir: string, name: string): string {
  const tokenFile = join(dataDir, name);
  if (!existsSync(tokenFile)) {
    try {
      const fd = openSync(tokenFile, "wx", 0o600);
      try { writeFileSync(fd, randomBytes(32).toString("hex") + "\n"); } finally { closeSync(fd); }
    } catch (e) { if ((e as NodeJS.ErrnoException).code !== "EEXIST") throw e; }
  }
  chmodSync(tokenFile, 0o600);
  const token = readFileSync(tokenFile, "utf8").trim();
  if (!token) throw new Error("本地 token 文件为空");
  return token;
}
