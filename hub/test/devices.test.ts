import { expect, test } from "bun:test";
import { randomBytes } from "node:crypto";
import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { HubDB } from "../src/db.ts";
import { updateGeneral } from "../src/general-settings.ts";
import { conversationsIn, saveSummary, selfSummarizingDevices, storedSummary } from "../src/conversations.ts";
import { DistillStore } from "../src/distill/store.ts";
import { conversationStep } from "../src/distill/run.ts";
import { identityFromRaw, openRequest, readEnvelope, suite } from "../src/devices/envelope.ts";
import { startServer } from "../src/server.ts";
import { ulid, validateRecord } from "../../packages/record/index.ts";
import vectors from "../../schema/fixtures/device-envelope.json";
import { operationAccess, type DeviceRole, type PairingRole } from "../src/devices/permissions.ts";
import { auditSecurity, pruneSecurityAudit } from "../src/security-audit.ts";
import { decodePairing, DeviceClient, type ResponseEnvelope } from "../src/devices/client.ts";
import { deviceFixture } from "./generate-device-fixture.ts";
import { fixture, setup, removeDeviceRoleSchema, removeProjectionSchema } from "./helpers.ts";

import { readHub, sessionContext } from "../src/agent-cli/client.ts";
import { ContextCache } from "../src/agent-cli/context-cache.ts";
import { deviceAccount, ensureAgentIdentity, fileAgentSecrets } from "../src/agent-cli/identity.ts";

const minute = 60_000;

async function runningHub(beforeModelKeySet?: () => Promise<void>, ports?: { local: number; lan: number }) {
  const modelKeys = new Map<string, string>();
  const ctx = setup();
  const probe = Bun.serve({ hostname: "0.0.0.0", port: ports?.lan ?? 0, fetch: () => new Response() });
  const lanPort = probe.port!;
  await probe.stop(true);
  writeFileSync(join(ctx.dir, "hub.json"), JSON.stringify({ lan_port: lanPort }));
  let now = Date.now(), key: string | null = null, writes = 0;
  const options = {
    db: ctx.db, token: ctx.config.token, agentToken: ctx.config.agentToken, port: ports?.local ?? 0, settings: { dataDir: ctx.dir, env: {}, keychain: {
      async has(provider: string) { return modelKeys.has(provider); },
      async set(provider: string, key: string) { await beforeModelKeySet?.(); modelKeys.set(provider, key); },
      async remove(provider: string) { return modelKeys.delete(provider); },
    }, probePort: async () => {}, llm: { readKey: (provider: string) => modelKeys.get(provider) ?? "" } },
    deviceDeps: {
      now: () => now, addresses: () => ["192.0.2.2"], name: "测试中枢",
      keys: { read: () => key, write: (value: string) => { key = value; writes++; } },
    },
  };
  let server = startServer(options);
  const lan = `http://127.0.0.1:${lanPort}`;
  const admin = (path: string, method = "GET", body?: object) =>
    fetch(new URL(path, server.url), { method, headers: { Authorization: `Bearer ${ctx.config.token}`, "Content-Type": "application/json" },
      body: body === undefined ? undefined : JSON.stringify(body) });
  const settings = (suffix = "", method = "GET", body?: object) => admin("/v1/settings/devices" + suffix, method, body);
  async function invite(role?: PairingRole) {
    const res = await settings("/pairing", "POST", role && { role });
    expect(res.status).toBe(200);
    const { uri, expires_at } = await res.json() as { uri: string; expires_at: string };
    const pairing = decodePairing(uri);
    expect(pairing.expires_at).toBe(expires_at);
    return pairing;
  }
  async function pair(role?: PairingRole, platform = role === undefined ? "android" : "mac") {
    const invitation = await invite(role), client = await DeviceClient.fromInvite(invitation, lan);
    expect((await client.pair(invitation, platform)).status).toBe(200);
    return client;
  }
  return {
    ...ctx, lan, lanPort, admin, settings, invite, pair,
    get origin() { return server.url.origin; },
    time: () => now,
    advance(ms: number) { now += ms; },
    get writes() { return writes; },
    loseKey() { key = null; },
    async restart() { await server.stop(true); server = startServer(options); },
    async dispose() { await server.stop(true); ctx.cleanup(); },
  };
}

test("LAN 仅在邀请或设备存在时监听，hello 返回身份，本机管理接口保持隔离", async () => {
  const hub = await runningHub();
  try {
    expect(await (await hub.settings()).json()).toMatchObject({
      hub_id: null, lan: { open: false, port: hub.lanPort, addrs: [`192.0.2.2:${hub.lanPort}`] }, pairing: null, devices: [],
    });
    await expect(fetch(hub.lan + "/v1/device/hello")).rejects.toThrow();
    expect(hub.writes).toBe(0);

    const invite = await hub.invite();
    expect(hub.writes).toBe(1);
    expect(invite.name).toBe("测试中枢");
    expect(await (await hub.admin("/v1/settings/hub")).json()).toMatchObject({ lan: true });
    expect(await (await fetch(hub.lan + "/v1/device/hello")).json()).toEqual({ hub_id: invite.hub_id, v: 1 });
    for (const path of ["/", "/v1/settings/devices", "/v1/health", "/v1/agent/search", "/v1/device"]) {
      expect((await fetch(hub.lan + path)).status).toBe(404);
    }
    expect(await (await hub.admin("/v1/device/hello")).json()).toEqual({ hub_id: invite.hub_id, v: 1 });
    // 采集端靠这个 hub_id 登记 Bonjour，邀请用完或采集端重启后也要能拿到。
    expect(await (await hub.settings()).json()).toMatchObject({ hub_id: invite.hub_id, pairing: { expires_at: invite.expires_at } });
    expect((await hub.settings("/pairing", "DELETE")).status).toBe(200);
    expect(await (await hub.admin("/v1/settings/hub")).json()).toMatchObject({ lan: false });
    await expect(fetch(hub.lan + "/v1/device/hello")).rejects.toThrow();
  } finally { await hub.dispose(); }
});

test("最后一个邀请过期后关闭监听，过期、替换、作废和已用邀请码均被拒", async () => {
  const hub = await runningHub();
  try {
    await hub.invite();
    hub.advance(10 * minute);
    expect(await (await hub.settings()).json()).toMatchObject({ pairing: null, lan: { open: false } });
    await expect(fetch(hub.lan + "/v1/device/hello")).rejects.toThrow();
    hub.advance(-10 * minute);

    await hub.pair();
    const expired = await hub.invite(), expiredClient = await DeviceClient.fromInvite(expired, hub.lan);
    hub.advance(10 * minute);
    expect(await (await hub.settings()).json()).toMatchObject({ pairing: null });
    const exp = await expiredClient.send("pair", await expiredClient.pairingBody(expired), { ts: expired.expires_at });
    expect(exp.status).toBe(403);

    const replaced = await hub.invite(), revoked = await hub.invite();
    const client = await DeviceClient.fromInvite(revoked, hub.lan);
    expect((await client.send("pair", await client.pairingBody(replaced), { ts: expired.expires_at })).status).toBe(403);
    await hub.settings("/pairing", "DELETE");
    expect((await client.send("pair", await client.pairingBody(revoked), { ts: expired.expires_at })).status).toBe(403);

    const single = await hub.invite();
    const other = await DeviceClient.fromInvite(single, hub.lan);
    const results = await Promise.all([
      client.send("pair", await client.pairingBody(single), { ts: expired.expires_at }),
      other.send("pair", await other.pairingBody(single), { ts: expired.expires_at }),
    ]);
    expect(results.map(r => r.status).sort()).toEqual([200, 403]);
    expect(await (await hub.settings()).json()).toMatchObject({ pairing: null });
    expect(hub.writes).toBe(1);
  } finally { await hub.dispose(); }
});

test("配对回执丢失后跨重启重放同一请求，仅原请求者可取回原设备和实际角色", async () => {
  const hub = await runningHub(undefined, { local: 48613, lan: 48612 });
  try {
    const invite = await hub.invite("admin");
    const client = await DeviceClient.fromInvite(invite, hub.lan);
    const body = { ...await client.pairingBody(invite), name: "合成 Mac", platform: "mac" };
    const nonce = randomBytes(16).toString("base64url");
    const first = await client.send("pair", body, { nonce });
    expect(first).toEqual({ status: 200, body: {
      device_id: expect.stringMatching(/^mac-/), hub_id: invite.hub_id, hub_name: invite.name, name: "合成 Mac", role: "admin",
    } });
    await hub.restart();
    expect(await client.send("pair", body, { nonce })).toEqual(first);
    expect(await client.send("pair", body)).toEqual(first);
    expect((await client.send("pair", { ...body, name: "不同的请求" })).status).toBe(403);
    const other = await DeviceClient.fromInvite(invite, hub.lan);
    expect((await other.pair(invite, "mac")).status).toBe(403);
    expect(hub.db.db.prepare("SELECT id FROM devices").all()).toEqual([{ id: first.body.device_id }]);
    expect(hub.db.db.prepare("SELECT id FROM issued_device_ids").all()).toEqual([{ id: first.body.device_id }]);
    hub.advance(5 * minute);
    expect((await client.send("pair", body, { ts: new Date(hub.time()).toISOString() })).status).toBe(403);
  } finally { await hub.dispose(); }
});

test("拒绝篡改、错误的发送方密钥、过期时间和同一 nonce，信封限长返回 JSON", async () => {
  const hub = await runningHub();
  try {
    const phone = await hub.pair(), other = await hub.pair();
    const nonce = randomBytes(16).toString("base64url");
    const input = { op: "sync", body: { cursor: 0 }, ts: new Date().toISOString(), nonce };
    const envelope = await phone.envelope(input);
    const ct = Buffer.from(envelope.ct, "base64url");
    ct[0] ^= 1;
    const impostor = new DeviceClient(phone.hub, other.keys);
    impostor.device = phone.device;
    for (const invalid of [
      { ...envelope, ct: ct.toString("base64url") },
      { ...envelope, device: other.device },
      await impostor.envelope(input),
    ]) {
      const reply = await phone.post(invalid);
      expect(reply.status).toBe(401);
      expect(await reply.json()).toEqual({ error: "设备未配对或已移除" });
    }
    expect((await phone.post({ ...envelope, enc: "x" })).status).toBe(400);
    expect((await phone.send("sync", { cursor: 0 }, { ts: new Date(Date.now() - 11 * minute).toISOString() })).status).toBe(400);
    expect((await phone.send("sync", { cursor: 0 }, { ts: "2026-11-19" })).status).toBe(400);
    expect((await phone.send("sync", { cursor: 0 }, { nonce })).status).toBe(200);
    expect((await phone.send("sync", { cursor: 0 }, { nonce })).status).toBe(400);

    const size = 8 * 1024 * 1024;
    for (const body of [
      " ".repeat(size + 10),
      new ReadableStream({ start(controller) {
        controller.enqueue(new Uint8Array(size));
        controller.enqueue(new Uint8Array(1));
        controller.close();
      } }),
    ]) {
      const response = await fetch(hub.lan + "/v1/device", { method: "POST", headers: { "Content-Type": "application/json" }, body });
      expect(response.status).toBe(413);
      expect(await response.json()).toEqual({ error: "信封超过 8 MiB" });
    }
  } finally { await hub.dispose(); }
});

test("配对、上传逐条核对来源和归属，中枢删改、同步并确认，移除后拒绝且保留记录", async () => {
  const hub = await runningHub();
  try {
    const phone = await hub.pair(), other = await hub.pair();
    const mac = fixture(), original = fixture({ device: phone.device!, source: "android.notifications" });
    const otherRecord = fixture({ device: other.device!, source: "android.usage" });
    const removed = fixture({ device: phone.device!, source: "manual.note", source_ref: "phone:note" });
    const correction = fixture({ source: "manual.correction", corrects: original.id });
    hub.db.ingest([mac, otherRecord]);

    const receipt = await phone.send("ingest", { device: other.device, records: [
      original, removed, otherRecord, fixture({ device: phone.device!, source: "mac.screen" }),
      fixture({ device: phone.device!, source: "manual.correction", corrects: mac.id }),
    ] });
    expect(receipt).toMatchObject({ status: 200, body: { accepted: 2, duplicates: 0, rejected: [
      { index: 2 }, { index: 3 }, { index: 4 },
    ] } });
    expect(await phone.send("delete", { device: other.device, ids: [mac.id, otherRecord.id] })).toEqual({ status: 200, body: { deleted: 0 } });
    expect(hub.db.get(mac.id)).not.toBeNull();
    expect(hub.db.get(otherRecord.id)).not.toBeNull();

    expect(hub.db.ingest([correction]).accepted).toBe(1);
    expect((await hub.admin(`/v1/records/${removed.id}`, "DELETE")).status).toBe(200);
    const sync = await phone.send<{ changes: { record?: unknown }[]; cursor: number }>("sync", { cursor: 0 });
    expect(sync).toMatchObject({ status: 200, body: { more: false, changes: [
      { kind: "correction", record: { id: correction.id, kind: "event", corrects: original.id } },
      { kind: "delete", id: removed.id, source: "manual.note", source_ref: "phone:note" },
    ] } });
    expect(validateRecord(sync.body.changes[0]!.record).ok).toBe(true);
    expect(await other.send("sync", { cursor: 0 })).toMatchObject({ body: { changes: [], cursor: 0 } });
    expect(await phone.send("sync.ack", { cursor: sync.body.cursor })).toEqual({ status: 200, body: { ok: true } });
    for (const language of ["zh", "en"]) {
      expect((await hub.admin("/v1/settings/general", "PUT", { language })).status).toBe(200);
      expect(await phone.send("sync", { cursor: 0 })).toMatchObject({ status: 200, body: { changes: [], cursor: 0, more: false, language } });
    }

    const status = await (await hub.admin("/v1/status")).json() as { devices: Record<string, unknown>[] };
    expect(status.devices.find(x => x.id === phone.device)).toMatchObject({
      name: "测试手机", last_seen: expect.any(String), records: 1, pending_changes: 0,
    });
    expect(status.devices.every(device => !("public_key" in device))).toBe(true);

    hub.db.delete(correction.id);
    expect(await phone.send("sync", { cursor: 0 })).toMatchObject({ body: { changes: [{ kind: "delete", id: correction.id }] } });
    expect((await hub.settings("/" + phone.device, "DELETE")).status).toBe(200);
    const wire = await phone.envelope({ op: "sync", body: { cursor: 0 }, ts: new Date().toISOString(), nonce: randomBytes(16).toString("base64url") });
    expect((await phone.post(wire)).status).toBe(401);
    expect(hub.db.get(original.id)).not.toBeNull();
    expect(hub.db.db.prepare("SELECT 1 FROM device_changes WHERE device=?").get(phone.device)).toBeUndefined();
    expect((await hub.settings("/" + other.device, "DELETE")).status).toBe(200);
    await expect(fetch(hub.lan + "/v1/device/hello")).rejects.toThrow();
  } finally { await hub.dispose(); }
});

test("同步跨 200 条的边界，跳过已删除的修正，按设备和游标确认", async () => {
  const hub = await runningHub();
  try {
    const phone = await hub.pair();
    const originals = Array.from({ length: 201 }, () => fixture({ device: phone.device!, source: "android.usage" }));
    hub.db.ingest(originals);
    const correction = fixture({ source: "manual.correction", corrects: originals[0]!.id });
    hub.db.ingest([correction]);
    hub.db.deleteMany(originals.map(record => record.id));
    const first = await phone.send<{ changes: { seq: number }[]; more: boolean; cursor: number }>("sync", { cursor: 0 });
    expect(first.body.changes.length).toBe(199);
    expect(first.body.changes.every((change, i, all) => i === 0 || all[i - 1]!.seq < change.seq)).toBe(true);
    expect(first.body.more).toBe(true);
    await phone.send("sync.ack", { cursor: first.body.cursor });
    const second = await phone.send<{ changes: unknown[]; more: boolean; cursor: number }>("sync", { cursor: first.body.cursor });
    expect(second.body.changes.length).toBe(3);
    expect(second.body.more).toBe(false);
    await phone.send("sync.ack", { cursor: second.body.cursor });
    expect(await phone.send("sync", { cursor: second.body.cursor })).toMatchObject({ body: { changes: [], cursor: second.body.cursor } });
  } finally { await hub.dispose(); }
});

test("变更队列写入失败时，修正与真删一同回滚", async () => {
  const hub = await runningHub();
  try {
    const phone = await hub.pair();
    const original = fixture({ device: phone.device!, source: "android.usage" });
    const correction = fixture({ source: "manual.correction", corrects: original.id });
    hub.db.ingest([original]);
    hub.db.db.exec(`
      CREATE TEMP TRIGGER reject_change BEFORE INSERT ON device_changes
      BEGIN SELECT RAISE(ABORT, 'synthetic queue failure'); END;
    `);
    expect(() => hub.db.ingest([correction])).toThrow("synthetic queue failure");
    expect(hub.db.get(correction.id)).toBeNull();
    expect(() => hub.db.deleteMany([original.id])).toThrow("synthetic queue failure");
    expect(hub.db.get(original.id)).not.toBeNull();
    expect(hub.db.db.prepare("SELECT * FROM tombstones").all()).toEqual([]);
    expect(hub.db.db.prepare("SELECT * FROM device_changes").all()).toEqual([]);
  } finally { await hub.dispose(); }
});

test("设备重启后仍配对，丢失中枢钥匙后须重新配对且保留原记录", async () => {
  const hub = await runningHub();
  try {
    const phone = await hub.pair();
    const original = fixture({ device: phone.device!, source: "android.usage" });
    await phone.send("ingest", { records: [original] });
    await hub.restart();
    expect((await phone.send("sync", { cursor: 0 })).status).toBe(200);

    hub.loseKey();
    await hub.restart();
    expect((await fetch(hub.lan + "/v1/device/hello")).status).toBe(401);
    const invite = await hub.invite();
    const replacement = await DeviceClient.fromInvite(invite, hub.lan, phone.keys);
    expect((await replacement.pair(invite)).status).toBe(200);
    expect(replacement.device).not.toBe(phone.device);
    expect(await (await hub.settings()).json()).toMatchObject({ devices: [{ id: replacement.device }] });
    expect(hub.db.get(original.id)).not.toBeNull();
  } finally { await hub.dispose(); }
});

test("音频转发只使用配对身份，拒绝跨设备修改对话和上传样本", async () => {
  const hub = await runningHub();
  try {
    const phone = await hub.pair(), other = await hub.pair();
    const ref = "fixture:conversation";
    const at = new Date().toISOString();
    const embeddings = { device: other.device, conversation_ref: ref, t_start: at, t_end: at,
      speakers: [{ local: "S1", track: "mic", seconds: 45, centroid: [1, ...Array(511).fill(0)] }] };
    expect((await phone.send("audio.embeddings", embeddings)).status).toBe(200);
    expect(hub.db.db.prepare("SELECT device FROM voice_embeddings").get()).toEqual({ device: phone.device });
    expect((await other.send("audio.embeddings", { ...embeddings, device: phone.device })).status).toBe(400);
    expect((await other.send("audio.lines", { device: phone.device, conversation_ref: ref, lines: [] })).status).toBe(400);
    expect((await other.send("audio.skipped", { device: phone.device, conversation_ref: ref })).status).toBe(400);
    expect((await phone.send("audio.lines", { conversation_ref: ref, lines: [] })).status).toBe(200);

    const sync = await phone.send<{ sample_requests: { id: string }[] }>("audio.sync", { device: other.device });
    expect(sync.body.sample_requests.length).toBe(1);
    const sample = { device: phone.device, request_id: sync.body.sample_requests[0]!.id, clips: [{ mime: "audio/wav", data: "AA==" }] };
    expect((await other.send("audio.samples", sample)).status).toBe(400);
    expect((await phone.send("audio.samples", sample)).status).toBe(200);
    expect((await phone.send("audio.sync.ack", { deleted: [], device: other.device })).status).toBe(200);
    expect((await phone.send("audio.skipped", { conversation_ref: ref })).status).toBe(200);
  } finally { await hub.dispose(); }
});

test("v12 加密数据库迁移到 v16，保留记录并清理验证通过的备份", () => {
  const hub = setup();
  try {
    const record = fixture();
    hub.db.ingest([record]);
    removeProjectionSchema(hub.db.db);
    hub.db.db.exec("DROP TABLE devices; DROP TABLE issued_device_ids; DROP TABLE device_changes; DROP INDEX records_device; PRAGMA user_version=12");
    hub.db.close();
    const migrated = new HubDB(hub.file, hub.config.dbKey);
    try {
      expect(migrated.db.pragma("user_version", { simple: true })).toBe(19);
      expect(migrated.get(record.id)).toMatchObject({ id: record.id });
      expect(migrated.db.prepare("SELECT * FROM devices").all()).toEqual([]);
      expect(existsSync(hub.file + ".migration-v12.bak")).toBe(false);
    } finally { migrated.close(); }
  } finally { hub.cleanup(); }
});

test("v12 结构冲突时保留加密备份并回滚迁移", () => {
  const hub = setup();
  try {
    hub.db.ingest([fixture()]);
    removeProjectionSchema(hub.db.db);
    hub.db.db.exec(`
      DROP TABLE devices; DROP TABLE issued_device_ids; DROP TABLE device_changes; DROP INDEX records_device;
      CREATE VIEW device_changes AS SELECT 1;
      PRAGMA user_version=12;
    `);
    hub.db.close();
    const source = readFileSync(hub.file);
    expect(() => new HubDB(hub.file, hub.config.dbKey)).toThrow(expect.objectContaining({ code: "db_migration_failed" }));
    expect(readFileSync(hub.file + ".migration-v12.bak")).toEqual(source);
    expect(readFileSync(hub.file)).toEqual(source);
  } finally { hub.cleanup(); }
});

test("互通向量可逐字节重建，base 和 auth 请求、回复均能解封", async () => {
  expect(JSON.stringify(await deviceFixture(), null, 2) + "\n")
    .toBe(readFileSync(new URL("../../schema/fixtures/device-envelope.json", import.meta.url), "utf8"));
  const { keyPairFromRaw } = await import("../src/devices/envelope.ts");
  const hub = await keyPairFromRaw(Buffer.from(vectors.hub.private_key_hex, "hex"));
  const device = await keyPairFromRaw(Buffer.from(vectors.device.private_key_hex, "hex"));
  const client = new DeviceClient(hub.publicKey, device);
  for (const { request, response } of [vectors.pairing, vectors.sync]) {
    const wire = await readEnvelope(new Request("http://test/v1/device", {
      method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(request.envelope),
    }));
    const sender = request.mode === "auth" ? device.publicKey : undefined;
    expect(await openRequest(wire, hub, sender)).toEqual(JSON.parse(request.plaintext_json_utf8));
    expect(await client.open(response.envelope as ResponseEnvelope, response.aad_utf8)).toEqual(JSON.parse(response.plaintext_json_utf8));
  }
  expect(Buffer.from(await suite.kem.serializePublicKey(hub.publicKey)).toString("base64url")).toBe(vectors.hub.public_key_base64url);
});

test("手机只能取回自己那几场对话的总结", async () => {
  const hub = await runningHub();
  try {
    const phone = await hub.pair(), other = await hub.pair();
    const audio = (device: string, ref: string, at: string) => fixture({ device, source: "android.audio", kind: "span",
      source_ref: `audio:${ref}`, t_start: at, t_end: at.replace(":00+", ":30+"), title: "对话记录",
      body: "[10:00:05] 我：周五下午三点在会议室见", capture: { method: "asr" } });
    const mine = audio(phone.device!, "a", "2026-11-08T10:00:00+08:00"), theirs = audio(other.device!, "b", "2026-11-08T10:00:00+08:00");
    expect((await phone.send("ingest", { records: [mine] })).body).toMatchObject({ accepted: 1 });
    expect((await other.send("ingest", { records: [theirs] })).body).toMatchObject({ accepted: 1 });
    const from = Date.parse("2026-11-08T00:00:00+08:00"), to = from + 86_400_000;
    for (const g of conversationsIn(hub.db, from, to)) saveSummary(hub.db, g, { title: "约会议时间", summary: "定在周五下午三点。", points: ["会议室"] });

    const got = await phone.send<{ conversations: { record_ids: string[]; title: string }[] }>("conversations", { from, to });
    expect(got).toMatchObject({ status: 200, body: { conversations: [
      { record_ids: [mine.id], title: "约会议时间", summary: "定在周五下午三点。", points: ["会议室"] },
    ] } });
    expect((await phone.send("conversations", { from, to: from + 40 * 86_400_000 })).status).toBe(400);
  } finally { await hub.dispose(); }
});

test("手机自己写的总结：组成一致才采用，开着时中枢不再重复写", async () => {
  const hub = await runningHub();
  try {
    const phone = await hub.pair(), other = await hub.pair();
    const audio = (device: string, ref: string, at: string) => fixture({ device, source: "android.audio", kind: "span",
      source_ref: `audio:${ref}`, t_start: at, t_end: at.replace(":00+", ":30+"), title: "对话记录",
      body: `[${at.slice(11, 19)}] 我：${"周五下午三点在会议室见，带上新办公室装修的预算表。".repeat(12)}`, capture: { method: "asr" } });
    const a = audio(phone.device!, "a", "2026-11-08T10:00:00+08:00"), b = audio(phone.device!, "b", "2026-11-08T10:05:00+08:00");
    const theirs = audio(other.device!, "c", "2026-11-08T10:00:00+08:00");
    expect((await phone.send("ingest", { records: [a, b] })).body).toMatchObject({ accepted: 2 });
    expect((await other.send("ingest", { records: [theirs] })).body).toMatchObject({ accepted: 1 });
    const summary = { title: "新办公室装修预算", summary: "约好周五下午三点在会议室看预算表。", points: ["带上预算表"] };
    const put = (summaries: unknown[], summarizing = true) => phone.send<{ saved: string[]; stale: string[] }>("conversations.put", { summarizing, summaries });

    // 只交了其中一段（另一段还没传上来时手机分的场）、或者拿别的设备的记录来交，都不采用。
    expect((await put([{ id: a.id, record_ids: [a.id], ...summary }, { id: theirs.id, record_ids: [theirs.id], ...summary }])).body)
      .toEqual({ saved: [], stale: [a.id, theirs.id] });
    expect((await put([{ id: a.id, record_ids: [b.id, a.id], ...summary }])).body).toEqual({ saved: [a.id], stale: [] });
    const day = Date.parse("2026-11-08T00:00:00+08:00");
    const g = conversationsIn(hub.db, day, day + 86_400_000, phone.device!)[0]!;
    expect(storedSummary(hub.db, g)).toEqual(summary);
    expect([...selfSummarizingDevices(hub.db)]).toEqual([phone.device!]);
    const longSummary = { title: "x".repeat(80), summary: "y".repeat(700), points: Array(5).fill("z".repeat(200)) };
    const longItem = { id: a.id, record_ids: [b.id, a.id], ...longSummary };
    expect((await put([longItem])).body).toEqual({ saved: [a.id], stale: [] });
    expect(storedSummary(hub.db, g)).toEqual(longSummary);
    for (const tooLong of [
      { title: "x".repeat(81) }, { summary: "y".repeat(701) },
      { points: Array(6).fill("z") }, { points: ["z".repeat(201)] },
    ]) {
      expect((await put([{ ...longItem, ...tooLong }])).status).toBe(400);
    }
    expect(storedSummary(hub.db, g)).toEqual(longSummary);

    // 开着“AI 总结”的手机，中枢只给别的设备写；关掉以后中枢接着写。
    expect((await hub.admin("/v1/settings/general", "PUT", { language: "zh" })).status).toBe(200);
    const calls: string[] = [];
    const llm = { complete: async <T,>(req: { prompt: string }) => { calls.push(req.prompt); return { ok: true as const, ms: 1, call_id: "c", data: summary as T }; } };
    hub.db.db.prepare("DELETE FROM conversation_summaries").run();
    const now = Date.parse("2026-11-08T12:00:00+08:00");
    expect((await conversationStep({ db: hub.db, llm: llm as never }, now)).calls).toBe(1);
    expect(storedSummary(hub.db, g)).toBeNull();
    expect((await put([], false)).body).toEqual({ saved: [], stale: [] });
    expect((await conversationStep({ db: hub.db, llm: llm as never }, now)).calls).toBe(1);
    expect(storedSummary(hub.db, g)).toEqual(summary);
  } finally { await hub.dispose(); }
});

test("v15 升级 v16，旧查看设备迁为 view、Android 保持 collect，验证后移除备份", () => {
  const hub = setup();
  try {
    removeDeviceRoleSchema(hub.db.db);
    const sql = hub.db.db.prepare("INSERT INTO devices(id,name,platform,public_key,paired_at,last_seen,viewer) VALUES(?,?,?,?,?,?,?)");
    const at = new Date().toISOString();
    sql.run("android-testaaaa", "合成手机", "android", Buffer.alloc(32), at, at, 0);
    sql.run("mac-testaaaa", "合成电脑", "mac", Buffer.alloc(32), at, at, 1);
    hub.db.db.pragma("user_version=15");
    hub.db.close();
    const migrated = new HubDB(hub.file, hub.config.dbKey);
    try {
      expect(migrated.db.pragma("user_version", { simple: true })).toBe(19);
      expect(migrated.db.prepare("SELECT id,role FROM devices ORDER BY id").all()).toEqual([
        { id: "android-testaaaa", role: "collect" }, { id: "mac-testaaaa", role: "view" },
      ]);
      expect(existsSync(hub.file + ".migration-v15.bak")).toBe(false);
      expect(() => migrated.db.prepare("UPDATE devices SET role='owner'").run()).toThrow();
    } finally { migrated.close(); }
  } finally { hub.cleanup(); }
});

test("角色矩阵覆盖设备写入、投影、原文、AI、状态、编辑、删除和管理", () => {
  const roles: DeviceRole[] = ["collect", "view", "admin", "agent"];
  const groups: [string[], DeviceRole[]][] = [
    [["ingest", "delete", "sync.ack", "audio.lines", "conversations.put", "collector.status", "relay"], ["collect", "view", "admin"]],
    [["projection.pull", "projection.ack", "events.subscribe"], ["view", "admin", "agent"]],
    [["records.get", "records.list", "history.segments", "conversations.detail", "timeline.query", "days.active"], ["view", "admin"]],
    // 回归（2026-11-24）：查看设备经 agent.* 能读到私密原文。
    [["agent.now", "agent.get", "agent.search", "agent.append", "agent.audit_sync"], ["admin", "agent"]],
    [["status.get", "diagnostics.get"], ["view", "admin"]],
    [["records.create", "segment.correct", "facts.update", "pending.resolve", "distill.request"], ["admin"]],
    [["segment.delete", "project.remove"], ["admin"]],
    [["history.import.begin", "history.import.batch", "history.import.status", "history.import.finish", "history.import.changes", "history.import.verify"], ["admin"]],
    [["agent.enroll", "devices.role.update", "settings.models", "runtime.calls", "audit.list", "audio.settings.put"], ["admin"]],
  ];
  for (const [ops, allowed] of groups) for (const op of ops) for (const role of roles) {
    expect(operationAccess(role, op)).toBe(allowed.includes(role) ? "allow" : "deny");
  }
  expect(operationAccess("admin", "invalid")).toBe("unknown");
});

test("配对锁定角色、管理邀请正好 5 分钟过期，Android 查看邀请不能自行提权", async () => {
  const hub = await runningHub();
  try {
    await hub.pair();
    const adminInvite = await hub.invite("admin");
    expect(Date.parse(adminInvite.expires_at) - hub.time()).toBe(5 * minute);
    const expired = await DeviceClient.fromInvite(adminInvite, hub.lan);
    hub.advance(5 * minute);
    expect((await expired.pair(adminInvite, "mac")).status).toBe(403);

    const viewInvite = await hub.invite("view");
    expect(Date.parse(viewInvite.expires_at) - hub.time()).toBe(10 * minute);
    const viewer = await DeviceClient.fromInvite(viewInvite, hub.lan);
    const paired = await viewer.send("pair", { ...await viewer.pairingBody(viewInvite), role: "admin" });
    expect(paired).toMatchObject({ status: 200, body: { role: "view" } });
    expect(await (await hub.settings()).json()).toMatchObject({ devices: expect.arrayContaining([
      expect.objectContaining({ id: paired.body.device_id, platform: "android", role: "view" }),
    ]) });
  } finally { await hub.dispose(); }
});

test("限制远程提权及最后管理员，降回 collect 只下发重置，管理令牌可授予 admin", async () => {
  const hub = await runningHub();
  try {
    const phone = await hub.pair();
    const admin = await hub.pair("admin");
    const target = await hub.pair("collect");
    const update = (client: DeviceClient, id: string | null, role: PairingRole) => client.send("devices.role.update", { id, role });
    expect(await phone.send("projection.pull", { cursor: 0 })).toEqual({ status: 403, body: { error: "当前设备权限不足" } });
    expect((await update(target, target.device, "view")).status).toBe(403);
    expect((await update(admin, phone.device, "admin")).status).toBe(403);
    expect((await update(admin, target.device, "admin")).status).toBe(403);
    expect(await update(admin, admin.device, "view")).toEqual({ status: 409, body: { error: "不能移除最后一台管理设备" } });
    expect((await admin.send("devices.remove", { id: admin.device })).status).toBe(409);
    expect((await hub.settings("/" + admin.device, "DELETE")).status).toBe(409);
    expect((await hub.settings("/" + admin.device + "/role", "PUT", { role: "collect", force: true })).status).toBe(409);

    expect((await update(admin, target.device, "view")).status).toBe(200);
    const initial = await target.send("projection.pull", { cursor: 0 });
    expect(initial.status).toBe(200);
    expect((await update(admin, target.device, "collect")).status).toBe(200);
    expect(await target.send("projection.pull", { cursor: initial.body.cursor, epoch: initial.body.epoch }))
      .toMatchObject({ status: 200, body: { kind: "projection.reset", reset: true, changes: [], more: false } });
    expect((await target.send("records.list", {})).status).toBe(403);
    expect((await target.send("projection.ack", { cursor: 0, epoch: initial.body.epoch })).status).toBe(403);

    expect((await hub.settings("/" + target.device + "/role", "PUT", { role: "admin" })).status).toBe(200);
    expect((await update(admin, admin.device, "collect")).status).toBe(200);
    expect((await target.send("devices.remove", { id: admin.device })).status).toBe(200);
    const { events } = await (await hub.admin("/v1/settings/security-audit")).json() as { events: object[] };
    expect(events).toEqual(expect.arrayContaining([
      expect.objectContaining({ action: "auth.denied", actor_device: phone.device, detail_code: "projection.pull" }),
      expect.objectContaining({ action: "device.role_change", actor_device: admin.device, target: target.device, detail_code: "view:collect" }),
      expect.objectContaining({ action: "device.remove", actor_device: target.device, target: admin.device }),
    ]));
  } finally { await hub.dispose(); }
});

test("Android 可用查看邀请和远程升降级，不能成为管理设备", async () => {
  const hub = await runningHub();
  try {
    const noAdmin = await hub.invite("admin");
    const denied = await DeviceClient.fromInvite(noAdmin, hub.lan);
    expect((await denied.pair(noAdmin, "android")).status).toBe(403);
    const phone = await hub.pair("view", "android");
    const admin = await hub.pair("admin");
    const role = (role: PairingRole) => admin.send("devices.role.update", { id: phone.device, role });
    expect(await phone.send("relay", {})).toMatchObject({ status: 200, body: { role: "view" } });
    expect((await phone.send("projection.pull", { cursor: 0, window_days: 30 })).status).toBe(200);
    expect((await phone.send("records.get", { ids: [ulid()], include_private: true })).status).toBe(403);
    expect((await hub.settings("/" + phone.device + "/role", "PUT", { role: "admin" })).status).toBe(403);
    expect((await role("collect")).status).toBe(200);
    expect(await phone.send("relay", {})).toMatchObject({ status: 200, body: { role: "collect" } });
    expect((await phone.send("records.get", { ids: [ulid()] })).status).toBe(403);
    expect((await role("view")).status).toBe(200);
    expect(await phone.send("relay", {})).toMatchObject({ status: 200, body: { role: "view" } });
    expect(await phone.send("projection.pull", { cursor: 0, window_days: 30 }))
      .toMatchObject({ status: 200, body: { reset: false } });
  } finally { await hub.dispose(); }
});

test("远程删除限额按库累计，包含修正、跨重启保留；远程设备删自己的记录不计入、额度用完也能删", async () => {
  const hub = await runningHub();
  try {
    const phone = await hub.pair();
    const admin = await hub.pair("admin");
    const otherAdmin = await hub.pair("admin");
    const marker = "合成正文-不进入安全审计";
    const rows = Array.from({ length: 1002 }, () => fixture({ device: phone.device!, body: marker }));
    const correction = fixture({ device: admin.device!, source: "manual.correction", corrects: rows[0]!.id });
    const own = fixture({ device: admin.device! });
    const ownPhone = fixture({ device: phone.device! });
    expect(hub.db.ingest([...rows, correction, own, ownPhone]).accepted).toBe(1005);
    const remove = async (start: number, end: number, client = admin) =>
      client.send("delete", { ids: rows.slice(start, end).map(row => row.id) }, { ts: new Date(hub.time()).toISOString() });
    expect(await remove(0, 100)).toMatchObject({ status: 200, body: { deleted: 101 } });
    expect(await remove(100, 199)).toMatchObject({ status: 200, body: { deleted: 99 } });
    await hub.restart();
    expect((await remove(199, 200, otherAdmin)).status).toBe(429);
    expect(hub.db.get(rows[199]!.id)).not.toBeNull();
    // 额度用完时，删自己采集的记录照样成功，且不占额度（手机删除不能被共享额度拦下）。
    expect(await admin.send("delete", { ids: [own.id] })).toMatchObject({ status: 200, body: { deleted: 1 } });
    expect(await phone.send("delete", { ids: [ownPhone.id] })).toMatchObject({ status: 200, body: { deleted: 1 } });
    for (let cursor = 199; cursor < 999; cursor += 200) {
      hub.advance(minute);
      expect((await remove(cursor, cursor + 100)).body.deleted).toBe(100);
      expect((await remove(cursor + 100, cursor + 200)).body.deleted).toBe(100);
    }
    hub.advance(minute);
    expect((await remove(999, 1000)).status).toBe(429);
    expect(hub.db.get(rows[999]!.id)).not.toBeNull();
    expect((await hub.admin("/v1/records", "DELETE", { ids: [rows[1001]!.id] })).status).toBe(200);
    expect(hub.db.get(rows[1001]!.id)).toBeNull();
    hub.advance(24 * 60 * minute - 5 * minute);
    expect((await remove(999, 1000)).status).toBe(200);
    const audit = await (await hub.admin("/v1/settings/security-audit")).json();
    expect(JSON.stringify(audit)).not.toContain(marker);
    expect(JSON.stringify(audit)).not.toContain(rows[0]!.id);
    expect(audit.events.filter((e: { action: string }) => e.action === "remote.delete")).toEqual(expect.arrayContaining([
      expect.objectContaining({ detail_code: "101", target: null, ok: 1 }),
      expect.objectContaining({ detail_code: "1", target: null, ok: 0 }),
    ]));
  } finally { await hub.dispose(); }
}, 15_000);

test("安全审计保留 90 天，通过本机接口只返回最近 200 条", async () => {
  const hub = await runningHub();
  try {
    const now = hub.time(), boundary = now - 90 * 24 * 60 * minute;
    auditSecurity(hub.db.db, "key.set", { now: boundary - 1 });
    auditSecurity(hub.db.db, "key.set", { now: boundary, code: "boundary" });
    pruneSecurityAudit(hub.db.db, now);
    expect(hub.db.db.prepare("SELECT detail_code FROM security_audit").all()).toEqual([{ detail_code: "boundary" }]);
    for (let i = 0; i < 201; i++) auditSecurity(hub.db.db, "key.delete", { code: String(i), now: now + i });
    const { events } = await (await hub.admin("/v1/settings/security-audit")).json() as { events: { detail_code: string }[] };
    expect(events.length).toBe(200);
    expect(events[0]!.detail_code).toBe("200");
    expect(events.at(-1)!.detail_code).toBe("1");
    await hub.pair();
    expect((await fetch(hub.lan + "/v1/settings/security-audit")).status).toBe(404);
  } finally { await hub.dispose(); }
});

test("agent 仅能拉取 project_context；未落地 op 依矩阵区分越权和无处理器", async () => {
  const hub = await runningHub();
  try {
    const device = await hub.pair("view");
    // Agent 身份签发留到后续，这里只测试已识别的角色。
    hub.db.db.prepare("UPDATE devices SET role='agent' WHERE id=?").run(device.device);
    new DistillStore(hub.db).upsertProject({ id: "trail", name: "合成项目", keys: { repos: [], hosts: [], chats: [] } });
    const page = await device.send<{ changes: { kind: string }[] }>("projection.pull", { cursor: 0 });
    expect(page.status).toBe(200);
    expect(page.body.changes.map(change => change.kind)).toEqual(["project_context"]);
    expect((await device.send("ingest", { records: [] })).status).toBe(403);
    expect((await device.send("agent.search", {})).status).toBe(400);
    expect((await device.send("facts.create", {})).status).toBe(403);
    expect((await device.send("facts.合成正文", {})).status).toBe(403);
    const audit = await (await hub.admin("/v1/settings/security-audit")).json();
    expect(audit.events).toEqual(expect.arrayContaining([
      expect.objectContaining({ action: "auth.denied", detail_code: "facts.create" }),
      expect.objectContaining({ action: "auth.denied", detail_code: "unknown_op" }),
    ]));
    expect(JSON.stringify(audit)).not.toContain("合成正文");
  } finally { await hub.dispose(); }
});

test("设备段删除校验成员并和普通删除共用限额", async () => {
  const hub = await runningHub();
  try {
    const phone = await hub.pair();
    const admin = await hub.pair("admin");
    const rows = Array.from({ length: 501 }, () => fixture({ device: phone.device! }));
    const correction = fixture({ source: "manual.correction", corrects: rows[0]!.id });
    expect(hub.db.ingest([...rows, correction]).accepted).toBe(502);
    const date = "2026-11-08";
    const body = { date, id: "segment:trail", record_ids: rows.slice(0, 199).map(row => row.id) };
    new DistillStore(hub.db).upsertDay({ date, detail: { items: [{
      ...body, title: "步道校对", description: "校对步道入口。", t_start: rows[0]!.t_start, t_end: rows[0]!.t_start,
      active_seconds: 0, sources: ["mac.screen"], apps: [], project_id: null, evidence: [],
    }] } });
    expect((await phone.send("segment.delete", body)).status).toBe(403);
    expect((await admin.send("segment.delete", { ...body, record_ids: body.record_ids.slice(1) })).status).toBe(409);
    expect(await admin.send("segment.delete", body)).toEqual({ status: 200, body: { deleted: 200 } });
    expect(hub.db.get(correction.id)).toBeNull();
    expect((await admin.send("delete", { ids: [rows[199]!.id] })).status).toBe(429);
    const { admin: local } = await localClients(hub);
    const localBody = { date, id: "segment:local", record_ids: rows.slice(201).map(row => row.id) };
    new DistillStore(hub.db).upsertDay({ date, detail: { items: [{
      ...localBody, title: "本机样例", description: "复核步道地图。", t_start: rows[201]!.t_start, t_end: rows[201]!.t_start,
      active_seconds: 0, sources: ["mac.screen"], apps: [], project_id: null, evidence: [],
    }] } });
    expect(await local.send("segment.delete", localBody)).toEqual({ status: 200, body: { deleted: 300 } });
    expect(hub.db.db.prepare("SELECT detail_code FROM security_audit WHERE action='local.delete' AND actor_device=?").all(local.device))
      .toEqual([{ detail_code: "300" }]);
  } finally { await hub.dispose(); }
});

type Bootstrap = { mac_device_id: string; agent_device_id: string; hub_id: string; hub_pk: string; endpoint: string };
async function bootstrapKeys() {
  const [mac, agent] = await Promise.all([identityFromRaw(randomBytes(32).toString("hex")), identityFromRaw(randomBytes(32).toString("hex"))]);
  return { mac, agent, body: { mac_pk: mac.publicKey.toString("base64url"), agent_pk: agent.publicKey.toString("base64url") } };
}

test("本机登记可接续单独 Agent，同一对公钥幂等，其余冲突拒绝", async () => {
  const hub = await runningHub();
  try {
    const { body } = await bootstrapKeys();
    const path = "/v1/settings/devices/local-bootstrap";
    const bootstrap = (input = body) => hub.settings("/local-bootstrap", "POST", input);
    const unauth = await fetch(hub.origin + path, { method: "POST", body: JSON.stringify(body) });
    expect(unauth.status).toBe(401);
    const alias = await fetch(hub.origin.replace("127.0.0.1", "localhost") + path, {
      method: "POST", headers: { Authorization: "Bearer " + hub.config.token }, body: JSON.stringify(body),
    });
    expect(alias.status).toBe(403);
    const agentToken = await fetch(hub.origin + path, {
      method: "POST", headers: { Authorization: "Bearer " + hub.config.agentToken }, body: JSON.stringify(body),
    });
    expect(agentToken.status).toBe(403);
    const first = await bootstrap();
    expect(first.status).toBe(200);
    const previous = await first.json() as Bootstrap;
    expect(previous).toEqual({
      hub_id: expect.stringMatching(/^[a-z2-7]{26}$/), hub_pk: expect.stringMatching(/^[\w-]{43}$/),
      mac_device_id: expect.stringMatching(/^mac-[a-z2-7]{8}$/), agent_device_id: expect.stringMatching(/^agent-[a-z2-7]{8}$/),
      endpoint: hub.origin + "/v1/device",
    });
    expect(await (await bootstrap()).json()).toEqual(previous);
    const second = (await bootstrapKeys()).body;
    expect((await bootstrap({ ...body, agent_pk: second.agent_pk })).status).toBe(409);
    expect((await bootstrap({ ...body, mac_pk: second.mac_pk })).status).toBe(409);
    expect((await bootstrap({ mac_pk: body.agent_pk, agent_pk: body.mac_pk })).status).toBe(409);
    const localAgent = (agent_pk: string) => hub.settings("/local-agent", "POST", { agent_pk });
    const installed = await localAgent(second.agent_pk);
    expect(installed.status).toBe(200);
    const standalone = await installed.json() as Omit<Bootstrap, "mac_device_id">;
    expect(await (await localAgent(second.agent_pk)).json()).toEqual(standalone);
    expect((await localAgent(body.mac_pk)).status).toBe(409);
    const upgraded = await bootstrap(second);
    expect(upgraded.status).toBe(200);
    const upgradedPair = await upgraded.json() as Bootstrap;
    expect(upgradedPair).toEqual({ ...standalone, mac_device_id: expect.stringMatching(/^mac-[a-z2-7]{8}$/) });
    expect(await (await bootstrap(second)).json()).toEqual(upgradedPair);
    expect(await (await localAgent(second.agent_pk)).json()).toEqual(standalone);
    expect((await bootstrap({ ...second, mac_pk: (await bootstrapKeys()).body.mac_pk })).status).toBe(409);
    expect(hub.db.db.prepare("SELECT COUNT(*) AS count FROM devices").get()).toEqual({ count: 4 });
    expect(hub.db.db.prepare("SELECT bootstrap_agent_id FROM devices WHERE id=?").get(upgradedPair.mac_device_id))
      .toEqual({ bootstrap_agent_id: standalone.agent_device_id });
    expect(hub.db.db.prepare("SELECT COUNT(*) AS count FROM security_audit WHERE action='device.local_register' AND ok=1").get()).toEqual({ count: 4 });
    expect((await (await hub.settings()).json() as { lan: { open: boolean } }).lan.open).toBe(false);
    expect((await fetch(hub.origin + "/v1/device/hello")).status).toBe(200);
    await expect(fetch(hub.lan + "/v1/device/hello")).rejects.toThrow();
    await hub.invite();
    expect((await fetch(hub.lan + "/v1/device/hello")).status).toBe(200);
    expect((await fetch(hub.lan + path, {
      method: "POST", headers: { Authorization: "Bearer " + hub.config.token }, body: JSON.stringify(body),
    })).status).toBe(404);
  } finally { await hub.dispose(); }
});

test("设备 Agent 查询沿用旧接口语义，写入和审计记录调用设备", async () => {
  const hub = await runningHub();
  try {
    const keys = await bootstrapKeys();
    const link = await (await hub.settings("/local-bootstrap", "POST", keys.body)).json() as Bootstrap;
    const publicKey = await suite.kem.deserializePublicKey(Buffer.from(link.hub_pk, "base64url"));
    const mac = new DeviceClient(publicKey, keys.mac.keys, hub.origin), agent = new DeviceClient(publicKey, keys.agent.keys, hub.origin);
    mac.device = link.mac_device_id;
    agent.device = link.agent_device_id;
    const row = fixture({ device: mac.device, title: "枫叶账本样例", source: "mac.screen" });
    const ingest = await mac.send("ingest", { records: [row, fixture({ device: mac.device, source: "android.app" })] });
    expect(ingest).toMatchObject({ status: 200, body: { accepted: 1, rejected: [{ index: 1, errors: ["/source 不支持此设备来源"] }] } });
    expect((await agent.send("ingest", { records: [fixture({ device: agent.device, source: "manual.note" })] })).status).toBe(403);

    const store = new DistillStore(hub.db);
    const project = ulid(), cwd = "/tmp/tacit-maple-ledger", now = Date.now();
    store.upsertProject({ id: project, name: "枫叶账本", keys: { repos: [cwd], hosts: [], chats: [] } });
    store.upsertThread({ id: ulid(), title: "对账", brief: "完成第一轮虚构对账", status: "active", domain: "work", project_id: project, last_ms: now });
    for (const [kind, args] of [
      ["context", { cwd, event: "startup" }], ["now", {}], ["get", { id: row.id, level: "detail" }],
      ["search", { q: "枫叶账本" }], ["timeline", { device: mac.device }],
    ] as const) {
      const params = { tool: "codex", ...args } as Record<string, string>;
      const legacy = await fetch(hub.origin + `/v1/agent/${kind}?${new URLSearchParams(params)}`, {
        headers: { Authorization: "Bearer " + hub.config.agentToken },
      });
      const device = await agent.send(`agent.${kind}`, params);
      expect(legacy.status).toBe(200);
      expect(device).toEqual({ status: legacy.status, body: await legacy.json() });
    }
    const append = await agent.send<{ id: string }>("agent.append", { tool: "codex", title: "写入虚构条目", body: "拿来做协议回归" });
    expect(append.status).toBe(200);
    expect(hub.db.get(append.body.id)?.device).toBe(agent.device);
    const audit = hub.db.db.prepare("SELECT kind FROM agent_reads WHERE json_extract(args,'$.agent_device')=? ORDER BY kind").all(agent.device);
    expect(audit).toEqual(["append", "context", "get", "now", "search", "timeline"].map(kind => ({ kind })));
    await hub.invite();
    const offMachine = new DeviceClient(publicKey, keys.agent.keys, hub.lan);
    offMachine.device = agent.device;
    await expect(offMachine.send("agent.now", { tool: "codex" })).rejects.toThrow("401");
  } finally { await hub.dispose(); }
});

test("SessionStart 800 ms 回退到按 remote 匹配的加密缓存，7 天过期，恢复连接补报一次", async () => {
  const hub = await runningHub();
  let requested = false;
  const slow = Bun.serve({
    hostname: "127.0.0.1", port: 0,
    async fetch() { requested = true; await Bun.sleep(1800); return new Response(null, { status: 503 }); },
  });
  try {
    const secrets = fileAgentSecrets(hub.dir);
    const env = { RA_DATA_DIR: hub.dir, RA_PORT: new URL(hub.origin).port };
    const link = await ensureAgentIdentity({ env, secrets });
    expect(await ensureAgentIdentity({ env, secrets })).toEqual(link);
    expect(await secrets.read(deviceAccount, AbortSignal.timeout(1000))).toMatch(/^[a-f0-9]{64}$/);
    const repoPath = join(hub.dir, "hub-side-repo"), checkout = join(hub.dir, "other-mac-repo");
    mkdirSync(checkout);
    for (const args of [["init", "-q"], ["remote", "add", "origin", "git@example.test:maple/ledger.git"]]) {
      expect(Bun.spawnSync(["git", "-C", checkout, ...args]).exitCode).toBe(0);
    }
    updateGeneral(hub.db, { language: "zh" });
    const store = new DistillStore(hub.db), projectId = ulid(), threadId = ulid();
    store.upsertProject({ id: projectId, name: "枫叶账本", keys: {
      repos: [repoPath], remotes: ["example.test/maple/ledger"], hosts: [], chats: [],
    } });
    store.upsertThread({ id: threadId, project_id: projectId, status: "active", domain: "work", title: "对账", brief: "合成对账完成" });
    const params = (cwd: string) => new URLSearchParams({ cwd, tool: "codex", event: "startup", session: "fictional-session" });
    const run = async (cwd: string, port = env.RA_PORT) => {
      let text = "";
      await sessionContext(params(cwd), AbortSignal.timeout(2000), value => { text = value; },
        { env: { ...env, RA_PORT: port }, secrets });
      return text;
    };
    const online = await run(repoPath);
    expect(online).toContain("合成对账完成");
    expect(online).not.toContain("离线缓存");
    const cachePath = join(hub.dir, "agent-context-cache", `${link.hub_id}-${link.device_id}`, `${projectId}.enc`);
    expect(readFileSync(cachePath).includes(Buffer.from("合成对账完成"))).toBe(false);

    const start = performance.now();
    const offline = await run(checkout, String(slow.port));
    const elapsed = performance.now() - start;
    expect(requested).toBe(true);
    expect(elapsed).toBeGreaterThanOrEqual(730);
    expect(elapsed).toBeLessThan(1600);
    expect(offline).toMatch(/^（离线缓存，同步于 \d{4}-\d{2}-\d{2} \d{2}:\d{2}）/);
    expect(offline).toContain(online);

    const cache = new ContextCache(hub.dir, link, secrets);
    expect(await cache.offline(params(checkout), "example.test/maple/ledger", AbortSignal.timeout(1000),
      Date.now() + 7 * 86_400_000 + 1000)).toBe("");

    const now = () => readHub("now", new URLSearchParams({ tool: "codex" }), AbortSignal.timeout(1000), undefined, { env, secrets });
    await now();
    await now();
    const rows = hub.db.db.prepare("SELECT args, result_ids, bytes FROM agent_reads WHERE json_extract(args,'$.cached')=1").all() as
      { args: string; result_ids: string; bytes: number }[];
    expect(rows).toHaveLength(1);
    expect(JSON.parse(rows[0]!.args)).toEqual({ session: "fictional-session", cwd: checkout, project: projectId, agent_device: link.device_id, cached: true });
    expect(JSON.parse(rows[0]!.result_ids)).toEqual([threadId]);
    expect(rows[0]!.bytes).toBe(0);
    expect(await run(checkout)).toBe(online);
  } finally { await slow.stop(true); await hub.dispose(); }
});

async function localClients(hub: Awaited<ReturnType<typeof runningHub>>) {
  const keys = await bootstrapKeys();
  const response = await hub.settings("/local-bootstrap", "POST", keys.body);
  expect(response.status).toBe(200);
  const link = await response.json() as Bootstrap;
  const publicKey = await suite.kem.deserializePublicKey(Buffer.from(link.hub_pk, "base64url"));
  const admin = new DeviceClient(publicKey, keys.mac.keys, hub.origin);
  const agent = new DeviceClient(publicKey, keys.agent.keys, hub.origin);
  admin.device = link.mac_device_id;
  agent.device = link.agent_device_id;
  return { admin, agent };
}

test("查看窗口的所有 op 沿用原 HTTP 状态和响应形状", async () => {
  const hub = await runningHub();
  const model = Bun.serve({ hostname: "127.0.0.1", port: 0, fetch(request) {
    if (new URL(request.url).pathname === "/models") return Response.json({ data: [{ id: "fixture-model" }] });
    if (new URL(request.url).pathname === "/v1/hello") return Response.json({
      tacit_relay: 1, limits: { space_bytes: 1000000, message_bytes: 100000, retention_days: 30 },
    });
    return Response.json({ choices: [{ finish_reason: "stop", message: { content: '{"ok":true}' } }] });
  } });
  try {
    const { admin } = await localClients(hub);
    const store = new DistillStore(hub.db);
    const pair = async (op: string, method: string, path: string, args: object = {}, payload?: object,
                        normalize: (v: any) => unknown = v => v, status = 200) => {
      const response = await hub.admin(path, method, payload);
      const expected = { status: response.status, body: normalize(await response.json()) };
      expect(expected.status).toBe(status);
      const actual = await admin.send(op, args);
      expect({ status: actual.status, body: normalize(actual.body) }).toEqual(expected);
      return actual.body;
    };
    const record = fixture({ source: "manual.note" });
    const createPath = "/v1/records";
    const originalCreate = await hub.admin(createPath, "POST", record);
    expect(originalCreate.status).toBe(200);
    const created = await originalCreate.json();
    const peer = fixture({ source: "manual.note" });
    expect(await admin.send("records.create", peer)).toEqual({ status: 200, body: created });
    expect(hub.db.get(peer.id)?.body).toBe(peer.body);
    // 格式错误的补写：两条通道都返回逐字段的 rejected，不入库（C3 联调发现设备协议曾只回一句 400）。
    const malformed = (id: string) => ({ ...fixture({ source: "manual.note" }), id, capture: { method: "manual", extra: true } });
    const badHTTP = await (await hub.admin(createPath, "POST", malformed(ulid()))).json();
    const badDevice = await admin.send("records.create", malformed(ulid()));
    expect(badDevice).toEqual({ status: 200, body: badHTTP });
    expect(badHTTP.rejected[0].errors.length).toBeGreaterThan(0);

    const date = "2026-11-08", id = "segment:fixture";
    const dayPath = `/v1/days/${date}/segments/${id}`;
    const seedSegment = (recordID: string) => store.upsertDay({ date, detail: { items: [{
      id, title: "核对苗圃", description: "检查标签。", t_start: record.t_start, t_end: record.t_start,
      active_seconds: 0, sources: ["manual.note"], apps: [], project_id: null, evidence: [], record_ids: [recordID],
    }] } });
    seedSegment(record.id);
    await pair("segment.correct", "PATCH", dayPath, { date, id, description: "校对苗圃标签。" }, { description: "校对苗圃标签。" });
    const httpSegment = await hub.admin(dayPath, "DELETE", { record_ids: [record.id] });
    seedSegment(peer.id);
    expect(await admin.send("segment.delete", { date, id, record_ids: [peer.id] }))
      .toEqual({ status: httpSegment.status, body: await httpSegment.json() });
    expect(httpSegment.status).toBe(200);
    expect(hub.db.get(peer.id)).toBeNull();

    const [first, second] = [fixture(), fixture()];
    expect(hub.db.ingest([first, second]).accepted).toBe(2);
    await pair("delete", "DELETE", createPath, { ids: [second.id] }, { ids: [first.id] });
    expect(hub.db.get(second.id)).toBeNull();

    const projects = [ulid(), ulid()];
    for (const project of projects) store.upsertProject({ id: project, name: "样例苗圃", keys: { repos: [], hosts: [], chats: [] } });
    const now = new Date().toISOString();
    const pending = projects.map(project_id => ({ id: ulid(), kind: "project" as const, payload: { project_id }, created_at: now }));
    for (const item of pending) store.createPending(item);
    await pair("pending.list", "GET", "/v1/pending");
    await pair("pending.resolve", "POST", "/v1/pending/" + pending[0]!.id, { id: pending[1]!.id, action: "confirm" }, { action: "confirm" });
    expect(store.project(projects[1]!)?.confirmed).toBe(1);
    await pair("project.remove", "DELETE", "/v1/projects/" + projects[0], { id: projects[1]! });
    expect(store.project(projects[1]!)).toBeNull();

    const thread = ulid();
    store.upsertThread({ id: thread, title: "苗圃", status: "active", domain: "work" });
    const evidence = fixture({ source: "manual.note" });
    expect(hub.db.ingest([evidence]).accepted).toBe(1);
    const factBody = { kind: "decision", text: "保留蓝色标签", evidence: [evidence.id], thread_id: thread, valid_at: now };
    const httpFact = await hub.admin("/v1/facts", "POST", factBody);
    expect(httpFact.status).toBe(200);
    const fact = await httpFact.json() as { id: string; created_at: string };
    const deviceFact = await admin.send("facts.create", factBody);
    expect(deviceFact.status).toBe(200);
    expect(deviceFact.body).toEqual({ ...fact, id: expect.any(String), created_at: expect.any(String) });
    await pair("facts.detach", "POST", `/v1/facts/${fact.id}/detach`, { id: deviceFact.body.id });
    expect(store.facts("thread_id", thread)).toEqual([]);

    const distillPath = "/v1/distill/requests";
    const request = { kind: "round" };
    const queued = await admin.send("distill.request", request);
    expect(queued.status).toBe(202);
    expect(queued.body).toMatchObject({ kind: "round", status: "queued" });
    await pair("distill.request", "POST", distillPath, request, request);
    await pair("distill.list", "GET", distillPath);

    const audioPath = "/v1/audio/settings";
    await pair("audio.settings.put", "PUT", audioPath, { retention_days: 9 }, { retention_days: 9 });
    await pair("audio.settings.get", "GET", audioPath);
    await pair("audio.purge", "POST", "/v1/audio/purge", {}, undefined, v => ({ purge_before: typeof v.purge_before }));
    await pair("speakers.list", "GET", "/v1/speakers");
    const sample = Buffer.from("synthetic-audio-sample"), sampleId = ulid();
    hub.db.db.prepare("INSERT INTO voice_samples VALUES (?,?,?,?,?,?)").run(sampleId, ulid(), ulid(), "audio/ogg", sample, now);
    const clip = await hub.admin("/v1/audio/samples/" + sampleId);
    expect(clip.status).toBe(200);
    expect(await admin.send("audio.sample.get", { id: sampleId })).toEqual({
      status: 200, body: { mime: clip.headers.get("content-type"), data_base64: Buffer.from(await clip.arrayBuffer()).toString("base64") },
    });

    await pair("status.get", "GET", "/v1/status", {}, undefined, v => {
      const { generated_at, ...rest } = v;
      return { ...rest, hub: { ...rest.hub, uptime_s: 0, started_at: "" }, devices: rest.devices.map((d: any) => ({ ...d, last_seen: "" })) };
    });
    // 2026-11-24 虚拟机联调回归：Mac 探测连接时带 read_nonce，后台不能当成未登记参数拒绝。
    expect((await admin.send("status.get", { read_nonce: "probe-0001" })).status).toBe(200);
    expect((await admin.send("status.get", { unknown_field: 1 })).status).toBe(400);
    await pair("diagnostics.get", "GET", "/v1/runtime/background?source=hub");
    await pair("runtime.background", "GET", "/v1/runtime/background?source=distill", { source: "distill" });
    await pair("audit.list", "GET", "/v1/audit?limit=1&tool=codex", { limit: 1, tool: "codex" });

    const settings = "/v1/settings";
    await pair("settings.hub.put", "PUT", settings + "/hub", { port: 49001 }, { port: 49001 });
    await pair("settings.hub.get", "GET", settings + "/hub");
    const provider = "openai-compatible", url = model.url.origin;
    const config = { provider, base_url: url, model: "fixture-model" };
    const tiers = { tiers: { minute: config, hour: config, day: config } };
    const key = { key: "synthetic-model-key-0123456789" };
    await pair("settings.keys.put", "PUT", settings + "/keys/" + provider, { provider, ...key }, key);
    await pair("settings.models.put", "PUT", settings + "/models", tiers, tiers);
    await pair("settings.models.get", "GET", settings + "/models");
    await pair("settings.models.local", "POST", settings + "/models/local", { base_url: url }, { base_url: url });
    const modelTest = { tier: "minute", config };
    await pair("settings.models.test", "POST", settings + "/models/test", modelTest, modelTest, v => {
      expect(v).toMatchObject({ ok: true, error: null });
      return { ...v, ms: 0 };
    });
    const logs = await pair("runtime.models", "GET", "/v1/runtime/models?limit=1", { limit: 1 }) as { calls: { id: string }[] };
    await pair("runtime.call", "GET", "/v1/runtime/calls/" + logs.calls[0]!.id, { id: logs.calls[0]!.id });
    const httpKeyDelete = await hub.admin(settings + "/keys/" + provider, "DELETE");
    await admin.send("settings.keys.put", { provider, ...key });
    expect(await admin.send("settings.keys.delete", { provider })).toEqual({ status: httpKeyDelete.status, body: await httpKeyDelete.json() });

    await pair("settings.general.put", "PUT", settings + "/general", { archive_days: 15 }, { archive_days: 15 });
    await pair("settings.general.get", "GET", settings + "/general");
    await pair("settings.relay.put", "PUT", settings + "/relay", { mode: "off" }, { mode: "off" });
    await pair("settings.relay.get", "GET", settings + "/relay");
    await pair("settings.relay.test", "POST", settings + "/relay/test", { url }, { url });
    await pair("devices.pairing.create", "POST", settings + "/devices/pairing", { role: "view" }, { role: "view" }, v => ({
      role: decodePairing(v.uri).role, expires_at: v.expires_at,
    }));
    await pair("devices.list", "GET", settings + "/devices", {}, undefined, v => ({
      ...v, current_device_id: null, devices: v.devices.map((d: any) => ({ ...d, last_seen: "" })),
    }));
    await pair("devices.pairing.cancel", "DELETE", settings + "/devices/pairing");
    expect((await (await hub.settings()).json()).pairing).toBeNull();

    const target = await hub.pair("view");
    await pair("devices.role.update", "PUT", settings + `/devices/${target.device}/role`, { id: target.device, role: "collect" }, { role: "collect" });
    const otherTarget = await hub.pair("view");
    await pair("devices.remove", "DELETE", settings + "/devices/" + target.device, { id: otherTarget.device });
    expect(hub.db.db.prepare("SELECT id FROM devices WHERE id=?").get(otherTarget.device)).toBeUndefined();
  } finally {
    await model.stop(true);
    await hub.dispose();
  }
}, 15_000);

test("查看窗口 op 拒绝无效路径、额外字段以及查看与 Agent 越权", async () => {
  const hub = await runningHub();
  try {
    const { admin, agent } = await localClients(hub);
    const viewer = await hub.pair("view");
    for (const [op, args] of [
      ["segment.correct", { date: "2026-11-08", id: "../123", description: "样例" }],
      ["segment.delete", { date: "2026-11-08", id: "%2F", record_ids: [ulid()] }],
      ["segment.correct", { date: "2026-02-31", id: "segment", description: "样例" }],
      ["project.remove", { id: ".." }],
      ["settings.keys.put", { provider: "unknown", key: "synthetic-key" }],
      ["devices.remove", { id: viewer.device, force: true }],
      ["settings.models.put", { tiers: {}, path: "/v1/records" }],
      ["settings.general.get", { method: "DELETE" }],
      ["audio.settings.put", { retention_days: 5, extra: true }],
      ["settings.unregistered", {}],
      ["constructor", {}],
    ] as const) expect((await admin.send(op, args)).status).toBe(400);
    for (const client of [viewer, agent]) {
      for (const op of ["records.create", "segment.correct", "segment.delete", "project.remove", "facts.create",
        "settings.hub.put", "settings.models.put", "settings.keys.put", "settings.relay.put", "audio.settings.put",
        "audio.purge", "audio.sample.get", "devices.pairing.create", "devices.remove"]) {
        expect((await client.send(op, {})).status).toBe(403);
      }
    }
  } finally { await hub.dispose(); }
});

test("仅远端管理 Mac 能登记 AI 身份，父设备降权或移除时撤销并审计", async () => {
  const hub = await runningHub(undefined, { local: 48613, lan: 48612 });
  try {
    const parent = await hub.pair("admin"), another = await hub.pair("admin");
    const viewer = await hub.pair("view"), collector = await hub.pair();
    const { admin: local, agent: localAgent } = await localClients(hub);
    const keys = await suite.kem.generateKeyPair();
    const agent_pk = Buffer.from(await suite.kem.serializePublicKey(keys.publicKey)).toString("base64url");
    for (const client of [local, localAgent, viewer, collector]) {
      expect((await client.send("agent.enroll", { agent_pk })).status).toBe(403);
    }
    expect((await parent.send("agent.enroll", { agent_pk: "invalid" })).status).toBe(400);
    const enrollment = await parent.send<{ device_id: string; hub_id: string }>("agent.enroll", { agent_pk });
    const { device_id, hub_id } = enrollment.body;
    expect(enrollment).toEqual({ status: 200, body: {
      device_id: expect.stringMatching(/^agent-/), hub_id: (await (await hub.settings()).json()).hub_id,
    } });
    expect(hub.db.db.prepare("SELECT role,local_only FROM devices WHERE id=?").get(device_id)).toEqual({ role: "agent", local_only: 0 });
    expect(await parent.send("agent.enroll", { agent_pk })).toEqual(enrollment);
    expect((await another.send("agent.enroll", { agent_pk })).status).toBe(409);
    const invite = await hub.invite("admin");
    expect((await (await DeviceClient.fromInvite(invite, hub.lan, keys)).pair(invite, "mac")).status).toBe(409);

    const agent = new DeviceClient(parent.hub, keys, hub.lan);
    agent.device = device_id;
    expect((await agent.send("agent.now", { tool: "codex" })).status).toBe(200);
    expect((await agent.send("agent.enroll", { agent_pk })).status).toBe(403);
    expect((await hub.settings(`/${device_id}/role`, "PUT", { role: "admin" })).status).toBe(403);

    expect((await another.send("devices.role.update", { id: parent.device, role: "view" })).status).toBe(200);
    expect((await parent.send("agent.enroll", { agent_pk })).status).toBe(403);
    await expect(agent.send("agent.now", { tool: "codex" })).rejects.toMatchObject({ status: 401 });
    const renewed = await another.send<{ device_id: string; hub_id: string }>("agent.enroll", { agent_pk });
    const replacement = renewed.body.device_id;
    expect(renewed).toEqual({ status: 200, body: { device_id: expect.stringMatching(/^agent-/), hub_id } });
    expect(replacement).not.toBe(device_id);
    agent.device = replacement;
    expect((await agent.send("agent.now", { tool: "codex" })).status).toBe(200);
    expect((await hub.settings(`/${another.device}`, "DELETE")).status).toBe(200);
    await expect(agent.send("agent.now", { tool: "codex" })).rejects.toMatchObject({ status: 401 });

    expect(hub.db.db.prepare("SELECT target FROM security_audit WHERE action='device.remove' AND detail_code='parent_revoked' ORDER BY rowid").all())
      .toEqual([{ target: device_id }, { target: replacement }]);
  } finally { await hub.dispose(); }
});

test("私密原文仅对直连管理设备显式开放，整理投影依旧隔离", async () => {
  const hub = await runningHub();
  try {
    const { admin: local } = await localClients(hub);
    const remote = await hub.pair("admin");
    const viewer = await hub.pair("view");
    const marker = "合成私密河道名录";
    const start = new Date(hub.time() - 60_000).toISOString();
    const end = new Date(hub.time() - 30_000).toISOString();
    const normal = fixture({ source: "mac.audio", kind: "span", t_start: start, t_end: end });
    const privateAudio = fixture({ source: "mac.audio", kind: "span", t_start: start, t_end: end,
      title: marker, body: "[10:00:00] 我：" + marker, sensitivity: "private" });
    const correction = fixture({ source: "manual.correction", corrects: normal.id, body: marker + "修正", sensitivity: "private" });
    expect(hub.db.ingest([normal, privateAudio, correction]).accepted).toBe(3);
    const range = { from: start, to: end };
    const requests = [
      ["records.get", { ids: [normal.id, privateAudio.id], include_corrections: true }],
      ["records.list", { q: marker, body: true }],
      ["history.segments", range],
      ["conversations.detail", { record_id: privateAudio.id }],
    ] as const;
    for (const [op, args] of requests) {
      expect((await viewer.send(op, { ...args, include_private: true })).status).toBe(403);
      expect(JSON.stringify(await remote.send(op, args))).not.toContain(marker);
      for (const client of [local, remote]) {
        const reply = await client.send(op, { ...args, include_private: true });
        expect(reply.status).toBe(200);
        if (op === "history.segments") expect(JSON.stringify(reply.body)).toContain(privateAudio.id);
        else expect(JSON.stringify(reply.body)).toContain(marker);
      }
    }
    const privateHistory = await remote.send("history.segments", { ...range, include_private: true });
    expect(privateHistory.body).toEqual(await (await hub.admin("/v1/history/segments?" + new URLSearchParams(range))).json());
    expect((await remote.send("conversations.detail", { record_id: privateAudio.id, include_private: true })).body)
      .toEqual(await (await hub.admin("/v1/conversations/" + privateAudio.id)).json());
    const pull = await local.send("projection.pull", { cursor: 0 });
    expect(pull.status).toBe(200);
    expect(JSON.stringify(pull.body)).not.toContain(marker);
    const cached = hub.db.db.prepare("SELECT payload FROM project_context_cache UNION ALL SELECT result FROM relay_receipts").all();
    expect(JSON.stringify(cached)).not.toContain(marker);
  } finally { await hub.dispose(); }
});

test("设备操作 days.active 遵守私密边界与权限控制，并与本机 HTTP 口径一致", async () => {
  const hub = await runningHub();
  try {
    const { admin: local } = await localClients(hub);
    const remote = await hub.pair("admin");
    const viewer = await hub.pair("view");
    const collector = await hub.pair("collect");
    const store = new DistillStore(hub.db);

    const localIso = (dayNum: number, hour = 10) => new Date(2026, 7, dayNum, hour, 0, 0, 0).toISOString();
    const pubRec = fixture({ source: "manual.note", t_start: localIso(3), title: "合成公开笔记", body: "核对灯塔巡检记录。" });
    const privOnlyRec = fixture({ source: "manual.note", t_start: localIso(5), title: "合成私密笔记", body: "私密内容。", sensitivity: "private" });
    const pubBaseRec = fixture({ source: "manual.note", t_start: localIso(7), title: "待修正记录", body: "初稿。" });
    const privCorrRec = fixture({ source: "manual.correction", corrects: pubBaseRec.id, t_start: localIso(7, 11), body: "改为私密。", sensitivity: "private" });
    const distilledPubRec = fixture({ source: "manual.note", t_start: localIso(9), title: "整理依据", body: "完成步道路线核对。" });
    expect(hub.db.ingest([pubRec, privOnlyRec, pubBaseRec, privCorrRec, distilledPubRec]).accepted).toBe(5);

    store.upsertDay({
      date: "2026-08-05",
      detail: {
        summary: "私密总结",
        record_ids: [privOnlyRec.id],
        items: [{
          id: "priv-seg", title: "私密段", description: "包含私密内容。", t_start: privOnlyRec.t_start, t_end: privOnlyRec.t_start,
          active_seconds: 60, sources: ["manual.note"], apps: [{ source: "manual.note", app: null }],
          record_ids: [privOnlyRec.id], project_id: null,
          evidence: [{ id: privOnlyRec.id, at: privOnlyRec.t_start, source: "manual.note", title: privOnlyRec.title }],
        }],
      },
    });
    store.upsertDay({
      date: "2026-08-09",
      detail: {
        summary: "完成了步道路线核对。",
        record_ids: [distilledPubRec.id],
        items: [{
          id: "pub-seg", title: "核对步道路线", description: "完成了石桥到林场的核对。", t_start: distilledPubRec.t_start, t_end: distilledPubRec.t_start,
          active_seconds: 120, sources: ["manual.note"], apps: [{ source: "manual.note", app: null }],
          record_ids: [distilledPubRec.id], project_id: null,
          evidence: [{ id: distilledPubRec.id, at: distilledPubRec.t_start, source: "manual.note", title: distilledPubRec.title }],
        }],
      },
    });

    // 普通查看态与未带 include_private 的远端管理态不泄露仅含私密记录（含私密修正）的日期
    expect(await viewer.send("days.active", { month: "2026-08" })).toEqual({
      status: 200,
      body: { month: "2026-08", dates: ["2026-08-03", "2026-08-09"] },
    });
    expect(await remote.send("days.active", { month: "2026-08" })).toEqual({
      status: 200,
      body: { month: "2026-08", dates: ["2026-08-03", "2026-08-09"] },
    });
    expect((await viewer.send("days.active", { month: "2026-08", include_private: true })).status).toBe(403);
    expect((await collector.send("days.active", { month: "2026-08" })).status).toBe(403);

    // 直连管理设备（本机/远端）带 include_private: true 与本机 HTTP 一致
    const httpBody = await (await hub.admin("/v1/days/active?month=2026-08")).json();
    expect(httpBody).toEqual({ month: "2026-08", dates: ["2026-08-03", "2026-08-05", "2026-08-07", "2026-08-09"] });
    expect(await local.send("days.active", { month: "2026-08", include_private: true })).toEqual({ status: 200, body: httpBody });
    expect(await remote.send("days.active", { month: "2026-08", include_private: true })).toEqual({ status: 200, body: httpBody });

    // 非法月份参数返回 400
    expect((await viewer.send("days.active", { month: "2026-13" })).status).toBe(400);
    expect((await viewer.send("days.active", {})).status).toBe(400);
  } finally { await hub.dispose(); }
});

test("管理设备只看到其他远程设备的安全事件，确认跨重启且只存事件 ID 与时间", async () => {
  const hub = await runningHub();
  const root = "/v1/settings/security-events";
  const list = "settings.security-events.list", ack = "settings.security-events.ack";
  try {
    const { admin: local, agent } = await localClients(hub);
    const remote = await hub.pair("admin");
    const viewer = await hub.pair("view");
    const phone = await hub.pair();
    const provider = "openai-compatible", key = "synthetic-key-123";
    const putKey = (client: DeviceClient) => client.send("settings.keys.put", { provider, key });
    const role = (client: DeviceClient, next: PairingRole) => client.send("devices.role.update", { id: viewer.device, role: next });

    expect(await (await hub.settings()).json()).toMatchObject({ current_device_id: local.device });
    expect(await remote.send("devices.list", {})).toMatchObject({ body: { current_device_id: remote.device } });
    expect((await (await hub.admin(root)).json()).events.map((event: { action: string }) => event.action)).toEqual(["pair.complete"]);
    expect(await remote.send(list, {})).toEqual({ status: 200, body: { events: [] } });

    expect((await putKey(local)).status).toBe(200);
    expect((await role(local, "collect")).status).toBe(200);
    expect((await hub.admin("/v1/settings/keys/" + provider, "PUT", { key })).status).toBe(200);
    expect((await hub.settings("/" + viewer.device + "/role", "PUT", { role: "view" })).status).toBe(200);
    expect((await role(remote, "collect")).status).toBe(200);
    expect((await putKey(remote)).status).toBe(200);

    const pending = await (await hub.admin(root)).json() as { events: { id: string; action: string; at: string }[] };
    expect(pending.events.map(x => x.action).sort()).toEqual(["device.role_change", "key.set", "pair.complete"]);
    const event = pending.events.find(x => x.action === "key.set")!;
    expect(Object.keys(event).sort()).toEqual(["action", "at", "id"]);
    expect(await local.send(list, {})).toEqual({ status: 200, body: pending });
    expect(await remote.send(list, {})).toEqual({ status: 200, body: { events: [] } });
    expect((await remote.send(ack, { id: event.id })).status).toBe(404);

    const ackPath = root + "/" + event.id + "/ack";
    for (const [path, method] of [[root, "GET"], [ackPath, "POST"]] as const) {
      const url = new URL(path, hub.origin);
      expect((await fetch(url, { method })).status).toBe(401);
      expect((await fetch(url, { method, headers: { Authorization: "Bearer " + hub.config.agentToken } })).status).toBe(403);
      expect((await fetch(hub.lan + path, { method })).status).toBe(404);
    }
    expect((await hub.settings("/" + viewer.device + "/role", "PUT", { role: "view" })).status).toBe(200);
    for (const client of [viewer, phone, agent]) {
      expect((await client.send(list, {})).status).toBe(403);
      expect((await client.send(ack, { id: event.id })).status).toBe(403);
    }

    // Removing the authenticated actor does not turn its older events into local events.
    expect((await hub.settings("/" + remote.device, "DELETE")).status).toBe(200);
    expect((await (await hub.admin(root)).json()).events).toEqual(pending.events);
    expect(await local.send(ack, { id: event.id })).toEqual({ status: 200, body: { ok: true } });
    const stored = hub.db.db.prepare("SELECT * FROM security_event_acknowledgements").all();
    expect(stored).toEqual([{ event_id: event.id, acknowledged_at: expect.any(String) }]);
    expect((await hub.admin(ackPath, "POST")).status).toBe(200);
    expect(hub.db.db.prepare("SELECT * FROM security_event_acknowledgements").all()).toEqual(stored);
    await hub.restart();
    expect(await (await hub.admin(root)).json()).toEqual({ events: pending.events.filter(x => x.id !== event.id) });
    const pairingEvent = pending.events.find(x => x.action === "pair.complete")!;
    expect((await hub.admin(root + "/" + pairingEvent.id + "/ack", "POST")).status).toBe(200);
    expect((await (await hub.admin(root)).json()).events.map((x: { action: string }) => x.action)).toEqual(["device.role_change"]);
    pruneSecurityAudit(hub.db.db, Date.now() + 91 * 24 * 60 * minute);
    expect(hub.db.db.prepare("SELECT * FROM security_event_acknowledgements").all()).toEqual([]);
  } finally { await hub.dispose(); }
});

test("写入模型密钥期间移除远程设备，仍会提示远程操作", async () => {
  const writing = Promise.withResolvers<void>(), resume = Promise.withResolvers<void>();
  const hub = await runningHub(async () => { writing.resolve(); await resume.promise; });
  try {
    await localClients(hub);
    const remote = await hub.pair("admin");
    const operation = remote.send("settings.keys.put", { provider: "openai-compatible", key: "synthetic-key-123" });
    await Promise.race([writing.promise, operation.then(() => { throw new Error("模型密钥写入未开始"); })]);
    expect((await hub.settings("/" + remote.device, "DELETE")).status).toBe(200);
    resume.resolve();
    expect((await operation).status).toBe(200);
    const pending = await (await hub.admin("/v1/settings/security-events")).json() as { events: { action: string }[] };
    expect(pending.events.map(x => x.action).sort()).toEqual(["key.set", "pair.complete"]);
  } finally {
    resume.resolve();
    await hub.dispose();
  }
});

test("历史导入仅远端管理 Mac 可用，拒绝冒充现有或导入授权后配对的设备", async () => {
  const hub = await runningHub(undefined, { local: 48620, lan: 48621 });
  try {
    const admin = await hub.pair("admin"), viewer = await hub.pair("view"), other = await hub.pair("admin");
    const { hub_id } = await (await hub.settings()).json() as { hub_id: string };
    const begin = { hub_id, snapshot_id: "b".repeat(64),
      identities: [{ device: "mac", kind: "mac", sources: ["mac.screen"] }] };
    expect((await viewer.send("history.import.begin", begin)).status).toBe(403);
    const moveToLocal = hub.db.db.prepare("UPDATE devices SET local_only=1 WHERE id=?");
    moveToLocal.run(other.device);
    const local = new DeviceClient(other.hub, other.keys, hub.origin);
    local.device = other.device;
    expect((await local.send("history.import.begin", begin)).status).toBe(403);
    expect(await admin.send("history.import.begin", { ...begin, identities: [{ ...begin.identities[0], device: other.device }] }))
      .toEqual({ status: 403, body: { error: "device_collision" } });
    const futureIdentity = "mac-zzzzzzzz";
    const started = await admin.send<{ session_id: string }>("history.import.begin", { ...begin,
      identities: [...begin.identities, { device: futureIdentity, kind: "mac", sources: ["mac.screen"] }] });
    expect(started.status).toBe(200);
    hub.db.db.prepare("INSERT INTO issued_device_ids VALUES(?)").run(futureIdentity);
    const record = fixture({ device: futureIdentity });
    expect(await admin.send("history.import.batch", { session_id: started.body.session_id, batch_number: 1, records: [record] }))
      .toMatchObject({ status: 200, body: { items: [{ id: record.id, status: "rejected", code: "device_collision" }] } });
    expect(hub.db.get(record.id)).toBeNull();
  } finally { await hub.dispose(); }
});
