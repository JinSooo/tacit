import { createCipheriv, createDecipheriv, createHash, randomBytes } from "node:crypto";
import { constants, openSync, closeSync, fsyncSync, writeFileSync, readFileSync, mkdirSync, chmodSync, lstatSync, readdirSync, renameSync, unlinkSync } from "node:fs";
import { join } from "node:path";
import { tryWriteWithoutWaiting } from "./db-busy.ts";
import type { HubDB } from "./db.ts";

type AuditRow = [string, string, string, string, string, string, number, number];
type Queue = { key: Buffer; directory: string | null; rows: Map<string, AuditRow>; errorLogged: boolean; timer?: ReturnType<typeof setInterval> };
const queues = new WeakMap<HubDB, Queue>();
const missing = (e: unknown) => (e as NodeJS.ErrnoException)?.code === "ENOENT";
const QUERY_RETENTION_MS = 7 * 86_400_000;

export function auditQueryExpiry(now = Date.now()): string {
  return new Date(now - QUERY_RETENTION_MS).toISOString();
}

function withoutQuery(row: AuditRow): AuditRow {
  const args = JSON.parse(row[4]);
  if (!Object.hasOwn(args, "q")) return row;
  delete args.q;
  const clean: AuditRow = [...row];
  clean[4] = JSON.stringify(args);
  return clean;
}

function directory(queue: Queue, create = false): boolean {
  if (!queue.directory) return false;
  if (create) mkdirSync(queue.directory, { mode: 0o700, recursive: true });
  try {
    const stat = lstatSync(queue.directory);
    if (!stat.isDirectory() || stat.isSymbolicLink()) throw new Error("审计暂存目录无效");
    if (create) chmodSync(queue.directory, 0o700);
    return true;
  } catch (error) { if (missing(error)) return false; throw error; }
}
function syncDirectory(path: string) {
  const fd = openSync(path, constants.O_RDONLY); try { fsyncSync(fd); } finally { closeSync(fd); }
}
function persist(queue: Queue, row: AuditRow) {
  if (!queue.directory) return; // :memory: 数据库本身也不跨进程保存。
  directory(queue, true);
  const iv = randomBytes(12), cipher = createCipheriv("aes-256-gcm", queue.key, iv);
  const encrypted = Buffer.concat([cipher.update(JSON.stringify(row), "utf8"), cipher.final()]);
  const bytes = Buffer.concat([iv, cipher.getAuthTag(), encrypted]);
  const temp = join(queue.directory, `${row[0]}-${randomBytes(8).toString("hex")}.tmp`);
  const target = join(queue.directory, `${row[0]}.enc`);
  let fd: number | undefined;
  try {
    fd = openSync(temp, constants.O_CREAT | constants.O_EXCL | constants.O_WRONLY | constants.O_NOFOLLOW, 0o600);
    writeFileSync(fd, bytes); fsyncSync(fd); closeSync(fd); fd = undefined;
    renameSync(temp, target); syncDirectory(queue.directory);
  } finally {
    if (fd !== undefined) closeSync(fd);
    try { unlinkSync(temp); } catch (e) { if (!missing(e)) throw e; }
  }
}
function restore(queue: Queue) {
  if (!directory(queue)) return;
  for (const name of readdirSync(queue.directory!)) {
    if (!/^[0-9A-HJKMNP-TV-Z]{26}\.enc$/.test(name)) continue;
    const id = name.slice(0, -4); if (queue.rows.has(id)) continue;
    const path = join(queue.directory!, name);
    let fd: number;
    try { fd = openSync(path, constants.O_RDONLY | constants.O_NOFOLLOW); }
    catch (e) { if (missing(e)) continue; throw e; }
    let bytes: Buffer; try { bytes = readFileSync(fd); } finally { closeSync(fd); }
    if (bytes.length < 29 || bytes.length > 256_000) throw new Error("审计暂存数据无效");
    const cipher = createDecipheriv("aes-256-gcm", queue.key, bytes.subarray(0, 12)); cipher.setAuthTag(bytes.subarray(12, 28));
    const row: unknown = JSON.parse(Buffer.concat([cipher.update(bytes.subarray(28)), cipher.final()]).toString("utf8"));
    if (!Array.isArray(row) || row.length !== 8 || row[0] !== id || !row.slice(0, 6).every(v => typeof v === "string")
      || !Number.isSafeInteger(row[6]) || ![0, 1].includes(row[7])) throw new Error("审计暂存数据无效");
    queue.rows.set(id, row as AuditRow);
  }
}
function retry(hub: HubDB, queue: Queue) {
  if (queue.rows.size && !queue.timer && hub.db.open) {
    queue.timer = setInterval(() => flushAgentAudit(hub), 2000); queue.timer.unref();
  }
}
/** 使用独立派生密钥加密，不把返回正文写入文件；检索词只以脱敏截断后的形式随参数保存。打开数据库即恢复未入库审计。 */
export function registerAgentAudit(hub: HubDB, databaseKey: string) {
  const queue: Queue = { key: createHash("sha256").update("record-anything:agent-audit:v1\0").update(databaseKey).digest(),
    directory: hub.db.name === ":memory:" ? null : `${hub.db.name}.audit-pending`, rows: new Map(), errorLogged: false };
  queues.set(hub, queue); restore(queue); flushAgentAudit(hub); retry(hub, queue);
}
/** 写库成功后才移除加密日志；提交后崩溃可重放，按审计 id 去重。 */
export function flushAgentAudit(hub: HubDB): void {
  const queue = queues.get(hub); if (!queue) return;
  if (!hub.db.open) { clearInterval(queue.timer); queue.timer = undefined; return; }
  try {
    restore(queue);
    if (!queue.rows.size) return;
    if (tryWriteWithoutWaiting(hub, () => {
      const insert = hub.db.prepare("INSERT INTO agent_reads(id,at,tool,kind,args,result_ids,bytes,ok) VALUES(?,?,?,?,?,?,?,?) ON CONFLICT(id) DO NOTHING");
      let cutoff: string | undefined;
      for (const row of queue.rows.values()) {
        let safe = row;
        if (row[3] === "search") {
          if (cutoff === undefined) {
            // 另一个连接可能已从磁盘恢复旧暂存。持有写锁时重查删除时间。
            const erased = hub.db.prepare("SELECT json_extract(v, '$') AS at FROM distill_state WHERE k='audit_query_erased_at'").get() as { at: string } | undefined;
            const expired = auditQueryExpiry();
            cutoff = erased && erased.at > expired ? erased.at : expired;
          }
          if (row[1] <= cutoff) safe = withoutQuery(row);
        }
        insert.run(...safe);
      }
    })) {
      for (const id of queue.rows.keys()) if (queue.directory) {
        try { unlinkSync(join(queue.directory, `${id}.enc`)); } catch (e) { if (!missing(e)) throw e; }
      }
      queue.rows.clear(); clearInterval(queue.timer); queue.timer = undefined;
    }
  } catch {
    if (!queue.errorLogged) { queue.errorLogged = true; console.error("Agent 审计暂未写入，已加密保存待重试"); }
  }
}
/** 日志必须落盘成功才允许返回读取结果；无法保存时由 HTTP 入口返回错误，不泄露未审计内容。 */
export function enqueueAgentAudit(hub: HubDB, row: AuditRow): void {
  const queue = queues.get(hub); if (!queue) throw new Error("审计未初始化");
  persist(queue, row); queue.rows.set(row[0], row); flushAgentAudit(hub); retry(hub, queue);
}
export function expireAuditQueries(hub: HubDB, now: number): void {
  // 审计时间统一使用 UTC ISO 字符串。
  hub.db.prepare("UPDATE agent_reads SET args=json_remove(args,'$.q') WHERE kind='search' AND at<=? AND json_type(args,'$.q') IS NOT NULL")
    .run(auditQueryExpiry(now));
}

/** 与原始记录删除共用数据库事务，清理加密暂存并阻止其他连接重放旧词。 */
export function eraseAuditQueries(hub: HubDB): void {
  hub.db.prepare("UPDATE agent_reads SET args=json_remove(args,'$.q') WHERE kind='search' AND json_type(args,'$.q') IS NOT NULL").run();
  hub.db.prepare(`INSERT INTO distill_state(k,v) VALUES ('audit_query_erased_at',json_quote(?))
    ON CONFLICT(k) DO UPDATE SET v=excluded.v`).run(new Date().toISOString());
  const queue = queues.get(hub); if (!queue) return;
  restore(queue);
  for (const row of queue.rows.values()) {
    const clean = withoutQuery(row);
    if (clean === row) continue;
    persist(queue, clean);
    queue.rows.set(clean[0], clean);
  }
}
export function stopAgentAudit(hub: HubDB): void {
  flushAgentAudit(hub);
  const queue = queues.get(hub); if (queue) { clearInterval(queue.timer); queue.timer = undefined; }
}
