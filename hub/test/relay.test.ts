import { expect, test } from "bun:test";
import { randomBytes } from "node:crypto";
import { existsSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { startRelay } from "../../relay/src/bun.ts";
import { defaultLimits } from "../../relay/src/core.ts";
import { HubDB } from "../src/db.ts";
import { DistillStore } from "../src/distill/store.ts";
import { localDateString } from "../src/distill/requests.ts";
import { projectionHead, pruneProjection, resetProjection, relayProjectionBytes } from "../src/devices/projection-store.ts";
import type { ProjectionPage } from "../src/devices/projection.ts";
import { dayMs, type RelayConfig } from "../src/devices/relay-store.ts";
import { startServer } from "../src/server.ts";
import { suite } from "../src/devices/envelope.ts";
import { decodePairing, DeviceClient, type ResponseEnvelope } from "../src/devices/client.ts";
import { fixture, setup, removeProjectionSchema } from "./helpers.ts";

const path = "/v1/settings/relay";
const id = () => randomBytes(16).toString("base64url");

async function hubFixture(restart?: () => void, ports?: { local: number; lan: number }) {
  const ctx = setup();
  const probe = Bun.serve({ hostname: "0.0.0.0", port: ports?.lan ?? 0, fetch: () => new Response() });
  const lanPort = probe.port!;
  await probe.stop(true);
  writeFileSync(join(ctx.dir, "hub.json"), JSON.stringify({ lan_port: lanPort }));
  let now = Date.now();
  let key: string | null = null;
  const credentials = new Map<string, string>();
  const options = {
    db: ctx.db, token: ctx.config.token, agentToken: "fixture-agent-token", port: ports?.local ?? 0, settings: { dataDir: ctx.dir, restart, probePort: async () => {} },
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
  async function invite(viewer = false) {
    const response = await admin("/v1/settings/devices/pairing", "POST", viewer ? { viewer } : undefined);
    expect(response.status).toBe(200);
    const pairing = decodePairing((await response.json() as { uri: string }).uri);
    return { pairing: pairing as typeof pairing & { relay?: RelayConfig }, phone: await DeviceClient.fromInvite(pairing, lan) };
  }
  async function pair(viewer = false, loopback = false) {
    const { pairing, phone: lanDevice } = await invite(viewer);
    const phone = loopback ? await DeviceClient.fromInvite(pairing, server.url.origin) : lanDevice;
    if (viewer) {
      const result = await phone.send<{ device_id: string }>("pair", { ...await phone.pairingBody(pairing), platform: "mac" });
      expect(result.status).toBe(200);
      phone.device = result.body.device_id;
    } else expect((await phone.pair(pairing)).status).toBe(200);
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

async function eventually<T>(get: () => Promise<T | undefined> | T | undefined, timeout = 3_000) {
  const deadline = Date.now() + timeout;
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
    expect((await hub.admin(path + "/test", "POST", { url: hub.url().origin })).status).toBe(400);
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

test("配对回执跨重启和直连/信箱可恢复，两个临时信箱到期关闭", async () => {
  const hub = await hubFixture(undefined, { local: 48617, lan: 48616 }), relay = relayFixture({ port: 48618 });
  try {
    await configure(hub, relay.url);
    const { pairing, phone } = await hub.invite();
    const temporary = pairing.relay!;
    expect(temporary.url).toBe(relay.url);
    expect(typeof temporary.token).toBe("string");
    expect((await remote(temporary, temporary.up)).status).toBe(403);
    const body = await phone.pairingBody(pairing);
    const nonce = await submit(temporary, phone, "pair", body, hub.time());
    const paired = await reply<{ device_id: string; relay: RelayConfig }>(phone, temporary, nonce);
    expect(paired).toMatchObject({ status: 200, body: { relay: { url: relay.url } } });
    phone.device = paired.body.device_id;
    expect(paired.body.relay.up).not.toBe(temporary.up);
    expect(await deviceConfig(phone)).toEqual(paired.body.relay);
    const relayOp = await submit(paired.body.relay, phone, "relay", {}, hub.time());
    expect(await reply(phone, paired.body.relay, relayOp)).toEqual({ status: 200, body: { relay: paired.body.relay, role: "collect" } });
    expect((await remote(temporary, temporary.down, "DELETE", nonce)).status).toBe(200);
    await hub.stop();
    hub.start();
    const retryDirect = new DeviceClient(phone.hub, phone.keys, hub.lan);
    expect(await retryDirect.send("pair", body, { nonce })).toEqual(paired);

    const inviteResponse = await hub.admin("/v1/settings/devices/pairing", "POST", { role: "admin" });
    const directInvite = decodePairing((await inviteResponse.json() as { uri: string }).uri);
    const direct = await DeviceClient.fromInvite(directInvite, hub.lan);
    const directBody = { ...await direct.pairingBody(directInvite), name: "合成管理 Mac", platform: "mac" };
    type AdminReceipt = { device_id: string; hub_id: string; relay: RelayConfig };
    const directReply = await direct.send<AdminReceipt>("pair", directBody);
    expect(directReply).toMatchObject({ status: 200, body: { role: "admin", relay: { url: relay.url } } });
    const retryBox = directInvite.relay!;
    const retryNonce = await submit(retryBox, direct, "pair", directBody, hub.time());
    expect(await reply(direct, retryBox, retryNonce)).toEqual(directReply);
    expect(hub.db.db.prepare("SELECT id FROM devices").all()).toHaveLength(2);

    direct.device = directReply.body.device_id;
    const agent = await suite.kem.generateKeyPair();
    const agent_pk = Buffer.from(await suite.kem.serializePublicKey(agent.publicKey)).toString("base64url");
    const agentBox = directReply.body.relay;
    const enrollment = await reply<Record<string, unknown>>(direct, agentBox, await submit(agentBox, direct, "agent.enroll", { agent_pk }, hub.time()));
    expect(enrollment).toEqual({ status: 200, body: { device_id: expect.stringMatching(/^agent-/), hub_id: directInvite.hub_id } });
    expect(await direct.send("agent.enroll", { agent_pk })).toEqual(enrollment);
    expect(hub.db.db.prepare("SELECT id FROM devices WHERE role='agent'").all()).toHaveLength(1);
    // A1 审查回归：低阶公钥不能登记；换信箱时只直连的 AI 身份不分配信箱。
    expect((await direct.send("agent.enroll", { agent_pk: Buffer.alloc(32).toString("base64url") })).status).toBe(400);
    const other = relayFixture();
    try {
      await configure(hub, other.url);
      expect(hub.db.db.prepare("SELECT b.device FROM relay_mailboxes b JOIN devices d ON d.id=b.device WHERE d.role='agent'").all()).toEqual([]);
      expect(hub.db.db.prepare("SELECT b.device FROM relay_mailboxes b WHERE b.device=?").all(direct.device)).not.toEqual([]);
    } finally { await configure(hub, relay.url); other.stop(true); }

    hub.advance(10 * 60_000);
    await hub.stop();
    hub.start();
    for (const box of [temporary, retryBox]) {
      await eventually(async () => (await remote(box, box.down)).status === 401 || undefined);
    }
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

test("能连上但不是信箱的地址提示“不是 Tacit 信箱”，不当成连不上", async () => {
  const hub = await hubFixture();
  const site = Bun.serve({ hostname: "127.0.0.1", port: 0, fetch: () => new Response("not found", { status: 404 }) });
  try {
    const url = `http://127.0.0.1:${site.port}`;
    for (const [route, method, body] of [[path + "/test", "POST", { url }], [path, "PUT", { mode: "custom", url }]] as const) {
      const response = await hub.admin(route, method, body);
      expect(response.status).toBe(400);
      expect(await response.json()).toEqual({ error: "地址不是 Tacit 信箱" });
    }
  } finally { await hub.dispose(); await site.stop(true); }
});

test("回执还没投出去时删掉记录，回执随删除清掉，原请求不再执行", async () => {
  const hub = await hubFixture(), limits = { ...defaultLimits }, relay = relayFixture({ limits });
  try {
    const phone = await hub.pair();
    await configure(hub, relay.url);
    const box = await deviceConfig(phone);
    await hub.stop();
    const record = fixture({ device: phone.device!, source: "android.audio", source_ref: "audio:fixture-erase" });
    const nonce = await submit(box, phone, "ingest", { records: [record] }, hub.time());
    limits.space_bytes = 1;
    hub.start();
    await eventually(() => hub.db.get(record.id) ?? undefined);
    await hub.stop();
    expect(hub.db.db.prepare("SELECT COUNT(*) AS n FROM relay_receipts").get()).toEqual({ n: 1 });
    expect(hub.db.deleteMany([record.id])).toBe(1);
    expect(hub.db.db.prepare("SELECT COUNT(*) AS n FROM relay_receipts").get()).toEqual({ n: 0 });
    limits.space_bytes = defaultLimits.space_bytes;
    hub.start();
    await eventually(async () => (await list(box, box.up, hub.credentials.get(box.space))).length === 0 || undefined);
    expect(await list(box)).toEqual([]);
    expect(hub.db.get(record.id)).toBeFalsy();
    expect(nonce).toBeTruthy();
  } finally { await hub.dispose(); relay.stop(true); }
});

test("v13 加密数据库升级到 v16，保留配对记录并清理迁移备份", () => {
  const ctx = setup();
  try {
    removeProjectionSchema(ctx.db.db);
    ctx.db.db.exec(`
      DROP TABLE device_nonces; DROP TABLE relay_mailboxes; DROP TABLE relay_spaces; DROP TABLE relay_receipts;
      INSERT INTO devices VALUES ('android-abcd2345','测试手机','android',X'00','2026-11-23','2026-11-23');
      PRAGMA user_version=13;
    `);
    ctx.db.close();
    const db = new HubDB(ctx.file, ctx.config.dbKey);
    try {
      expect(db.db.pragma("user_version", { simple: true })).toBe(19);
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

function projectionItem(record: ReturnType<typeof fixture>, project_id: string | null = null) {
  return {
    id: record.id, record_ids: [record.id], project_id,
    title: record.title, description: record.body, t_start: record.t_start, t_end: record.t_start,
    active_seconds: 60, sources: [record.source], apps: [],
    evidence: [{ id: record.id, at: record.t_start, source: record.source, title: record.title }],
  };
}

function projectionDay(store: DistillStore, date: string, records: ReturnType<typeof fixture>[]) {
  store.upsertDay({ date, brief: "苗圃安排", needs_regen: 0, updated_at: new Date().toISOString(), detail: {
    summary: "苗圃安排", cutoff: records.at(-1)?.t_start, items: records.map(record => projectionItem(record, "garden")),
    record_ids: records.map(r => r.id), omitted_record_ids: [],
  } });
}

function projectionThread(store: DistillStore, id: string, rows: ReturnType<typeof fixture>[], title = "整理苗圃") {
  store.upsertThread({ id, project_id: "garden", status: "active", domain: "work", title, brief: "已经检查苗圃",
    detail: { goal: "规划新苗床", progress: "核对完图纸", internal: "内部字段不传" },
    last_ms: Date.now() - 60_000, needs_regen: 0, updated_at: new Date().toISOString() });
  const time = Date.parse(rows[0]!.t_start);
  const frame = `frame-${id}`;
  store.createFrame({ id: frame, key: frame, t_start_ms: time, t_end_ms: time, record_ids: rows.map(r => r.id),
    chars: 10, private: Number(rows.some(r => r.sensitivity === "private")), status: "new" });
  store.assign(frame, id, "rule", 1);
}

test("查看邀请限定 Mac；Android 和伪装请求无权读取，WebSocket 只发鉴权后的删除序号", async () => {
  const hub = await hubFixture();
  let socket: WebSocket | undefined;
  try {
    const android = await hub.pair();
    const unauthorized = await hub.invite();
    const attempted = await unauthorized.phone.send("pair", { ...await unauthorized.phone.pairingBody(unauthorized.pairing), platform: "mac", viewer: true });
    expect(attempted.status).toBe(200);
    expect(attempted.body.role).toBe("collect");
    const viewer = await hub.pair(true, true);
    expect(viewer.device).toMatch(/^mac-/);
    expect((await android.send("projection.pull", { cursor: 0, device: viewer.device })).status).toBe(403);
    expect((await android.send("records.list", {})).status).toBe(403);
    expect((await viewer.send("delete", { ids: [fixture().id] })).status).toBe(200);
    const record = fixture({ title: "测试折叠温室" });
    hub.db.ingest([record]);

    const envelope = await viewer.envelope({ op: "events.subscribe", body: {}, ts: hub.time(), nonce: id() });
    const events: { seq: number; epoch: number; urgent: boolean }[] = [];
    const url = new URL("/v1/device/events", hub.url());
    url.protocol = "ws:";
    socket = new WebSocket(url);
    socket.onopen = () => socket?.send(JSON.stringify(envelope));
    socket.onmessage = event => events.push(JSON.parse(String(event.data)));
    await eventually(() => events[0]);
    const before = projectionHead(hub.db.db).seq;
    const worker = new HubDB(hub.file, hub.config.dbKey);
    try { expect(worker.delete(record.id)).toBe(true); } finally { worker.close(); }
    const event = await eventually(() => events.find(event => event.urgent && event.seq > before));
    expect(Object.keys(event).sort()).toEqual(["epoch", "seq", "urgent"]);
    const page = await viewer.send<ProjectionPage>("projection.pull", { cursor: before, epoch: event.epoch });
    expect(page.body.changes).toContainEqual(expect.objectContaining({ kind: "record_gone", id: record.id, op: "delete" }));
  } finally { socket?.close(); await hub.dispose(); }
});

test("投影与按需读取撤掉私密内容，混合事项仅保留有公开依据的事实", async () => {
  const hub = await hubFixture();
  try {
    const viewer = await hub.pair(true);
    const now = Date.parse(hub.time()), date = localDateString(now - 2 * dayMs);
    const t_start = date + "T12:00:00Z";
    const pub = fixture({ t_start, source: "manual.note", title: "公开苗床", body: "公开苗床已贴标签" });
    const mixed = fixture({ t_start, source: "manual.note", title: "公开外侧苗床", body: "公开外侧苗床已清理" });
    const hidden = fixture({ t_start, title: "私密水池名称", body: "私密水池正文", sensitivity: "private" });
    const entirely = fixture({ t_start, title: "私密花盆名称", body: "私密花盆正文", sensitivity: "private" });
    hub.db.ingest([pub, mixed, hidden, entirely]);
    const store = new DistillStore(hub.db);
    store.upsertProject({ id: "garden", name: "试验苗圃", confirmed: 1, keys: { repos: [], hosts: [], chats: [] }, brief: "混合的项目概况" });
    projectionThread(store, "public", [pub]);
    projectionThread(store, "mixed", [mixed, hidden], "私密水池派生标题");
    projectionThread(store, "hidden", [entirely], "私密花盆派生标题");
    const factBase = { kind: "open" as const, origin: "user" as const, thread_id: "mixed", project_id: "garden", valid_at: t_start, created_at: t_start };
    store.writeFact({ ...factBase, id: "mixed-private", evidence: [hidden.id, mixed.id], text: "私密水池派生事实" });
    store.writeFact({ ...factBase, id: "mixed-public", evidence: [mixed.id], text: "外侧苗床待补标签" });
    projectionDay(store, date, [pub, hidden]);
    const first = (await viewer.send<ProjectionPage>("projection.pull", { cursor: 0 })).body;
    const firstWire = JSON.stringify(first);
    for (const secret of ["私密", hidden.id, entirely.id, "混合的项目概况", "内部字段不传"]) expect(firstWire).not.toContain(secret);
    expect(firstWire).toContain("外侧苗床待补标签");
    expect(firstWire).toContain("整理苗圃");
    expect(first.changes.find(change => change.kind === "thread" && change.id === "mixed")).toMatchObject({ data: { brief: null, detail: null } });
    expect(first.changes.find(change => change.kind === "thread" && change.id === "hidden")).toMatchObject({ op: "delete" });

    const correction = fixture({ source: "manual.correction", corrects: pub.id, sensitivity: "private", title: "新私密标题", body: "新私密修正文", t_start: hub.time() });
    expect(hub.db.ingest([correction]).accepted).toBe(1);
    const next = (await viewer.send<ProjectionPage>("projection.pull", { cursor: first.cursor, epoch: first.epoch })).body;
    expect(next.changes).toContainEqual(expect.objectContaining({ kind: "record_gone", id: pub.id, op: "delete" }));
    expect(next.changes).toContainEqual(expect.objectContaining({ kind: "thread", id: "public", op: "delete" }));
    expect(JSON.stringify(next)).not.toContain("公开苗床已贴标签");
    expect(JSON.stringify(next)).not.toContain("新私密");
    expect((await viewer.send("records.get", { ids: [pub.id], include_private: true })).status).toBe(403);
    const { body: reads } = await viewer.send("records.get", { ids: [pub.id, hidden.id, mixed.id], include_corrections: true });
    expect(reads.records).toMatchObject([{ id: pub.id, redacted_private: true }, { id: hidden.id, redacted_private: true }, { id: mixed.id, body: mixed.body }]);
    expect((await viewer.send("records.list", { q: "私密", body: true })).body.records).toEqual([]);
    expect((await viewer.send("records.list", { q: "公开苗床", body: true })).body.records).toEqual([]);
    expect((await viewer.send("timeline.locate", { record_id: pub.id })).status).toBe(404);
    const query = await viewer.send("timeline.query", { q: "私密" });
    expect(query.body.days).toEqual([]);
    const segments = await viewer.send("history.segments", { from: date + "T00:00:00Z", to: date + "T23:59:59Z" });
    expect(segments.status).toBe(200);
    expect(JSON.stringify(segments)).not.toContain(hidden.id);
    expect(JSON.stringify(segments)).not.toContain(pub.id);
    expect(JSON.stringify(segments)).toContain(mixed.id);
  } finally { await hub.dispose(); }
});

// 回归（C2 联调发现）：没有公开活跃事项时“此刻”整条被撤下，查看端看不到“有新活动待整理 / 整理失败”；
// 当天下推缺未入时间线的记录 ID；本机 admin 定位私密记录不能按需读取。
test("此刻在无活跃事项时仍下推待整理状态，当天带公开的未入时间线 ID，admin 可按需定位私密记录", async () => {
  const hub = await hubFixture();
  try {
    const viewer = await hub.pair(true);
    const now = Date.parse(hub.time()), date = localDateString(now);
    const pub = fixture({ t_start: new Date(now - 5 * 60_000).toISOString(), source: "manual.note", title: "苗圃浇水", body: "苗圃浇水完成" });
    const hidden = fixture({ t_start: new Date(now - 4 * 60_000).toISOString(), title: "私密水池", body: "私密水池正文", sensitivity: "private" });
    hub.db.ingest([pub, hidden]);
    const store = new DistillStore(hub.db);
    store.upsertDay({ date, brief: null, needs_regen: 1, updated_at: null, detail: {
      summary: null, cutoff: pub.t_start, items: [], record_ids: [pub.id, hidden.id], omitted_record_ids: [pub.id, hidden.id] } });
    store.setState("now", null);
    const page = (await viewer.send<ProjectionPage>("projection.pull", { cursor: 0 })).body;
    const nowChange = page.changes.find(change => change.kind === "now");
    expect(nowChange).toMatchObject({ op: "upsert", data: { brief: "有新活动待整理。", detail: { threads: [] } } });
    const day = page.changes.find(change => change.kind === "day" && change.id === date) as { data: { detail: { omitted_record_ids: string[]; omitted_count: number } } };
    expect(day.data.detail.omitted_record_ids).toEqual([pub.id]);
    expect(day.data.detail.omitted_count).toBe(1);
    expect(JSON.stringify(page)).not.toContain(hidden.id);
    // 查看级不能按需读私密；admin 可以（参数被接受，不再 400）。
    expect((await viewer.send("timeline.locate", { record_id: hidden.id, include_private: true })).status).toBe(403);
    hub.db.db.prepare("UPDATE devices SET role='admin' WHERE id=?").run(viewer.device);
    expect((await viewer.send("timeline.locate", { record_id: hidden.id })).status).toBe(404);
    expect((await viewer.send("timeline.locate", { record_id: hidden.id, include_private: true })).status).toBe(200);
  } finally { await hub.dispose(); }
});

test("游标分页跨越冷启动窗口，确认单调且 epoch 重置后全量重拉", async () => {
  const hub = await hubFixture();
  try {
    const viewer = await hub.pair(true);
    const store = new DistillStore(hub.db);
    const now = Date.parse(hub.time());
    const days = [5, 1, 8, 2, 20].map(age => localDateString(now - age * dayMs));
    for (const date of days) store.upsertDay({ date, needs_regen: 0 });
    let page = (await viewer.send<ProjectionPage>("projection.pull", { cursor: 0, limit: 1, window_days: 4 })).body;
    const seen = new Set<string>();
    const initialEpoch = page.epoch;
    for (let count = 0; ; count++) {
      expect(count).toBeLessThan(20);
      for (const change of page.changes) if (change.kind === "day") seen.add(change.id);
      if (!page.more) break;
      const previous = page.cursor;
      page = (await viewer.send<ProjectionPage>("projection.pull", { cursor: previous, epoch: initialEpoch, limit: 1 })).body;
      expect(page.cursor).toBeGreaterThan(previous);
    }
    expect(seen.has(days[1]!)).toBe(true);
    expect(seen.has(days[3]!)).toBe(true);
    for (const index of [0, 2, 4]) expect(seen.has(days[index]!)).toBe(false);
    expect((await viewer.send("projection.ack", { cursor: page.cursor, epoch: initialEpoch })).status).toBe(200);
    expect((await viewer.send("projection.ack", { cursor: page.cursor - 1, epoch: initialEpoch })).status).toBe(200);
    expect(hub.db.db.prepare("SELECT projection_cursor FROM devices WHERE id=?").get(viewer.device)).toEqual({ projection_cursor: page.cursor });
    const gone = fixture({ t_start: hub.time() });
    hub.db.ingest([gone]);
    expect(hub.db.delete(gone.id)).toBe(true);
    const latestSeq = projectionHead(hub.db.db).seq;
    expect((await viewer.send("projection.ack", { cursor: latestSeq, epoch: initialEpoch })).status).toBe(200);
    pruneProjection(hub.db.db, now + 31 * dayMs);
    expect(projectionHead(hub.db.db).floor).toBeGreaterThan(page.cursor);
    expect(hub.db.db.prepare("SELECT 1 FROM projection_changes WHERE entity_id=?").get(gone.id)).toBeUndefined();
    const reset = (await viewer.send<ProjectionPage>("projection.pull", { cursor: page.cursor, epoch: initialEpoch })).body;
    expect(reset).toMatchObject({ reset: true, cursor: 0, more: true, epoch: initialEpoch + 1, changes: [] });
    expect((await viewer.send("projection.ack", { cursor: page.cursor, epoch: initialEpoch })).status).toBe(409);
    const latest = (await viewer.send<ProjectionPage>("projection.pull", { cursor: 0, epoch: reset.epoch })).body;
    expect(latest.reset).toBe(false);
    expect(latest.changes).toContainEqual(expect.objectContaining({ kind: "day", id: days[4] }));
  } finally { await hub.dispose(); }
});

test("长原文含引号、换行和非 BMP 字符时按码点续读", async () => {
  const hub = await hubFixture();
  try {
    const viewer = await hub.pair(true);
    const text = '𠮷行"\n'.repeat(23_000);
    const record = fixture({ source: "manual.note", body: text });
    expect(hub.db.ingest([record]).accepted).toBe(1);
    const correction = fixture({ source: "manual.correction", corrects: record.id, body: "清点完成" });
    expect(hub.db.ingest([correction]).accepted).toBe(1);
    let cursor: string | null = null, restored = "", corrected = "";
    const count = Array.from(text).length;
    for (let pages = 0; ; pages++) {
      expect(pages).toBeLessThan(20);
      const result: { status: number; body: {
        records: { body?: string; body_range?: { start: number; end: number; total: number }; corrections?: { body: string }[] }[];
        next_cursor: string | null;
      } } = await viewer.send("records.get", { ids: [record.id], include_corrections: true, ...(cursor ? { cursor } : {}) });
      expect(result.status).toBe(200);
      const page = result.body;
      for (const row of page.records) {
        expect(JSON.stringify(row).length).toBeLessThanOrEqual(38_000);
        if (row.corrections) corrected += row.corrections[0]!.body;
        else {
          expect(row.body_range).toEqual({ start: Array.from(restored).length, end: Array.from(restored + row.body).length, total: count });
          restored += row.body;
        }
      }
      cursor = page.next_cursor;
      if (!cursor) break;
    }
    expect(restored).toEqual(text);
    expect(corrected).toBe(correction.body);
  } finally { await hub.dispose(); }
});

test("真实信箱分页和主动推送：先撤回旧下行正文，再放无正文的删除通知", async () => {
  const relay = relayFixture(), hub = await hubFixture();
  try {
    await configure(hub, relay.url);
    const { pairing, phone: viewer } = await hub.invite(true);
    const inviteBox = pairing.relay!;
    const pairId = await submit(inviteBox, viewer, "pair", { ...await viewer.pairingBody(pairing), platform: "mac" }, hub.time());
    const paired = await reply<{ device_id: string; relay: RelayConfig }>(viewer, inviteBox, pairId);
    expect(paired.status).toBe(200);
    viewer.device = paired.body.device_id;
    const config = paired.body.relay;
    const store = new DistillStore(hub.db);
    const baseline = (await viewer.send<ProjectionPage>("projection.pull", { cursor: 0 })).body;
    expect((await viewer.send("projection.ack", { cursor: baseline.cursor, epoch: baseline.epoch })).status).toBe(200);
    hub.advance(5 * 60_000);
    const date = localDateString(Date.parse(hub.time()) - 2 * dayMs);
    const record = fixture({ source: "manual.note", title: "等待撤回的苗床", body: "清点种植架完成。", t_start: date + "T08:00:00Z" });
    hub.db.ingest([record]);
    projectionDay(store, date, [record]);
    const pushed = async (kind: string, timeout?: number) => await eventually(async () => {
      for (const message of await list(config)) {
        const response = await remote(config, config.down, "GET", message.id);
        if (response.status !== 200) continue;
        const value = await viewer.openPayload<Record<string, unknown>>(await response.json() as ResponseEnvelope, message.id);
        if (value.kind === kind) return { message, value };
      }
    }, timeout);
    const delta = await pushed("projection.delta");
    expect(JSON.stringify(delta.value)).toContain(record.body);
    expect(await list(config)).toHaveLength(1);

    const readId = await submit(config, viewer, "records.get", { ids: [record.id] }, hub.time());
    expect((await reply<{ records: { body: string }[] }>(viewer, config, readId)).body.records[0]?.body).toBe(record.body);
    expect(hub.db.delete(record.id)).toBe(true);
    const withdrawal = await pushed("projection.invalidate");
    expect(withdrawal.value.items).toContainEqual({ kind: "record_gone", id: record.id });
    expect(JSON.stringify(withdrawal.value)).not.toContain(record.body);
    expect((await remote(config, config.down, "GET", delta.message.id)).status).toBe(404);
    expect((await remote(config, config.down, "GET", readId)).status).toBe(404);
    expect(await list(config)).toEqual([withdrawal.message]);

    store.upsertProject({ id: "garden", name: "试验苗圃", confirmed: 1, keys: { repos: [], hosts: [], chats: [] } });
    const publicRows = Array.from({ length: 12 }, (_, index) => fixture({ source: "manual.note", t_start: date + "T10:00:00Z", title: `苗床编号 ${index}` }));
    hub.db.ingest(publicRows);
    const writeMany = hub.db.db.transaction(() => {
      for (const [i, row] of publicRows.entries()) {
        projectionThread(store, `large-${i}`, [row]);
        store.upsertThread({ ...store.thread(`large-${i}`)!, detail: { goal: "测试展示".repeat(16_000) } });
      }
    });
    writeMany();
    const pulledId = await submit(config, viewer, "projection.pull", { cursor: baseline.cursor, epoch: baseline.epoch, limit: 200 }, hub.time());
    const page = await reply<ProjectionPage>(viewer, config, pulledId);
    expect(page.status).toBe(200);
    expect(Buffer.byteLength(JSON.stringify(page))).toBeLessThanOrEqual(relayProjectionBytes);
    expect(page.body.more).toBe(true);
    const secondId = await submit(config, viewer, "projection.pull", { cursor: page.body.cursor, epoch: page.body.epoch, limit: 200 }, hub.time());
    const second = await reply<ProjectionPage>(viewer, config, secondId);
    expect(second.body.cursor).toBeGreaterThan(page.body.cursor);
    expect(Buffer.byteLength(JSON.stringify(second))).toBeLessThanOrEqual(relayProjectionBytes);

    const longRecords = Array.from({ length: 20 }, () => fixture({ source: "manual.note", body: "𠮷".repeat(17_000) }));
    expect(hub.db.ingest(longRecords).accepted).toBe(20);
    const ids = longRecords.map(record => record.id);
    const rawId = await submit(config, viewer, "records.get", { ids }, hub.time());
    const raw = await reply<{ next_cursor: string; records: { id: string; body_range: { start: number; end: number; total: number } }[] }>(viewer, config, rawId);
    expect(raw.status).toBe(200);
    expect(raw.body.next_cursor).toBeTruthy();
    expect(Buffer.byteLength(JSON.stringify(raw))).toBeLessThanOrEqual(relayProjectionBytes);
    const restId = await submit(config, viewer, "records.get", { ids, cursor: raw.body.next_cursor }, hub.time());
    const rest = await reply<{ next_cursor: string; records: { id: string; body_range: { start: number } }[] }>(viewer, config, restId);
    expect(rest.status).toBe(200);
    const boundary = raw.body.records.at(-1)!;
    if (boundary.body_range.end < boundary.body_range.total) {
      expect(rest.body.records[0]?.id).toBe(boundary.id);
      expect(rest.body.records[0]?.body_range.start).toBe(boundary.body_range.end);
    } else expect(rest.body.records[0]?.id).toBe(ids[raw.body.records.length]);

    // A restored backup may have no local metadata for a still-pending older reply.
    hub.db.db.prepare("DELETE FROM relay_projection_replies WHERE id=?").run(restId);
    resetProjection(hub.db.db, Date.now());
    const reset = await pushed("projection.reset");
    expect(reset.value.epoch).toBeGreaterThan(baseline.epoch);
    expect((await remote(config, config.down, "GET", restId)).status).toBe(404);

    const restart = (await viewer.send<ProjectionPage>("projection.pull", { cursor: 0 }, { ts: hub.time() })).body;
    expect((await viewer.send("projection.ack", { cursor: restart.cursor, epoch: restart.epoch }, { ts: hub.time() })).status).toBe(200);
    hub.advance(5 * 60_000);
    projectionDay(store, date, [publicRows[0]!]);
    const active = await pushed("projection.delta");
    // Mark the viewer inactive and let the relay maintenance loop inspect the existing push.
    hub.db.db.prepare("UPDATE devices SET last_seen=? WHERE id=?").run(new Date(Date.parse(hub.time()) - 2 * dayMs).toISOString(), viewer.device);
    const wake = await pushed("projection.hint", 6_000);
    expect(wake.value.latest_seq).toBe(active.value.to_seq);
    expect(await list(config)).toEqual([wake.message]);
  } finally { await hub.dispose(); relay.stop(true); }
}, 12_000);

test("降权时真实信箱撤回旧投影和原文回执，只向采集设备发 reset", async () => {
  const relay = relayFixture(), hub = await hubFixture();
  try {
    expect((await hub.admin(path, "PUT", { mode: "custom", url: relay.url })).status).toBe(200);
    const viewer = await hub.pair(true);
    const { relay: box } = (await viewer.send<{ relay: RelayConfig }>("relay", {})).body;
    const record = fixture({ source: "manual.note" });
    const privateRecord = fixture({ source: "manual.note", sensitivity: "private" });
    hub.db.ingest([record, privateRecord]);
    const readId = await submit(box, viewer, "records.get", { ids: [record.id] }, hub.time());
    expect((await reply<{ records: { body: string }[] }>(viewer, box, readId)).body.records[0]?.body).toBe(record.body);
    const oldPush = await eventually(() => hub.db.db.prepare<[string], { push_msg_id: string }>(
      "SELECT push_msg_id FROM relay_mailboxes WHERE device=? AND push_msg_id IS NOT NULL").get(viewer.device!)?.push_msg_id);
    expect((await hub.admin("/v1/settings/devices/" + viewer.device + "/role", "PUT", { role: "admin" })).status).toBe(200);
    const privateRead = await viewer.send<{ records: { body: string }[] }>("records.get", { ids: [privateRecord.id], include_private: true });
    expect(privateRead.body.records[0]?.body).toBe(privateRecord.body);
    const privateId = await submit(box, viewer, "records.get", { ids: [privateRecord.id], include_private: true }, hub.time());
    expect((await reply(viewer, box, privateId)).status).toBe(403);
    // Force is local CLI only. Pair a second administrator before demoting this one.
    const invitation = await hub.admin("/v1/settings/devices/pairing", "POST", { role: "admin" });
    const pairing = decodePairing((await invitation.json() as { uri: string }).uri);
    const admin = await DeviceClient.fromInvite(pairing, hub.lan);
    expect((await admin.pair(pairing, "mac")).status).toBe(200);
    // Leave a fresh raw response in the same mailbox immediately before the demotion.
    const lastRead = await submit(box, viewer, "records.get", { ids: [record.id] }, hub.time());
    expect((await reply(viewer, box, lastRead)).status).toBe(200);
    expect((await admin.send("devices.role.update", { id: viewer.device, role: "collect" })).status).toBe(200);
    const reset = await eventually(async () => {
      for (const message of await list(box)) {
        const envelope = await remote(box, box.down, "GET", message.id);
        if (!envelope.ok) continue;
        const payload = await viewer.openPayload<{ kind?: string; epoch?: number }>(await envelope.json(), message.id);
        if (payload.kind === "projection.reset") return payload;
      }
    });
    expect(reset).toEqual({ kind: "projection.reset", epoch: expect.any(Number) });
    for (const message of [oldPush, readId, lastRead]) expect((await remote(box, box.down, "GET", message)).status).toBe(404);
    expect((await viewer.send("records.get", { ids: [record.id] })).status).toBe(403);
  } finally { await hub.dispose(); await relay.stop(); }
}, 15_000);

test("信箱查看窗口 op 走共享设置逻辑，禁私密读取，按完整明文大小限制返回", async () => {
  const limits = { ...defaultLimits }, relay = relayFixture({ limits });
  let restarted = 0;
  const hub = await hubFixture(() => { restarted++; });
  try {
    expect((await hub.admin(path, "PUT", { mode: "custom", url: relay.url })).status).toBe(200);
    const admin = await hub.pair(true);
    expect((await hub.admin("/v1/settings/devices/" + admin.device + "/role", "PUT", { role: "admin" })).status).toBe(200);
    const { relay: box } = (await admin.send<{ relay: RelayConfig }>("relay", {})).body;
    const send = async (op: string, args: object) => reply(admin, box, await submit(box, admin, op, args, hub.time()));
    expect(await send("audio.settings.put", { retention_days: 12 })).toEqual({ status: 200, body: { retention_days: 12 } });
    expect((await send("devices.list", {})).status).toBe(200);
    expect((await send("devices.pairing.create", { role: "view" })).status).toBe(200);
    expect((await send("devices.pairing.cancel", {})).status).toBe(200);
    const record = fixture({ source: "manual.note", sensitivity: "private", body: "合成私密记录只留本机" });
    expect(hub.db.ingest([record]).accepted).toBe(1);
    for (const [op, args] of [
      ["records.get", { ids: [record.id] }],
      ["records.list", {}],
      ["history.segments", { from: record.t_start, to: record.t_start }],
      ["conversations.detail", { record_id: record.id }],
    ] as const) expect((await send(op, { ...args, include_private: true })).status).toBe(403);

    const sampleID = fixture().id;
    hub.db.db.prepare("INSERT INTO voice_samples VALUES (?,?,?,?,?,?)")
      .run(sampleID, "fixture-speaker", "fixture-request", "audio/ogg", Buffer.alloc(500 * 1024, 42), hub.time());
    const direct = await admin.send<{ data_base64: string }>("audio.sample.get", { id: sampleID });
    expect(direct.status).toBe(200);
    expect(Buffer.from(direct.body.data_base64, "base64").byteLength).toBe(500 * 1024);
    expect((await send("audio.sample.get", { id: sampleID })).status).toBe(413);
    expect(JSON.stringify(hub.db.db.prepare("SELECT result FROM relay_receipts").all())).not.toContain(record.body);

    // An envelope rejected by the relay's storage limit can be retried after
    // reconnecting without running the setting twice or restarting early.
    await hub.stop();
    const nonce = await submit(box, admin, "settings.hub.put", { port: 49002 }, hub.time());
    limits.space_bytes = 1;
    hub.start();
    await eventually(() => {
      const row = hub.db.db.prepare<[string], { result: string }>("SELECT result FROM relay_receipts WHERE id=?").get(nonce);
      return row && JSON.parse(row.result).status === 200 ? true : undefined;
    });
    expect(restarted).toBe(0);
    await hub.stop();
    limits.space_bytes = defaultLimits.space_bytes;
    hub.start();
    expect(await reply(admin, box, nonce)).toEqual({ status: 200, body: { port: 49002, restarting: true } });
    await eventually(() => restarted === 1 || undefined);
  } finally {
    await hub.dispose();
    await relay.server.stop(true);
  }
}, 15_000);

test("历史导入经真实信箱在同一事务留下上行收据，换 nonce 重放与超限有确定回复", async () => {
  const limits = { ...defaultLimits };
  const hub = await hubFixture(undefined, { local: 48622, lan: 48623 }), relay = relayFixture({ port: 48624, limits });
  try {
    await configure(hub, relay.url);
    const admin = await hub.pair(true);
    expect((await hub.admin("/v1/settings/devices/" + admin.device + "/role", "PUT", { role: "admin" })).status).toBe(200);
    const { hub_id } = await (await hub.admin("/v1/settings/devices")).json() as { hub_id: string };
    const box = await deviceConfig(admin);
    const send = async <T>(op: string, args: object) => reply<T>(admin, box, await submit(box, admin, op, args, hub.time()));
    const started = await send<{ session_id: string }>("history.import.begin", { hub_id, snapshot_id: "c".repeat(64),
      identities: [{ device: "mac", kind: "mac", sources: ["mac.screen"] }] });
    expect(started.status).toBe(200);
    const record = fixture({ body: "虚构的信箱导入正文" });
    const batch = { session_id: started.body.session_id, batch_number: 1, records: [record] };
    await hub.stop();
    const nonce = await submit(box, admin, "history.import.batch", batch, hub.time());
    limits.space_bytes = 1;
    hub.start();
    const pending = await eventually(() => hub.db.db.prepare<[string], { result: string }>(
      "SELECT result FROM relay_receipts WHERE id=?").get(nonce));
    expect(hub.db.get(record.id)?.body).toBe(record.body);
    expect(JSON.parse(pending.result)).toMatchObject({
      status: 200, body: { items: [{ id: record.id, status: "added", remote_id: record.id }] },
    });
    await hub.stop();
    limits.space_bytes = defaultLimits.space_bytes;
    hub.start();
    const response = await reply(admin, box, nonce);
    expect(response).toEqual(JSON.parse(pending.result));
    expect(await send("history.import.batch", batch)).toEqual(response);
    const records = Array.from({ length: 4 }, () => fixture({ body: "g".repeat(170_000) }));
    expect(await send("history.import.batch", { ...batch, batch_number: 2, records }))
      .toEqual({ status: 413, body: { error: "batch_too_large" } });
    expect(hub.db.db.prepare("SELECT COUNT(*) AS n FROM history_import_batches").get()).toEqual({ n: 1 });
    expect(hub.db.get(record.id)?.body).toBe(record.body);
    expect(hub.db.get(records[0]!.id)).toBeNull();
  } finally { await hub.dispose(); await relay.stop(); }
}, 15_000);

// 2026-11-24 回归：信箱回 429（今天的请求次数用完）后，后台原来每 5 秒重试一次，额度一直恢复不了。
test("信箱限流后整个空间暂停，暂停期间不再发请求，到期后恢复并补发", async () => {
  const relay = relayFixture(), hub = await hubFixture();
  const realFetch = globalThis.fetch;
  const hits: string[] = [];
  let limited = false;
  globalThis.fetch = (async (input: Parameters<typeof fetch>[0], init?: RequestInit) => {
    const url = String(input instanceof Request ? input.url : input);
    if (url.startsWith(relay.url) && limited) {
      hits.push(`${init?.method ?? "GET"} ${url}`);
      return new Response("{}", { status: 429 });
    }
    return realFetch(input, init);
  }) as typeof fetch;
  try {
    await configure(hub, relay.url);
    const { pairing, phone: viewer } = await hub.invite(true);
    const inviteBox = pairing.relay!;
    const pairId = await submit(inviteBox, viewer, "pair", { ...await viewer.pairingBody(pairing), platform: "mac" }, hub.time());
    const paired = await reply<{ device_id: string; relay: RelayConfig }>(viewer, inviteBox, pairId);
    viewer.device = paired.body.device_id;
    const config = paired.body.relay;
    const baseline = (await viewer.send<ProjectionPage>("projection.pull", { cursor: 0 })).body;
    expect((await viewer.send("projection.ack", { cursor: baseline.cursor, epoch: baseline.epoch })).status).toBe(200);

    limited = true;
    // 删除是紧急变更，后台会马上尝试向手机推撤回通知。
    const doomed = fixture({ source: "manual.note", title: "要撤回的苗床", body: "撤回" });
    hub.db.ingest([doomed]);
    expect(hub.db.delete(doomed.id)).toBe(true);
    await eventually(() => hits.length > 0 || undefined);
    // 第一次 429 之后，至少两轮维护（每轮 5 秒）都不再碰信箱。
    await Bun.sleep(11_000);
    expect(hits).toHaveLength(1);

    limited = false;
    hub.advance(61_000);
    const pushed = await eventually(async () => {
      for (const message of await list(config)) {
        const response = await remote(config, config.down, "GET", message.id);
        if (response.status !== 200) continue;
        const value = await viewer.openPayload<Record<string, unknown>>(await response.json() as ResponseEnvelope, message.id);
        if (value.kind === "projection.invalidate") return value;
      }
    }, 8_000);
    expect(pushed.items).toContainEqual({ kind: "record_gone", id: doomed.id });

    // 状态里记着今天这台后台发了多少请求、按用途分、什么时候被限流；暂停期间被拦下的不算。
    type Usage = { day: string; requests: number; by_kind: Record<string, number>; limited_at: string | null; requests_before_limit: number | null };
    const usage = await eventually(async () => {
      const value = (await (await hub.admin(path)).json() as { usage: Usage | null }).usage;
      return value && value.by_kind.push! >= 2 ? value : undefined;
    });
    expect(usage.day).toBe(new Date(Date.parse(hub.time())).toISOString().slice(0, 10));
    expect(usage.limited_at).not.toBeNull();
    expect(usage.requests_before_limit).toBeGreaterThan(0);
    expect(usage.requests).toBe(Object.values(usage.by_kind).reduce((sum, n) => sum + n, 0));
    expect(usage.requests).toBeGreaterThan(usage.requests_before_limit!);
  } finally { globalThis.fetch = realFetch; await hub.dispose(); relay.stop(true); }
}, 30_000);
