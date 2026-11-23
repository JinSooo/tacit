import type { HubDB } from "../db.ts";
import { auditSecurity } from "../security-audit.ts";
import { deviceID, WireError } from "./envelope.ts";
import { devicePermissionDenied, isPairingRole, projectionRoles, type DeviceRole } from "./permissions.ts";
import { touchProjectionDay } from "./projection-store.ts";
import { localDateString } from "../distill/requests.ts";

type SQL = HubDB["db"];
type Actor = { actor?: string; force?: boolean; now?: number };
const lastAdmin = "不能移除最后一台管理设备";

export const deviceSchema = `
CREATE TABLE IF NOT EXISTS devices (
  id TEXT PRIMARY KEY, name TEXT NOT NULL, platform TEXT NOT NULL, public_key BLOB NOT NULL,
  paired_at TEXT NOT NULL, last_seen TEXT NOT NULL
);
-- 只留分配过的 ID，防止重新配对复用已移除设备的身份。
CREATE TABLE IF NOT EXISTS issued_device_ids (id TEXT PRIMARY KEY);
CREATE TABLE IF NOT EXISTS device_changes (
  seq INTEGER PRIMARY KEY AUTOINCREMENT, device TEXT NOT NULL, kind TEXT NOT NULL,
  record_id TEXT NOT NULL, source TEXT, source_ref TEXT, created_at TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS device_changes_device_seq ON device_changes(device, seq);
CREATE INDEX IF NOT EXISTS records_device ON records(device);
PRAGMA user_version=13;
`;

export function deviceList(hub: HubDB) {
  return hub.db.prepare(`
    SELECT d.id, d.name, d.platform, d.paired_at, d.last_seen,
      (SELECT COUNT(*) FROM records r WHERE r.device=d.id) AS records,
      (SELECT COUNT(*) FROM device_changes c WHERE c.device=d.id) AS pending_changes, d.role
    FROM devices d ORDER BY d.paired_at, d.id
  `).all();
}

export function deviceAccess(sql: SQL, id: string) {
  return sql.prepare<[string], { role: DeviceRole; role_revision: number; projection_reset: number; platform: string }>(
    "SELECT role,role_revision,projection_reset,platform FROM devices WHERE id=?",
  ).get(id);
}

function targetDevice(sql: SQL, id: unknown) {
  if (typeof id !== "string" || !deviceID.test(id)) throw new WireError(400, "设备 ID 无效");
  const target = deviceAccess(sql, id);
  if (!target) throw new WireError(404, "设备不存在");
  return { id, ...target };
}

function protectLastAdmin(sql: SQL, role: DeviceRole, force = false) {
  if (role === "admin" && !force && !sql.prepare("SELECT 1 FROM devices WHERE role='admin' LIMIT 1 OFFSET 1").get()) {
    throw new WireError(409, lastAdmin);
  }
}

function clearDeviceReceipts(sql: SQL, id: string, activeOnly: boolean) {
  sql.prepare(`DELETE FROM relay_receipts WHERE EXISTS (
    SELECT 1 FROM relay_mailboxes WHERE space=relay_receipts.space AND up=relay_receipts.up AND device=? AND (NOT ? OR state='active')
  )`).run(id, Number(activeOnly));
}

export function updateDeviceRole(sql: SQL, id: unknown, role: unknown, options: Actor = {}) {
  if (!isPairingRole(role)) throw new WireError(400, "设备角色无效");
  return sql.transaction(() => {
    const target = targetDevice(sql, id);
    if (target.role === role) return { id: target.id, role };
    if (target.role === "agent" || (options.actor && role === "admin")) {
      throw new WireError(403, devicePermissionDenied);
    }
    if (target.platform === "android" && role !== "collect") throw new WireError(403, devicePermissionDenied);
    protectLastAdmin(sql, target.role, options.force);
    const reset = role === "collect" && projectionRoles(target.role);
    sql.prepare(`UPDATE devices SET role=?,role_revision=role_revision+1,projection_reset=?,
      projection_cursor=0,projection_epoch=0,projection_window_from=NULL,projection_window_until=NULL WHERE id=?`)
      .run(role, Number(reset), target.id);
    clearDeviceReceipts(sql, target.id, true);
    if (projectionRoles(role)) touchProjectionDay(sql, localDateString(options.now ?? Date.now()));
    auditSecurity(sql, "device.role_change", { ...options, target: target.id, code: target.role + ":" + role });
    return { id: target.id, role };
  }).immediate();
}

export function removeDevice(sql: SQL, id: unknown, options: Actor = {}) {
  return sql.transaction(() => {
    const target = targetDevice(sql, id);
    protectLastAdmin(sql, target.role, options.force);
    sql.prepare("DELETE FROM device_changes WHERE device=?").run(target.id);
    clearDeviceReceipts(sql, target.id, false);
    sql.prepare(`UPDATE relay_mailboxes SET state='revoked', token=NULL, move_body=NULL, move_id=NULL WHERE device=?`).run(target.id);
    sql.prepare("DELETE FROM devices WHERE id=?").run(target.id);
    auditSecurity(sql, "device.remove", { ...options, target: target.id });
    return { deleted: true };
  }).immediate();
}
