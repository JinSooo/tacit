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
  payload: { speaker_id?: string; label?: string; conversations?: number; seconds?: number; samples?: { id: string; mime: string }[]; samples_pending?: boolean; project_id?: string; name?: string; keys?: { repos?: string[]; hosts?: string[]; chats?: string[] }; threads?: { id: string; title: string; brief?: string | null }[]; thread_id?: string; title?: string; brief?: string | null; a?: string; b?: string; a_name?: string; b_name?: string; reason?: string };
}
export type Resolution = { action: "me" | "confirm" | "rename" | "merge_into" | "ignore" | "done" | "continue" | "abandon" | "merge" | "keep"; name?: string; target?: string };
export const factGroups: { kind: FactKind; label: string }[] = [
  { kind: "decision", label: "已定（决定）" }, { kind: "rejected", label: "否决" },
  { kind: "open", label: "未决" }, { kind: "next", label: "下一步" }, { kind: "inference", label: "推测" },
];
export function groupFacts(facts: Fact[]) {
  return factGroups.map(group => ({ ...group, facts: facts.filter(fact => fact.kind === group.kind && !fact.invalid_at && !fact.superseded_by) })).filter(group => group.facts.length);
}
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
    ...(payload.threads ?? []).map(thread => `线程：${thread.title}`),
  ];
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
        if (cursor && seen.has(cursor)) throw new Error("线程分页游标重复，请重试");
        if (cursor) seen.add(cursor);
      } while (cursor);
      return [...new Map(rows.map(row => [row.id, row])).values()];
    },
    thread: (id: string, level: "detail" | "evidence", signal?: AbortSignal) => api<ThreadDetail>(`/v1/threads/${encodeURIComponent(id)}?level=${level}`, { signal }),
    project: (id: string, level: "detail" | "evidence", signal?: AbortSignal) => api<ProjectDetail>(`/v1/projects/${encodeURIComponent(id)}?level=${level}`, { signal }),
    resolve: (id: string, resolution: Resolution) => api(`/v1/pending/${encodeURIComponent(id)}`, { method: "POST", body: JSON.stringify(resolution) }),
    correct: (fact: Fact, text: string) => {
      if (!text.trim()) throw new Error("请填写修正内容");
      return api("/v1/facts", { method: "POST", body: JSON.stringify({ kind: fact.kind, text: text.trim(), thread_id: fact.thread_id, project_id: fact.project_id, evidence: fact.evidence, supersedes: fact.id }) });
    },
  };
}
export type DistillationApi = ReturnType<typeof createDistillationApi>;
