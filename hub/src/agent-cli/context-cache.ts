import { createCipheriv, createDecipheriv, randomBytes } from "node:crypto";
import { execFile } from "node:child_process";
import { readFile, readdir, rm } from "node:fs/promises";
import { join } from "node:path";
import { toLocalIso, ulid } from "../../../packages/record/index.ts";
import { normalizeGitRemote, originArgs, projectForPath, projectForRemote, repoContainsPath, repositoryArgs, repositoryRoot } from "../repo-identity.ts";
import type { DeviceClient } from "../devices/client.ts";
import { object } from "../devices/envelope.ts";
import { atomicWrite, contextAccount, missing, readAgentKey, type AgentLink, type AgentSecrets } from "./identity.ts";

const maxAge = 7 * 86_400_000;
const maxQueue = 500;
const filename = /^[0-9A-HJKMNP-TV-Z]{26}\.enc$/;

interface ContextResult {
  text: string;
  project_id: string | null;
  cache?: {
    keys: { repos: string[]; remotes?: string[] };
    ignored_repos: string[];
    result_ids: string[];
    synced_at: string;
  };
}
type ProjectContext = NonNullable<ContextResult["cache"]> & { project_id: string; text: string };

export function readContextResult(raw: unknown): ContextResult | null {
  const row = object(raw);
  if (!row || typeof row.text !== "string") return null;
  const cache = object(row.cache), keys = object(cache?.keys);
  const strings = (value: unknown): value is string[] => Array.isArray(value) && value.every(item => typeof item === "string");
  const id = row.project_id;
  if (typeof id !== "string" || !filename.test(id + ".enc") || !cache || !keys ||
      !strings(keys.repos) || (keys.remotes !== undefined && !strings(keys.remotes)) ||
      !strings(cache.ignored_repos) || !strings(cache.result_ids) || typeof cache.synced_at !== "string" ||
      !Number.isFinite(Date.parse(cache.synced_at))) return { text: row.text, project_id: null };
  return { text: row.text, project_id: id, cache: {
    keys: { repos: keys.repos, remotes: keys.remotes }, ignored_repos: cache.ignored_repos,
    result_ids: cache.result_ids, synced_at: cache.synced_at,
  } };
}

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

  constructor(dir: string, link: AgentLink, private readonly secrets: AgentSecrets) {
    this.scope = `${link.hub_id}-${link.device_id}`;
    this.root = join(dir, "agent-context-cache", this.scope);
  }

  private async key(signal: AbortSignal, create = false) {
    const hex = await readAgentKey(this.secrets, contextAccount, signal, create);
    return hex === null ? null : Buffer.from(hex, "hex");
  }

  private aad(name: string) { return `tacit:agent-context:v1:${this.scope}:${name}`; }

  private async write(name: string, value: object, key: Buffer, signal: AbortSignal) {
    signal.throwIfAborted();
    const nonce = randomBytes(12), cipher = createCipheriv("aes-256-gcm", key, nonce);
    cipher.setAAD(Buffer.from(this.aad(name)));
    const encrypted = Buffer.concat([cipher.update(JSON.stringify(value), "utf8"), cipher.final()]);
    await atomicWrite(join(this.root, name), Buffer.concat([Buffer.from([1]), nonce, cipher.getAuthTag(), encrypted]));
  }

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

  private async find(cwd: string, remote: string | null, key: Buffer, signal: AbortSignal) {
    const names = await this.names();
    const projects: ProjectContext[] = [];
    for (const name of names) {
      signal.throwIfAborted();
      const result = readContextResult(await this.read(name, key, signal));
      if (result?.cache && result.project_id + ".enc" === name && result.project_id) {
        projects.push({ project_id: result.project_id, text: result.text, ...result.cache });
      }
    }
    let root: string | undefined;
    let project = projectForPath(cwd, projects);
    if (!project && projects.length) {
      const output = await gitOutput(repositoryArgs(cwd), signal);
      const [common, worktree] = output?.split("\n") ?? [];
      if (common && worktree) {
        root = repositoryRoot(common, worktree);
        project = projectForPath(root, projects);
      }
    }
    project ??= projectForRemote(remote, projects);
    if (project?.ignored_repos.some(repo => repoContainsPath(repo, cwd) || (root && repoContainsPath(repo, root)))) return null;
    return project;
  }

  async refresh(result: ContextResult, cwd: string, remote: string | null, signal: AbortSignal) {
    const key = await this.key(signal, !!result.cache);
    if (!key) return;
    if (result.cache) {
      await this.write(result.project_id + ".enc", result, key, signal);
    } else {
      const stale = await this.find(cwd, remote, key, signal);
      if (stale) await rm(join(this.root, stale.project_id + ".enc"), { force: true });
    }
  }

  async offline(params: URLSearchParams, remote: string | null, signal: AbortSignal, now = Date.now()) {
    const cwd = params.get("cwd")!;
    const key = await this.key(signal);
    const match = key && await this.find(cwd, remote, key, signal);
    const synced = match && Date.parse(match.synced_at);
    if (!key || !match || !synced || synced > now || now - synced > maxAge || !match.text.trim()) return "";
    const id = ulid(now);
    const entries = join(this.root, "audit");
    await this.write(`audit/${id}.enc`, {
      id, at: new Date(now).toISOString(), tool: params.get("tool"), session: params.get("session") ?? undefined, cwd,
      project_id: match.project_id, result_ids: match.result_ids, cached: true,
    }, key, signal);
    const pending = await this.names(entries);
    for (const name of pending.slice(0, Math.max(0, pending.length - maxQueue))) {
      signal.throwIfAborted();
      await rm(join(entries, name), { force: true });
    }
    return `（离线缓存，同步于 ${toLocalIso(synced).slice(0, 16).replace("T", " ")}）\n${match.text}`;
  }

  async syncAudit(client: DeviceClient, signal: AbortSignal) {
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
