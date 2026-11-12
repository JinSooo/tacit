import type { HubDB } from "./db.ts";

type AuditRow = [string, string, string, string, string, string, number, number];
type Queue = { rows: AuditRow[]; dropped: number; errorLogged: boolean; timer?: ReturnType<typeof setInterval> };
const queues = new WeakMap<HubDB, Queue>();
const MAX_ROWS = 10000;

/** 同步冲刷不等锁；失败的事务整批保留，下次请求或定时器再试。 */
export function flushAgentAudit(hub: HubDB): void {
  const queue = queues.get(hub);
  if (!queue) return;
  if (!hub.db.open) {
    clearInterval(queue.timer);
    queue.timer = undefined;
    return;
  }
  if (!queue.rows.length) return;
  try {
    const timeout = hub.db.pragma("busy_timeout", { simple: true }) as number;
    try {
      hub.db.pragma("busy_timeout=0");
      hub.db.transaction(() => {
        const insert = hub.db.prepare("INSERT INTO agent_reads(id,at,tool,kind,args,result_ids,bytes,ok) VALUES(?,?,?,?,?,?,?,?)");
        for (const row of queue.rows) insert.run(...row);
      }).immediate();
      queue.rows.length = 0;
      clearInterval(queue.timer);
      queue.timer = undefined;
    } finally { hub.db.pragma(`busy_timeout=${timeout}`); }
  } catch (error) {
    const code = (error as { code?: unknown } | null)?.code;
    if (code !== "SQLITE_BUSY" && !queue.errorLogged) {
      queue.errorLogged = true;
      // 不打印异常消息，避免数据库错误夹带记录内容。
      console.error("Agent 审计暂未写入，已保留待重试");
    }
  }
}

export function enqueueAgentAudit(hub: HubDB, row: AuditRow): void {
  let queue = queues.get(hub);
  if (!queue) {
    queue = { rows: [], dropped: 0, errorLogged: false };
    queues.set(hub, queue);
  }
  if (queue.rows.length === MAX_ROWS) {
    queue.rows.shift();
    queue.dropped++;
    if (queue.dropped === 1) console.error("Agent 审计队列已满，开始丢弃最旧审计并累计丢弃数量");
  }
  queue.rows.push(row);
  flushAgentAudit(hub);
  if (queue.rows.length && !queue.timer && hub.db.open) {
    queue.timer = setInterval(() => flushAgentAudit(hub), 2000);
    queue.timer.unref();
  }
}

/** serve 停止或进程正常退出时只尽力尝试一次，不等待其他进程解锁。 */
export function stopAgentAudit(hub: HubDB): void {
  flushAgentAudit(hub);
  const queue = queues.get(hub);
  if (queue) {
    clearInterval(queue.timer);
    queue.timer = undefined;
  }
}
