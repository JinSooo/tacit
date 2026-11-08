import type { Api } from "./distillation.ts";
export interface AuditRead { id: string; at: string; tool: string; kind: string; args: Record<string, string | number>; result_ids: string[]; bytes: number; ok: number | boolean }
export interface AuditPage { reads: AuditRead[]; next_cursor: string | null }
export function auditPath(tool: string, cursor: string | null) {
  const params = new URLSearchParams({ limit: "50" });
  if (tool) params.set("tool", tool);
  if (cursor) params.set("cursor", cursor);
  return `/v1/audit?${params}`;
}
export function auditSummary(args: AuditRead["args"]) {
  return [args.cwd, args.id && `${args.id}${args.level ? ` / ${args.level}` : ""}`, args.q_length !== undefined && `q_length=${args.q_length}`, (args.from || args.to) && `${args.from || "不限"} 至 ${args.to || "不限"}`].filter(value => value !== undefined && value !== false && value !== "").join(" · ") || "无";
}
// 审计只保存 ID；分别查当前实体以免将已删除记录或 fact 误链到线程。
export async function auditTargets(api: Api, ids: string[], signal?: AbortSignal) {
  const targets = new Map<string, "thread" | "project">();
  let index = 0;
  await Promise.all(Array.from({ length: Math.min(4, ids.length) }, async () => {
    while (index < ids.length && !signal?.aborted) {
      const id = ids[index++];
      if (!/^[\w-]{1,128}$/.test(id)) continue;
      for (const kind of ["thread", "project"] as const) {
        try { await api(`/v1/${kind}s/${encodeURIComponent(id)}?level=brief`, { signal }); targets.set(id, kind); break; }
        catch (error) {
          if (signal?.aborted) return;
          if (!(error instanceof Error) || !/不存在|404/.test(error.message)) throw error;
        }
      }
    }
  }));
  return targets;
}
