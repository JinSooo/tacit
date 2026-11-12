import type { HubDB } from "./db.ts";

export function isDatabaseBusy(error: unknown): boolean {
  const code = (error as { code?: unknown } | null)?.code;
  return typeof code === "string" && code.startsWith("SQLITE_BUSY");
}

/** 尽力写入：不等锁，撞锁整笔回滚留待下次；其他错误仍交给调用方。 */
export function tryWriteWithoutWaiting(hub: HubDB, write: () => void): boolean {
  const timeout = hub.db.pragma("busy_timeout", { simple: true }) as number;
  try {
    hub.db.pragma("busy_timeout=0");
    try {
      hub.db.transaction(write).immediate();
      return true;
    } catch (error) {
      if (isDatabaseBusy(error)) return false;
      throw error;
    }
  } finally { hub.db.pragma(`busy_timeout=${timeout}`); }
}

/** 只记响应次数，不保留请求、路径或内容；每个服务实例启动时清零。 */
export class BusyResponses {
  readonly since = new Date(Date.now() - Math.round(process.uptime() * 1000)).toISOString();
  private total = 0;
  private byRoute = { ingest: 0, agent: 0, web: 0 };
  private lastAt: string | null = null;

  record(path: string) {
    const route = path === "/v1/ingest" ? "ingest" : path.startsWith("/v1/agent/") ? "agent" : "web";
    this.total++;
    this.byRoute[route]++;
    this.lastAt = new Date().toISOString();
  }

  snapshot() {
    return { since: this.since, total: this.total, by_route: { ...this.byRoute }, last_at: this.lastAt };
  }
}
