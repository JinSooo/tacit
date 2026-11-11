export type Api = <T>(path: string, init?: RequestInit) => Promise<T>;
export type FactKind = "decision" | "rejected" | "open" | "next" | "inference";
export interface Fact {
  id: string; thread_id?: string | null; project_id?: string | null; kind: FactKind;
  text: string; reason?: string | null; evidence: string[]; confidence?: number | null;
  invalid_at?: string | null; superseded_by?: string | null;
}
export interface Evidence { id: string; title: string; t_start: string; source?: string }
export interface Thread {
  id: string; project_id: string | null; title: string; brief: string | null; last_ms: number | null;
  status: "active" | "paused" | "done" | "abandoned" | "archived";
}
export interface Project {
  id: string; name: string; brief: string | null; confirmed: number | boolean; last_ms: number | null; thread_count: number;
}
export interface ThreadDetail extends Thread {
  detail: { goal?: string; progress?: string } | null; facts: Fact[]; records?: Evidence[];
}
export interface ProjectDetail extends Project {
  detail: { goal?: string; status?: string; people?: string[] } | null; facts: Fact[]; records?: Evidence[];
}
export interface Pending {
  id: string; kind: "project" | "thread_done" | "merge" | "voice";
  payload: { speaker_id?: string; label?: string; conversations?: number; seconds?: number; samples?: { id: string; mime: string; at?: string; said?: string }[]; samples_pending?: boolean; project_id?: string; name?: string; keys?: { repos?: string[]; hosts?: string[]; chats?: string[] }; threads?: { id: string; title: string; brief?: string | null }[]; thread_id?: string; title?: string; brief?: string | null; a?: string; b?: string; a_name?: string; b_name?: string; reason?: string };
}
export type Resolution = { action: "me" | "confirm" | "rename" | "merge_into" | "ignore" | "done" | "continue" | "abandon" | "merge" | "keep"; name?: string; target?: string };
export const factGroups: { kind: FactKind; label: string }[] = [
  { kind: "decision", label: "已定" }, { kind: "rejected", label: "否决" },
  { kind: "open", label: "未决" }, { kind: "next", label: "下一步" }, { kind: "inference", label: "推测" },
];
export function groupFacts(facts: Fact[]) {
  return factGroups.map(group => ({ ...group, facts: facts.filter(fact => fact.kind === group.kind && !fact.invalid_at && !fact.superseded_by) })).filter(group => group.facts.length);
}
/** 两种纠错（AGENTS.md）：文案写错用"这条不对"改写，只给已定和推测；内容根本不是这件事的用"不属于这里"，只给挂在事项上的。 */
export const canCorrect = (fact: Fact) => fact.kind === "decision" || fact.kind === "inference";
export const canDetach = (fact: Fact) => !!fact.thread_id;
export function relativeTime(value: number | string | null, now = Date.now()): string {
  if (value === null) return "暂无活动";
  const time = typeof value === "number" ? value : Date.parse(value);
  if (!Number.isFinite(time)) return "时间未知";
  const minutes = Math.floor(Math.max(0, now - time) / 60000);
  if (minutes < 1) return "刚刚";
  if (minutes < 60) return `${minutes}分钟前`;
  if (minutes < 1440) return `${Math.floor(minutes / 60)}小时前`;
  return `${Math.floor(minutes / 1440)}天前`;
}
export function pendingSummary(payload: Pending["payload"]): string[] {
  const keys = payload.keys;
  return [
    ...(keys?.repos ?? []).map(value => `仓库：${value}`),
    ...(keys?.hosts ?? []).map(value => `网站：${value}`),
    ...(keys?.chats ?? []).map(value => `会话：${value}`),
    ...(payload.threads ?? []).map(thread => `事项：${thread.title}`),
  ];
}
/** 待确认卡片的标题，撤销提示里也用它。 */
export function pendingTitle(item: Pending): string {
  const p = item.payload;
  if (item.kind === "voice") return p.label ?? "新声音";
  if (item.kind === "project") return p.name ?? "未命名项目";
  if (item.kind === "merge") return `${p.a_name ?? "?"} 和 ${p.b_name ?? "?"}`;
  return p.title ?? "";
}
/** "此刻"页的最近暂停：3 天内有活动的暂停事项，最近的在前（与 Mac 客户端一致）。 */
export const recentPausedMs = 3 * 86_400_000;
export function recentPaused(threads: Thread[], now = Date.now()): Thread[] {
  return threads.filter(thread => thread.status === "paused" && thread.last_ms !== null && thread.last_ms > now - recentPausedMs)
    .sort((a, b) => (b.last_ms ?? 0) - (a.last_ms ?? 0));
}
export function createDistillationApi(api: Api) {
  return {
    now: (signal?: AbortSignal) => api<{ now: { brief: string; detail: unknown; updated_at: string } | null }>("/v1/now", { signal }),
    projects: (signal?: AbortSignal) => api<{ projects: Project[] }>("/v1/projects", { signal }),
    pending: (signal?: AbortSignal) => api<{ pending: Pending[] }>("/v1/pending", { signal }),
    threads: async (project?: string, signal?: AbortSignal): Promise<Thread[]> => {
      const rows: Thread[] = [];
      let cursor: string | null = null;
      const seen = new Set<string>();
      do {
        const params = new URLSearchParams(project ? { project } : { status: "active" });
        if (cursor) params.set("cursor", cursor);
        const page = await api<{ threads: Thread[]; next_cursor: string | null }>(`/v1/threads?${params}`, { signal });
        rows.push(...page.threads);
        cursor = page.next_cursor;
        if (cursor && seen.has(cursor)) throw new Error("事项列表读取出错，请重试");
        if (cursor) seen.add(cursor);
      } while (cursor);
      return [...new Map(rows.map(row => [row.id, row])).values()];
    },
    /** 某个时间之后有活动的暂停线程。列表按最近活动倒序，翻到更早的就停。 */
    pausedSince: async (since: number, signal?: AbortSignal): Promise<Thread[]> => {
      const rows: Thread[] = [];
      let cursor: string | null = null;
      do {
        const params = new URLSearchParams({ status: "paused", limit: "100" });
        if (cursor) params.set("cursor", cursor);
        const page: { threads: Thread[]; next_cursor: string | null } = await api(`/v1/threads?${params}`, { signal });
        rows.push(...page.threads);
        cursor = page.threads.some(thread => (thread.last_ms ?? 0) <= since) ? null : page.next_cursor;
      } while (cursor);
      return rows.filter(thread => (thread.last_ms ?? 0) > since);
    },
    thread: (id: string, level: "detail" | "evidence", signal?: AbortSignal) => api<ThreadDetail>(`/v1/threads/${encodeURIComponent(id)}?level=${level}`, { signal }),
    project: (id: string, level: "detail" | "evidence", signal?: AbortSignal) => api<ProjectDetail>(`/v1/projects/${encodeURIComponent(id)}?level=${level}`, { signal }),
    // 离开网页时提交的待确认要用 keepalive，页面关掉后请求仍会发出。
    resolve: (id: string, resolution: Resolution, keepalive = false) => api(`/v1/pending/${encodeURIComponent(id)}`, { method: "POST", body: JSON.stringify(resolution), ...(keepalive ? { keepalive } : {}) }),
    correct: (fact: Fact, text: string) => {
      if (!text.trim()) throw new Error("请填写修正内容");
      return api("/v1/facts", { method: "POST", body: JSON.stringify({ kind: fact.kind, text: text.trim(), thread_id: fact.thread_id, project_id: fact.project_id, evidence: fact.evidence, supersedes: fact.id }) });
    },
    /** 证据所在的活动移出这件事项、不再分回来，下一轮整理重新归属。 */
    detach: (fact: Fact) => api<{ frames: number; facts: number }>(`/v1/facts/${encodeURIComponent(fact.id)}/detach`, { method: "POST" }),
  };
}
export type DistillationApi = ReturnType<typeof createDistillationApi>;
