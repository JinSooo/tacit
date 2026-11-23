import { spawnSync } from "node:child_process";
import { homedir } from "node:os";
import { resolve } from "node:path";
import { normalizeGitRemote, originArgs, projectForPath, repositoryRoot } from "../repo-identity.ts";

export { projectForPath, projectForRemote, repoContainsPath } from "../repo-identity.ts";

type Repository = { root: string; worktree: string };
const cache = new Map<string, { value: Repository | null; at: number }>();

/** 缓存只存 git 探测，项目别名每次从当前库读取，合并后不会命中过时项目。 */
export function resolveRepository(path: string, projects: { keys: { repos: string[] } }[]): Repository | null {
  const absolute = resolve(path), now = Date.now();
  let cached = cache.get(absolute);
  if (!cached || now - cached.at >= 60_000) {
    const git = (flag: string) => spawnSync("git", ["-C", absolute, "rev-parse", "--path-format=absolute", flag],
      { encoding: "utf8", timeout: 500 });
    const common = git("--git-common-dir");
    let value: Repository | null = null;
    if (common.status === 0) {
      const top = git("--show-toplevel");
      if (top.status === 0) {
        const worktree = resolve(top.stdout.trim());
        value = { root: repositoryRoot(common.stdout.trim(), worktree), worktree };
      }
    }
    if (cache.size >= 2048) cache.delete(cache.keys().next().value!);
    cached = { value, at: now }; cache.set(absolute, cached);
  }
  if (cached.value) return cached.value.root === homedir() ? null : cached.value;
  const project = projectForPath(absolute, projects);
  const root = project?.keys.repos.find(repo => resolve(repo) !== homedir());
  return root ? { root: resolve(root), worktree: absolute } : null;
}

/** 任意目录归一到主仓库；目录已删除时使用项目中保留的别名。 */
export function resolveRepoRoot(path: string, projects: { keys: { repos: string[] } }[]): string | null {
  return resolveRepository(path, projects)?.root ?? null;
}

const remoteCache = new Map<string, { value: string | null; at: number }>();

export function repositoryRemote(cwd: string): string | null {
  const now = Date.now();
  const cached = remoteCache.get(cwd);
  if (cached && now - cached.at < 60_000) return cached.value;
  const git = spawnSync("git", originArgs(cwd), { encoding: "utf8", timeout: 250, maxBuffer: 8192 });
  const value = git.status === 0 ? normalizeGitRemote(git.stdout.trim()) : null;
  if (remoteCache.size >= 2048) remoteCache.delete(remoteCache.keys().next().value!);
  remoteCache.set(cwd, { value, at: now });
  return value;
}
