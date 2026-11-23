import { spawnSync } from "node:child_process";
import { createHash, randomBytes, timingSafeEqual } from "node:crypto";
import { hostname, networkInterfaces } from "node:os";
import { AudioStore } from "../audio.ts";
import { conversationsIn, storedSummary } from "../conversations.ts";
import { InputError, type HubDB } from "../db.ts";
import { isDatabaseBusy } from "../db-busy.ts";
import { logFailure } from "../diagnostics.ts";
import { deviceKeychain, relayKeychain, type DeviceKeyStorage, type RelayKeyStorage } from "../keys.ts";
import { base32, base64url, deviceID, identityFromRaw, invalidEnvelope, object,
  openRequest, readEnvelope, responseSealer, suite, unpaired, validateRequest, WireError } from "./envelope.ts";
import { deviceList } from "./store.ts";
import { RelayService } from "./relay.ts";
import { dayMs, type RelayConfig, type RelayRequest } from "./relay-store.ts";

const invitationMs = 10 * 60_000;
const idPattern = /^[0-9A-HJKMNP-TV-Z]{26}$/;
const identityKey = "device_hub_id";
type Identity = Awaited<ReturnType<typeof identityFromRaw>>;
type Invitation = { code: Buffer; expires: number; relay: RelayConfig | null };
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
  relayKeys?: RelayKeyStorage;
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
  readonly relay: RelayService;
  private readonly audio: AudioStore;
  private readonly clock: () => number;
  private readonly keys: DeviceKeyStorage;

  constructor(private readonly hub: HubDB, private readonly port: number, private readonly deps: DeviceDeps = {}) {
    this.audio = new AudioStore(hub);
    this.clock = deps.now ?? Date.now;
    this.keys = deps.keys ?? deviceKeychain;
    this.relay = new RelayService(hub, deps.relayKeys ?? relayKeychain, this.clock,
      (request, context) => this.receive(request, context),
      async (publicKey, id, relay) => {
        const identity = await this.activeIdentity();
        if (!identity) throw unpaired();
        const seal = await responseSealer(identity.keys, await suite.kem.deserializePublicKey(publicKey), id);
        return await seal({ kind: "relay.moved", relay });
      });
  }

  get open() { return this.listener !== undefined; }
  get lanPort() { return this.port; }
  private get sql() { return this.hub.db; }
  private get name() { return this.deps.name ?? computerName(); }
  private get addresses() { return [...new Set((this.deps.addresses ?? ipv4)())].map(ip => `${ip}:${this.port}`); }
  private currentInvite(now = this.clock()) {
    return this.invite && this.invite.expires > now ? this.invite : null;
  }

  start() {
    this.reconcile();
    this.relay.start();
  }

  async stop(force = false) {
    this.stopped = true;
    clearTimeout(this.expiry);
    clearTimeout(this.retry);
    const listener = this.listener;
    this.listener = undefined;
    await Promise.all([listener?.stop(force), this.relay.stop()]);
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
        this.relay.revokeDevice();
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
        await this.relay.run(() => {
          if (!this.currentInvite()) this.clearInvite();
          this.reconcile();
        });
      }
      return json(ok({
        hub_id: this.boundHubID() ?? null,
        lan: { open: this.open, port: this.port, addrs: this.addresses },
        pairing: invite ? { expires_at: new Date(invite.expires).toISOString() } : null,
        devices: deviceList(this.hub),
      }));
    }
    if (method === "POST" && path === root + "/pairing") {
      return await this.relay.run(async () => {
        const identity = await this.ensureIdentity();
        if (this.stopped) return json(fail(503, "中枢正在关闭"));
        try { this.listen(); }
        catch { return json(fail(409, "局域网端口无法监听")); }
        const code = randomBytes(16), expires = this.clock() + invitationMs;
        let relay: RelayConfig | null;
        try { relay = await this.relay.provisionInvite(expires); }
        catch (error) {
          this.reconcile();
          logFailure("relay.invite", error);
          return json(fail(502, "无法创建配对信箱"));
        }
        this.clearInvite();
        this.invite = { code, expires, relay };
        this.expiry = setTimeout(() => {
          void this.relay.run(() => {
            if (!this.currentInvite()) this.clearInvite();
            this.reconcile();
          }).catch(error => { if (!this.stopped) logFailure("devices.invite", error); });
        }, Math.max(0, expires - this.clock()));
        this.expiry.unref();
        const expires_at = new Date(expires).toISOString();
        const payload = {
          v: 1, hub_id: identity.hubID, name: this.name, pk: identity.publicKey.toString("base64url"),
          code: code.toString("base64url"), addrs: this.addresses, expires_at, ...(relay ? { relay } : {}),
        };
        return json(ok({ uri: `tacit://pair?d=${Buffer.from(JSON.stringify(payload)).toString("base64url")}`, expires_at }));
      });
    }
    if (method !== "DELETE") return null;
    if (path === root + "/pairing") {
      await this.relay.run(() => {
        this.clearInvite();
        this.reconcile();
      });
      return json(ok({ ok: true }));
    }
    const id = path.slice(root.length + 1);
    if (!path.startsWith(root + "/") || !deviceID.test(id)) return null;
    const deleted = await this.relay.run(async () => {
      const removed = this.sql.transaction(() => {
        this.sql.prepare("DELETE FROM device_changes WHERE device=?").run(id);
        const removed = this.sql.prepare("DELETE FROM devices WHERE id=?").run(id).changes > 0;
        if (removed) this.relay.revokeDevice(id);
        return removed;
      }).immediate();
      this.reconcile();
      if (removed) await this.relay.flushRevocations(id);
      return removed;
    });
    return json(deleted ? ok({ deleted }) : fail(404, "设备不存在"));
  }

  private clearInvite() {
    this.relay.revokeInvite(this.invite?.relay);
    this.invite = null;
    clearTimeout(this.expiry);
  }

  private async lanRequest(request: Request) {
    const path = new URL(request.url).pathname;
    try {
      if (request.method === "GET" && path === "/v1/device/hello") {
        const identity = await this.activeIdentity();
        if (!identity) throw unpaired();
        return json(ok({ hub_id: identity.hubID, v: 1 }));
      }
      if (request.method === "POST" && path === "/v1/device") return json(ok((await this.receive(request))!));
      return json(fail(404, "接口不存在"));
    } catch (error) {
      if (error instanceof WireError) return json(fail(error.status, error.message));
      if (isDatabaseBusy(error)) return json(fail(503, "数据库忙，稍后再试"));
      logFailure("devices.request", error);
      return json(fail(500, "存储操作失败"));
    }
  }

  private async receive(request: Request | Response, context?: RelayRequest) {
    const envelope = await readEnvelope(request, context !== undefined);
    const { device } = envelope;
    if (context && device !== (context.mailbox.state === "active" ? context.mailbox.device : null)) throw unpaired();
    const identity = await this.activeIdentity();
    if (!identity || this.stopped) throw unpaired();
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
    if (context && nonce !== context.id) throw invalidEnvelope();
    // 先确认回复能加密，再消耗邀请或执行设备写入。
    let seal: Awaited<ReturnType<typeof responseSealer>>;
    try {
      seal = await responseSealer(identity.keys, sender ?? await suite.kem.deserializePublicKey(pairKey!), nonce);
    } catch {
      throw invalidEnvelope();
    }
    const execute = async () => {
      if (this.stopped || this.boundHubID() !== identity.hubID) throw unpaired();
      if (device !== null) this.touch(device, registered!.public_key);
      return await this.execute(input, nonce, device, pairKey, identity.hubID, context,
        context && createHash("sha256").update(envelope.enc).update(envelope.ct).digest("hex"));
    };
    // 邮件取信和设置已经在同一队列里，直连配对也在此队列里分配信箱。
    const result = device === null && !context ? await this.relay.run(execute) : await execute();
    return result && await seal(result);
  }

  private touch(device: string, publicKey: Buffer) {
    // HPKE 会让出事件循环，执行前要再次确认设备没有被移除。
    const updated = this.sql.prepare("UPDATE devices SET last_seen=? WHERE id=? AND public_key=?")
      .run(new Date(this.clock()).toISOString(), device, publicKey);
    if (!updated.changes) throw unpaired();
  }

  private async execute(input: Record<string, unknown> | null, nonce: string, device: string | null,
                        pairKey: Buffer | null, hubID: string, context?: RelayRequest, hash?: string): Promise<Result | null> {
    const space = context?.mailbox.space, up = context?.mailbox.up;
    if (context) {
      const receipt = this.sql.prepare<[string, string, string], { request_hash: string; result: string }>(
        "SELECT request_hash, result FROM relay_receipts WHERE space=? AND up=? AND id=?",
      ).get(space!, up!, nonce);
      if (receipt) {
        if (receipt.request_hash !== hash) throw invalidEnvelope();
        return JSON.parse(receipt.result) as Result;
      }
      if (context.mailbox.state === "pair_reply") return null;
    }
    const now = this.clock();
    const remember = (result: Result) => {
      if (context) this.sql.prepare("INSERT INTO relay_receipts VALUES (?,?,?,?,?,?)")
        .run(space, up, nonce, hash, JSON.stringify(result), now);
      return result;
    };
    try {
      const { op, body } = validateRequest(input, now, context ? 30 * dayMs : undefined);
      const claim = () => this.sql.prepare("INSERT OR IGNORE INTO device_nonces VALUES (?,?,?)")
        .run(device ?? "", nonce, now).changes > 0;
      const replay = () => context ? null : fail(400, "请求 nonce 已使用");
      if (device === null && op === "pair") {
        if (this.sql.prepare("SELECT 1 FROM device_nonces WHERE device='' AND nonce=?").get(nonce)) return replay();
        return await this.pair(body, pairKey!, hubID, context, claim, remember);
      }
      return this.sql.transaction(() => {
        if (!claim()) return replay();
        try {
          return remember(device === null ? fail(400, "配对信封只允许 pair") : this.dispatch(device, op, body));
        } catch (error) {
          if (error instanceof InputError) return remember(fail(400, error.message));
          throw error;
        }
      }).immediate();
    } catch (error) {
      if (error instanceof InputError || error instanceof WireError) return remember(fail(400, error.message));
      if (isDatabaseBusy(error)) throw error;
      logFailure("devices.operation", error);
      return fail(500, "存储操作失败");
    }
  }

  private async pair(body: Record<string, unknown>, publicKey: Buffer, hubID: string, context: RelayRequest | undefined,
                     claim: () => boolean, remember: (result: Result) => Result) {
    const invite = this.currentInvite(), code = base64url(body.code, 16);
    const valid = invite && code && timingSafeEqual(code, invite.code) &&
      (!context || invite.relay?.space === context.mailbox.space && invite.relay.up === context.mailbox.up);
    const commitError = (result: Result) => this.sql.transaction(() => { claim(); return remember(result); }).immediate();
    if (!valid) return commitError(fail(403, "配对邀请无效或已过期"));
    if (body.platform !== "android" || typeof body.name !== "string" || !body.name.trim() || body.name.length > 200) {
      return commitError(fail(400, "设备名称或平台无效"));
    }
    const name = body.name.trim();
    const allocate = this.sql.prepare("INSERT OR IGNORE INTO issued_device_ids VALUES(?)");
    let device_id: string;
    do { device_id = `android-${base32(randomBytes(5))}`; } while (!allocate.run(device_id).changes);
    let provisioned: Awaited<ReturnType<RelayService["provisionDevice"]>>;
    try { provisioned = await this.relay.provisionDevice(device_id); }
    catch (error) {
      logFailure("relay.pair", error);
      return commitError(fail(503, "无法创建设备信箱，稍后再试"));
    }
    if (this.currentInvite() !== invite || this.stopped) {
      if (provisioned) this.relay.revokeDevice(device_id);
      return commitError(fail(403, "配对邀请无效或已过期"));
    }
    const at = new Date(this.clock()).toISOString();
    try {
      const result = this.sql.transaction(() => {
        claim();
        this.sql.prepare("INSERT INTO devices VALUES(?,?, 'android', ?,?,?)").run(device_id, name, publicKey, at, at);
        if (provisioned) this.relay.setState(provisioned.box, "active");
        if (context) {
          this.sql.prepare("UPDATE relay_mailboxes SET state='pair_reply', device=?, token=NULL WHERE space=? AND up=?")
            .run(device_id, context.mailbox.space, context.mailbox.up);
        } else this.relay.revokeInvite(invite.relay);
        return remember(ok({ device_id, hub_id: hubID, name, ...(provisioned ? { relay: provisioned.relay } : {}) }));
      }).immediate();
      this.invite = null;
      clearTimeout(this.expiry);
      return result;
    } catch (error) {
      if (provisioned) this.relay.revokeDevice(device_id);
      throw error;
    }
  }

  /** The summaries the Mac wrote for this device's own conversations; nothing from any other device. */
  private conversations(device: string, body: Record<string, unknown>) {
    const from = body.from, to = body.to;
    if (!Number.isSafeInteger(from) || !Number.isSafeInteger(to) || (from as number) > (to as number) ||
      (to as number) - (from as number) > 32 * 86_400_000) throw new InputError("from/to 必须是不超过 32 天的毫秒时间范围");
    return conversationsIn(this.hub, from as number, to as number, device).flatMap(g => {
      const summary = storedSummary(this.hub, g);
      return summary ? [{ id: g.id, record_ids: g.record_ids, start_ms: g.start_ms, end_ms: g.end_ms, ...summary }] : [];
    });
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
      case "relay": return ok({ relay: this.relay.config(device) });
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
      case "conversations": return ok({ conversations: this.conversations(device, body) });
      default: return fail(400, "设备操作无效");
    }
  }
}
