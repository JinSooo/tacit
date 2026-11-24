import { createPublicKey, diffieHellman, generateKeyPairSync, randomBytes } from "node:crypto";
import type { HubDB } from "../db.ts";
import { auditSecurity } from "../security-audit.ts";
import { base32, base64url, deviceID, WireError } from "./envelope.ts";
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
  return sql.prepare<[string], { role: DeviceRole; role_revision: number; projection_reset: number; platform: string; local_only: number }>(
    "SELECT role,role_revision,projection_reset,platform,local_only FROM devices WHERE id=?",
  ).get(id);
}

export function allocateDeviceID(sql: SQL, platform: "mac" | "android" | "agent") {
  const allocate = sql.prepare("INSERT OR IGNORE INTO issued_device_ids VALUES(?)");
  let id: string;
  do { id = `${platform}-${base32(randomBytes(5))}`; } while (!allocate.run(id).changes);
  return id;
}

export function registerLocalDevices(sql: SQL, agentKey: Buffer, macKey: Buffer | null, now: number) {
  return sql.transaction(() => {
    const find = sql.prepare<[Buffer], { id: string; platform: string; role: DeviceRole; local_only: number; bootstrap_agent_id: string | null }>(
      "SELECT id, platform, role, local_only, bootstrap_agent_id FROM devices WHERE public_key=? ORDER BY id LIMIT 2");
    const agents = find.all(agentKey), macs = macKey ? find.all(macKey) : [];
    const [agent] = agents, [mac] = macs;
    const usableAgent = agents.length === 1 && agent?.platform === "agent" && agent.role === "agent" && agent.local_only === 1;
    const existingPair = usableAgent && macs.length === 1 && mac?.platform === "mac" &&
      mac.local_only === 1 && mac.bootstrap_agent_id === agent.id;
    const agentAlreadyPaired = usableAgent && macKey && !macs.length &&
      sql.prepare("SELECT 1 FROM devices WHERE platform='mac' AND bootstrap_agent_id=?").get(agent.id);
    if ((agents.length && !usableAgent) || (macs.length && !existingPair) || agentAlreadyPaired) {
      auditSecurity(sql, "device.local_register", { ok: false, code: "key_conflict", now });
      return null;
    }
    if (existingPair) return { mac_device_id: mac.id, agent_device_id: agent.id };
    if (usableAgent && !macKey) return { agent_device_id: agent.id };

    const at = new Date(now).toISOString();
    const insert = sql.prepare(`INSERT INTO devices(id,name,platform,public_key,paired_at,last_seen,role,local_only,bootstrap_agent_id)
      VALUES(?,?,?,?,?,?,?,1,?)`);
    const agentId = agent?.id ?? allocateDeviceID(sql, "agent");
    if (!agent) {
      insert.run(agentId, "Tacit AI", "agent", agentKey, at, at, "agent", null);
      auditSecurity(sql, "device.local_register", { target: agentId, code: "agent", now });
    }
    if (!macKey) return { agent_device_id: agentId };
    const macId = allocateDeviceID(sql, "mac");
    insert.run(macId, "Tacit Mac", "mac", macKey, at, at, "admin", agentId);
    auditSecurity(sql, "device.local_register", { target: macId, code: "admin", now });
    touchProjectionDay(sql, localDateString(now));
    return { mac_device_id: macId, agent_device_id: agentId };
  }).immediate();
}

/** 低阶点（全零等）协商出全零密钥，OpenSSL 会拒绝；这里同步试一次，避免登记出无法通信的僵尸设备。 */
function usableX25519(raw: Buffer) {
  try {
    const publicKey = createPublicKey({ key: { kty: "OKP", crv: "X25519", x: raw.toString("base64url") }, format: "jwk" });
    diffieHellman({ privateKey: generateKeyPairSync("x25519").privateKey, publicKey });
    return true;
  } catch { return false; }
}

/** Called in the authenticated operation transaction, including the mailbox receipt if present. */
export function enrollRemoteAgent(sql: SQL, parent: string, agentPK: unknown, now: number) {
  const key = base64url(agentPK, 32);
  if (!key || !usableX25519(key)) throw new WireError(400, "Agent 公钥无效");
  const existing = sql.prepare<[Buffer], { id: string; platform: string; role: DeviceRole; local_only: number; bootstrap_agent_id: string | null }>(
    "SELECT id, platform, role, local_only, bootstrap_agent_id FROM devices WHERE public_key=? LIMIT 2",
  ).all(key);
  const [agent] = existing;
  if (existing.length) {
    if (existing.length === 1 && agent?.platform === "agent" && agent.role === "agent" &&
        agent.local_only === 0 && agent.bootstrap_agent_id === parent) return agent.id;
    throw new WireError(409, "公钥已用于其他设备");
  }

  // Local bootstrap keeps its Mac -> Agent link; remote Agent rows use the field for their parent Mac.
  const id = allocateDeviceID(sql, "agent"), at = new Date(now).toISOString();
  sql.prepare(`INSERT INTO devices(id,name,platform,public_key,paired_at,last_seen,role,local_only,bootstrap_agent_id)
    VALUES(?, 'Tacit AI', 'agent', ?, ?, ?, 'agent', 0, ?)`).run(id, key, at, at, parent);
  return id;
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
    SELECT 1 FROM relay_mailboxes WHERE space=relay_receipts.space AND up=relay_receipts.up AND device=? AND (NOT ? OR state IN ('active','pair_reply'))
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
    if (target.platform === "android" && role === "admin") throw new WireError(403, devicePermissionDenied);
    protectLastAdmin(sql, target.role, options.force);
    const reset = role === "collect" && projectionRoles(target.role);
    sql.prepare(`UPDATE devices SET role=?,role_revision=role_revision+1,projection_reset=?,
      projection_cursor=0,projection_epoch=0,projection_window_from=NULL,projection_window_until=NULL WHERE id=?`)
      .run(role, Number(reset), target.id);
    clearDeviceReceipts(sql, target.id, true);
    if (target.role === "admin") revokeRemoteAgents(sql, target.id, options);
    if (projectionRoles(role)) touchProjectionDay(sql, localDateString(options.now ?? Date.now()));
    auditSecurity(sql, "device.role_change", { ...options, target: target.id, code: target.role + ":" + role });
    return { id: target.id, role };
  }).immediate();
}

function deleteDevice(sql: SQL, id: string, options: Actor, code?: string) {
  sql.prepare("DELETE FROM device_changes WHERE device=?").run(id);
  clearDeviceReceipts(sql, id, false);
  sql.prepare(`UPDATE relay_mailboxes SET state='revoked', token=NULL, move_body=NULL, move_id=NULL WHERE device=?`).run(id);
  sql.prepare("DELETE FROM devices WHERE id=?").run(id);
  sql.prepare("DELETE FROM distill_state WHERE k=?").run(`collector_status:${id}`);
  auditSecurity(sql, "device.remove", { ...options, target: id, code });
}

function revokeRemoteAgents(sql: SQL, parent: string, options: Actor) {
  const agents = sql.prepare<[string], { id: string }>(`
    SELECT id FROM devices WHERE platform='agent' AND role='agent' AND local_only=0 AND bootstrap_agent_id=?
  `).all(parent);
  for (const { id } of agents) deleteDevice(sql, id, options, "parent_revoked");
}

export function removeDevice(sql: SQL, id: unknown, options: Actor = {}) {
  return sql.transaction(() => {
    const target = targetDevice(sql, id);
    protectLastAdmin(sql, target.role, options.force);
    if (target.role === "admin") revokeRemoteAgents(sql, target.id, options);
    deleteDevice(sql, target.id, options);
    return { deleted: true };
  }).immediate();
}
