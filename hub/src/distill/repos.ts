import { spawnSync } from "node:child_process";
import { homedir } from "node:os";
import { basename, dirname, resolve, sep } from "node:path";
import type { Project } from "./store.ts";

type Repository = { root: string; worktree: string };
const cache = new Map<string, { value: Repository | null; at: number }>();

/** 按路径边界取最长别名，不能把 foo 和 foobar 当成同一仓库。 */
export function projectForPath(path: string, projects: Project[]): Project | null {
  const absolute = resolve(path);
  return projects.flatMap(project => project.keys.repos.flatMap(repo => {
    const root = resolve(repo);
    return root !== homedir() && (absolute === root || absolute.startsWith(root.endsWith(sep) ? root : root + sep))
      ? [{ project, length: root.length }] : [];
  })).sort((a,b) => b.length - a.length)[0]?.project ?? null;
}

/** 缓存只存 git 探测，项目别名每次从当前库读取，合并后不会命中过时项目。 */
export function resolveRepository(path: string, projects: Project[]): Repository | null {
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
        const shared = resolve(common.stdout.trim()), worktree = resolve(top.stdout.trim());
        value = { root: basename(shared) === ".git" ? dirname(shared) : worktree, worktree };
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
export function resolveRepoRoot(path: string, projects: Project[]): string | null {
  return resolveRepository(path, projects)?.root ?? null;
}
