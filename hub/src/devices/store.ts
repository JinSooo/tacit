import type { HubDB } from "../db.ts";

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
      (SELECT COUNT(*) FROM device_changes c WHERE c.device=d.id) AS pending_changes, d.viewer
    FROM devices d ORDER BY d.paired_at, d.id
  `).all();
}
