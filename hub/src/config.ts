import { chmodSync, closeSync, existsSync, mkdirSync, openSync, readdirSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { randomBytes } from "node:crypto";
import { SecretError, openSecretStore, type SecretStore } from "./secrets/index.ts";
import { dataDirOf, hubModeOf, resolveLanPort, resolvePort, resolveTimezone, type HubMode } from "./hub-json.ts";

export interface HubConfig { dataDir: string; dbKey: string; token: string; agentToken: string; port: number; lanPort: number; mode: HubMode }

const unreadableKey = () => Object.assign(new Error("无法读取或保存数据库密钥"), { code: "db_key_unreadable" });
/** 根密钥和 secrets.enc 的问题保留固定类别（master_key_unreadable）；其余存取失败统一成 db_key_unreadable。 */
const keyFailure = (error: unknown) => error instanceof SecretError && error.code === "master_key_unreadable" ? error : unreadableKey();

export function loadConfig(
  env: NodeJS.ProcessEnv = process.env,
  /** 只给测试：换掉按环境选出的密钥后端。 */
  secrets?: SecretStore,
): HubConfig {
  const dataDir = dataDirOf(env);
  const mode = hubModeOf(env);
  const { port } = resolvePort(env, dataDir);
  const lanPort = resolveLanPort(dataDir, env);
  resolveTimezone(env, dataDir);
  mkdirSync(dataDir, { recursive: true, mode: 0o700 });
  let dbKey = env.RA_DB_KEY;
  if (dbKey === undefined) {
    // sealed-file 在这里就做启动硬校验：根密钥缺失、位置或权限不对、secrets.enc 解不开都直接抛错，不往下新建任何密钥。
    let store: SecretStore;
    try { store = secrets ?? openSecretStore({ env, dataDir }); } catch (error) { throw keyFailure(error); }
    let found: string | null;
    try { found = store.read("db-key"); } catch (error) { throw keyFailure(error); }
    if (found === null) {
      // 主库、SQLite 附属文件及迁移副本都可能是唯一可恢复的加密数据。
      if (readdirSync(dataDir).some(name => /\.(?:db|sqlite3?)(?:$|[-.])/i.test(name))) {
        throw Object.assign(new Error(`${store.backend === "keychain" ? "钥匙串" : "secrets.enc"}里找不到数据库密钥，但已有记录库`), { code: "db_key_missing" });
      }
      const candidate = randomBytes(32).toString("hex");
      try {
        // 只在不存在时创建；并发的另一个进程先建好了就用它的，绝不覆盖。
        found = store.create("db-key", candidate) ? candidate : store.read("db-key");
      } catch (error) { throw keyFailure(error); }
    }
    dbKey = found ?? undefined;
  }
  if (!dbKey) throw unreadableKey();
  const token = localToken(dataDir, "token"), agentToken = localToken(dataDir, "agent-token");
  return { dataDir, dbKey, token, agentToken, port, lanPort, mode };
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
