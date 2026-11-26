import { chatApp, chatKey, recordChat } from "../chat.ts";
import { chatAliases } from "../chat-aliases.ts";
import { basename, resolve } from "node:path";
import { ulid, type RecordV1 } from "../../../packages/record/index.ts";
import { DistillStore, type Frame, type Project, type ProjectKeys } from "./store.ts";

import { projectForRemote, repoContainsPath, repositoryRemote, resolveRepository } from "./repos.ts";

function recordRepo(record: RecordV1) {
  return record.context?.repo ?? ((record.source === "codex.session" || record.source === "claude_code.session") ? record.context?.cwd : null);
}

export function ignoredRepo(path: string, repos: string[], repository = repos.length ? resolveRepository(path, []) : null) {
  // git 能识别时以仓库根和 worktree 根为准，让独立的嵌套仓库仍可作为自己的项目。
  return repos.some(key => repository ? [repository.root, repository.worktree].includes(resolve(key)) : repoContainsPath(key, path));
}

function ignoredChat(chat: string | null | undefined, chats: string[]) {
  return !!chat && chats.some(key => chatKey(key) === chatKey(chat));
}

function ignoredHost(host: string | undefined, hosts: string[]) {
  return !!host && hosts.some(key => key.toLowerCase() === host.toLowerCase());
}

export class DistillRules {
  constructor(readonly store: DistillStore) {}
  projectForRepo(path: string): Project | null {
    const discovered = resolveRepository(path, []);
    const remote = discovered ? repositoryRemote(discovered.worktree) : null;
    return this.store.hub.db.transaction(() => {
      const ignored = this.store.ignoredProjectKeys();
      if (ignoredRepo(path, ignored.repos, discovered) || (remote && ignored.remotes?.includes(remote))) return null;
      const projects = this.store.projects();
      const repository = discovered ?? resolveRepository(path, projects);
      if (!repository || ignoredRepo(path, ignored.repos, repository)) return null;
      const { root: repo, worktree } = repository;
      const existing = projects.find(p => p.keys.repos.some(key => resolve(key) === repo)) ?? projectForRemote(remote, projects);
      if (existing) {
        const repos = [...new Set([...existing.keys.repos, repo, worktree])];
        const remotes = remote && !existing.keys.remotes?.includes(remote) ? [...(existing.keys.remotes ?? []), remote] : undefined;
        if (repos.length !== existing.keys.repos.length || remotes) {
          existing.keys = { ...existing.keys, repos, ...(remotes ? { remotes } : {}) };
          this.store.upsertProject(existing);
        }
        return existing;
      }
      const project: Project = { id: ulid(),name: basename(repo),confirmed: 0,keys: { repos: [...new Set([repo, worktree])],hosts: [],chats: [], ...(remote ? { remotes: [remote] } : {}) } };
      this.store.upsertProject(project);
      this.store.createPending({ id: ulid(),kind: "project",payload: { project_id: project.id },created_at: new Date().toISOString() });
      return project;
    }).immediate();
  }
  assign(frame: Frame): { status: "assigned"; thread_id: string; project_id: string } | { status: "unassigned" } {
    // repo/host 只提名项目，不能替代语义归属。保留明确聊天对象的既有规则。
    if (!frame.key.startsWith("chat:")) return { status: "unassigned" };
    const chat = frame.key.slice(5);
    if (ignoredChat(chat, this.store.ignoredProjectKeys().chats)) return { status: "unassigned" };
    const project = this.store.projects().find(p => ignoredChat(chat, p.keys.chats));
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
    const paths = new Set(this.publicRecords(frame).flatMap(record => recordRepo(record) || []));
    if (!paths.size && frame.key.startsWith("repo:")) paths.add(frame.key.slice(5));
    const projects = new Map([...paths].flatMap(path => { const p = this.projectForRepo(path); return p ? [[p.id, p] as const] : []; }));
    return projects.size === 1 ? [...projects.values()][0]! : null;
  }
  private publicRecords(frame: Frame) {
    return frame.record_ids.flatMap(id => {
      const record = this.store.hub.get(id);
      return record && record.sensitivity !== "private" ? [record] : [];
    });
  }
  hasIgnoredProjectKey(frame: Frame, ignored: ProjectKeys): boolean {
    if (frame.key.startsWith("repo:") && ignoredRepo(frame.key.slice(5), ignored.repos)) return true;
    if (frame.key.startsWith("chat:") && ignoredChat(frame.key.slice(5), ignored.chats)) return true;
    if (frame.key.startsWith("host:") && ignoredHost(frame.key.slice(5), ignored.hosts)) return true;
    const aliases = chatAliases(this.store.hub);
    return this.publicRecords(frame).some(record => {
      const path = recordRepo(record), context = record.context;
      const read = recordChat(record), name = read && aliases.name(chatApp(record), read);
      const chat = name && `${chatApp(record)}:${name}`;
      const host = context?.url ? URL.parse(context.url)?.hostname : undefined;
      return (!!path && ignoredRepo(path, ignored.repos)) || ignoredChat(chat, ignored.chats)
        || ignoredChat(name, ignored.chats) || ignoredChat(read && `${chatApp(record)}:${read}`, ignored.chats)
        || ignoredChat(read, ignored.chats) || ignoredHost(host, ignored.hosts);
    });
  }
}
/**
 * 没有仓库线索的线程，标题或简略版里写着已有项目的名字时，把这个项目提名为候选；是否真属于它仍由模型判断。
 * 2026-11-12 实测："修复 record-anything 页面配色与状态文案"在 Codex 桌面版里做，片段不是 repo:，一直没挂项目。
 * 名字太短（少于 4 个字符）的不按名字找，避免误配。
 */
export function projectByName(store: DistillStore, text: string, ignored = store.ignoredProjectKeys()): Project | null {
  const lower = text.toLowerCase();
  const hits = store.projects().filter(p => p.name.trim().length >= 4 && lower.includes(p.name.trim().toLowerCase())
    && !p.keys.repos.some(repo => ignored.repos.some(key => resolve(key) === resolve(repo)))
    && !p.keys.chats.some(chat => ignoredChat(chat, ignored.chats))
    && !p.keys.hosts.some(host => ignoredHost(host, ignored.hosts)));
  // 一个文本里写了两个项目名时不猜。
  return hits.length === 1 ? hits[0]! : null;
}
export function projectForRepo(store: DistillStore, path: string) { return new DistillRules(store).projectForRepo(path); }
