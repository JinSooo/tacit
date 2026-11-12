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
