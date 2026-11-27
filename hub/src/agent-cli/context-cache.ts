import { createDecipheriv } from "node:crypto";
import { execFile } from "node:child_process";
import { readFile, readdir, rm } from "node:fs/promises";
import { join } from "node:path";
import { normalizeGitRemote, originArgs } from "../repo-identity.ts";
import type { DeviceClient } from "../devices/client.ts";
import type { RemoteHubBinding } from "../hub-binding.ts";
import { agentAccount, contextAccount, missing, readAgentKey, type AgentLink, type AgentSecrets } from "./identity.ts";

const maxQueue = 500;
const filename = /^[0-9A-HJKMNP-TV-Z]{26}\.enc$/;

function gitOutput(args: string[], signal: AbortSignal): Promise<string | null> {
  if (signal.aborted) return Promise.resolve(null);
  return new Promise(resolve => {
    execFile("git", args, { encoding: "utf8", signal, timeout: 200, maxBuffer: 8192, killSignal: "SIGKILL" },
      (error, stdout) => resolve(error ? null : stdout.trim()));
  });
}

export async function gitOrigin(cwd: string, signal: AbortSignal) {
  const output = await gitOutput(originArgs(cwd), signal);
  return output && normalizeGitRemote(output) || null;
}

export class ContextCache {
  private readonly root: string;
  private readonly scope: string;

  constructor(dir: string, link: AgentLink, private readonly secrets: AgentSecrets,
              private readonly remote?: RemoteHubBinding | null) {
    this.scope = `${link.hub_id}-${link.device_id}`;
    this.root = join(remote ? join(dir, remote.dir) : dir, "agent-context-cache", this.scope);
  }

  private async key(signal: AbortSignal) {
    const hex = await readAgentKey(this.secrets, agentAccount(contextAccount, this.remote), signal, false);
    return hex === null ? null : Buffer.from(hex, "hex");
  }

  private aad(name: string) { return `tacit:agent-context:v1:${this.scope}:${name}`; }

  private async read(name: string, key: Buffer, signal: AbortSignal): Promise<unknown> {
    try {
      const data = await readFile(join(this.root, name), { signal });
      if (data.length < 30 || data[0] !== 1) return null;
      const decipher = createDecipheriv("aes-256-gcm", key, data.subarray(1, 13));
      decipher.setAAD(Buffer.from(this.aad(name)));
      decipher.setAuthTag(data.subarray(13, 29));
      return JSON.parse(Buffer.concat([decipher.update(data.subarray(29)), decipher.final()]).toString("utf8"));
    } catch { return null; }
  }

  private async names(dir = this.root) {
    try { return (await readdir(dir)).filter(name => filename.test(name)).sort(); }
    catch (error) { if (missing(error)) return []; throw error; }
  }

  /** 会话开始时带入撤下前（2026-11-27）留下的加密项目摘要已无人读取，直接删掉。 */
  async dropProjectCache() {
    await Promise.all((await this.names()).map(name => rm(join(this.root, name), { force: true })));
  }

  async syncAudit(client: DeviceClient, signal: AbortSignal) {
    await this.dropProjectCache().catch(() => {});
    const root = join(this.root, "audit"), pending = (await this.names(root)).slice(-maxQueue);
    if (!pending.length) return;
    const key = await this.key(signal);
    if (!key) return;
    const entries = [];
    for (const name of pending) {
      signal.throwIfAborted();
      const entry = await this.read(`audit/${name}`, key, signal);
      if (entry) entries.push(entry);
    }
    if (!entries.length) return;
    const reply = await client.send<{ accepted: number }>("agent.audit_sync", { entries }, { signal });
    if (reply.status !== 200 || reply.body.accepted !== entries.length) return;
    await Promise.all(pending.map(name => rm(join(root, name), { force: true })));
  }
}
