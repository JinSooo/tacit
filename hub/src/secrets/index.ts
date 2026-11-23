// 密钥存放入口：按环境选后端，统一成 SecretStore。设计见 docs/contracts.md 6.11.3。
//   RA_SECRET_BACKEND=keychain | sealed-file；不设时 macOS 用 keychain（老用户零变化），其他系统用 sealed-file。
//   sealed-file：RA_MASTER_KEY_FILE（数据目录之外、0400/0600）；仅开发测试可用 RA_MASTER_KEY。
import { dataDirOf } from "../hub-json.ts";
import { SecretError } from "./errors.ts";
import { keychainStore, type SecurityRun } from "./keychain.ts";
import { sealedFileStore, type SealedFileOptions } from "./sealed-file.ts";
import type { SecretStore } from "./store.ts";

export { SecretError, type SecretCode, type SecretReason } from "./errors.ts";
export { PROVIDER_KEY_PATTERN, checkAccount, checkValue, providerAccount, relayAccount } from "./accounts.ts";
export { keychainStore, runSystemSecurity, KEYCHAIN_SERVICE, type SecurityRun } from "./keychain.ts";
export { sealedFileStore, SECRETS_FILE, type SealedFileOptions } from "./sealed-file.ts";
export type { SecretStore } from "./store.ts";

export type SecretBackend = SecretStore["backend"];

export function secretBackendOf(env: NodeJS.ProcessEnv = process.env, platform: string = process.platform): SecretBackend {
  const value = env.RA_SECRET_BACKEND?.trim();
  if (!value) return platform === "darwin" ? "keychain" : "sealed-file";
  if (value === "keychain" || value === "sealed-file") return value;
  throw new SecretError("invalid_config");
}

export interface OpenSecretStoreOptions {
  env?: NodeJS.ProcessEnv;
  dataDir?: string;
  /** 只给测试：换掉 /usr/bin/security。 */
  run?: SecurityRun;
  sealed?: Partial<SealedFileOptions>;
}

export function openSecretStore(o: OpenSecretStoreOptions = {}): SecretStore {
  const env = o.env ?? process.env;
  if (secretBackendOf(env) === "keychain") return keychainStore(o.run);
  const masterKeyFile = env.RA_MASTER_KEY_FILE?.trim() || undefined;
  return sealedFileStore({ dataDir: o.dataDir ?? dataDirOf(env), masterKeyFile, masterKey: masterKeyFile ? undefined : env.RA_MASTER_KEY || undefined, ...o.sealed });
}

let cached: { key: string; store: SecretStore } | undefined;

/** 进程内共用的默认存储，按当前环境惰性创建；环境变了（只会出现在测试里）就重建。创建失败不缓存，下次重试。 */
export function defaultSecretStore(env: NodeJS.ProcessEnv = process.env): SecretStore {
  const key = JSON.stringify([env.RA_SECRET_BACKEND, env.RA_DATA_DIR, env.RA_MASTER_KEY_FILE, env.RA_MASTER_KEY !== undefined, process.platform]);
  if (cached?.key !== key) cached = { key, store: openSecretStore({ env }) };
  return cached.store;
}
