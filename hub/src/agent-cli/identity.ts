import { createHash, randomBytes } from "node:crypto";
import { constants } from "node:fs";
import { link, mkdir, open, readFile, rename, rm, writeFile } from "node:fs/promises";
import { dirname, join } from "node:path";
import { readHubBinding, type RemoteHubBinding } from "../hub-binding.ts";
import { dataDirOf, resolvePort } from "../hub-json.ts";
import { base32, base64url, identityFromRaw, object, suite } from "../devices/envelope.ts";
import { DeviceClient } from "../devices/client.ts";
import { createKeychainAsync, readKeychainAsync } from "../secrets/keychain.ts";

export const deviceAccount = "agent-device-key";
export const contextAccount = "agent-context-cache-key";
type AccountBase = typeof deviceAccount | typeof contextAccount;
type Account = AccountBase | `${AccountBase}.${string}`;
export const agentAccount = (base: AccountBase, remote?: RemoteHubBinding | null): Account => remote ? `${base}.${remote.hub_id}` : base;

export interface AgentSecrets {
  read(account: Account, signal: AbortSignal): Promise<string | null>;
  create(account: Account, value: string, signal: AbortSignal): Promise<void>;
}

export interface AgentLink {
  hub_id: string;
  hub_pk: string;
  device_id: string;
  address: string;
}

export interface AgentClientOptions {
  env?: NodeJS.ProcessEnv;
  secrets?: AgentSecrets;
}

export const missing = (error: unknown) => (error as NodeJS.ErrnoException)?.code === "ENOENT";
const exists = (error: unknown) => (error as NodeJS.ErrnoException)?.code === "EEXIST";

export async function atomicWrite(path: string, value: string | Buffer, create = false) {
  await mkdir(dirname(path), { recursive: true, mode: 0o700 });
  const temp = `${path}.${randomBytes(8).toString("hex")}.tmp`;
  try {
    await writeFile(temp, value, { mode: 0o600, flag: "wx" });
    if (create) {
      try { await link(temp, path); } catch (error) { if (!exists(error)) throw error; }
    } else await rename(temp, path);
  } finally { await rm(temp, { force: true }); }
}

export function fileAgentSecrets(dir: string): AgentSecrets {
  return {
    async read(account, signal) {
      let fd: Awaited<ReturnType<typeof open>>;
      try { fd = await open(join(dir, account), constants.O_RDONLY | constants.O_NOFOLLOW | constants.O_NONBLOCK); }
      catch (error) { if (missing(error)) return null; throw error; }
      try {
        const stat = await fd.stat();
        if (!stat.isFile() || (stat.mode & 0o777) !== 0o600 || stat.size > 65) throw new Error("Agent 密钥文件权限或格式无效");
        return (await fd.readFile({ encoding: "utf8", signal })).trim();
      } finally { await fd.close(); }
    },
    async create(account, value, signal) {
      signal.throwIfAborted();
      await atomicWrite(join(dir, account), value + "\n", true);
    },
  };
}

export function agentSecrets(dir: string) {
  return process.platform === "darwin" ? { read: readKeychainAsync, create: createKeychainAsync } : fileAgentSecrets(dir);
}

export async function readAgentKey(secrets: AgentSecrets, account: Account, signal: AbortSignal, create = false) {
  let hex = await secrets.read(account, signal);
  if (hex === null && create) {
    await secrets.create(account, randomBytes(32).toString("hex"), signal);
    hex = await secrets.read(account, signal);
  }
  if (hex === null && !create) return null;
  if (!hex || !/^[0-9a-f]{64}$/i.test(hex)) throw new Error("Agent 密钥缺失或格式无效");
  return hex;
}

function origin(value: unknown) {
  const url = typeof value === "string" ? URL.parse(value) : null;
  if (!url || !["http:", "https:"].includes(url.protocol) || url.username || url.password || url.search || url.hash || url.pathname !== "/") {
    throw new Error("Agent 中枢地址无效");
  }
  return url.origin;
}

function linkFrom(raw: unknown): AgentLink {
  const row = object(raw);
  const pk = base64url(row?.hub_pk, 32);
  const id = pk && base32(createHash("sha256").update(pk).digest().subarray(0, 16));
  if (!row || !id || row.hub_id !== id || typeof row.device_id !== "string" || !/^agent-[a-z2-7]{8}$/.test(row.device_id)) {
    throw new Error("Agent 连接配置无效");
  }
  return { hub_id: id, hub_pk: row.hub_pk as string, device_id: row.device_id, address: origin(row.address) };
}

export async function readAgentLink(dir: string, signal: AbortSignal): Promise<AgentLink | null> {
  let raw: string;
  try { raw = await readFile(join(dir, "agent-link.json"), { encoding: "utf8", signal }); }
  catch (error) { if (missing(error)) return null; throw error; }
  return linkFrom(JSON.parse(raw));
}

export async function readBoundAgentLink(dir: string, signal: AbortSignal, remote: RemoteHubBinding | null) {
  const link = await readAgentLink(remote ? join(dir, remote.dir) : dir, signal);
  if (remote && (!link || link.hub_id !== remote.hub_id || link.hub_pk !== remote.hub_pk)) {
    throw new Error("远端 Agent 连接配置缺失或与后台绑定不匹配");
  }
  return link;
}

export async function linkedClient(link: AgentLink, env: NodeJS.ProcessEnv, dir: string, secrets: AgentSecrets,
                                   signal: AbortSignal, remote?: RemoteHubBinding | null) {
  const hex = await readAgentKey(secrets, agentAccount(deviceAccount, remote), signal);
  if (hex === null) throw new Error("Agent 私钥缺失，请重新登记设备");
  const loopback = !remote && new URL(link.address).hostname === "127.0.0.1";
  const configured = loopback ? resolvePort(env, dir) : null;
  const address = configured && configured.source !== "default" && configured.port > 0
    ? `http://127.0.0.1:${configured.port}` : link.address;
  const client = new DeviceClient(await suite.kem.deserializePublicKey(base64url(link.hub_pk, 32)!),
    (await identityFromRaw(hex)).keys, address);
  client.device = link.device_id;
  return client;
}

/** Called only by an applied install. The private key is stored before registration for safe retries. */
export async function ensureAgentIdentity(options: AgentClientOptions = {}) {
  const env = options.env ?? process.env, dir = dataDirOf(env);
  const signal = AbortSignal.timeout(10_000);
  const { remote } = readHubBinding(dir);
  const existing = await readBoundAgentLink(dir, signal, remote);
  if (remote) {
    const hex = await readAgentKey(options.secrets ?? agentSecrets(dir), agentAccount(deviceAccount, remote), signal);
    if (!hex) throw new Error("远端 Agent 私钥缺失，请在 Tacit 中重新登记设备");
    return existing!;
  }
  if (existing) return existing;
  const { port } = resolvePort(env, dir);
  if (!port) throw new Error("Agent 登记需要可连接的本机中枢端口");
  const token = (await readFile(join(dir, "token"), { encoding: "utf8", signal })).trim();
  if (!token) throw new Error("Agent 登记需要本机管理令牌");
  const secrets = options.secrets ?? agentSecrets(dir);
  const hex = await readAgentKey(secrets, deviceAccount, signal, true);
  if (!hex) throw new Error("Agent 私钥缺失");
  const { publicKey } = await identityFromRaw(hex);
  const address = `http://127.0.0.1:${port}`;
  let response: Response;
  try {
    response = await fetch(address + "/v1/settings/devices/local-agent", {
      method: "POST", headers: { "Content-Type": "application/json", Authorization: `Bearer ${token}` },
      body: JSON.stringify({ agent_pk: publicKey.toString("base64url") }), signal, redirect: "error",
    });
  } catch { throw new Error("当前无法连接 Tacit 中枢"); }
  if (!response.ok) {
    await response.body?.cancel();
    throw new Error(`Agent 设备登记失败（HTTP ${response.status}）`);
  }
  const raw = object(await response.json());
  const link = linkFrom({ ...raw, device_id: raw?.agent_device_id, address });
  if (raw?.endpoint !== address + "/v1/device") throw new Error("Agent 设备端点无效");
  await atomicWrite(join(dir, "agent-link.json"), JSON.stringify(link) + "\n");
  return link;
}
