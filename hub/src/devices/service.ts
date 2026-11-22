import { spawnSync } from "node:child_process";
import { randomBytes, timingSafeEqual } from "node:crypto";
import { hostname, networkInterfaces } from "node:os";
import { AudioStore } from "../audio.ts";
import { InputError, type HubDB } from "../db.ts";
import { isDatabaseBusy } from "../db-busy.ts";
import { logFailure } from "../diagnostics.ts";
import { deviceKeychain, type DeviceKeyStorage } from "../keys.ts";
import { base32, base64url, deviceID, identityFromRaw, invalidEnvelope, object,
  openRequest, readEnvelope, RequestWindow, responseSealer, suite, unpaired, WireError } from "./envelope.ts";
import { deviceList } from "./store.ts";

const invitationMs = 10 * 60_000;
const idPattern = /^[0-9A-HJKMNP-TV-Z]{26}$/;
const identityKey = "device_hub_id";
type Identity = Awaited<ReturnType<typeof identityFromRaw>>;
type Invitation = { code: Buffer; expires: number };
type Result = { status: number; body: object };
const ok = (body: object): Result => ({ status: 200, body });
const fail = (status: number, error: string): Result => ({ status, body: { error } });

function json(result: Result) {
  return Response.json(result.body, { status: result.status, headers: { "Cache-Control": "no-store" } });
}
function computerName() {
  const result = spawnSync("/usr/sbin/scutil", ["--get", "ComputerName"], {
    encoding: "utf8", timeout: 1_000, stdio: ["ignore", "pipe", "ignore"],
  });
  return result.stdout?.trim() || hostname();
}

function ipv4() {
  return Object.values(networkInterfaces()).flatMap(interfaces =>
    (interfaces ?? []).filter(item => item.family === "IPv4" && !item.internal).map(item => item.address));
}
function cursorOf(value: unknown): number {
  if (typeof value !== "number" || !Number.isSafeInteger(value) || value < 0) throw new InputError("cursor 必须是非负整数");
  return value;
}

export interface DeviceDeps {
  keys?: DeviceKeyStorage;
  now?: () => number;
  name?: string;
  addresses?: () => string[];
}

export class DeviceService {
  private invite: Invitation | null = null;
  private expiry?: ReturnType<typeof setTimeout>;
  private retry?: ReturnType<typeof setTimeout>;
  private listener?: Bun.Server<undefined>;
  private identity?: Promise<Identity | null>;
  private creatingIdentity?: Promise<Identity>;
  private stopped = false;
  private readonly replay = new RequestWindow();
  private readonly audio: AudioStore;
  private readonly clock: () => number;
  private readonly keys: DeviceKeyStorage;

  constructor(private readonly hub: HubDB, private readonly port: number, private readonly deps: DeviceDeps = {}) {
    this.audio = new AudioStore(hub);
    this.clock = deps.now ?? Date.now;
    this.keys = deps.keys ?? deviceKeychain;
  }

  get open() { return this.listener !== undefined; }
  get lanPort() { return this.port; }
  private get sql() { return this.hub.db; }
  private get name() { return this.deps.name ?? computerName(); }
  private get addresses() { return [...new Set((this.deps.addresses ?? ipv4)())].map(ip => `${ip}:${this.port}`); }
  private currentInvite(now = this.clock()) {
    return this.invite && this.invite.expires > now ? this.invite : null;
  }

  start() { this.reconcile(); }

  stop(force = false) {
    this.stopped = true;
    clearTimeout(this.expiry);
    clearTimeout(this.retry);
    const listener = this.listener;
    this.listener = undefined;
    return listener?.stop(force);
  }

  private reconcile() {
    if (this.stopped) return;
    try {
      if (this.currentInvite() || this.sql.prepare("SELECT 1 FROM devices LIMIT 1").get()) {
        this.listen();
      } else {
        const listener = this.listener;
        this.listener = undefined;
        void listener?.stop();
      }
      clearTimeout(this.retry);
      this.retry = undefined;
    } catch (error) {
      if (this.retry) return;
      logFailure("devices.listen", error);
      this.retry = setTimeout(() => { this.retry = undefined; this.reconcile(); }, 5_000);
      this.retry.unref();
    }
  }

  private listen() {
    this.listener ??= Bun.serve({
      hostname: "0.0.0.0", port: this.port,
      // 由 readEnvelope 按流限长，保证超限返回契约指定的 JSON 413。
      maxRequestBodySize: Number.MAX_SAFE_INTEGER,
      fetch: request => this.lanRequest(request),
    });
  }

  private activeIdentity() {
    this.identity ??= Promise.resolve().then(async () => {
      const raw = this.keys.read();
      if (raw === null) return null;
      const identity = await identityFromRaw(raw);
      return this.boundHubID() === identity.hubID ? identity : null;
    }).catch(error => { this.identity = undefined; throw error; });
    return this.identity;
  }

  private boundHubID(): string | undefined {
    return this.sql.prepare<[string], { id: string }>("SELECT json_extract(v,'$') AS id FROM distill_state WHERE k=?").get(identityKey)?.id;
  }

  private ensureIdentity() {
    this.creatingIdentity ??= this.createIdentity().finally(() => { this.creatingIdentity = undefined; });
    return this.creatingIdentity;
  }

  private async createIdentity() {
    const raw = this.keys.read();
    const hex = raw ?? randomBytes(32).toString("hex");
    const identity = await identityFromRaw(hex);
    this.sql.transaction(() => {
      if (this.boundHubID() !== identity.hubID) {
        this.sql.prepare("DELETE FROM device_changes").run();
        this.sql.prepare("DELETE FROM devices").run();
        this.sql.prepare("INSERT INTO distill_state(k,v) VALUES (?,json_quote(?)) ON CONFLICT(k) DO UPDATE SET v=excluded.v")
          .run(identityKey, identity.hubID);
      }
      if (raw === null) this.keys.write(hex);
    }).immediate();
    this.identity = Promise.resolve(identity);
    return identity;
  }

  async settings(method: string, path: string): Promise<Response | null> {
    const root = "/v1/settings/devices";
    if (method === "GET" && path === root) {
      const invite = this.currentInvite();
      if (this.invite && !invite) {
        this.invite = null;
        clearTimeout(this.expiry);
        this.reconcile();
      }
      return json(ok({
        hub_id: this.boundHubID() ?? null,
        lan: { open: this.open, port: this.port, addrs: this.addresses },
        pairing: invite ? { expires_at: new Date(invite.expires).toISOString() } : null,
        devices: deviceList(this.hub),
      }));
    }
    if (method === "POST" && path === root + "/pairing") {
      const identity = await this.ensureIdentity();
      if (this.stopped) return json(fail(503, "中枢正在关闭"));
      try { this.listen(); }
      catch { return json(fail(409, "局域网端口无法监听")); }
      const code = randomBytes(16), expires = this.clock() + invitationMs;
      this.invite = { code, expires };
      clearTimeout(this.expiry);
      this.expiry = setTimeout(() => { this.invite = null; this.reconcile(); }, invitationMs);
      this.expiry.unref();
      const expires_at = new Date(expires).toISOString();
      const payload = {
        v: 1, hub_id: identity.hubID, name: this.name, pk: identity.publicKey.toString("base64url"),
        code: code.toString("base64url"), addrs: this.addresses, expires_at,
      };
      return json(ok({ uri: `tacit://pair?d=${Buffer.from(JSON.stringify(payload)).toString("base64url")}`, expires_at }));
    }
    if (method !== "DELETE") return null;
    if (path === root + "/pairing") {
      this.invite = null;
      clearTimeout(this.expiry);
      this.reconcile();
      return json(ok({ ok: true }));
    }
    const id = path.slice(root.length + 1);
    if (!path.startsWith(root + "/") || !deviceID.test(id)) return null;
    const deleted = this.sql.transaction(() => {
      this.sql.prepare("DELETE FROM device_changes WHERE device=?").run(id);
      return this.sql.prepare("DELETE FROM devices WHERE id=?").run(id).changes > 0;
    }).immediate();
    this.reconcile();
    return json(deleted ? ok({ deleted }) : fail(404, "设备不存在"));
  }

  private async lanRequest(request: Request) {
    const path = new URL(request.url).pathname;
    try {
      if (request.method === "GET" && path === "/v1/device/hello") {
        const identity = await this.activeIdentity();
        if (!identity) throw unpaired();
        return json(ok({ hub_id: identity.hubID, v: 1 }));
      }
      if (request.method === "POST" && path === "/v1/device") return await this.receive(request);
      return json(fail(404, "接口不存在"));
    } catch (error) {
      if (error instanceof WireError) return json(fail(error.status, error.message));
      if (isDatabaseBusy(error)) return json(fail(503, "数据库忙，稍后再试"));
      logFailure("devices.request", error);
      return json(fail(500, "存储操作失败"));
    }
  }

  private async receive(request: Request) {
    const envelope = await readEnvelope(request);
    const identity = await this.activeIdentity();
    if (!identity || this.stopped) throw unpaired();
    const { device } = envelope;
    const registered = device === null ? null : this.sql.prepare<[string], { public_key: Buffer }>("SELECT public_key FROM devices WHERE id=?").get(device);
    if (device !== null && !registered) throw unpaired();
    const sender = registered && await suite.kem.deserializePublicKey(registered.public_key);
    const input = await openRequest(envelope, identity.keys, sender ?? undefined);
    const pairKey = device === null ? base64url(object(input?.body)?.device_pk, 32) : null;
    if (device === null && !pairKey) throw invalidEnvelope();
    if (!base64url(input?.nonce, 16)) {
      if (device !== null) this.touch(device, registered!.public_key);
      throw invalidEnvelope();
    }
    const nonce = input!.nonce as string;
    // 在消耗邀请前确认设备公钥能用于 HPKE，避免无效公钥导致邀请被锁死。
    let seal: Awaited<ReturnType<typeof responseSealer>>;
    try {
      seal = await responseSealer(identity.keys, sender ?? await suite.kem.deserializePublicKey(pairKey!), nonce);
    } catch {
      throw invalidEnvelope();
    }
    if (this.stopped || this.boundHubID() !== identity.hubID) throw unpaired();
    if (device !== null) this.touch(device, registered!.public_key);
    let result: Result;
    try {
      const { op, body } = this.replay.validate(input, this.clock());
      result = device === null
        ? op === "pair" ? this.pair(body, pairKey!, identity.hubID) : fail(400, "配对信封只允许 pair")
        : this.dispatch(device, op, body);
    } catch (error) {
      if (error instanceof InputError) result = fail(400, error.message);
      else if (error instanceof WireError) result = fail(error.status, error.message);
      else if (isDatabaseBusy(error)) throw error;
      else {
        logFailure("devices.operation", error);
        result = fail(500, "存储操作失败");
      }
    }
    return json(ok(await seal(result)));
  }

  private touch(device: string, publicKey: Buffer) {
    // HPKE 解封和封装上下文都会让出事件循环。再次核对设备仍在，才允许操作。
    const updated = this.sql.prepare("UPDATE devices SET last_seen=? WHERE id=? AND public_key=?")
      .run(new Date(this.clock()).toISOString(), device, publicKey);
    if (!updated.changes) throw unpaired();
  }

  private pair(body: Record<string, unknown>, publicKey: Buffer, hubID: string): Result {
    const now = this.clock(), invite = this.currentInvite(now), code = base64url(body.code, 16);
    if (!invite || !code || !timingSafeEqual(code, invite.code)) return fail(403, "配对邀请无效或已过期");
    if (body.platform !== "android" || typeof body.name !== "string" || !body.name.trim() || body.name.length > 200) {
      throw new InputError("设备名称或平台无效");
    }
    const name = body.name.trim(), at = new Date(now).toISOString();
    const device_id = this.sql.transaction(() => {
      const claim = this.sql.prepare("INSERT OR IGNORE INTO issued_device_ids VALUES(?)");
      let id: string;
      do { id = `android-${base32(randomBytes(5))}`; } while (!claim.run(id).changes);
      this.sql.prepare("INSERT INTO devices VALUES(?,?, 'android', ?,?,?)").run(id, name, publicKey, at, at);
      return id;
    }).immediate();
    this.invite = null;
    clearTimeout(this.expiry);
    return ok({ device_id, hub_id: hubID, name });
  }

  private dispatch(device: string, op: string, body: Record<string, unknown>): Result {
    switch (op) {
      case "ingest":
        if (!Array.isArray(body.records) || body.records.length > 200) throw new InputError("records 必须是最多 200 条的数组");
        return ok(this.hub.ingest(body.records, device));
      case "delete":
        if (!Array.isArray(body.ids) || body.ids.length < 1 || body.ids.length > 100 ||
          !body.ids.every(id => typeof id === "string" && idPattern.test(id))) throw new InputError("每次删除需要 1–100 个有效记录 id");
        return ok({ deleted: this.hub.deleteMany(body.ids, device) });
      case "sync": return ok(this.hub.deviceChanges(device, cursorOf(body.cursor)));
      case "sync.ack":
        this.sql.prepare("DELETE FROM device_changes WHERE device=? AND seq<=?").run(device, cursorOf(body.cursor));
        return ok({ ok: true });
      case "audio.sync": return ok(this.audio.sync(device));
      case "audio.sync.ack": return ok(this.audio.ack({ ...body, device }));
      case "audio.embeddings": return ok(this.audio.embeddings({ ...body, device }, device));
      case "audio.skipped": return ok(this.audio.skipped(body.conversation_ref, device));
      case "audio.samples": return ok(this.audio.uploadSamples(body, device));
      case "audio.lines": return ok(this.audio.lines({ ...body, device }, device));
      default: return fail(400, "设备操作无效");
    }
  }
}
