import type { Api, Project, Thread } from "./distillation.ts";
import { recordTitle } from "./history.ts";
export interface AuditRead { id: string; at: string; tool: string; kind: string; args: Record<string, string | number>; result_ids: string[]; bytes: number; ok: number | boolean }
export interface AuditPage { reads: AuditRead[]; next_cursor: string | null }
export type AuditTarget = { kind: "thread"; title: string; item: Thread } | { kind: "project"; title: string; item: Project } | { kind: "record"; title: string; search: string };
export type AuditTargetCache = Map<string, Promise<AuditTarget | null>>;
export function auditPath(tool: string, cursor: string | null) {
  const params = new URLSearchParams({ limit: "50" });
  if (tool) params.set("tool", tool);
  if (cursor) params.set("cursor", cursor);
  return `/v1/audit?${params}`;
}
const appendResults: Record<string, string> = { created: "已添加", unchanged: "已经有了，没有重复添加", corrected: "内容有变化，已添加修正", deleted: "之前删除过，没有添加" };
const levels: Record<string, string> = { brief: "简略版", detail: "详细版", evidence: "依据" };
/** AI 工具的显示名；没列出的原样显示。 */
export const toolNames: Record<string, string> = { "claude-code": "Claude Code", codex: "Codex", "claude-desktop": "Claude Desktop" };
/** 这次读取做了什么。 */
export function auditAction(kind: string, args: AuditRead["args"]): string {
  switch (kind) {
    case "context": return args.event === "compact" ? "对话压缩后重新带入" : "新会话开始时带入";
    case "now": return "查看此刻";
    case "get": return `读取${levels[String(args.level)] ?? "内容"}`;
    case "search": return "搜索历史记录";
    case "timeline": return "查看时间线";
    case "append": return "添加到历史记录";
    default: return kind;
  }
}
const shortTime = (value: string | number) => String(value).slice(0, 16).replace("T", " ");
/** 参数写成人话；id 换成已解析出的标题，解析不出就不显示。 */
export function auditSummary(args: AuditRead["args"], targets?: ReadonlyMap<string, AuditTarget | null>) {
  const title = args.id !== undefined ? targets?.get(String(args.id))?.title : undefined;
  return [
    args.cwd !== undefined && String(args.cwd).replace(/^\/Users\/[^/]+(?=\/|$)/, "~"),
    title,
    args.q_length !== undefined && `搜索词 ${args.q_length} 个字`,
    (args.from || args.to) && (args.from && args.to ? `${shortTime(args.from)} 至 ${shortTime(args.to)}` : args.from ? `${shortTime(args.from)} 以后` : `${shortTime(args.to!)} 以前`),
    args.result !== undefined && (appendResults[args.result] ?? String(args.result)),
    args.redactions !== undefined && `隐去了 ${args.redactions} 处密钥`,
  ].filter(value => value !== undefined && value !== false && value !== "").join("，");
}
// 只把 404 当作不存在，权限、网络和存储故障必须交给页面报错。
async function resolveTarget(api: Api, id: string, signal?: AbortSignal): Promise<AuditTarget | null> {
  if (!/^[\w-]{1,128}$/.test(id)) return null;
  for (const kind of ["thread", "project", "record"] as const) {
    signal?.throwIfAborted();
    try {
      const item = await api<Thread & Project>(`/v1/${kind}s/${encodeURIComponent(id)}${kind === "record" ? "" : "?level=brief"}`, { signal });
      signal?.throwIfAborted();
      if (kind === "record") return { kind, title: recordTitle(item as unknown as { source?: string; title: string }), search: item.title };
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
/** 一行默认只列前几个结果，其余（含已删除或认不出的）折成"还有 N 项"。 */
export function auditVisible<T>(items: T[], unresolved: number, expanded: boolean, limit = 3) {
  const shown = expanded ? items : items.slice(0, limit);
  return { shown, hidden: expanded ? 0 : items.length - shown.length + unresolved, unresolved: expanded ? unresolved : 0 };
}
