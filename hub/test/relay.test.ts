import { expect, test } from "bun:test";
import { randomBytes } from "node:crypto";
import { existsSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { startRelay } from "../../relay/src/bun.ts";
import { defaultLimits } from "../../relay/src/core.ts";
import { HubDB } from "../src/db.ts";
import { dayMs, type RelayConfig } from "../src/devices/relay-store.ts";
import { startServer } from "../src/server.ts";
import { decodePairing, DeviceClient, type ResponseEnvelope } from "./device-client.ts";
import { fixture, setup } from "./helpers.ts";

const path = "/v1/settings/relay";
const id = () => randomBytes(16).toString("base64url");

async function hubFixture() {
  const ctx = setup();
  const probe = Bun.serve({ hostname: "0.0.0.0", port: 0, fetch: () => new Response() });
  const lanPort = probe.port!;
  await probe.stop(true);
  writeFileSync(join(ctx.dir, "hub.json"), JSON.stringify({ lan_port: lanPort }));
  let now = Date.now();
  let key: string | null = null;
  const credentials = new Map<string, string>();
  const options = {
    db: ctx.db, token: ctx.config.token, agentToken: "fixture-agent-token", port: 0, settings: { dataDir: ctx.dir },
    deviceDeps: {
      name: "测试中枢", addresses: () => ["192.0.2.2"], now: () => now,
      keys: { read: () => key, write: (value: string) => { key = value; } },
      relayKeys: {
        read: (space: string) => credentials.get(space) ?? null,
        write: (space: string, value: string) => { credentials.set(space, value); },
        remove: (space: string) => { credentials.delete(space); },
      },
    },
  };
  let server = startServer(options);
  const lan = `http://127.0.0.1:${lanPort}`;
  const admin = (route: string, method = "GET", body?: object) => fetch(new URL(route, server.url), {
    method, headers: { Authorization: `Bearer ${ctx.config.token}`, "Content-Type": "application/json" },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  async function invite() {
    const response = await admin("/v1/settings/devices/pairing", "POST");
    expect(response.status).toBe(200);
    const pairing = decodePairing((await response.json() as { uri: string }).uri);
    return { pairing: pairing as typeof pairing & { relay?: RelayConfig }, phone: await DeviceClient.fromInvite(pairing, lan) };
  }
  async function pair() {
    const { pairing, phone } = await invite();
    expect((await phone.pair(pairing)).status).toBe(200);
    return phone;
  }
  return {
    ...ctx, admin, credentials, invite, pair, lan,
    url: () => server.url,
    advance(ms: number) { now += ms; },
    time: () => new Date(now).toISOString(),
    async stop() { await server.stop(true); },
    start() { server = startServer(options); },
    async dispose() { await server.stop(true); ctx.cleanup(); },
  };
}

function relayFixture(options: Parameters<typeof startRelay>[0] = {}) {
  const relay = startRelay({ port: 0, hostname: "127.0.0.1", ...options });
  return { ...relay, url: `http://127.0.0.1:${relay.server.port}` };
}

const remote = (relay: RelayConfig, box: string, method = "GET", nonce?: string, body?: object, token = relay.token) =>
  fetch(`${relay.url}/v1/spaces/${relay.space}/boxes/${box}/messages${nonce ? "/" + nonce : ""}`, {
    method, headers: { Authorization: `Bearer ${token}`, "Content-Type": "application/json" },
    body: body === undefined ? undefined : JSON.stringify(body),
  });

async function eventually<T>(get: () => Promise<T | undefined> | T | undefined) {
  const deadline = Date.now() + 3_000;
  do {
    const value = await get();
    if (value !== undefined) return value;
    await Bun.sleep(15);
  } while (Date.now() < deadline);
  throw new Error("等待信箱状态超时");
}

async function list(relay: RelayConfig, box = relay.down, token = relay.token) {
  const response = await remote(relay, box, "GET", undefined, undefined, token);
  expect(response.status).toBe(200);
  return (await response.json() as { messages: { id: string }[] }).messages;
}

async function submit(relay: RelayConfig, phone: DeviceClient, op: string, body: object, ts: string, nonce = id(), message = nonce) {
  const input = { op, body, ts, nonce };
  const envelope = await phone.envelope(input);
  expect((await remote(relay, relay.up, "PUT", message, envelope)).status).toBe(201);
  return message;
}

async function replyWire(relay: RelayConfig, nonce: string) {
  return await eventually(async () => {
    const response = await remote(relay, relay.down, "GET", nonce);
    if (response.status === 404) return;
    expect(response.status).toBe(200);
    return await response.json() as ResponseEnvelope;
  });
}

async function reply<T>(phone: DeviceClient, relay: RelayConfig, nonce: string) {
  return await phone.open<T>(await replyWire(relay, nonce), nonce);
}

async function configure(hub: Awaited<ReturnType<typeof hubFixture>>, url: string, code?: string) {
  const response = await hub.admin(path, "PUT", { mode: "custom", url, code });
  expect(response.status).toBe(200);
  expect(await response.json()).toMatchObject({ mode: "custom", url });
}

async function deviceConfig(phone: DeviceClient) {
  const response = await phone.send<{ relay: RelayConfig | null }>("relay", {});
  expect(response.status).toBe(200);
  return response.body.relay!;
}

test("管理令牌隔离，真实信箱上传、跨重启防重放并丢弃错投和错误消息编号", async () => {
  const hub = await hubFixture(), relay = relayFixture({ createCode: "fixture-code" });
  try {
    expect((await hub.admin(path, "PUT", { mode: "custom", url: "http://example.test" })).status).toBe(400);
    expect((await hub.admin(path + "/test", "POST", { url: hub.url().origin })).status).toBe(502);
    const probe = await hub.admin(path + "/test", "POST", { url: relay.url });
    expect(await probe.json()).toMatchObject({ tacit_relay: 1 });
    expect((await hub.admin(path, "PUT", { mode: "custom", url: relay.url, code: "wrong" })).status).toBe(403);
    const phone = await hub.pair(), other = await hub.pair();
    expect(await deviceConfig(phone)).toBeNull();
    await configure(hub, relay.url, "fixture-code");
    const box = await deviceConfig(phone);
    const spaceToken = hub.credentials.get(box.space)!;
    expect((await fetch(hub.lan + path, { headers: { Authorization: `Bearer ${hub.config.token}` } })).status).toBe(404);
    expect((await fetch(new URL(path, hub.url()), { headers: { Authorization: "Bearer fixture-agent-token" } })).status).toBe(403);
    const record = fixture({ device: phone.device!, source: "android.audio", source_ref: "audio:fixture-relay" });
    const lastWeek = new Date(Date.parse(hub.time()) - 7 * dayMs).toISOString();
    const nonce = await submit(box, phone, "ingest", { records: [record] }, lastWeek);
    expect(await reply(phone, box, nonce)).toMatchObject({ status: 200, body: { accepted: 1 } });
    expect(hub.db.get(record.id)).not.toBeNull();
    await eventually(async () => (await list(box, box.up, spaceToken)).length === 0 || undefined);
    await remote(box, box.down, "DELETE", nonce);

    await hub.stop();
    hub.start();
    expect(await phone.send("sync", { cursor: 0 }, { nonce })).toEqual({ status: 400, body: { error: "请求 nonce 已使用" } });
    const replayed = fixture({ device: phone.device!, source: "android.audio", source_ref: "audio:fixture-replay" });
    const wrongDevice = fixture({ device: other.device!, source: "android.audio", source_ref: "audio:fixture-misroute" });
    const wrongID = fixture({ device: phone.device!, source: "android.audio", source_ref: "audio:fixture-wrong-id" });
    await submit(box, phone, "ingest", { records: [replayed] }, hub.time(), nonce);
    await submit(box, other, "ingest", { records: [wrongDevice] }, hub.time());
    await submit(box, phone, "ingest", { records: [wrongID] }, hub.time(), id(), id());
    await eventually(async () => (await list(box, box.up, spaceToken)).length === 0 || undefined);
    expect(await list(box)).toEqual([]);
    for (const ts of [Date.parse(hub.time()) - 31 * dayMs, Date.parse(hub.time()) + 11 * 60_000]) {
      const expired = await submit(box, phone, "relay", {}, new Date(ts).toISOString());
      expect(await reply(phone, box, expired)).toMatchObject({ status: 400, body: { error: "请求时间无效或已过期" } });
    }
    for (const entry of [replayed, wrongDevice, wrongID]) expect(hub.db.get(entry.id)).toBeNull();
    const status = await (await hub.admin("/v1/status")).text();
    expect(JSON.parse(status).relay).toMatchObject({ connected: true, unprocessable: 2, last_fetch_at: expect.any(String) });
    expect(status).not.toContain(box.token);
    expect(status).not.toContain(spaceToken);
    expect(await (await hub.admin(path)).text()).not.toContain(box.token);

    expect((await hub.admin(`/v1/settings/devices/${phone.device}`, "DELETE")).status).toBe(200);
    expect((await remote(box, box.down)).status).toBe(401);
    expect(hub.db.get(record.id)).not.toBeNull();
  } finally { await hub.dispose(); relay.stop(true); }
});

test("信箱配对回复保留到手机读删，直连配对也发放设备信箱", async () => {
  const hub = await hubFixture(), relay = relayFixture();
  try {
    await configure(hub, relay.url);
    const { pairing, phone } = await hub.invite();
    const temporary = pairing.relay!;
    expect(temporary.url).toBe(relay.url);
    expect(typeof temporary.token).toBe("string");
    expect((await remote(temporary, temporary.up)).status).toBe(403);
    const nonce = await submit(temporary, phone, "pair", await phone.pairingBody(pairing), hub.time());
    const paired = await reply<{ device_id: string; relay: RelayConfig }>(phone, temporary, nonce);
    expect(paired).toMatchObject({ status: 200, body: { relay: { url: relay.url } } });
    phone.device = paired.body.device_id;
    expect(paired.body.relay.up).not.toBe(temporary.up);
    expect(await deviceConfig(phone)).toEqual(paired.body.relay);
    const relayOp = await submit(paired.body.relay, phone, "relay", {}, hub.time());
    expect(await reply(phone, paired.body.relay, relayOp)).toEqual({ status: 200, body: { relay: paired.body.relay } });
    expect((await remote(temporary, temporary.down, "DELETE", nonce)).status).toBe(200);
    await hub.stop();
    hub.start();
    await eventually(async () => (await remote(temporary, temporary.down)).status === 401 || undefined);
    const direct = await hub.invite();
    const directReply = await direct.phone.send<{ relay: RelayConfig }>("pair", await direct.phone.pairingBody(direct.pairing));
    expect(directReply).toMatchObject({ status: 200, body: { relay: { url: relay.url } } });
    await eventually(async () => (await remote(direct.pairing.relay!, direct.pairing.relay!.down)).status === 401 || undefined);
  } finally { await hub.dispose(); relay.stop(true); }
});

test("换信箱和关闭会通知旧设备，旧空间仍可取信并在七天后删除", async () => {
  const hub = await hubFixture(), first = relayFixture(), second = relayFixture();
  try {
    const phone = await hub.pair();
    await configure(hub, first.url);
    const a = await deviceConfig(phone);
    await configure(hub, second.url);
    const b = await deviceConfig(phone);
    const moveA = await eventually(async () => (await list(a))[0]?.id);
    expect(await phone.openPayload(await replyWire(a, moveA), moveA)).toEqual({ kind: "relay.moved", relay: b });
    const viaOld = await submit(a, phone, "sync", { cursor: 0 }, hub.time());
    expect(await reply(phone, a, viaOld)).toMatchObject({ status: 200 });

    expect((await hub.admin(path, "PUT", { mode: "off" })).status).toBe(200);
    expect(await deviceConfig(phone)).toBeNull();
    const moveB = await eventually(async () => (await list(b))[0]?.id);
    expect(await phone.openPayload(await replyWire(b, moveB), moveB)).toEqual({ kind: "relay.moved", relay: null });
    expect(await (await hub.admin(path)).json()).toMatchObject({
      mode: "off", retiring: [{ url: first.url, retire_at: expect.any(String) }, { url: second.url, retire_at: expect.any(String) }],
    });
    await hub.stop();
    hub.advance(7 * dayMs + 1);
    hub.start();
    await eventually(() => hub.credentials.size === 0 || undefined);
    expect((await remote(a, a.down)).status).toBe(401);
    expect((await remote(b, b.down)).status).toBe(401);
    expect(await (await hub.admin(path)).json()).toMatchObject({ mode: "off", retiring: [] });
  } finally { await hub.dispose(); first.stop(true); second.stop(true); }
});

test("回执写入失败后重启可补发原结果，已执行的请求不再执行", async () => {
  const hub = await hubFixture(), limits = { ...defaultLimits }, relay = relayFixture({ limits });
  try {
    const phone = await hub.pair();
    await configure(hub, relay.url);
    const box = await deviceConfig(phone);
    await hub.stop();
    const record = fixture({ device: phone.device!, source: "android.audio", source_ref: "audio:fixture-recovery" });
    const nonce = await submit(box, phone, "ingest", { records: [record] }, hub.time());
    limits.space_bytes = 1;
    hub.start();
    await eventually(() => hub.db.get(record.id) ?? undefined);
    await hub.stop();
    expect((await list(box, box.up, hub.credentials.get(box.space))).map(m => m.id)).toEqual([nonce]);
    expect(await list(box)).toEqual([]);
    limits.space_bytes = defaultLimits.space_bytes;
    hub.start();
    expect(await reply(phone, box, nonce)).toMatchObject({ status: 200, body: { accepted: 1, duplicates: 0 } });
    await eventually(async () => (await list(box, box.up, hub.credentials.get(box.space))).length === 0 || undefined);
  } finally { await hub.dispose(); relay.stop(true); }
});

test("v13 加密数据库升级到 v14，保留配对记录并清理迁移备份", () => {
  const ctx = setup();
  try {
    ctx.db.db.exec(`
      DROP TABLE device_nonces; DROP TABLE relay_mailboxes; DROP TABLE relay_spaces; DROP TABLE relay_receipts;
      INSERT INTO devices VALUES ('android-abcd2345','测试手机','android',X'00','2026-11-23','2026-11-23');
      PRAGMA user_version=13;
    `);
    ctx.db.close();
    const db = new HubDB(ctx.file, ctx.config.dbKey);
    try {
      expect(db.db.pragma("user_version", { simple: true })).toBe(14);
      expect(db.db.prepare("SELECT id FROM devices").all()).toEqual([{ id: "android-abcd2345" }]);
      expect(db.db.prepare("SELECT * FROM device_nonces").all()).toEqual([]);
      expect(existsSync(ctx.file + ".migration-v13.bak")).toBe(false);
    } finally { db.close(); }
  } finally { ctx.cleanup(); }
});

test("信箱离线时移除设备并保留待吊销项，重连时吊销并删信箱", async () => {
  const hub = await hubFixture(), file = join(hub.dir, "fixture-relay.sqlite");
  let relay = relayFixture({ db: file });
  let online = true;
  try {
    const removed = await hub.pair(), kept = await hub.pair();
    await configure(hub, relay.url);
    const box = await deviceConfig(removed);
    const port = relay.server.port!;
    relay.stop(true);
    online = false;
    expect((await hub.admin(`/v1/settings/devices/${removed.device}`, "DELETE")).status).toBe(200);
    expect(hub.db.db.prepare("SELECT state, token FROM relay_mailboxes WHERE device=?").get(removed.device))
      .toEqual({ state: "revoked", token: null });
    const wire = await removed.envelope({ op: "sync", body: { cursor: 0 }, nonce: id(), ts: hub.time() });
    expect((await removed.post(wire)).status).toBe(401);
    expect((await kept.send("sync", { cursor: 0 })).status).toBe(200);

    relay = relayFixture({ db: file, port });
    online = true;
    await hub.stop();
    hub.start();
    await eventually(async () => (await remote(box, box.down)).status === 401 || undefined);
    await eventually(() => !hub.db.db.prepare("SELECT 1 FROM relay_mailboxes WHERE device=?").get(removed.device) || undefined);
  } finally {
    await hub.dispose();
    if (online) relay.stop(true);
  }
});
