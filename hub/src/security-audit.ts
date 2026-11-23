import { randomUUID } from "node:crypto";
import type { HubDB } from "./db.ts";

type SQL = HubDB["db"];
type Action = "pair.create" | "pair.complete" | "device.local_register" | "device.remove" | "device.role_change" |
  "key.set" | "key.delete" | "relay.change" | "remote.delete" | "local.delete" | "auth.denied";

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

export const securityEventsSchema = `
ALTER TABLE security_audit ADD COLUMN remote_actor INTEGER NOT NULL DEFAULT 0;
UPDATE security_audit SET actor_device=target WHERE action='pair.complete' AND ok=1 AND actor_device IS NULL;
UPDATE security_audit SET remote_actor=1 WHERE actor_device IN (SELECT id FROM devices WHERE local_only=0);
CREATE TABLE security_event_acknowledgements (
  event_id TEXT PRIMARY KEY, acknowledged_at TEXT NOT NULL
);
PRAGMA user_version=18;
`;

const visibleSecurityEvent = `
  e.ok=1 AND e.remote_actor=1 AND e.actor_device IS NOT ?
  AND (e.action IN ('device.role_change','key.set') OR (e.action='pair.complete' AND e.detail_code='admin'))
`;
export const securityEventID = (value: string) => /^[a-f0-9]{8}-(?:[a-f0-9]{4}-){3}[a-f0-9]{12}$/.test(value);

export function pendingSecurityEvents(sql: SQL, actor?: string) {
  return sql.prepare(`
    SELECT e.id, e.at, e.action FROM security_audit e
    WHERE ${visibleSecurityEvent}
      AND NOT EXISTS (SELECT 1 FROM security_event_acknowledgements a WHERE a.event_id=e.id)
    ORDER BY e.at DESC, e.rowid DESC LIMIT 200
  `).all(actor ?? null);
}

export function acknowledgeSecurityEvent(sql: SQL, id: string, actor?: string, now = Date.now()) {
  // Repeating an acknowledgement is safe and preserves the original timestamp.
  return !!sql.prepare(`
    INSERT INTO security_event_acknowledgements(event_id,acknowledged_at)
    SELECT e.id, ? FROM security_audit e WHERE e.id=? AND ${visibleSecurityEvent}
    ON CONFLICT(event_id) DO UPDATE SET acknowledged_at=acknowledged_at
  `).run(new Date(now).toISOString(), id, actor ?? null).changes;
}

const dayMs = 86_400_000;
export const remoteDeleteLimit = "远程删除达到安全上限，请在中枢本机执行或稍后再试";

export function auditSecurity(sql: SQL, action: Action, event: {
  actor?: string | null; remoteActor?: boolean; target?: string; ok?: boolean; code?: string; now?: number;
} = {}) {
  sql.prepare(`
    INSERT INTO security_audit(id,at,actor_device,action,target,ok,detail_code,remote_actor)
    VALUES (?,?,?,?,?,?,?,COALESCE(?,EXISTS(SELECT 1 FROM devices WHERE id=? AND local_only=0)))
  `)
    .run(randomUUID(), new Date(event.now ?? Date.now()).toISOString(), event.actor ?? null, action,
      event.target ?? null, event.ok === false ? 0 : 1, event.code ?? null,
      event.remoteActor === undefined ? null : Number(event.remoteActor), event.actor ?? null);
}

export function securityAudit(sql: SQL) {
  return sql.prepare("SELECT id,at,actor_device,action,target,ok,detail_code FROM security_audit ORDER BY at DESC, rowid DESC LIMIT 200").all();
}

export function pruneSecurityAudit(sql: SQL, now = Date.now()) {
  sql.transaction(() => {
    sql.prepare("DELETE FROM security_audit WHERE at<?").run(new Date(now - 90 * dayMs).toISOString());
    sql.prepare(`DELETE FROM security_event_acknowledgements
      WHERE NOT EXISTS (SELECT 1 FROM security_audit e WHERE e.id=event_id)`).run();
  }).immediate();
}

/** Called under the same write lock as the deletion. The quota is shared by all remote devices. */
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
