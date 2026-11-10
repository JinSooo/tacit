import { basename, resolve } from "node:path";
import { ulid } from "../../../packages/record/index.ts";
import { DistillStore, type Frame, type Project } from "./store.ts";

import { resolveRepository, resolveRepoRoot } from "./repos.ts";

export class DistillRules {
  constructor(readonly store: DistillStore) {}
  projectForRepo(path: string): Project | null {
    const repository = resolveRepository(path, this.store.projects());
    if (!repository) return null;
    const { root: repo, worktree } = repository;
    return this.store.hub.db.transaction(() => {
      const existing = this.store.projects().find(p => p.keys.repos.some(key => resolve(key) === repo));
      if (existing) {
        if (!existing.keys.repos.includes(worktree)) {
          existing.keys.repos.push(worktree);
          this.store.upsertProject(existing);
        }
        return existing;
      }
      const project: Project = { id: ulid(),name: basename(repo),confirmed: 0,keys: { repos: [...new Set([repo, worktree])],hosts: [],chats: [] } };
      this.store.upsertProject(project);
      this.store.createPending({ id: ulid(),kind: "project",payload: { project_id: project.id },created_at: new Date().toISOString() });
      return project;
    })();
  }
  assign(frame: Frame): { status: "assigned"; thread_id: string; project_id: string } | { status: "unassigned" } {
    const projects = this.store.projects();
    const repo = frame.key.startsWith("repo:") ? resolveRepoRoot(frame.key.slice(5), projects) : null;
    const project = projects.find(p => frame.key.startsWith("repo:") ? repo !== null && p.keys.repos.some(key => resolve(key) === repo) : frame.key.startsWith("host:") ? p.keys.hosts.includes(frame.key.slice(5)) : frame.key.startsWith("chat:") ? p.keys.chats.includes(frame.key.slice(5)) : false);
    if (!project) return { status: "unassigned" };
    // 同一项目里可能同时在做几件事：只有恰好一条活跃线程、且它在这个片段前 2 小时内还在动，才按规则直接归；其余交给模型判断。
    const active = this.store.hub.db.prepare("SELECT id,last_ms FROM threads WHERE project_id=? AND status='active'").all(project.id) as { id: string; last_ms: number | null }[];
    const thread = active.length === 1 && frame.t_start_ms - (active[0]!.last_ms ?? 0) <= 2 * 3_600_000 ? active[0] : undefined;
    if (!thread || this.store.rejectedThreads(frame.id).includes(thread.id)) return { status: "unassigned" };
    this.store.assign(frame.id,thread.id,"rule",1);
    return { status: "assigned",thread_id: thread.id,project_id: project.id };
  }
}
export function projectForRepo(store: DistillStore, path: string) { return new DistillRules(store).projectForRepo(path); }
