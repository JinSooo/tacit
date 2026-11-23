export const relaySchema = `
CREATE TABLE IF NOT EXISTS device_nonces (
  device TEXT NOT NULL, nonce TEXT NOT NULL, seen_at INTEGER NOT NULL, PRIMARY KEY(device, nonce)
);
CREATE INDEX IF NOT EXISTS device_nonces_seen ON device_nonces(seen_at);
CREATE TABLE IF NOT EXISTS relay_spaces (
  space TEXT PRIMARY KEY, url TEXT NOT NULL,
  state TEXT NOT NULL CHECK(state IN ('staging', 'current', 'retiring')),
  retire_at INTEGER, last_fetch INTEGER, used_bytes INTEGER,
  discarded INTEGER NOT NULL DEFAULT 0, remote_deleted INTEGER NOT NULL DEFAULT 0
);
CREATE UNIQUE INDEX IF NOT EXISTS relay_current ON relay_spaces(state) WHERE state='current';
CREATE TABLE IF NOT EXISTS relay_mailboxes (
  space TEXT NOT NULL, up TEXT NOT NULL, down TEXT NOT NULL,
  device TEXT, token_id TEXT, token TEXT, expires_at INTEGER,
  state TEXT NOT NULL CHECK(state IN ('staging', 'active', 'invite', 'pair_reply', 'revoked')),
  move_id TEXT, move_body TEXT, pending INTEGER,
  PRIMARY KEY(space, up)
);
CREATE INDEX IF NOT EXISTS relay_mailboxes_device ON relay_mailboxes(device);
CREATE TABLE IF NOT EXISTS relay_receipts (
  space TEXT NOT NULL, up TEXT NOT NULL, id TEXT NOT NULL,
  request_hash TEXT NOT NULL, result TEXT NOT NULL, seen_at INTEGER NOT NULL,
  PRIMARY KEY(space, up, id)
);
CREATE INDEX IF NOT EXISTS relay_receipts_seen ON relay_receipts(seen_at);
PRAGMA user_version=14;
`;

export const dayMs = 86_400_000;

export interface RelayConfig {
  url: string;
  space: string;
  up: string;
  down: string;
  token: string;
}

export interface Space {
  space: string;
  url: string;
  state: "staging" | "current" | "retiring";
  retire_at: number | null;
  last_fetch: number | null;
  used_bytes: number | null;
  discarded: number;
  remote_deleted: 0 | 1;
}

export interface Mailbox {
  space: string;
  up: string;
  down: string;
  device: string | null;
  token_id: string | null;
  token: string | null;
  expires_at: number | null;
  state: "staging" | "active" | "invite" | "pair_reply" | "revoked";
  move_id: string | null;
  move_body: string | null;
  pending: number | null;
  role_revision: number;
  push_msg_id: string | null;
  push_seq: number | null;
  push_epoch: number | null;
  push_at: number | null;
  push_kind: string | null;
  projection_purged_epoch: number | null;
}

export interface RelayRequest {
  mailbox: Mailbox;
  id: string;
  replyDelivered?: () => void;
  projectionRead?: { seq: number; urgent: number; epoch: number; revision: number };
}

export function relayConfig(space: Space, box: Mailbox): RelayConfig {
  return { url: space.url, space: space.space, up: box.up, down: box.down, token: box.token! };
}
