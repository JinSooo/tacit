import { expect, test } from "bun:test";
import { randomBytes } from "node:crypto";
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { HubDB } from "../src/db.ts";
import { conversationsIn, saveSummary } from "../src/conversations.ts";
import { openRequest, readEnvelope, suite } from "../src/devices/envelope.ts";
import { startServer } from "../src/server.ts";
import { validateRecord } from "../../packages/record/index.ts";
import vectors from "../../schema/fixtures/device-envelope.json";
import { decodePairing, DeviceClient, type ResponseEnvelope } from "./device-client.ts";
import { deviceFixture } from "./generate-device-fixture.ts";
import { fixture, setup } from "./helpers.ts";

const minute = 60_000;

async function runningHub() {
  const ctx = setup();
  const probe = Bun.serve({ hostname: "0.0.0.0", port: 0, fetch: () => new Response() });
  const lanPort = probe.port!;
  await probe.stop(true);
  writeFileSync(join(ctx.dir, "hub.json"), JSON.stringify({ lan_port: lanPort }));
  let now = Date.now(), key: string | null = null, writes = 0;
  const options = {
    db: ctx.db, token: ctx.config.token, port: 0, settings: { dataDir: ctx.dir },
    deviceDeps: {
      now: () => now, addresses: () => ["192.0.2.2"], name: "测试中枢",
      keys: { read: () => key, write: (value: string) => { key = value; writes++; } },
    },
  };
  let server = startServer(options);
  const lan = `http://127.0.0.1:${lanPort}`;
  const admin = (path: string, method = "GET") =>
    fetch(new URL(path, server.url), { method, headers: { Authorization: `Bearer ${ctx.config.token}` } });
  const settings = (suffix = "", method = "GET") => admin("/v1/settings/devices" + suffix, method);
  async function invite() {
    const res = await settings("/pairing", "POST");
    expect(res.status).toBe(200);
    const { uri, expires_at } = await res.json() as { uri: string; expires_at: string };
    const pairing = decodePairing(uri);
    expect(pairing.expires_at).toBe(expires_at);
    return pairing;
  }
  async function pair() {
    const invitation = await invite(), client = await DeviceClient.fromInvite(invitation, lan);
    expect((await client.pair(invitation)).status).toBe(200);
    return client;
  }
  return {
    ...ctx, lan, lanPort, admin, settings, invite, pair,
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
    expect((await hub.admin("/v1/device/hello")).status).toBe(404);
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
    const pairBody = await client.pairingBody(single);
    const results = await Promise.all([
      client.send("pair", pairBody, { ts: expired.expires_at }),
      client.send("pair", pairBody, { ts: expired.expires_at }),
    ]);
    expect(results.map(r => r.status).sort()).toEqual([200, 403]);
    expect(await (await hub.settings()).json()).toMatchObject({ pairing: null });
    expect(hub.writes).toBe(1);
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
    expect(await phone.send("sync", { cursor: 0 })).toMatchObject({ body: { changes: [] } });

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

test("v12 加密数据库迁移到 v13，保留记录并清理验证通过的备份", () => {
  const hub = setup();
  try {
    const record = fixture();
    hub.db.ingest([record]);
    hub.db.db.exec("DROP TABLE devices; DROP TABLE issued_device_ids; DROP TABLE device_changes; DROP INDEX records_device; PRAGMA user_version=12");
    hub.db.close();
    const migrated = new HubDB(hub.file, hub.config.dbKey);
    try {
      expect(migrated.db.pragma("user_version", { simple: true })).toBe(13);
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
