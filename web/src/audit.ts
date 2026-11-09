import type { Api, Project, Thread } from "./distillation.ts";
export interface AuditRead { id: string; at: string; tool: string; kind: string; args: Record<string, string | number>; result_ids: string[]; bytes: number; ok: number | boolean }
export interface AuditPage { reads: AuditRead[]; next_cursor: string | null }
export type AuditTarget = { kind: "thread"; title: string; item: Thread } | { kind: "project"; title: string; item: Project } | { kind: "record"; title: string };
export type AuditTargetCache = Map<string, Promise<AuditTarget | null>>;
export function auditPath(tool: string, cursor: string | null) {
  const params = new URLSearchParams({ limit: "50" });
  if (tool) params.set("tool", tool);
  if (cursor) params.set("cursor", cursor);
  return `/v1/audit?${params}`;
}
const appendResults: Record<string, string> = { created: "新增", unchanged: "已存在，未重复写入", corrected: "内容有变，已挂修正", deleted: "已被删除过，未写入" };
export function auditSummary(args: AuditRead["args"]) {
  return [args.cwd, args.id && `${args.id}${args.level ? ` / ${args.level}` : ""}`, args.q_length !== undefined && `q_length=${args.q_length}`, (args.from || args.to) && `${args.from || "不限"} 至 ${args.to || "不限"}`, args.result !== undefined && `写入：${appendResults[args.result] ?? args.result}`, args.redactions !== undefined && `拦下 ${args.redactions} 处密钥`].filter(value => value !== undefined && value !== false && value !== "").join(" · ") || "无";
}
// 只把 404 当作不存在，权限、网络和存储故障必须交给页面报错。
async function resolveTarget(api: Api, id: string, signal?: AbortSignal): Promise<AuditTarget | null> {
  if (!/^[\w-]{1,128}$/.test(id)) return null;
  for (const kind of ["thread", "project", "record"] as const) {
    signal?.throwIfAborted();
    try {
      const item = await api<Thread & Project>(`/v1/${kind}s/${encodeURIComponent(id)}${kind === "record" ? "" : "?level=brief"}`, { signal });
      signal?.throwIfAborted();
      if (kind === "record") return { kind, title: item.title };
      return { kind, title: kind === "thread" ? item.title : item.name, item };
    } catch (error) {
      signal?.throwIfAborted();
      if (!(error instanceof Error) || !("status" in error) || error.status !== 404) throw error;
    }
  }
  return null;
}
// 缓存包含未解析项和进行中的请求；失败或取消的请求可重试。记录正文不进入缓存。
export async function auditTargets(api: Api, ids: string[], signal?: AbortSignal, cache: AuditTargetCache = new Map()) {
  const targets = new Map<string, AuditTarget | null>();
  const unique = [...new Set(ids)];
  let index = 0;
  await Promise.all(Array.from({ length: Math.min(4, unique.length) }, async () => {
    while (index < unique.length) {
      signal?.throwIfAborted();
      const id = unique[index++];
      let request = cache.get(id);
      if (!request) {
        request = resolveTarget(api, id, signal);
        cache.set(id, request);
        const pending = request;
        void request.catch(() => { if (cache.get(id) === pending) cache.delete(id); });
      }
      targets.set(id, await request);
    }
  }));
  signal?.throwIfAborted();
  return targets;
}
export function auditResults(ids: string[], targets: ReadonlyMap<string, AuditTarget | null>) {
  const items: { id: string; target: AuditTarget }[] = [];
  let unresolved = 0;
  for (const id of new Set(ids)) {
    const target = targets.get(id);
    if (target) items.push({ id, target });
    else if (target === null) unresolved++;
  }
  return { items, unresolved };
}
