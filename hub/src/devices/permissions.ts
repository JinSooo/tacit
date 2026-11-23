export const pairingRoles = ["collect", "view", "admin"] as const;
export type PairingRole = typeof pairingRoles[number];
export type DeviceRole = PairingRole | "agent";

export function isPairingRole(value: unknown): value is PairingRole {
  return pairingRoles.some(role => role === value);
}

export const projectionRoles = (role: DeviceRole) => role === "view" || role === "admin";
export const devicePermissionDenied = "当前设备权限不足";

const collectOps = new Set([
  "ingest", "delete", "sync", "sync.ack", "audio.sync", "audio.sync.ack", "audio.embeddings",
  "audio.skipped", "audio.samples", "audio.lines", "conversations", "conversations.put", "collector.status", "relay",
]);
const projectionOps = new Set(["projection.pull", "projection.ack", "events.subscribe"]);
export const projectionReads = new Set(["records.get", "records.list", "history.segments", "conversations.detail", "timeline.query", "timeline.locate"]);
const agentOps = new Set(["agent.now", "agent.get", "agent.search", "agent.timeline", "agent.context", "agent.append", "agent.audit_sync"]);
const statusOps = new Set(["status.get", "diagnostics.get"]);
const adminOps = new Set([
  "devices.role.update", "devices.remove", "devices.pairing.create", "devices.pairing.cancel", "devices.list",
  "records.create", "segment.correct", "segment.delete", "project.remove", "distill.request", "audit.list",
  "pending.list", "pending.resolve", "facts.create", "facts.detach",
  "distill.list", "audio.purge", "speakers.list", "audio.sample.get",
  "settings.security-events.list", "settings.security-events.ack",
  "settings.hub.get", "settings.hub.put", "settings.models.get", "settings.models.put", "settings.models.local", "settings.models.test",
  "settings.keys.put", "settings.keys.delete", "settings.general.get", "settings.general.put",
  "settings.relay.get", "settings.relay.put", "settings.relay.test", "audio.settings.get", "audio.settings.put",
  "runtime.models", "runtime.call", "runtime.background",
]);

export function operationAccess(role: DeviceRole, op: string): "allow" | "deny" | "unknown" {
  if (collectOps.has(op)) return role === "agent" ? "deny" : "allow";
  if (projectionOps.has(op)) return role === "collect" ? "deny" : "allow";
  if (projectionReads.has(op) || op.startsWith("timeline.") || statusOps.has(op)) return projectionRoles(role) ? "allow" : "deny";
  if (agentOps.has(op)) return role === "collect" ? "deny" : "allow";
  if (adminOps.has(op) || /^(?:facts|pending|settings|devices|runtime|audio\.settings)\./.test(op)) {
    return role === "admin" ? "allow" : "deny";
  }
  return "unknown";
}

/** Request op names are untrusted. Only known protocol names may reach the audit log. */
export function auditOp(op: string) {
  return [collectOps, projectionOps, projectionReads, agentOps, statusOps, adminOps].some(group => group.has(op)) ? op : "unknown_op";
}
