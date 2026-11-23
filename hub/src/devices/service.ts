import { spawnSync } from "node:child_process";
import { createHash, randomBytes, timingSafeEqual } from "node:crypto";
import { hostname, networkInterfaces } from "node:os";
import { AgentReads } from "../agent.ts";
import { agentOperation } from "../agent-device.ts";
import { AudioStore } from "../audio.ts";
import { conversationsIn, saveSummary, setSelfSummarizing, storedSummary } from "../conversations.ts";
import { InputError, type HubDB } from "../db.ts";
import { isDatabaseBusy } from "../db-busy.ts";
import { logFailure } from "../diagnostics.ts";
import { deviceKeychain, relayKeychain, type DeviceKeyStorage, type RelayKeyStorage } from "../keys.ts";
import { base64url, deviceID, identityFromRaw, invalidEnvelope, object,
  openRequest, readEnvelope, responseSealer, suite, unpaired, validateRequest, WireError } from "./envelope.ts";
import { allocateDeviceID, deviceAccess, deviceList, registerLocalDevices, removeDevice, updateDeviceRole } from "./store.ts";
import { auditOp, devicePermissionDenied, isPairingRole, operationAccess, projectionReads, projectionRoles, type DeviceRole, type PairingRole } from "./permissions.ts";
import { auditSecurity, remoteDeleteLimit, reserveRemoteDelete } from "../security-audit.ts";
import { deleteTimelineSegment } from "../timeline.ts";
import { DistillStore } from "../distill/store.ts";
import { RelayService } from "./relay.ts";
import { Projection } from "./projection.ts";
import { directProjectionBytes, flushProjectionDraft, projectionHead, relayProjectionBytes, touchProjectionDay } from "./projection-store.ts";
import { localDateString } from "../distill/requests.ts";
import { viewerOperation, viewerOperationNeedsRelayLock, type ViewerActor, type ViewerOperation } from "./viewer-operations.ts";
import { hubStatus } from "../status.ts";
import { dayMs, type RelayConfig, type RelayRequest } from "./relay-store.ts";

const invitationMs = 10 * 60_000;
const idPattern = /^[0-9A-HJKMNP-TV-Z]{26}$/;
const identityKey = "device_hub_id";
const inviteKey = "device_pairing_invite";
type Identity = Awaited<ReturnType<typeof identityFromRaw>>;
type Invitation = { code: Buffer; expires: number; relay: RelayConfig | null; role: PairingRole };
type EventSocket = { local?: boolean; lastSeq?: number; device?: string; revision?: number; authenticating?: boolean; timer?: ReturnType<typeof setTimeout> };
type Result = { status: number; body: object };
const ok = (body: object): Result => ({ status: 200, body });
const fail = (status: number, error: string): Result => ({ status, body: { error } });

class RemoteDeleteLimited extends WireError {
  constructor(readonly count: number) { super(429, remoteDeleteLimit); }
}

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
  /** server 模式下设备端口始终监听，不在无设备时关闭，绑定失败直接抛出。 */
  alwaysListen?: boolean;
  /** status.get 设备操作回调，提供与 GET /v1/status 一致的状态快照。 */
  getStatus?: (role: DeviceRole) => object;
}

export class DeviceService {
  private expiry?: ReturnType<typeof setTimeout>;
  private retry?: ReturnType<typeof setTimeout>;
  private listener?: Bun.Server<EventSocket>;
  private projectionTimer?: ReturnType<typeof setInterval>;
  private devicePoll?: ReturnType<typeof setInterval>;
  private projectionSeen?: ReturnType<typeof projectionHead>;
  private readonly subscribers = new Set<Bun.ServerWebSocket<EventSocket>>();
  private identity?: Promise<Identity | null>;
  private creatingIdentity?: Promise<Identity>;
  private stopped = false;
  private restartAfterRelayReply?: () => void;
  private viewerStatus?: () => ReturnType<typeof hubStatus>;
  private viewerHandler?: (route: ViewerOperation, actor: ViewerActor) => Promise<Response>;
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
      async (publicKey, id, payload) => {
        const identity = await this.activeIdentity();
        if (!identity) throw unpaired();
        const seal = await responseSealer(identity.keys, await suite.kem.deserializePublicKey(publicKey), id);
        return await seal(payload);
      });
  }

  setViewerHandlers(handler: NonNullable<DeviceService["viewerHandler"]>, status: () => ReturnType<typeof hubStatus>, restart?: () => void) {
    this.viewerHandler = handler;
    this.viewerStatus = status;
    this.restartAfterRelayReply = restart;
  }

  get open() { return this.listener !== undefined; }
  get lanPort() { return this.listener?.port ?? this.port; }
  private get sql() { return this.hub.db; }
  private get name() { return this.deps.name ?? computerName(); }
  private get addresses() { return [...new Set((this.deps.addresses ?? ipv4)())].map(ip => `${ip}:${this.lanPort}`); }

  private loadStoredInvite(): Invitation | null {
    const row = this.sql.prepare<[string], { v: string }>("SELECT v FROM distill_state WHERE k=?").get(inviteKey);
    if (!row) return null;
    try {
      const parsed = object(JSON.parse(row.v));
      const code = base64url(parsed?.code, 16);
      const expires = parsed?.expires;
      const role = parsed?.role;
      if (!code || typeof expires !== "number" || !Number.isFinite(expires) || !isPairingRole(role)) return null;
      const relay = parsed?.relay === null || parsed?.relay === undefined ? null : parsed.relay as RelayConfig;
      return { code, expires, relay, role };
    } catch { return null; }
  }

  private currentInvite(now = this.clock()): Invitation | null {
    const stored = this.loadStoredInvite();
    return stored && stored.expires > now ? stored : null;
  }

  start() {
    if (this.deps.alwaysListen) this.listen();
    else this.reconcile();
    this.relay.start();
    this.reconcileProjectionEvents();
    // The local device CLI writes through another connection.
    let version = this.sql.pragma("data_version", { simple: true });
    this.devicePoll = setInterval(() => {
      try {
        const next = this.sql.pragma("data_version", { simple: true });
        if (next === version) return;
        version = next;
        this.devicePermissionsChanged();
      } catch (error) { if (!isDatabaseBusy(error)) logFailure("devices.reconcile", error); }
    }, 1_000);
    this.devicePoll.unref();
  }

  private devicePermissionsChanged() {
    this.reconcile();
    this.reconcileProjectionEvents();
    this.relay.kick(true);
    this.relay.kickProjection();
  }

  private reconcileProjectionEvents() {
    for (const socket of this.subscribers) {
      if (!socket.data.device) continue;
      const access = deviceAccess(this.sql, socket.data.device);
      if (access?.role_revision === socket.data.revision) continue;
      if (access?.projection_reset) {
        const { epoch, seq } = projectionHead(this.sql);
        socket.send(JSON.stringify({ epoch, seq, urgent: true }));
      }
      socket.close(1008, "设备权限已变更");
    }
    if (!this.sql.prepare("SELECT 1 FROM devices WHERE role IN ('view','admin','agent') LIMIT 1").get()) {
      clearInterval(this.projectionTimer);
      this.projectionTimer = undefined;
      this.projectionSeen = undefined;
      return;
    }
    if (this.projectionTimer) return;
    this.projectionTimer = setInterval(() => {
      try { this.notifyProjection(); }
      catch (error) { if (!isDatabaseBusy(error)) logFailure("projection.notify", error); }
    }, 250);
    this.projectionTimer.unref();
  }

  async stop(force = false) {
    this.stopped = true;
    clearTimeout(this.expiry);
    clearTimeout(this.retry);
    clearInterval(this.projectionTimer);
    clearInterval(this.devicePoll);
    for (const socket of this.subscribers) socket.close(1001, "中枢正在关闭");
    const listener = this.listener;
    this.listener = undefined;
    await Promise.all([listener?.stop(force), this.relay.stop()]);
  }

  private reconcile() {
    if (this.stopped) return;
    try {
      if (this.deps.alwaysListen || this.currentInvite() || this.sql.prepare("SELECT 1 FROM devices WHERE local_only=0 LIMIT 1").get()) {
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
      websocket: this.events,
      fetch: (request, server) => {
        const routed = this.route(request, server);
        return routed === null ? this.lanRequest(request) : routed;
      },
    });
  }

  private async activeIdentity(): Promise<Identity | null> {
    if (this.identity) {
      const cached = await this.identity;
      if (cached && this.boundHubID() === cached.hubID) return cached;
      this.identity = undefined;
    }
    const pending = Promise.resolve().then(async () => {
      const raw = this.keys.read();
      if (raw === null) return null;
      const identity = await identityFromRaw(raw);
      return this.boundHubID() === identity.hubID ? identity : null;
    });
    this.identity = pending;
    try {
      const resolved = await pending;
      if (!resolved && this.identity === pending) this.identity = undefined;
      return resolved;
    } catch (error) {
      if (this.identity === pending) this.identity = undefined;
      throw error;
    }
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
        for (const { id } of this.sql.prepare<[], { id: string }>("SELECT id FROM devices").all()) {
          auditSecurity(this.sql, "device.remove", { target: id, code: "hub_identity_changed", now: this.clock() });
        }
        this.sql.prepare("DELETE FROM devices").run();
        this.sql.prepare("INSERT INTO distill_state(k,v) VALUES (?,json_quote(?)) ON CONFLICT(k) DO UPDATE SET v=excluded.v")
          .run(identityKey, identity.hubID);
      }
      if (raw === null) this.keys.write(hex);
    }).immediate();
    this.identity = Promise.resolve(identity);
    this.reconcileProjectionEvents();
    return identity;
  }

  /** 创建配对邀请并持久化到数据库，供本机 HTTP 接口与 CLI `pair` 共用。 */
  async createPairing(options: { role?: unknown; viewer?: unknown; relayUrl?: string; openListener?: boolean; actor?: ViewerActor } = {}): Promise<{ uri: string; expires_at: string; role: PairingRole }> {
    if (options.viewer !== undefined && options.viewer !== true && options.viewer !== false) throw new InputError("viewer 必须是布尔值");
    const role = options.role === undefined ? options.viewer === true ? "view" : "collect" : options.role;
    if (!isPairingRole(role)) throw new InputError("设备角色无效");
    const openListener = options.openListener ?? true;
    const audit = (success: boolean, code: string = role) =>
      auditSecurity(this.sql, "pair.create", { actor: options.actor?.device, ok: success, code, now: this.clock() });
    return await this.withRelayLock(options.actor, async () => {
      const identity = await this.ensureIdentity();
      if (this.stopped) throw new WireError(503, "中枢正在关闭");
      if (openListener) {
        try { this.listen(); }
        catch { audit(false, "listen_failed"); throw new WireError(409, "局域网端口无法监听"); }
      }
      if (options.relayUrl !== undefined) {
        try { await this.relay.configureDirect(options.relayUrl); }
        catch (error) {
          if (openListener) this.reconcile();
          logFailure("relay.invite", error);
          audit(false, "relay_failed");
          if (error instanceof WireError) throw error;
          throw new WireError(502, "无法配置配对信箱");
        }
      }
      const code = randomBytes(16), expires = this.clock() + (role === "admin" ? 5 * 60_000 : invitationMs);
      let relay: RelayConfig | null;
      try { relay = await this.relay.provisionInvite(expires); }
      catch (error) {
        if (openListener) this.reconcile();
        logFailure("relay.invite", error);
        audit(false, "relay_failed");
        throw new WireError(502, "无法创建配对信箱");
      }
      this.clearInvite();
      this.sql.prepare("INSERT INTO distill_state(k,v) VALUES (?,?) ON CONFLICT(k) DO UPDATE SET v=excluded.v")
        .run(inviteKey, JSON.stringify({ code: code.toString("base64url"), expires, relay, role }));
      if (openListener) {
        this.expiry = setTimeout(() => {
          void this.relay.run(() => {
            if (!this.currentInvite()) this.clearInvite();
            this.reconcile();
          }).catch(error => { if (!this.stopped) logFailure("devices.invite", error); });
        }, Math.max(0, expires - this.clock()));
        this.expiry.unref();
      }
      const expires_at = new Date(expires).toISOString();
      const payload = {
        v: 1, hub_id: identity.hubID, name: this.name, pk: identity.publicKey.toString("base64url"),
        code: code.toString("base64url"), addrs: this.addresses, expires_at, role, ...(relay ? { relay } : {}),
      };
      audit(true);
      return { uri: `tacit://pair?d=${Buffer.from(JSON.stringify(payload)).toString("base64url")}`, expires_at, role };
    });
  }

  private async withRelayLock<T>(actor: ViewerActor | undefined, run: () => T | Promise<T>) {
    return actor?.relayLocked ? await run() : await this.relay.run(run);
  }

  async settings(method: string, path: string, readJSON?: () => Promise<unknown>, loopbackEndpoint?: string, actor?: ViewerActor): Promise<Response | null> {
    const root = "/v1/settings/devices";
    if (method === "GET" && path === root) {
      const invite = this.currentInvite();
      if (!invite && this.loadStoredInvite()) {
        await this.withRelayLock(actor, () => {
          if (!this.currentInvite()) this.clearInvite();
          this.reconcile();
        });
      }
      return json(ok({
        hub_id: this.boundHubID() ?? null,
        lan: { open: this.open, port: this.lanPort, addrs: this.addresses },
        pairing: invite ? { expires_at: new Date(invite.expires).toISOString(), role: invite.role } : null,
        devices: deviceList(this.hub),
      }));
    }
    if (method === "POST" && (path === root + "/local-bootstrap" || path === root + "/local-agent")) {
      if (!loopbackEndpoint) return json(fail(403, "设备登记仅允许从 127.0.0.1 调用"));
      const bootstrap = path.endsWith("/local-bootstrap");
      const input = readJSON && object(await readJSON());
      const agentKey = base64url(input?.agent_pk, 32), macKey = bootstrap ? base64url(input?.mac_pk, 32) : null;
      if (!agentKey || (bootstrap && !macKey) || agentKey.equals(macKey ?? Buffer.alloc(0)) ||
          !input || Object.keys(input).length !== (bootstrap ? 2 : 1)) throw new InputError("需要不同的 X25519 公钥");
      return await this.relay.run(async () => {
        if (this.stopped) return json(fail(503, "中枢正在关闭"));
        const identity = await this.ensureIdentity();
        try {
          for (const key of macKey ? [agentKey, macKey] : [agentKey]) {
            await responseSealer(identity.keys, await suite.kem.deserializePublicKey(key), "");
          }
        } catch { throw new InputError("X25519 公钥无效"); }
        const ids = registerLocalDevices(this.sql, agentKey, macKey, this.clock());
        if (!ids) return json(fail(409, "公钥已属于其他设备或登记不完整"));
        this.devicePermissionsChanged();
        return json(ok({ ...ids, hub_id: identity.hubID, hub_pk: identity.publicKey.toString("base64url"), endpoint: loopbackEndpoint }));
      });
    }
    if (method === "POST" && path === root + "/pairing") {
      const input = readJSON ? object(await readJSON()) : {};
      if (!input) throw new InputError("配对邀请必须是 JSON 对象");
      try {
        const { uri, expires_at } = await this.createPairing({ role: input.role, viewer: input.viewer, openListener: true, actor });
        return json(ok({ uri, expires_at }));
      } catch (error) {
        if (error instanceof WireError) return json(fail(error.status, error.message));
        throw error;
      }
    }
    if (method === "DELETE" && path === root + "/pairing") {
      await this.withRelayLock(actor, () => {
        this.clearInvite();
        this.reconcile();
      });
      return json(ok({ ok: true }));
    }
    if (!path.startsWith(root + "/")) return null;
    const [id, suffix, extra] = path.slice(root.length + 1).split("/");
    if (!id || !deviceID.test(id) || extra !== undefined) return null;
    if (method === "PUT" && suffix === "role") {
      const input = readJSON && object(await readJSON());
      const updated = await this.relay.run(() => updateDeviceRole(this.sql, id, input && input.role, { now: this.clock() }));
      this.devicePermissionsChanged();
      return json(ok(updated));
    }
    if (method !== "DELETE" || suffix !== undefined) return null;
    return await this.relay.run(async () => {
      const removed = removeDevice(this.sql, id, { now: this.clock() });
      this.devicePermissionsChanged();
      await this.relay.flushRevocations(id);
      return json(ok(removed));
    });
  }

  private clearInvite() {
    const existing = this.loadStoredInvite();
    this.relay.revokeInvite(existing?.relay);
    this.sql.prepare("DELETE FROM distill_state WHERE k=?").run(inviteKey);
    clearTimeout(this.expiry);
  }

  /** The loopback listener checks its Host header before routing here. */
  route(request: Request, server: Bun.Server<EventSocket>, local = false) {
    const path = new URL(request.url).pathname;
    if (request.method === "POST" && path === "/v1/device") {
      // Encrypted settings operations can take up to 60 seconds to test a model.
      server.timeout(request, 75);
      return this.lanRequest(request, local);
    }
    if (request.method === "GET" && path === "/v1/device/hello") return this.lanRequest(request, local);
    if (request.method === "GET" && path === "/v1/device/events") {
      return server.upgrade(request, { data: { local } }) ? undefined : json(fail(400, "需要 WebSocket"));
    }
    return null;
  }

  readonly events: Bun.WebSocketHandler<EventSocket> = {
    maxPayloadLength: 16 * 1024,
    idleTimeout: 120,
    sendPings: true,
    open: socket => {
      socket.data.timer = setTimeout(() => socket.close(1008, "鉴权超时"), 5_000);
      socket.data.timer.unref();
      this.subscribers.add(socket);
    },
    message: (socket, message) => {
      if (socket.data.authenticating || socket.data.device || typeof message !== "string") {
        socket.close(1008, "需要鉴权信封");
        return;
      }
      socket.data.authenticating = true;
      void this.subscribe(socket, message).catch(() => socket.close(1008, "设备无法订阅"));
    },
    close: socket => {
      clearTimeout(socket.data.timer);
      this.subscribers.delete(socket);
    },
  };

  private denied(device: string, op: string) {
    auditSecurity(this.sql, "auth.denied", { actor: device, code: auditOp(op), ok: false, now: this.clock() });
    return fail(403, devicePermissionDenied);
  }

  private projectionEvent(role: DeviceRole, head: ReturnType<typeof projectionHead>) {
    if (role !== "agent") return head;
    return this.sql.prepare<[], { seq: number; urgent: number }>(`SELECT
      COALESCE(MAX(seq),0) AS seq, COALESCE(MAX(urgent_seq),0) AS urgent
      FROM projection_changes WHERE kind='project_context'`).get()!;
  }

  private async subscribe(socket: Bun.ServerWebSocket<EventSocket>, message: string) {
    const envelope = await readEnvelope(new Response(message, { headers: { "Content-Type": "application/json" } }));
    const device = envelope.device;
    if (!device) throw unpaired();
    const identity = await this.activeIdentity();
    const registered = this.sql.prepare<[string], { public_key: Buffer; local_only: number }>("SELECT public_key, local_only FROM devices WHERE id=?").get(device);
    if (!identity || !registered || (registered.local_only && !socket.data.local)) throw unpaired();
    const sender = await suite.kem.deserializePublicKey(registered.public_key);
    const input = await openRequest(envelope, identity.keys, sender);
    const { op } = validateRequest(input, this.clock());
    if (op !== "events.subscribe" || this.stopped || !this.subscribers.has(socket)) throw unpaired();
    const { access, denied } = this.sql.transaction(() => {
      if (!this.sql.prepare("INSERT OR IGNORE INTO device_nonces VALUES (?,?,?)").run(device, input!.nonce, this.clock()).changes) {
        throw invalidEnvelope();
      }
      this.touch(device, registered.public_key);
      const access = deviceAccess(this.sql, device)!;
      const denied = operationAccess(access.role, op) === "deny" ? this.denied(device, op) : null;
      return { access, denied };
    }).immediate();
    if (denied) {
      const seal = await responseSealer(identity.keys, sender, input!.nonce as string);
      socket.send(JSON.stringify(await seal(denied)));
      socket.close(1008, devicePermissionDenied);
      return;
    }
    clearTimeout(socket.data.timer);
    socket.data.device = device;
    socket.data.revision = access.role_revision;
    const head = projectionHead(this.sql);
    const { seq } = this.projectionEvent(access.role, head);
    socket.send(JSON.stringify({ seq, epoch: head.epoch, urgent: false }));
    socket.data.lastSeq = seq;
  }

  private notifyProjection() {
    const now = this.clock();
    // The distillation worker has a separate database connection.
    const today = localDateString(now);
    const day = this.sql.prepare<[], { v: string }>("SELECT v FROM distill_state WHERE k='projection_today'").get()?.v;
    if (day !== today) this.sql.transaction(() => {
      if (day) touchProjectionDay(this.sql, day);
      touchProjectionDay(this.sql, today);
      this.sql.prepare("INSERT OR REPLACE INTO distill_state(k,v) VALUES ('projection_today',?)").run(today);
    }).immediate();
    flushProjectionDraft(this.sql, now, today);
    const next = projectionHead(this.sql);
    const seen = this.projectionSeen;
    if (seen?.seq === next.seq && seen.epoch === next.epoch) return;
    this.projectionSeen = next;
    this.relay.kickProjection();
    this.reconcileProjectionEvents();
    for (const socket of this.subscribers) {
      const device = socket.data.device;
      if (!device) continue;
      const access = deviceAccess(this.sql, device);
      if (!access || access.role === "collect" || access.role_revision !== socket.data.revision) continue;
      const { seq, urgent } = this.projectionEvent(access.role, next);
      if (seq === socket.data.lastSeq && next.epoch === seen?.epoch) continue;
      socket.send(JSON.stringify({ seq, epoch: next.epoch, urgent: next.epoch !== seen?.epoch || urgent > (socket.data.lastSeq ?? 0) }));
      socket.data.lastSeq = seq;
    }
  }

  private async lanRequest(request: Request, local = false) {
    const path = new URL(request.url).pathname;
    try {
      if (request.method === "GET" && path === "/v1/device/hello") {
        const identity = await this.activeIdentity();
        if (!identity) throw unpaired();
        return json(ok({ hub_id: identity.hubID, v: 1 }));
      }
      if (request.method === "POST" && path === "/v1/device") return json(ok((await this.receive(request, undefined, local))!));
      return json(fail(404, "接口不存在"));
    } catch (error) {
      if (error instanceof WireError) return json(fail(error.status, error.message));
      if (isDatabaseBusy(error)) return json(fail(503, "数据库忙，稍后再试"));
      logFailure("devices.request", error);
      return json(fail(500, "存储操作失败"));
    }
  }

  private async receive(request: Request | Response, context?: RelayRequest, local = false) {
    const envelope = await readEnvelope(request, context !== undefined);
    const { device } = envelope;
    if (context && device !== (context.mailbox.state === "active" ? context.mailbox.device : null)) throw unpaired();
    const identity = await this.activeIdentity();
    if (!identity || this.stopped) throw unpaired();
    const registered = device === null ? null : this.sql.prepare<[string], { public_key: Buffer; local_only: number }>("SELECT public_key, local_only FROM devices WHERE id=?").get(device);
    if (device !== null && (!registered || (registered.local_only && !local))) throw unpaired();
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
    const reading = device !== null && (input?.op === "projection.pull" || input?.op === "runtime.call" || input?.op === "audio.sample.get" ||
      typeof input?.op === "string" && projectionReads.has(input.op));
    const before = reading ? projectionHead(this.sql) : null;
    const revision = reading ? deviceAccess(this.sql, device!)?.role_revision : undefined;
    const serialized = !context && (device === null || typeof input?.op === "string" && viewerOperationNeedsRelayLock(input.op));
    const result = serialized ? await this.relay.run(execute) : await execute();
    if (!result) return null;
    const sealed = await seal(result);
    if (before && result.status === 200) {
      const current = deviceAccess(this.sql, device!);
      if (!current) throw unpaired();
      if (current.role_revision !== revision) {
        const reseal = await responseSealer(identity.keys, sender!, nonce);
        return await reseal(this.denied(device!, input!.op as string));
      }
      const after = projectionHead(this.sql);
      if (before.epoch !== after.epoch || before.urgent !== after.urgent) {
        const retry = fail(409, "读取期间内容已撤下，请重试");
        const reseal = await responseSealer(identity.keys, sender!, nonce);
        return await reseal(retry);
      }
    }
    if (context && before && result.status === 200) context.projectionRead = { ...before, revision: revision! };
    if (context && input?.op === "settings.hub.put" && result.status === 200 &&
        "restarting" in result.body && result.body.restarting === true) {
      context.replyDelivered = this.restartAfterRelayReply;
    }
    return sealed;
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
    let retryRead = false;
    if (context) {
      const receipt = this.sql.prepare<[string, string, string], { request_hash: string; result: string }>(
        "SELECT request_hash, result FROM relay_receipts WHERE space=? AND up=? AND id=?",
      ).get(space!, up!, nonce);
      if (receipt) {
        if (receipt.request_hash !== hash) throw invalidEnvelope();
        if (receipt.result !== "null") return JSON.parse(receipt.result) as Result;
        retryRead = true;
      }
      if (context.mailbox.state === "pair_reply") return null;
    }
    const now = this.clock();
    const saveReceipt = (result: string) => {
      if (context) this.sql.prepare("INSERT INTO relay_receipts VALUES (?,?,?,?,?,?)")
        .run(space, up, nonce, hash, result, now);
    };
    const replaceReceipt = (result: Result) => {
      if (!context) return result;
      // A deletion or permission change can withdraw the pending reply.
      // Never recreate it with the result of an operation already in flight.
      const replaced = this.sql.prepare("UPDATE relay_receipts SET result=? WHERE space=? AND up=? AND id=?")
        .run(JSON.stringify(result), space, up, nonce);
      return replaced.changes ? result : fail(409, "回复已撤下，请刷新状态后再试");
    };
    const limitReply = (result: Result) => context && Buffer.byteLength(JSON.stringify(result)) > relayProjectionBytes
      ? fail(413, "响应超过信箱大小上限，请缩小查询范围或改用直连") : result;
    const remember = (result: Result) => {
      const limited = limitReply(result);
      if (retryRead) return replaceReceipt(limited);
      if (context) saveReceipt(JSON.stringify(limited));
      return limited;
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
      const memoryOnly = op === "audio.sample.get" || op === "runtime.call";
      const result = this.sql.transaction(() => {
        if (!retryRead && !claim()) return replay();
        try {
          const dispatched = device === null ? fail(400, "配对信封只允许 pair") : this.dispatch(device, op, body, !!context);
          if (typeof dispatched !== "function") return remember(dispatched);
          // An interrupted async mutation must never be replayed. Keep a reply
          // for the caller even if the process stops before the result is recorded.
          if (!retryRead && context) {
            if (memoryOnly) saveReceipt("null");
            else remember(fail(409, "上次操作结果未确认，请刷新状态后再试"));
          }
          return dispatched;
        } catch (error) {
          if (error instanceof InputError) return remember(fail(400, error.message));
          if (error instanceof RemoteDeleteLimited) {
            auditSecurity(this.sql, "remote.delete", { actor: device, ok: false, code: String(error.count), now });
          }
          if (error instanceof WireError) return remember(fail(error.status, error.message));
          throw error;
        }
      }).immediate();
      // Network and file settings may await. Keep SQLite transactions synchronous and
      // claim the authenticated nonce before running an async operation.
      if (typeof result === "function") {
        const reply = limitReply(await result());
        return memoryOnly ? reply : replaceReceipt(reply);
      }
      if (result?.status === 200 && (op === "devices.role.update" || op === "devices.remove")) this.devicePermissionsChanged();
      return result;
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
    const commitError = (result: Result, code: string) => this.sql.transaction(() => {
      if (!claim()) return context ? null : fail(400, "请求 nonce 已使用");
      auditSecurity(this.sql, "pair.complete", { ok: false, code, now: this.clock() });
      return remember(result);
    }).immediate();
    if (!valid) return commitError(fail(403, "配对邀请无效或已过期"), "invite_invalid");
    const platform = body.platform;
    if ((platform !== "android" && platform !== "mac") || typeof body.name !== "string" || !body.name.trim() || body.name.length > 200) {
      return commitError(fail(400, "设备名称或平台无效"), "platform_or_name_invalid");
    }
    if (platform === "android" && invite.role !== "collect") return commitError(fail(403, devicePermissionDenied), "platform_role");
    const name = body.name.trim();
    if (this.sql.prepare("SELECT 1 FROM devices WHERE public_key=? AND local_only=1").get(publicKey)) {
      return commitError(fail(409, "公钥已用于本机登记"), "key_conflict");
    }
    const device_id = allocateDeviceID(this.sql, platform);
    let provisioned: Awaited<ReturnType<RelayService["provisionDevice"]>>;
    try { provisioned = await this.relay.provisionDevice(device_id); }
    catch (error) {
      logFailure("relay.pair", error);
      return commitError(fail(503, "无法创建设备信箱，稍后再试"), "relay_failed");
    }
    const latest = this.currentInvite();
    if (!latest || !timingSafeEqual(latest.code, invite.code) || this.stopped) {
      if (provisioned) this.relay.revokeDevice(device_id);
      return commitError(fail(403, "配对邀请无效或已过期"), "invite_invalid");
    }
    const at = new Date(this.clock()).toISOString();
    try {
      const result = this.sql.transaction(() => {
        if (!claim()) return context ? null : fail(400, "请求 nonce 已使用");
        const active = this.currentInvite();
        if (!active || !timingSafeEqual(active.code, invite.code)) {
          auditSecurity(this.sql, "pair.complete", { ok: false, code: "invite_invalid", now: this.clock() });
          return remember(fail(403, "配对邀请无效或已过期"));
        }
        this.sql.prepare("DELETE FROM distill_state WHERE k=?").run(inviteKey);
        this.sql.prepare("INSERT INTO devices(id,name,platform,public_key,paired_at,last_seen,role) VALUES(?,?,?,?,?,?,?)")
          .run(device_id, name, platform, publicKey, at, at, invite.role);
        auditSecurity(this.sql, "pair.complete", { target: device_id, code: invite.role, now: this.clock() });
        if (projectionRoles(invite.role)) touchProjectionDay(this.sql, localDateString(this.clock()));
        if (provisioned) this.relay.setState(provisioned.box, "active");
        if (context) {
          this.sql.prepare("UPDATE relay_mailboxes SET state='pair_reply', device=?, token=NULL WHERE space=? AND up=?")
            .run(device_id, context.mailbox.space, context.mailbox.up);
        } else this.relay.revokeInvite(invite.relay);
        return remember(ok({ device_id, hub_id: hubID, name, role: invite.role, ...(provisioned ? { relay: provisioned.relay } : {}) }));
      }).immediate();
      if (result?.status !== 200) {
        if (provisioned) this.relay.revokeDevice(device_id);
        return result;
      }
      clearTimeout(this.expiry);
      if (projectionRoles(invite.role)) this.reconcileProjectionEvents();
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

  /** 手机自己写好的对话总结：组成和中枢按同一规则分出的那一场完全一致才采用，否则算过期，等下一次同步。 */
  private putConversations(device: string, body: Record<string, unknown>) {
    if (typeof body.summarizing !== "boolean") throw new InputError("summarizing 必须是布尔值");
    const list = body.summaries ?? [];
    if (!Array.isArray(list) || list.length > 50) throw new InputError("summaries 必须是最多 50 项的数组");
    const text = (v: unknown, max: number) => typeof v === "string" && v.trim().length > 0 && v.length <= max;
    const items = list.map(item => {
      const it = object(item) ?? {};
      const ids = it.record_ids, points = it.points ?? [];
      if (!text(it.id, 26) || !idPattern.test(it.id as string) || !Array.isArray(ids) || ids.length < 1 || ids.length > 500 ||
        !ids.every(id => typeof id === "string" && idPattern.test(id)) || !text(it.title, 40) || !text(it.summary, 400) ||
        !Array.isArray(points) || points.length > 5 || !points.every(p => typeof p === "string" && p.length <= 120)) throw new InputError("对话总结格式无效");
      return { id: it.id as string, record_ids: ids as string[], title: (it.title as string).trim(), summary: (it.summary as string).trim(),
        points: (points as string[]).map(p => p.trim()).filter(Boolean) };
    });
    const first = this.sql.prepare<[string, string], { t_start_ms: number }>("SELECT t_start_ms FROM records WHERE id=? AND device=? AND source='android.audio'");
    return this.sql.transaction(() => {
      setSelfSummarizing(this.hub, device, body.summarizing as boolean);
      const saved: string[] = [], stale: string[] = [];
      for (const item of items) {
        const row = first.get(item.record_ids[0]!, device);
        const g = row && conversationsIn(this.hub, row.t_start_ms, row.t_start_ms, device).find(g => g.record_ids.includes(item.record_ids[0]!));
        const same = g && g.record_ids.length === item.record_ids.length && g.record_ids.every(id => item.record_ids.includes(id));
        if (!g || !same || g.private) { stale.push(item.id); continue; }
        saveSummary(this.hub, g, item);
        saved.push(item.id);
      }
      return { saved, stale };
    }).immediate();
  }

  private deleteRecords(device: string, ids: string[], ownOnly: boolean, local: boolean) {
    return this.hub.deleteMany(ids, ownOnly ? device : undefined, rows => {
      if (!rows.length) return;
      if (local) { auditSecurity(this.sql, "local.delete", { actor: device, code: String(rows.length), now: this.clock() }); return; }
      // 远程设备删自己采集的记录不计入：密钥泄露时也只波及这台设备自己的数据，且手机等采集端的删除不能占用共享额度被拦下（6.11.4）。
      const requested = new Set(ids);
      const cross = new Set(rows.filter(row => row.device !== device && requested.has(row.id)).map(row => row.id));
      const count = rows.filter(row => cross.has(row.id) || (row.corrects !== null && cross.has(row.corrects))).length;
      if (count && !reserveRemoteDelete(this.sql, device, count, this.clock())) throw new RemoteDeleteLimited(count);
    });
  }

  private async runViewerOperation(route: ViewerOperation, actor: ViewerActor): Promise<Result> {
    const response = await this.viewerHandler!(route, actor);
    if (route.binary && response.ok) {
      const data = Buffer.from(await response.arrayBuffer()).toString("base64");
      return { status: response.status, body: { mime: response.headers.get("content-type"), data_base64: data } };
    }
    return { status: response.status, body: await response.json() as object };
  }

  private dispatch(device: string, op: string, body: Record<string, unknown>, fromRelay: boolean): Result | (() => Promise<Result>) {
    const access = deviceAccess(this.sql, device);
    if (!access) throw unpaired();
    const { role, projection_reset, local_only } = access;
    // Former viewers can pull the withdrawal control message, with no data or usable cursor.
    if (op === "projection.pull" && role === "collect" && projection_reset) {
      return ok({ kind: "projection.reset", epoch: projectionHead(this.sql).epoch, reset: true,
        changes: [], cursor: 0, more: false, server_time: new Date(this.clock()).toISOString() });
    }
    const permission = operationAccess(role, op);
    if (permission === "deny") return this.denied(device, op);
    if (permission === "unknown") return fail(400, "设备操作无效");
    if (op === "projection.pull" || op === "projection.ack" || projectionReads.has(op)) {
      const projection = new Projection(this.hub, this.clock());
      const max = fromRelay ? relayProjectionBytes : directProjectionBytes;
      if (op === "projection.pull") return ok(projection.pull(device, body, max, role === "agent"));
      if (op === "projection.ack") return ok(projection.ack(device, body));
      const includePrivate = body.include_private === true;
      if (includePrivate && (role !== "admin" || fromRelay)) return this.denied(device, op);
      if (body.include_private !== undefined && (typeof body.include_private !== "boolean" ||
          !["records.get", "records.list", "history.segments", "conversations.detail", "timeline.locate"].includes(op))) {
        throw new InputError("include_private 无效");
      }
      return ok(projection.read(op, body, max, includePrivate));
    }
    if (op.startsWith("agent.")) {
      if (fromRelay) return this.denied(device, op);
      return agentOperation(new AgentReads(this.hub), device, op.slice(6), body);
    }
    const route = viewerOperation(op, body);
    if (route && !route.native && this.viewerHandler) {
      return () => this.runViewerOperation(route, { device, fromRelay, relayLocked: fromRelay || viewerOperationNeedsRelayLock(op) });
    }
    const remove = (ids: string[]) => this.deleteRecords(device, ids, role !== "admin", local_only === 1);
    switch (op) {
      case "ingest":
        if (!Array.isArray(body.records) || body.records.length > 200) throw new InputError("records 必须是最多 200 条的数组");
        return ok(this.hub.ingest(body.records, device, access.platform, access.platform === "mac" && role === "admin"));
      case "delete":
        if (!Array.isArray(body.ids) || body.ids.length < 1 || body.ids.length > 100 ||
          !body.ids.every(id => typeof id === "string" && idPattern.test(id))) throw new InputError("每次删除需要 1–100 个有效记录 id");
        return ok({ deleted: remove(body.ids) });
      case "segment.delete": {
        if (typeof body.date !== "string" || typeof body.id !== "string") throw new InputError("缺少日期或段编号");
        const deleted = deleteTimelineSegment(new DistillStore(this.hub), body.date, body.id, body, remove);
        if (!deleted) return fail(404, "内容不存在");
        if (deleted.changed) return fail(409, "这段记录已更新，请刷新后再确认删除");
        return ok(deleted);
      }
      case "devices.role.update":
        try { return ok(updateDeviceRole(this.sql, body.id, body.role, { actor: device, now: this.clock() })); }
        catch (error) {
          if (error instanceof WireError && error.status === 403) return this.denied(device, op);
          throw error;
        }
      case "devices.remove": return ok(removeDevice(this.sql, body.id, { actor: device, now: this.clock() }));
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
      case "conversations.put": return ok(this.putConversations(device, body));
      case "status.get": {
        if (this.deps.getStatus) return ok(this.deps.getStatus(role));
        const snapshot = this.viewerStatus?.() ?? hubStatus(this.hub, { port: null, lanPort: this.open ? this.lanPort : null, now: this.clock(), relay: this.relay.status() });
        return ok(role === "admin" ? snapshot : { ...snapshot, database: { ...snapshot.database, file: null } });
      }
      default: return fail(400, "设备操作无效");
    }
  }
}
