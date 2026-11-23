import { randomUUID } from "node:crypto";
import type { HubDB } from "./db.ts";

type SQL = HubDB["db"];
type Action = "pair.create" | "pair.complete" | "device.remove" | "device.role_change" |
  "key.set" | "key.delete" | "relay.change" | "remote.delete" | "auth.denied";

export const deviceRoleSchema = `
ALTER TABLE devices ADD COLUMN role TEXT NOT NULL DEFAULT 'collect' CHECK(role IN ('collect','view','admin','agent'));
UPDATE devices SET role='view' WHERE viewer=1;
ALTER TABLE devices ADD COLUMN role_revision INTEGER NOT NULL DEFAULT 0;
ALTER TABLE devices ADD COLUMN projection_reset INTEGER NOT NULL DEFAULT 0;
ALTER TABLE relay_mailboxes ADD COLUMN role_revision INTEGER NOT NULL DEFAULT 0;
CREATE TABLE security_audit (
  id TEXT PRIMARY KEY, at TEXT NOT NULL, actor_device TEXT, action TEXT NOT NULL,
  target TEXT, ok INTEGER NOT NULL, detail_code TEXT
);
CREATE INDEX security_audit_at ON security_audit(at DESC);
CREATE INDEX security_audit_remote_delete ON security_audit(at) WHERE action='remote.delete' AND ok=1;
PRAGMA user_version=16;
`;

const dayMs = 86_400_000;
export const remoteDeleteLimit = "远程删除达到安全上限，请在中枢本机执行或稍后再试";

export function auditSecurity(sql: SQL, action: Action, event: {
  actor?: string | null; target?: string; ok?: boolean; code?: string; now?: number;
} = {}) {
  sql.prepare("INSERT INTO security_audit(id,at,actor_device,action,target,ok,detail_code) VALUES (?,?,?,?,?,?,?)")
    .run(randomUUID(), new Date(event.now ?? Date.now()).toISOString(), event.actor ?? null, action,
      event.target ?? null, event.ok === false ? 0 : 1, event.code ?? null);
}

export function securityAudit(sql: SQL) {
  return sql.prepare("SELECT * FROM security_audit ORDER BY at DESC, rowid DESC LIMIT 200").all();
}

export function pruneSecurityAudit(sql: SQL, now = Date.now()) {
  sql.prepare("DELETE FROM security_audit WHERE at<?").run(new Date(now - 90 * dayMs).toISOString());
}

/** Called under the same write lock as the deletion. The quota is shared by all remote admins. */
export function reserveRemoteDelete(sql: SQL, actor: string, count: number, now: number) {
  if (count === 0) return true;
  const minute = new Date(now - 60_000).toISOString(), day = new Date(now - dayMs).toISOString();
  const used = sql.prepare<[string, string], { minute: number; day: number }>(`
    SELECT COALESCE(SUM(CASE WHEN at>? THEN CAST(detail_code AS INTEGER) ELSE 0 END),0) AS minute,
      COALESCE(SUM(CAST(detail_code AS INTEGER)),0) AS day
    FROM security_audit WHERE action='remote.delete' AND ok=1 AND at>?
  `).get(minute, day)!;
  const ok = used.minute + count <= 200 && used.day + count <= 1000;
  if (ok) auditSecurity(sql, "remote.delete", { actor, code: String(count), now });
  return ok;
}
