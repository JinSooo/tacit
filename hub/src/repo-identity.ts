import { homedir } from "node:os";
import { basename, dirname, resolve, sep } from "node:path";

export function repoContainsPath(repo: string, path: string): boolean {
  const root = resolve(repo), absolute = resolve(path);
  return root !== homedir() && (absolute === root || absolute.startsWith(root.endsWith(sep) ? root : root + sep));
}

/** 按路径边界取最长别名，不能把 foo 和 foobar 当成同一仓库。 */
export function projectForPath<T extends { keys: { repos: string[] } }>(path: string, projects: T[]): T | null {
  const absolute = resolve(path);
  return projects.flatMap(project => project.keys.repos.flatMap(repo => {
    return repoContainsPath(repo, absolute) ? [{ project, length: resolve(repo).length }] : [];
  })).sort((a,b) => b.length - a.length)[0]?.project ?? null;
}

/** Collapse HTTPS, SSH and SCP-style origin URLs without keeping credentials or query strings. */
export function normalizeGitRemote(value: string): string | null {
  const scp = /^(?:[^@/\s]+@)?([^:/\s]+):([^\s]+)$/.exec(value);
  const url = URL.parse(value.includes("://") ? value : scp ? `ssh://${scp[1]}/${scp[2]}` : "");
  if (!url || !["http:", "https:", "ssh:", "git:"].includes(url.protocol) || !url.hostname) return null;
  const path = url.pathname.replace(/^\/+|\/+$/g, "").replace(/\.git$/i, "");
  if (!path || path.length > 512 || /%(?:00|0a|0d)/i.test(path)) return null;
  return `${url.hostname.toLowerCase()}${url.port && !(url.protocol === "ssh:" && url.port === "22") ? ":" + url.port : ""}/${path}`;
}

export const originArgs = (cwd: string) => ["-C", cwd, "config", "--local", "--get", "remote.origin.url"];

export function projectForRemote<T extends { keys: { remotes?: string[] } }>(remote: string | null, projects: T[]): T | null {
  if (!remote) return null;
  const matching = projects.filter(project => project.keys.remotes?.includes(remote));
  return matching.length === 1 ? matching[0]! : null;
}

export const repositoryArgs = (cwd: string) => ["-C", cwd, "rev-parse", "--path-format=absolute", "--git-common-dir", "--show-toplevel"];

export function repositoryRoot(commonDir: string, worktree: string): string {
  const common = resolve(commonDir);
  return basename(common) === ".git" ? dirname(common) : resolve(worktree);
}
