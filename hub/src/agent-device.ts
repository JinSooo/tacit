import { isAbsolute } from "node:path";
import { AgentReads } from "./agent.ts";
import { InputError } from "./db.ts";
import { insertAgentAudit } from "./agent-audit.ts";
import { object } from "./devices/envelope.ts";

const idPattern = /^[0-9A-HJKMNP-TV-Z]{26}$/;
const clean = (value: unknown, max: number): value is string =>
  typeof value === "string" && value.length > 0 && value.length <= max && !/[\x00-\x1f\x7f]/.test(value);

function syncAudit(reads: AgentReads, actor: string, body: Record<string, unknown>) {
  const { entries } = body;
  if (!Array.isArray(entries) || entries.length > 500) throw new InputError("entries 必须是最多 500 条的数组");
  const rows = entries.map(raw => {
    const entry = object(raw);
    if (!entry || Object.keys(entry).some(key => !["id", "at", "tool", "session", "cwd", "project_id", "result_ids", "cached"].includes(key))) {
      throw new InputError("离线审计格式无效");
    }
    const { id, at, tool, session, cwd, project_id, result_ids, cached } = entry;
    if (!clean(id, 26) || !idPattern.test(id) || !clean(at, 24) || !/^\d{4}-\d{2}-\d{2}T.*Z$/.test(at) ||
        !Number.isFinite(Date.parse(at)) || !clean(tool, 32) || /\s/.test(tool) ||
        (session !== undefined && !clean(session, 128)) || !clean(cwd, 4096) || !isAbsolute(cwd) ||
        !clean(project_id, 26) || !idPattern.test(project_id) ||
        !Array.isArray(result_ids) || result_ids.length > 500 ||
        !result_ids.every(id => clean(id, 26) && idPattern.test(id)) || cached !== true) throw new InputError("离线审计格式无效");
    return { id, at: new Date(at).toISOString(), tool, args: { session, cwd, project: project_id, cached, agent_device: actor }, result_ids };
  });
  const insert = insertAgentAudit(reads.hub);
  for (const row of rows) insert.run(row.id, row.at, row.tool, "context", JSON.stringify(row.args), JSON.stringify(row.result_ids), 0, 1);
  return { status: 200, body: { accepted: rows.length } };
}

export function agentOperation(reads: AgentReads, actor: string, kind: string, body: Record<string, unknown>) {
  if (kind === "audit_sync") return syncAudit(reads, actor, body);
  const { cache, remote, ...input } = body;
  const params = new URLSearchParams();
  if (kind === "append") {
    const { tool, cwd, session, ...record } = input;
    if (typeof tool === "string") params.set("tool", tool);
    return reads.appendResult(params, record, actor);
  }
  for (const [key, value] of Object.entries(input)) {
    if (typeof value !== "string" && !(key === "limit" && typeof value === "number")) throw new InputError(`${key} 无效`);
    params.set(key, String(value));
  }
  if (kind === "context") {
    if (cache !== undefined && typeof cache !== "boolean" || remote !== undefined && !clean(remote, 768)) {
      throw new InputError("上下文缓存或仓库标识无效");
    }
    return reads.read(kind, params, actor, { cache: cache === true, remote: typeof remote === "string" ? remote : null });
  }
  return reads.read(kind, params, actor);
}
