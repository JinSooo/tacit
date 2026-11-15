import { chatKey } from "../chat.ts";
import { basename, resolve } from "node:path";
import { ulid } from "../../../packages/record/index.ts";
import { DistillStore, type Frame, type Project } from "./store.ts";

import { resolveRepository } from "./repos.ts";

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
    // repo/host 只提名项目，不能替代语义归属。保留明确聊天对象的既有规则。
    if (!frame.key.startsWith("chat:")) return { status: "unassigned" };
    const projects = this.store.projects();
    const project = projects.find(p => p.keys.chats.some(key => chatKey(key) === chatKey(frame.key.slice(5))));
    if (!project) return { status: "unassigned" };
    // 同一项目里可能同时在做几件事：只有恰好一条活跃线程、且它在这个片段前 2 小时内还在动，才按规则直接归；其余交给模型判断。
    const active = this.store.hub.db.prepare("SELECT id,last_ms FROM threads WHERE project_id=? AND status='active'").all(project.id) as { id: string; last_ms: number | null }[];
    const elapsed = frame.t_start_ms - (active[0]?.last_ms ?? 0);
    const thread = active.length === 1 && elapsed >= 0 && elapsed <= 2 * 3_600_000 ? active[0] : undefined;
    if (!thread || this.store.rejectedThreads(frame.id).includes(thread.id)) return { status: "unassigned" };
    this.store.assign(frame.id,thread.id,"rule",1);
    return { status: "assigned",thread_id: thread.id,project_id: project.id };
  }
  /** 分组身份与项目线索分开，session/window 键不能丢掉记录本身的仓库信息。 */
  projectForFrame(frame: Frame): Project | null {
    const paths = new Set(frame.record_ids.flatMap(id => {
      const r = this.store.hub.get(id);
      if (!r || r.sensitivity === "private") return [];
      const repo = r.context?.repo ?? ((r.source === "codex.session" || r.source === "claude_code.session") ? r.context?.cwd : null);
      return repo ? [repo] : [];
    }));
    if (!paths.size && frame.key.startsWith("repo:")) paths.add(frame.key.slice(5));
    const projects = new Map([...paths].flatMap(path => { const p = this.projectForRepo(path); return p ? [[p.id, p] as const] : []; }));
    return projects.size === 1 ? [...projects.values()][0]! : null;
  }
}
/**
 * 没有仓库线索的线程，标题或简略版里写着已有项目的名字时，把这个项目提名为候选；是否真属于它仍由模型判断。
 * 2026-11-12 实测："修复 record-anything 页面配色与状态文案"在 Codex 桌面版里做，片段不是 repo:，一直没挂项目。
 * 名字太短（少于 4 个字符）的不按名字找，避免误配。
 */
export function projectByName(store: DistillStore, text: string): Project | null {
  const lower = text.toLowerCase();
  const hits = store.projects().filter(p => p.name.trim().length >= 4 && lower.includes(p.name.trim().toLowerCase()));
  // 一个文本里写了两个项目名时不猜。
  return hits.length === 1 ? hits[0]! : null;
}
export function projectForRepo(store: DistillStore, path: string) { return new DistillRules(store).projectForRepo(path); }
