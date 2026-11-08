import { basename, resolve } from "node:path";
import { spawnSync } from "node:child_process";
import { ulid } from "../../../packages/record/index.ts";
import { DistillStore, type Frame, type Project } from "./store.ts";

const repoCache = new Map<string,string | null>();

export class DistillRules {
  constructor(readonly store: DistillStore) {}
  projectForRepo(path: string): Project | null {
    const absolute = resolve(path);
    if (!repoCache.has(absolute)) {
      const result = spawnSync("git",["-C",absolute,"rev-parse","--show-toplevel"],{ encoding: "utf8" });
      repoCache.set(absolute,result.status === 0 ? result.stdout.trim() : null);
    }
    const repo = repoCache.get(absolute);
    if (!repo) return null;
    return this.store.hub.db.transaction(() => {
      const existing = this.store.projects().find(p => p.keys.repos.includes(repo));
      if (existing) return existing;
      const project: Project = { id: ulid(),name: basename(repo),confirmed: 0,keys: { repos: [repo],hosts: [],chats: [] } };
      this.store.upsertProject(project);
      this.store.createPending({ id: ulid(),kind: "project",payload: { project_id: project.id },created_at: new Date().toISOString() });
      return project;
    })();
  }
  assign(frame: Frame): { status: "assigned"; thread_id: string; project_id: string } | { status: "unassigned" } {
    const project = this.store.projects().find(p => frame.key.startsWith("repo:") ? p.keys.repos.includes(frame.key.slice(5)) : frame.key.startsWith("host:") ? p.keys.hosts.includes(frame.key.slice(5)) : frame.key.startsWith("chat:") ? p.keys.chats.includes(frame.key.slice(5)) : false);
    if (!project) return { status: "unassigned" };
    const thread = this.store.hub.db.prepare("SELECT id FROM threads WHERE project_id=? AND status='active' ORDER BY last_ms DESC,id DESC LIMIT 1").get(project.id) as { id: string } | undefined;
    if (!thread) return { status: "unassigned" };
    this.store.assign(frame.id,thread.id,"rule",1);
    return { status: "assigned",thread_id: thread.id,project_id: project.id };
  }
}
export function projectForRepo(store: DistillStore, path: string) { return new DistillRules(store).projectForRepo(path); }
