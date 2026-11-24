import { createHash } from "node:crypto";
import type { HubDB } from "../db.ts";
import type { PairingRole } from "./permissions.ts";
import type { RelayConfig, RelayRequest } from "./relay-store.ts";

type SQL = HubDB["db"];
export type PairReceipt = {
  device_id: string;
  hub_id: string;
  name: string;
  role: PairingRole;
  relay?: RelayConfig;
};
const prefix = "device_pair_receipt:";
const digest = (value: Buffer | string) => createHash("sha256").update(value).digest("hex");

export const pairReceiptKey = (code: Buffer) => prefix + digest(code);
export const pairRequestHash = (key: Buffer, platform: unknown, name: unknown) =>
  digest(JSON.stringify([key.toString("base64url"), platform, name]));

export function savePairReceipt(sql: SQL, key: string, request: string, expires: number, reply: PairReceipt, relay: RelayConfig | null) {
  // Only routing IDs for the invitation are needed. The invitation code and token are consumed.
  const mailbox = relay && { space: relay.space, up: relay.up };
  sql.prepare("INSERT INTO distill_state(k,v) VALUES (?,?)").run(key, JSON.stringify({ request, expires, reply, mailbox }));
}

export function recoverPairReceipt(sql: SQL, key: string, request: string, hubID: string, now: number, context?: RelayRequest) {
  const row = sql.prepare<[string, string, string, number], { v: string }>(`
    SELECT s.v FROM distill_state s JOIN devices d ON d.id=json_extract(s.v,'$.reply.device_id')
    WHERE s.k=? AND json_extract(s.v,'$.request')=? AND json_extract(s.v,'$.reply.hub_id')=?
      AND json_extract(s.v,'$.expires')>? AND d.role_revision=0
  `).get(key, request, hubID, now);
  if (!row) return null;
  const { reply, mailbox } = JSON.parse(row.v) as { reply: PairReceipt; mailbox: { space: string; up: string } | null };
  if (context && (mailbox?.space !== context.mailbox.space || mailbox.up !== context.mailbox.up)) return null;
  return reply;
}

export function prunePairReceipts(sql: SQL, now: number) {
  const query = "FROM distill_state WHERE k GLOB 'device_pair_receipt:*' AND json_extract(v,'$.expires')<=?";
  // Avoid acquiring a write lock on an idle hub.
  if (sql.prepare("SELECT 1 " + query + " LIMIT 1").get(now)) sql.prepare("DELETE " + query).run(now);
}
