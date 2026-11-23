// 服务端后端：32 字节根密钥来自数据目录之外的只读文件，其余密钥合并成一份 AES-256-GCM 密文放在 <数据目录>/secrets.enc。
// 设计见 docs/contracts.md 6.11.3。硬规则：根密钥缺失、位置或权限不对、secrets.enc 解不开，一律失败；绝不自动生成任何密钥。
import { createCipheriv, createDecipheriv, hkdfSync, randomBytes } from "node:crypto";
import { chmodSync, closeSync, existsSync, fsyncSync, openSync, readFileSync, realpathSync, renameSync, rmSync, statSync, writeSync } from "node:fs";
import { basename, dirname, isAbsolute, join, resolve, sep } from "node:path";
import { SecretError } from "./errors.ts";
import { checkAccount, checkValue } from "./accounts.ts";
import type { SecretStore } from "./store.ts";

export const SECRETS_FILE = "secrets.enc";
const MAGIC = Buffer.from("TSE1"); // 文件头同时作为 AEAD 的附加认证数据，版本号变化即格式变化
const NONCE = 12, TAG = 16, MAX_FILE = 1 << 20;
const HKDF_INFO = "tacit-hub/secrets.enc/v1";
const LOCK_STALE_MS = 30_000;

export interface SealedFileOptions {
  dataDir: string;
  /** 根密钥文件的绝对路径（RA_MASTER_KEY_FILE）。 */
  masterKeyFile?: string;
  /** 只给开发测试：64 位十六进制根密钥（RA_MASTER_KEY）；用了就告警。 */
  masterKey?: string;
  warn?: (message: string) => void;
  lockTimeoutMs?: number;
  /** 测试钩子：临时文件写完、替换前调用，抛错即模拟写入中途失败。 */
  beforeCommit?: () => void;
}

const canonical = (path: string): string => {
  try { return realpathSync.native(path); }
  catch { const parent = dirname(path); return parent === path ? path : join(canonical(parent), basename(path)); }
};
const inside = (parent: string, child: string) => child === parent || child.startsWith(parent.endsWith(sep) ? parent : parent + sep);

function parseRootKey(raw: Buffer): Buffer {
  const text = raw.toString("utf8").trim();
  if (/^[0-9a-fA-F]{64}$/.test(text)) return Buffer.from(text, "hex");
  if (raw.length === 32) return Buffer.from(raw);
  throw new SecretError("master_key_format");
}

function loadRootKey(o: SealedFileOptions): Buffer {
  if (o.masterKeyFile) {
    if (!isAbsolute(o.masterKeyFile)) throw new SecretError("master_key_path");
    const dataDir = canonical(resolve(o.dataDir));
    // 字面路径和解开符号链接后的路径都不能落在数据目录里。
    if (inside(resolve(o.dataDir), resolve(o.masterKeyFile)) || inside(dataDir, canonical(o.masterKeyFile))) throw new SecretError("master_key_in_data_dir");
    let raw: Buffer;
    try {
      const stat = statSync(o.masterKeyFile);
      if (!stat.isFile()) throw new SecretError("master_key_unreadable");
      if (process.platform !== "win32" && (stat.mode & 0o077) !== 0) throw new SecretError("master_key_permissions");
      raw = readFileSync(o.masterKeyFile);
    } catch (error) {
      throw error instanceof SecretError ? error : new SecretError("master_key_unreadable");
    }
    try { return parseRootKey(raw); } finally { raw.fill(0); }
  }
  if (o.masterKey !== undefined) {
    if (!/^[0-9a-fA-F]{64}$/.test(o.masterKey)) throw new SecretError("master_key_format");
    (o.warn ?? (m => console.warn(m)))("RA_MASTER_KEY 只供开发测试：根密钥留在进程环境里，生产请改用 RA_MASTER_KEY_FILE。");
    return Buffer.from(o.masterKey, "hex");
  }
  throw new SecretError("master_key_missing");
}

const sleep = (ms: number) => Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, ms);

export function sealedFileStore(o: SealedFileOptions): SecretStore {
  const file = join(o.dataDir, SECRETS_FILE), lockFile = `${file}.lock`;
  const root = loadRootKey(o);
  const fileKey = Buffer.from(hkdfSync("sha256", root, Buffer.alloc(0), HKDF_INFO, 32));
  root.fill(0);

  /** 解开 secrets.enc；文件不存在是空集合（第一次写入时才创建），存在但打不开就失败。 */
  function load(): Map<string, string> {
    if (!existsSync(file)) return new Map();
    let blob: Buffer;
    try {
      if (statSync(file).size > MAX_FILE) throw new SecretError("secrets_corrupt");
      blob = readFileSync(file);
    } catch (error) { throw error instanceof SecretError ? error : new SecretError("secrets_corrupt"); }
    if (blob.length < MAGIC.length + NONCE + TAG || !blob.subarray(0, MAGIC.length).equals(MAGIC)) throw new SecretError("secrets_corrupt");
    let plain: Buffer;
    try {
      const decipher = createDecipheriv("aes-256-gcm", fileKey, blob.subarray(MAGIC.length, MAGIC.length + NONCE));
      decipher.setAAD(MAGIC);
      decipher.setAuthTag(blob.subarray(blob.length - TAG));
      plain = Buffer.concat([decipher.update(blob.subarray(MAGIC.length + NONCE, blob.length - TAG)), decipher.final()]);
    } catch { throw new SecretError("secrets_undecryptable"); }
    try {
      const parsed = JSON.parse(plain.toString("utf8")) as { v?: unknown; entries?: unknown };
      if (parsed?.v !== 1 || !parsed.entries || typeof parsed.entries !== "object" || Array.isArray(parsed.entries)) throw 0;
      const map = new Map<string, string>();
      for (const [account, value] of Object.entries(parsed.entries)) {
        if (typeof value !== "string") throw 0;
        checkAccount(account, "sealed-file");
        map.set(account, value);
      }
      return map;
    } catch { throw new SecretError("secrets_corrupt"); }
    finally { plain.fill(0); }
  }

  function commit(map: Map<string, string>): void {
    const plain = Buffer.from(JSON.stringify({ v: 1, entries: Object.fromEntries(map) }), "utf8");
    const nonce = randomBytes(NONCE), cipher = createCipheriv("aes-256-gcm", fileKey, nonce);
    cipher.setAAD(MAGIC);
    const body = Buffer.concat([cipher.update(plain), cipher.final()]);
    plain.fill(0);
    const blob = Buffer.concat([MAGIC, nonce, body, cipher.getAuthTag()]);
    // 同目录临时文件 + 原子替换：任何时刻磁盘上都是完整的旧文件或完整的新文件。
    const temp = `${file}.${randomBytes(6).toString("hex")}.tmp`;
    let fd: number | undefined;
    try {
      fd = openSync(temp, "wx", 0o600);
      writeSync(fd, blob);
      fsyncSync(fd);
      closeSync(fd); fd = undefined;
      o.beforeCommit?.();
      renameSync(temp, file);
      chmodSync(file, 0o600);
      try { const dir = openSync(o.dataDir, "r"); try { fsyncSync(dir); } finally { closeSync(dir); } } catch { /* 目录同步尽力而为 */ }
    } catch (error) {
      if (fd !== undefined) try { closeSync(fd); } catch { /* 忽略 */ }
      rmSync(temp, { force: true });
      throw error instanceof SecretError ? error : new SecretError("secrets_write");
    }
  }

  /** 读-改-写期间持有锁文件：serve 与 distill 两个进程都可能写。 */
  function locked<T>(fn: () => T): T {
    const deadline = Date.now() + (o.lockTimeoutMs ?? 5_000);
    let fd: number | undefined;
    for (;;) {
      try { fd = openSync(lockFile, "wx", 0o600); break; }
      catch (error) {
        if ((error as NodeJS.ErrnoException).code !== "EEXIST") throw new SecretError("secrets_write");
        try { if (Date.now() - statSync(lockFile).mtimeMs > LOCK_STALE_MS) { rmSync(lockFile, { force: true }); continue; } } catch { continue; }
        if (Date.now() >= deadline) throw new SecretError("secrets_locked");
        sleep(20);
      }
    }
    try { return fn(); }
    finally { try { closeSync(fd!); } catch { /* 忽略 */ } rmSync(lockFile, { force: true }); }
  }

  // 启动即硬校验：已有 secrets.enc 必须能用这把根密钥解开。
  load();
  if (existsSync(file)) { try { chmodSync(file, 0o600); } catch { /* 只读挂载时忽略 */ } }

  return {
    backend: "sealed-file",
    read(account) { checkAccount(account, "sealed-file"); return load().get(account) ?? null; },
    has(account) { checkAccount(account, "sealed-file"); return load().has(account); },
    write(account, value) {
      checkAccount(account, "sealed-file"); checkValue(account, value);
      locked(() => { const map = load(); map.set(account, value); commit(map); });
    },
    create(account, value) {
      checkAccount(account, "sealed-file"); checkValue(account, value);
      return locked(() => {
        const map = load();
        if (map.has(account)) return false;
        map.set(account, value); commit(map);
        return true;
      });
    },
    remove(account) {
      checkAccount(account, "sealed-file");
      return locked(() => {
        const map = load();
        if (!map.delete(account)) return false;
        commit(map);
        return true;
      });
    },
  };
}
