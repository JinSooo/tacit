import type { ViewerActor } from "./viewer-operations.ts";
import { randomBytes } from "node:crypto";
import type { HubDB } from "../db.ts";
import { logFailure } from "../diagnostics.ts";
import type { RelayKeyStorage } from "../keys.ts";
import { base64url, object, WireError } from "./envelope.ts";
import { auditSecurity } from "../security-audit.ts";
import { deviceAccess } from "./store.ts";
import { Projection } from "./projection.ts";
import { projectionHead, pruneProjection, relayProjectionBytes, type ChangeRow } from "./projection-store.ts";
import { dayMs, relayConfig, type Mailbox, type RelayRequest, type Space } from "./relay-store.ts";
import { proxiedFetch, proxyFor } from "../net/system-proxy.ts";

const tickMs = 5_000;
// 单条消息最大 1 MiB，经代理或慢网络时一次存取可能要十几秒（2026-11-23 线上实测 14–17 秒）。
const messageTimeoutMs = 60_000;
const pollMs = 60_000;
const inventoryMs = 5 * pollMs;
const RelayWebSocket = WebSocket as typeof WebSocket & {
  new (url: URL, options: Bun.WebSocketOptions): WebSocket;
};
const randomID = () => randomBytes(16).toString("base64url");

type Receive = (response: Response, context: RelayRequest) => Promise<object | null>;
type Seal = (publicKey: Buffer, id: string, payload: object) => Promise<object>;
type Message = { id: string; size: number };

class RelayHTTPError extends Error {
  readonly code: string;
  constructor(readonly status: number, readonly retryAfterMs?: number) {
    super("信箱请求失败");
    this.code = `HTTP_${status}`;
  }
}

function relayURL(value: unknown) {
  if (typeof value !== "string") throw new WireError(400, "需要信箱地址");
  let url: URL;
  try { url = new URL(value); }
  catch { throw new WireError(400, "信箱地址无效"); }
  if (url.username || url.password || url.search || url.hash ||
      !(url.protocol === "https:" || url.protocol === "http:" && ["localhost", "127.0.0.1"].includes(url.hostname))) {
    throw new WireError(400, "信箱地址必须使用 HTTPS，本机可使用 HTTP");
  }
  return url.href.replace(/\/+$/, "");
}

/** 这台后台对信箱的请求用途：收信轮询、清点下行、取信、确认删除、回复、撤回、投影推送、监听连接、空间管理。 */
export type RelayUsageKind = "poll" | "inventory" | "receive" | "ack" | "reply" | "withdraw" | "push" | "watch" | "space";
export interface RelayUsage {
  space: string;
  day: string;
  requests: number;
  by_kind: Partial<Record<RelayUsageKind, number>>;
  /** 今天第一次被信箱限流的时刻，以及那之前这台后台已发的请求数；其余用量来自其他设备。 */
  limited_at: string | null;
  requests_before_limit: number | null;
}
const utcDay = (ms: number) => new Date(ms).toISOString().slice(0, 10);

export class RelayService {
  private readonly sql: HubDB["db"];
  private readonly shutdown = new AbortController();
  private serial: Promise<unknown> = Promise.resolve();
  private timer?: ReturnType<typeof setInterval>;
  private lastTick = 0;
  private lastPrune = -Infinity;
  private readonly watches = new Map<string, WebSocket>();
  private readonly connected = new Map<string, boolean>();
  private readonly lastPoll = new Map<string, number>();
  private readonly lastInventory = new Map<string, number>();
  private readonly hints = new Map<string, Set<string>>();
  /** 信箱回 429（请求次数用完）后，这个空间暂停到 until，期间不发任何请求。 */
  private readonly backoff = new Map<string, { until: number; delay: number }>();
  /** 当前空间今天（按信箱的 UTC 计数日）由这台后台发出的请求次数，按用途分；每轮维护后存一次。 */
  private usage?: RelayUsage;
  private usageDirty = false;
  private purpose?: RelayUsageKind;
  private maintenance?: Promise<void>;

  constructor(private readonly hub: HubDB, private readonly keys: RelayKeyStorage, private readonly clock: () => number,
              private readonly receive: Receive, private readonly seal: Seal) {
    this.sql = hub.db;
  }

  run<T>(job: () => T | Promise<T>): Promise<T> {
    const next = this.serial.then(() => {
      if (this.shutdown.signal.aborted) throw new WireError(503, "后台服务正在关闭");
      return job();
    });
    this.serial = next.catch(() => {});
    return next;
  }

  start() {
    const now = this.clock();
    this.sql.prepare("UPDATE relay_mailboxes SET state='revoked', token=NULL WHERE state='staging' OR (state='invite' AND (expires_at IS NULL OR expires_at<=?))").run(now);
    // AI 工具身份只直连：启动时撤下任何仍挂在它名下的信箱（不再轮询、不再投递）。
    this.sql.prepare("UPDATE relay_mailboxes SET state='revoked', token=NULL WHERE state<>'revoked' AND device IN (SELECT id FROM devices WHERE role='agent')").run();
    this.lastTick = now;
    this.kick(true);
    this.timer = setInterval(() => {
      const now = this.clock();
      const woke = now - this.lastTick > tickMs * 3;
      this.lastTick = now;
      this.kick(woke);
    }, tickMs);
    this.timer.unref();
  }

  async stop() {
    clearInterval(this.timer);
    this.shutdown.abort();
    for (const space of this.watches.keys()) this.closeWatch(space);
    await this.serial;
  }

  private current() {
    return this.sql.prepare<[], Space>("SELECT * FROM relay_spaces WHERE state='current'").get();
  }

  private boxes(space: string) {
    return this.sql.prepare<[string], Mailbox>("SELECT * FROM relay_mailboxes WHERE space=?").all(space);
  }

  config(device: string) {
    const space = this.current();
    if (!space) return null;
    const box = this.sql.prepare<[string, string], Mailbox>(
      "SELECT * FROM relay_mailboxes WHERE space=? AND device=? AND state='active'",
    ).get(space.space, device);
    return box ? relayConfig(space, box) : null;
  }

  status() {
    const current = this.current();
    const retiring = this.sql.prepare<[], Space>("SELECT * FROM relay_spaces WHERE state='retiring' ORDER BY retire_at").all();
    const at = (ms: number | null) => ms === null ? null : new Date(ms).toISOString();
    const describe = (s: Space) => ({
      url: s.url, connected: this.connected.get(s.space) ?? false, last_fetch_at: at(s.last_fetch),
      // 429 后的暂停截止时刻；界面据此说“限流，几点再试”，不把限流说成连不上。
      paused_until: at(this.pausedUntil(s.space) || null),
      used_bytes: s.used_bytes, unprocessable: s.discarded,
      devices: this.boxes(s.space).filter(b => b.state === "active" && b.device)
        .map(b => ({ device: b.device!, pending: b.pending })),
    });
    const usage = current ? this.loadUsage(current.space) : null;
    return {
      mode: current ? "custom" as const : "off" as const,
      usage: usage && { day: usage.day, requests: usage.requests, by_kind: { ...usage.by_kind },
        limited_at: usage.limited_at, requests_before_limit: usage.requests_before_limit },
      ...(current ? describe(current) : {
        url: null, connected: false, last_fetch_at: null, used_bytes: null, unprocessable: 0, devices: [],
      }),
      retiring: retiring.map(s => ({ ...describe(s), retire_at: at(s.retire_at) })),
    };
  }

  async settings(method: string, path: string, readJSON: () => Promise<unknown>, actor?: ViewerActor) {
    const root = "/v1/settings/relay";
    const reply = (body: object, status = 200) => Response.json(body, { status, headers: { "Cache-Control": "no-store" } });
    if (method === "GET" && path === root) return reply(this.status());
    const test = method === "POST" && path === root + "/test";
    if (!test && !(method === "PUT" && path === root)) return null;
    try {
      const input = object(await readJSON());
      if (test) return reply(await this.hello(relayURL(input?.url)));
      if (input?.mode !== "off" && input?.mode !== "custom") throw new WireError(400, "信箱模式无效");
      const url = input.mode === "off" ? null : relayURL(input.url);
      if (url !== null && input.code !== undefined && typeof input.code !== "string") throw new WireError(400, "开通码无效");
      const configure = async () => {
        try { await this.configure(url, url === null ? undefined : input.code as string | undefined, actor?.device); }
        catch (error) {
          auditSecurity(this.sql, "relay.change", { actor: actor?.device, ok: false, code: "configure_failed", now: this.clock() });
          throw error;
        }
      };
      if (actor?.relayLocked) await configure();
      else await this.run(configure);
      return reply(this.status());
    } catch (error) {
      if (error instanceof WireError) return reply({ error: error.message }, error.status);
      if (!(error instanceof RelayHTTPError) && !(error instanceof TypeError) && !(error instanceof DOMException)) throw error;
      logFailure("relay.settings", error);
      const status = error instanceof RelayHTTPError && [403, 429, 507].includes(error.status) ? error.status : 502;
      return reply({ error: "信箱操作失败" }, status);
    }
  }

  private async request(url: string, method: string, token?: string, body?: unknown, timeout = tickMs) {
    const response = await proxiedFetch(url, {
      method, redirect: "error", signal: AbortSignal.any([this.shutdown.signal, AbortSignal.timeout(timeout)]),
      headers: {
        ...(token === undefined ? {} : { Authorization: `Bearer ${token}` }),
        ...(body === undefined ? {} : { "Content-Type": "application/json" }),
      },
      body: body === undefined ? undefined : typeof body === "string" ? body : JSON.stringify(body),
    });
    if (!response.ok) {
      void response.body?.cancel().catch(() => {});
      const seconds = Number(response.headers.get("retry-after"));
      throw new RelayHTTPError(response.status, Number.isFinite(seconds) && seconds > 0 ? seconds * 1000 : undefined);
    }
    return response;
  }

  private async hello(url: string) {
    let response: Response;
    try { response = await this.request(url + "/v1/hello", "GET"); }
    catch (error) {
      // 能连上但没有 hello 接口（普通网站多是 404）说明地址不是信箱，不算连不上。
      if (error instanceof RelayHTTPError && error.status >= 400 && error.status < 500 && error.status !== 429) {
        throw new WireError(400, "地址不是 Tacit 信箱");
      }
      throw error;
    }
    const hello = object(await response.json().catch(() => null));
    const limits = object(hello?.limits);
    if (hello?.tacit_relay !== 1 || !limits || !["space_bytes", "message_bytes", "retention_days"].every(key =>
      typeof limits[key] === "number" && Number.isSafeInteger(limits[key]) && limits[key] > 0)) {
      throw new WireError(400, "地址不是 Tacit 信箱");
    }
    return { tacit_relay: 1, limits: {
      space_bytes: limits.space_bytes, message_bytes: limits.message_bytes, retention_days: limits.retention_days,
    } };
  }

  private pausedUntil(space: string) {
    const until = this.backoff.get(space)?.until ?? 0;
    return until > this.clock() ? until : 0;
  }

  private loadUsage(space: string): RelayUsage {
    const day = utcDay(this.clock());
    if (this.usage?.day === day && this.usage.space === space) return this.usage;
    let saved: RelayUsage | undefined;
    try {
      const row = this.sql.prepare<[], { v: string }>("SELECT v FROM distill_state WHERE k='relay_usage'").get();
      saved = row ? JSON.parse(row.v) as RelayUsage : undefined;
    } catch { saved = undefined; }
    this.usage = saved?.day === day && saved.space === space && typeof saved.requests === "number" ? saved
      : { space, day, requests: 0, by_kind: {}, limited_at: null, requests_before_limit: null };
    return this.usage;
  }

  private countRequest(space: string, kind: RelayUsageKind) {
    const usage = this.loadUsage(space);
    usage.requests++;
    usage.by_kind[kind] = (usage.by_kind[kind] ?? 0) + 1;
    this.usageDirty = true;
  }

  private saveUsage() {
    if (!this.usageDirty || !this.usage) return;
    this.sql.prepare("INSERT INTO distill_state(k,v) VALUES ('relay_usage',?) ON CONFLICT(k) DO UPDATE SET v=excluded.v")
      .run(JSON.stringify(this.usage));
    this.usageDirty = false;
  }

  /** 由路径推出这次请求做什么；投影推送期间按推送计。 */
  private requestKind(space: Space, method: string, path: string): RelayUsageKind {
    if (this.purpose) return this.purpose;
    const box = /^\/boxes\/([^/?]+)\/messages(\/[^/?]+)?/.exec(path);
    if (!box) return "space";
    const up = this.sql.prepare("SELECT 1 FROM relay_mailboxes WHERE space=? AND up=?").get(space.space, box[1]!) !== null;
    if (!box[2]) return up ? "poll" : "inventory";
    if (up) return method === "DELETE" ? "ack" : "receive";
    return method === "PUT" ? "reply" : "withdraw";
  }

  private async spaceRequest(space: Space, token: string, method: string, path: string, body?: unknown) {
    // 暂停期间不碰网络：被限流后每轮重试只会继续耗请求次数（2026-11-24 发现每 5 秒一次、每分钟约 26 条 429）。
    if (this.pausedUntil(space.space)) throw new RelayHTTPError(429);
    if (space.state === "current") this.countRequest(space.space, this.requestKind(space, method, path));
    try {
      const timeout = /\/messages\/[^/?]+$/.test(path) ? messageTimeoutMs : tickMs;
      const response = await this.request(`${space.url}/v1/spaces/${space.space}${path}`, method, token, body, timeout);
      this.connected.set(space.space, true);
      this.backoff.delete(space.space);
      return response;
    } catch (error) {
      this.connected.set(space.space, error instanceof RelayHTTPError && ![401, 403].includes(error.status));
      if (error instanceof RelayHTTPError && error.status === 429) {
        const usage = space.state === "current" ? this.loadUsage(space.space) : undefined;
        if (usage && usage.limited_at === null) {
          usage.limited_at = new Date(this.clock()).toISOString();
          usage.requests_before_limit = usage.requests - 1;
          this.usageDirty = true;
        }
        // 从 1 分钟起翻倍，最多 1 小时；信箱给了 Retry-After 时按它等，最多 6 小时。
        const delay = Math.min(Math.max(60_000, (this.backoff.get(space.space)?.delay ?? 30_000) * 2), 60 * 60_000);
        const wait = Math.max(delay, Math.min(error.retryAfterMs ?? 0, 6 * 60 * 60_000));
        this.backoff.set(space.space, { until: this.clock() + wait, delay });
      }
      throw error;
    }
  }

  private async spaceJSON<T>(space: Space, token: string, method: string, path: string, body?: unknown): Promise<T> {
    const response = await this.spaceRequest(space, token, method, path, body);
    return await response.json() as T;
  }

  private async send(space: Space, token: string, method: string, path: string, body?: unknown) {
    const response = await this.spaceRequest(space, token, method, path, body);
    await response.body?.cancel();
  }

  private async remove(space: Space, token: string, path: string, ignore: number) {
    try { await this.send(space, token, "DELETE", path); }
    catch (error) { if (!(error instanceof RelayHTTPError) || error.status !== ignore) throw error; }
  }

  private token(space: Space) {
    const token = this.keys.read(space.space);
    if (!token) throw new Error("找不到信箱密钥");
    return token;
  }

  /** 在调用方已持有 relay.run 队列时按地址配置信箱（供 CLI pair --relay 复用）。 */
  async configureDirect(url: string) {
    await this.configure(relayURL(url));
  }

  private async configure(url: string | null, code?: string, actor?: string) {
    const old = this.current();
    if (url !== null) await this.hello(url);
    if ((old?.url ?? null) === url) return;
    const devices = this.sql.prepare<[], { id: string; public_key: Buffer }>("SELECT id, public_key FROM devices WHERE local_only=0 AND role<>'agent'").all();
    let next: Space | null = null;
    const configs = new Map<string, ReturnType<typeof relayConfig>>();
    try {
      if (url !== null) {
        const response = await this.request(url + "/v1/spaces", "POST", undefined, { code });
        const created = object(await response.json());
        if (!base64url(created?.space, 16) || !base64url(created?.token, 32)) throw new RelayHTTPError(502);
        const id = created!.space as string, token = created!.token as string;
        try {
          this.sql.prepare("INSERT INTO relay_spaces(space,url,state) VALUES (?,?,'staging')").run(id, url);
          this.keys.write(id, token);
        } catch (error) {
          await this.request(`${url}/v1/spaces/${id}`, "DELETE", token)
            .then(response => response.body?.cancel()).catch(cause => logFailure("relay.rollback", cause));
          throw error;
        }
        next = this.sql.prepare<[string], Space>("SELECT * FROM relay_spaces WHERE space=?").get(id)!;
        for (const device of devices) configs.set(device.id, relayConfig(next, await this.provision(next, device.id)));
      }
      const moves: { box: Mailbox; id: string; body: string }[] = [];
      if (old) {
        for (const box of this.boxes(old.space)) {
          if (box.state !== "active" || !box.device) continue;
          const device = devices.find(d => d.id === box.device);
          if (!device) continue;
          const id = randomID();
          const body = await this.seal(device.public_key, id, { kind: "relay.moved", relay: configs.get(device.id) ?? null });
          moves.push({ box, id, body: JSON.stringify(body) });
        }
      }
      const deadline = this.clock() + 7 * dayMs;
      this.sql.transaction(() => {
        if (old) this.sql.prepare("UPDATE relay_spaces SET state='retiring', retire_at=? WHERE space=?").run(deadline, old.space);
        if (next) {
          this.sql.prepare("UPDATE relay_spaces SET state='current' WHERE space=?").run(next.space);
          this.sql.prepare("UPDATE relay_mailboxes SET state='active' WHERE space=?").run(next.space);
        }
        auditSecurity(this.sql, "relay.change", { actor, code: next ? "custom" : "off", now: this.clock() });
        for (const { box, id, body } of moves) {
          this.sql.prepare("UPDATE relay_mailboxes SET move_id=?, move_body=? WHERE space=? AND up=?")
            .run(id, body, box.space, box.up);
        }
      }).immediate();
      if (next) this.connected.set(next.space, true);
    } finally {
      this.kick(true);
    }
  }

  private async provision(space: Space, device: string | null, expiry?: number): Promise<Mailbox> {
    const up = randomID(), down = randomID(), token = this.token(space);
    this.sql.prepare("INSERT INTO relay_mailboxes(space,up,down,device,expires_at,state) VALUES (?,?,?,?,?,'staging')")
      .run(space.space, up, down, device, expiry ?? null);
    try {
      await this.send(space, token, "POST", "/boxes", { boxes: [up, down] });
      const created = await this.spaceJSON<{ id: string; token: string }>(space, token, "POST", "/tokens", {
        write: [up], read: [down], expires_at: expiry === undefined ? undefined : new Date(expiry).toISOString(),
      });
      if (!/^[0-9a-f]{16}$/.test(created?.id) || !base64url(created?.token, 32)) throw new RelayHTTPError(502);
      this.sql.prepare("UPDATE relay_mailboxes SET token_id=?, token=? WHERE space=? AND up=?")
        .run(created.id, created.token, space.space, up);
      return this.sql.prepare<[string, string], Mailbox>("SELECT * FROM relay_mailboxes WHERE space=? AND up=?")
        .get(space.space, up)!;
    } catch (error) {
      this.sql.prepare("UPDATE relay_mailboxes SET state='revoked' WHERE space=? AND up=?").run(space.space, up);
      this.kick();
      throw error;
    }
  }

  async provisionInvite(expiry: number) {
    const space = this.current();
    if (!space) return null;
    const box = await this.provision(space, null, expiry);
    this.setState(box, "invite");
    this.kick(true);
    return relayConfig(space, box);
  }

  async provisionDevice(device: string) {
    const space = this.current();
    if (!space) return null;
    const box = await this.provision(space, device);
    return { box, relay: relayConfig(space, box) };
  }

  setState(box: Pick<Mailbox, "space" | "up">, state: Mailbox["state"]) {
    this.sql.prepare("UPDATE relay_mailboxes SET state=? WHERE space=? AND up=?").run(state, box.space, box.up);
  }

  retainPairReply(box: Pick<Mailbox, "space" | "up">, device: string) {
    // Keep the temporary mailbox addressable until the invitation's original expiry.
    this.sql.prepare("UPDATE relay_mailboxes SET state='pair_reply', device=?, token=NULL WHERE space=? AND up=? AND state='invite'")
      .run(device, box.space, box.up);
  }

  revokeInvite(invite: ReturnType<typeof relayConfig> | null | undefined) {
    if (invite) {
      this.sql.prepare("UPDATE relay_mailboxes SET state='revoked', token=NULL WHERE space=? AND up=? AND state='invite'")
        .run(invite.space, invite.up);
      this.kick(true);
    }
  }

  revokeDevice(device?: string) {
    this.sql.prepare(`DELETE FROM relay_receipts WHERE EXISTS (
      SELECT 1 FROM relay_mailboxes b WHERE b.space=relay_receipts.space AND b.up=relay_receipts.up
        AND b.device IS NOT NULL AND (? IS NULL OR b.device=?)
    )`).run(device ?? null, device ?? null);
    this.sql.prepare(`UPDATE relay_mailboxes SET state='revoked', token=NULL, move_body=NULL, move_id=NULL
      WHERE device IS NOT NULL AND (? IS NULL OR device=?)`).run(device ?? null, device ?? null);
    this.kick();
  }

  async flushRevocations(device: string) {
    const spaces = this.sql.prepare<[string], Space>(`
      SELECT * FROM relay_spaces s WHERE EXISTS (
        SELECT 1 FROM relay_mailboxes b WHERE b.space=s.space AND b.device=? AND b.state='revoked'
      )
    `).all(device);
    for (const space of spaces) {
      try {
        const token = this.token(space);
        for (const box of this.boxes(space.space)) {
          if (box.device === device && box.state === "revoked") await this.deleteBoxes(space, token, box);
        }
      } catch (error) {
        if (!this.shutdown.signal.aborted) logFailure("relay.revoke", error);
      }
    }
  }

  private openWatch(space: Space, token: string) {
    if (this.watches.has(space.space)) return;
    const url = new URL(`${space.url}/v1/spaces/${space.space}/watch`);
    url.protocol = url.protocol === "https:" ? "wss:" : "ws:";
    if (space.state === "current") this.countRequest(space.space, "watch");
    const socket = new RelayWebSocket(url, { proxy: proxyFor(url), headers: { Authorization: `Bearer ${token}` } });
    this.watches.set(space.space, socket);
    socket.onopen = () => {
      this.connected.set(space.space, true);
      this.kick(true, space.space);
    };
    socket.onmessage = event => {
      if (typeof event.data !== "string" || event.data.length > 100) return;
      try {
        const box = object(JSON.parse(event.data))?.box;
        if (typeof box === "string" && base64url(box, 16) &&
            this.sql.prepare("SELECT 1 FROM relay_mailboxes WHERE space=? AND up=? AND state IN ('active','invite','pair_reply')").get(space.space, box)) {
          this.kick(false, space.space, box);
        }
      } catch { /* 信箱通知只是取信提示。 */ }
    };
    socket.onclose = socket.onerror = () => {
      if (this.watches.get(space.space) === socket) this.closeWatch(space.space);
    };
    const deadline = setTimeout(() => {
      if (this.watches.get(space.space) === socket && socket.readyState === WebSocket.CONNECTING) this.closeWatch(space.space);
    }, tickMs);
    deadline.unref();
  }

  private closeWatch(space: string) {
    const socket = this.watches.get(space);
    this.watches.delete(space);
    if (!socket) return;
    socket.onopen = socket.onmessage = socket.onclose = socket.onerror = null;
    socket.close();
  }

  private full = false;
  private projectionPending = false;
  kickProjection() {
    this.projectionPending = true;
    return this.kick();
  }
  kick(full = false, space?: string, box?: string) {
    if (this.shutdown.signal.aborted) return Promise.resolve();
    if (space) {
      const boxes = this.hints.get(space) ?? new Set<string>();
      boxes.add(full ? "" : box!);
      this.hints.set(space, boxes);
    } else this.full ||= full;
    if (!this.maintenance) {
      this.maintenance = this.run(async () => {
        const all = this.full;
        const hints = new Map(this.hints);
        this.full = false;
        this.projectionPending = false;
        this.hints.clear();
        try { await this.round(all, hints); } finally { this.saveUsage(); }
      }).catch(error => {
        if (!this.shutdown.signal.aborted) logFailure("relay.poll", error);
      }).finally(() => {
        this.maintenance = undefined;
        if (this.full || this.hints.size || this.projectionPending) this.kick();
      });
    }
    return this.maintenance;
  }

  private async round(full: boolean, hints: Map<string, Set<string>>) {
    const now = this.clock();
    if (now - this.lastPrune >= pollMs) {
      this.sql.prepare("DELETE FROM device_nonces WHERE seen_at<?").run(now - 31 * dayMs);
      this.sql.prepare("DELETE FROM relay_receipts WHERE seen_at<?").run(now - 31 * dayMs);
      this.sql.prepare("DELETE FROM relay_projection_replies WHERE created_at<?").run(now - 30 * dayMs);
      pruneProjection(this.sql, now);
      this.lastPrune = now;
    }
    const spaces = this.sql.prepare<[], Space>("SELECT * FROM relay_spaces").all();
    for (const space of spaces) {
      if (this.shutdown.signal.aborted) return;
      const id = space.space;
      if (this.pausedUntil(id)) continue;
      const notify = hints.get(id);
      const due = now - (this.lastPoll.get(id) ?? -Infinity) >= pollMs;
      const inventory = now - (this.lastInventory.get(id) ?? -Infinity) >= inventoryMs;
      const haveProjection = this.sql.prepare(`SELECT 1 FROM relay_mailboxes b JOIN devices d ON d.id=b.device
        WHERE b.space=? AND b.state='active' AND (d.role IN ('view','admin') OR (d.projection_reset=1 AND (b.role_revision<>d.role_revision OR b.push_kind IS NOT 'projection.reset'))) LIMIT 1`).get(id);
      if (!(full || notify || due || inventory || haveProjection)) continue;
      if (due) this.lastPoll.set(id, now);
      if (inventory) this.lastInventory.set(id, now);
      try {
        if (space.state === "staging" || space.retire_at !== null && now >= space.retire_at) {
          if (full || due) await this.deleteSpace(space);
          continue;
        }
        const token = this.token(space);
        if (haveProjection) {
          this.purpose = "push";
          try { await this.pushProjections(space, token); } finally { this.purpose = undefined; }
        }
        const watched = this.watches.get(id)?.readyState === WebSocket.OPEN;
        if (due || full) this.openWatch(space, token);
        const scan = full || notify?.has("") || due && !watched || inventory;
        if (scan || due || notify) {
          const selected = !scan && !due ? notify : undefined;
          const read = await this.pull(space, token, scan, inventory || full, selected);
          if (read) this.sql.prepare("UPDATE relay_spaces SET last_fetch=? WHERE space=?").run(this.clock(), id);
        }
      } catch (error) {
        if (this.shutdown.signal.aborted) return;
        this.connected.set(id, false);
        logFailure("relay.space", error);
      }
    }
  }

  private async pushProjections(space: Space, token: string) {
    const boxes = this.sql.prepare<[string], Mailbox & {
      public_key: Buffer; last_seen: string; projection_cursor: number; projection_epoch: number; projection_reset: number; device_revision: number;
    }>(`SELECT b.*,d.public_key,d.last_seen,d.projection_cursor,d.projection_epoch,d.projection_reset,d.role_revision AS device_revision
      FROM relay_mailboxes b JOIN devices d ON d.id=b.device
      WHERE b.space=? AND b.state='active' AND (d.role IN ('view','admin') OR (d.projection_reset=1 AND (b.role_revision<>d.role_revision OR b.push_kind IS NOT 'projection.reset')))`).all(space.space);
    const recovery = this.sql.prepare<[], { v: string }>("SELECT v FROM distill_state WHERE k='projection_relay_purge_epoch'").get();
    const recoverEpoch = Number(recovery?.v ?? 0);
    for (const box of boxes) {
      const head = projectionHead(this.sql), now = this.clock();
      const down = `/boxes/${box.down}/messages/`;
      const clear = async (id: string) => { await this.remove(space, token, down + id, 404); };
      const current = () => deviceAccess(this.sql, box.device!)?.role_revision === box.device_revision;
      if (!current()) continue;
      if (recoverEpoch > (box.projection_purged_epoch ?? 0) || box.role_revision !== box.device_revision) {
        // A copied older DB cannot know about messages sent after its snapshot.
        if (recoverEpoch > (box.projection_purged_epoch ?? 0)) {
          for await (const message of this.messages(space, token, box.down)) await clear(message.id);
        } else {
          if (box.push_msg_id) await clear(box.push_msg_id);
          const prior = this.sql.prepare<[string, string], { id: string }>(
            "SELECT id FROM relay_projection_replies WHERE space=? AND up=?").all(box.space, box.up);
          for (const { id } of prior) await clear(id);
        }
        if (!current()) { this.projectionPending = true; continue; }
        this.sql.prepare("DELETE FROM relay_projection_replies WHERE space=? AND up=?").run(box.space, box.up);
        this.sql.prepare(`UPDATE relay_mailboxes SET projection_purged_epoch=?,role_revision=?,push_msg_id=NULL,push_epoch=NULL,push_seq=NULL,push_at=NULL,push_kind=NULL
          WHERE space=? AND up=?`).run(recoverEpoch, box.device_revision, box.space, box.up);
        box.push_msg_id = box.push_epoch = box.push_seq = box.push_at = box.push_kind = null;
      }
      const stale = this.sql.prepare<[string, string, number, number], { id: string }>(
        "SELECT id FROM relay_projection_replies WHERE space=? AND up=? AND (epoch<>? OR seq<?)")
        .all(box.space, box.up, head.epoch, head.urgent);
      for (const { id } of stale) {
        await clear(id);
        this.sql.prepare("DELETE FROM relay_projection_replies WHERE space=? AND up=? AND id=?").run(box.space, box.up, id);
      }

      const cursor = box.projection_epoch === head.epoch ? box.projection_cursor : 0;
      const sent = box.push_epoch === head.epoch ? box.push_seq ?? 0 : 0;
      const retiring = space.state !== "current";
      const offline = now - Date.parse(box.last_seen) > dayMs;
      const expireDelta = offline && box.push_kind === "projection.delta" && !!box.push_msg_id && cursor < sent;
      const reset = box.projection_reset === 1 || box.projection_epoch > 0 && (box.projection_epoch !== head.epoch || cursor > head.seq || cursor > 0 && cursor < head.floor);
      const urgent = head.urgent > Math.max(cursor, sent);
      const revoke = box.push_msg_id && (retiring || box.push_epoch !== head.epoch || urgent || cursor >= sent);
      if (revoke) {
        await clear(box.push_msg_id!);
        this.sql.prepare("UPDATE relay_mailboxes SET push_msg_id=NULL WHERE space=? AND up=?").run(box.space, box.up);
      }
      if (retiring && !box.projection_reset) continue;
      if (!expireDelta && (reset ? box.push_epoch === head.epoch && box.push_seq === head.seq : head.seq <= Math.max(cursor, sent))) continue;
      if (!urgent && !reset && !expireDelta && now - (box.push_at ?? -Infinity) < 5 * 60_000) continue;

      let payload: { kind: string } & Record<string, unknown>;
      if (reset) payload = { kind: "projection.reset", epoch: head.epoch };
      else if (urgent) {
        const rows = this.sql.prepare<[number], ChangeRow>(`SELECT kind,entity_id FROM projection_changes
          WHERE urgent_seq>0 AND urgent_seq>? ORDER BY urgent_seq LIMIT 1001`).all(cursor);
        payload = rows.length > 1000 ? { kind: "projection.reset", epoch: head.epoch } :
          { kind: "projection.invalidate", epoch: head.epoch, to_seq: head.seq, items: rows.map(row => ({ kind: row.kind, id: row.entity_id })) };
      } else {
        const hint = { kind: "projection.hint", epoch: head.epoch, latest_seq: head.seq };
        if (offline || cursor === 0) payload = hint;
        else {
          const page = this.sql.transaction(() => new Projection(this.hub, now)
            .pull(box.device!, { cursor, epoch: head.epoch }, relayProjectionBytes)).immediate();
          payload = page.reset ? { kind: "projection.reset", epoch: page.epoch } : page.more ? hint :
            { kind: "projection.delta", epoch: page.epoch, from_seq: cursor, to_seq: page.cursor, changes: page.changes, more: page.more };
        }
      }
      if (Buffer.byteLength(JSON.stringify(payload)) > relayProjectionBytes) payload = { kind: "projection.reset", epoch: head.epoch };

      const id = randomID();
      const sealed = await this.seal(box.public_key, id, payload);
      const beforePut = projectionHead(this.sql);
      if (!current() || head.epoch !== beforePut.epoch || head.urgent !== beforePut.urgent) { this.projectionPending = true; continue; }
      if (box.push_msg_id && !revoke) await clear(box.push_msg_id);
      const afterDelete = projectionHead(this.sql);
      if (!current() || head.epoch !== afterDelete.epoch || head.urgent !== afterDelete.urgent) { this.projectionPending = true; continue; }
      // Persist the ID first: crash or uncertain PUT can be retried without leaving an untracked message.
      this.sql.prepare("UPDATE relay_mailboxes SET push_msg_id=?,push_seq=NULL,push_epoch=NULL,push_kind=NULL WHERE space=? AND up=?")
        .run(id, box.space, box.up);
      await this.send(space, token, "PUT", down + id, sealed);
      if (!current()) {
        await clear(id);
        this.projectionPending = true;
        continue;
      }
      this.sql.prepare("UPDATE relay_mailboxes SET push_seq=?,push_epoch=?,push_at=?,push_kind=? WHERE space=? AND up=?")
        .run(head.seq, head.epoch, now, payload.kind, box.space, box.up);
      const afterPut = projectionHead(this.sql);
      if (head.epoch !== afterPut.epoch || head.urgent !== afterPut.urgent) this.projectionPending = true;
    }
  }

  private async deleteSpace(space: Space) {
    const id = space.space;
    this.closeWatch(id);
    if (!space.remote_deleted) {
      const token = this.keys.read(id);
      if (token) await this.remove(space, token, "", 401);
      else if (space.state !== "staging") throw new Error("找不到信箱密钥");
      this.sql.prepare("UPDATE relay_spaces SET remote_deleted=1 WHERE space=?").run(id);
    }
    this.keys.remove(id);
    this.sql.transaction(() => {
      this.sql.prepare("DELETE FROM relay_receipts WHERE space=?").run(id);
      this.sql.prepare("DELETE FROM relay_mailboxes WHERE space=?").run(id);
      this.sql.prepare("DELETE FROM relay_spaces WHERE space=?").run(id);
    }).immediate();
    this.connected.delete(id);
    this.lastPoll.delete(id);
    this.lastInventory.delete(id);
  }

  private async deleteBoxes(space: Space, token: string, box: Mailbox) {
    if (box.token_id) await this.remove(space, token, `/tokens/${box.token_id}`, 404);
    await this.remove(space, token, `/boxes/${box.up}`, 404);
    await this.remove(space, token, `/boxes/${box.down}`, 404);
    this.sql.transaction(() => {
      this.sql.prepare("DELETE FROM relay_receipts WHERE space=? AND up=?").run(box.space, box.up);
      this.sql.prepare("DELETE FROM relay_mailboxes WHERE space=? AND up=?").run(box.space, box.up);
      this.sql.prepare("DELETE FROM relay_projection_replies WHERE space=? AND up=?").run(box.space, box.up);
    }).immediate();
  }

  private async *messages(space: Space, token: string, box: string) {
    let cursor: string | null = "0";
    do {
      const page: { messages: Message[]; next: string | null } = await this.spaceJSON(
        space, token, "GET", `/boxes/${box}/messages?after=${cursor}`,
      );
      if (!Array.isArray(page?.messages) || !page.messages.every(m => base64url(m?.id, 16) && Number.isSafeInteger(m.size) && m.size >= 0) ||
          page.next !== null && (typeof page.next !== "string" || !/^\d{1,15}$/.test(page.next) || Number(page.next) <= Number(cursor))) {
        throw new RelayHTTPError(502);
      }
      yield* page.messages;
      cursor = page.next;
    } while (cursor !== null);
  }

  private async pull(space: Space, token: string, scan: boolean, inventory: boolean, hints?: Set<string>) {
    const boxes = this.boxes(space.space).filter(box => !hints || hints.has(box.up));
    let bytes = 0;
    let completeInventory = true;
    let read = false;
    if (scan && !boxes.length) {
      // 空空间也要用空间令牌访问，否则信箱不会更新空间的活跃时间。已知不存在的信箱返回 404。
      try { await this.spaceJSON(space, token, "GET", `/boxes/${randomID()}/messages`); }
      catch (error) { if (!(error instanceof RelayHTTPError) || error.status !== 404) throw error; }
      read = true;
    }
    for (const box of boxes) {
      try {
        if (box.state === "revoked" || box.state === "staging" || box.expires_at !== null && this.clock() >= box.expires_at) {
          // 清理完的信箱从用量中移除。
          await this.deleteBoxes(space, token, box);
          continue;
        }
        if (box.move_id && box.move_body) {
          try {
            await this.send(space, token, "PUT", `/boxes/${box.down}/messages/${box.move_id}`, box.move_body);
            this.sql.prepare("UPDATE relay_mailboxes SET move_id=NULL, move_body=NULL WHERE space=? AND up=?").run(box.space, box.up);
          } catch (error) {
            if (this.shutdown.signal.aborted) throw error;
            logFailure("relay.move", error);
          }
        }
        if (scan || hints?.has(box.up) || box.state === "pair_reply" || (box.pending ?? 0) > 0) {
          let pending = 0;
          for await (const message of this.messages(space, token, box.up)) {
            try {
              await this.deliver(space, token, box, message.id);
            } catch (error) {
              if (this.shutdown.signal.aborted) throw error;
              pending++;
              bytes += message.size;
              logFailure("relay.message", error);
            }
          }
          read = true;
          this.sql.prepare("UPDATE relay_mailboxes SET pending=? WHERE space=? AND up=?").run(pending, box.space, box.up);
        }
        if (inventory || box.state === "pair_reply") {
          for await (const message of this.messages(space, token, box.down)) bytes += message.size;
        }
      } catch (error) {
        if (this.shutdown.signal.aborted || this.connected.get(space.space) === false) throw error;
        completeInventory = false;
        logFailure("relay.box", error);
      }
    }
    if (inventory && completeInventory) this.sql.prepare("UPDATE relay_spaces SET used_bytes=? WHERE space=?").run(bytes, space.space);
    return read;
  }

  private async deliver(space: Space, token: string, mailbox: Mailbox, id: string) {
    const up = `/boxes/${mailbox.up}/messages/${id}`;
    let discarded = false;
    let result: object | null = null;
    const context: RelayRequest = { mailbox, id };
    try {
      const response = await this.spaceRequest(space, token, "GET", up);
      try { result = await this.receive(response, context); }
      finally { if (!response.bodyUsed) await response.body?.cancel().catch(() => {}); }
    } catch (error) {
      if (error instanceof WireError && [400, 401, 413].includes(error.status)) discarded = true;
      else if (!(error instanceof RelayHTTPError) || error.status !== 404) throw error;
    }
    if (result && context.projectionRead) {
      const read = context.projectionRead, head = projectionHead(this.sql);
      if (read.epoch !== head.epoch || read.urgent !== head.urgent ||
          !mailbox.device || deviceAccess(this.sql, mailbox.device)?.role_revision !== read.revision) result = null;
      else this.sql.prepare("INSERT OR REPLACE INTO relay_projection_replies VALUES (?,?,?,?,?,?)")
        .run(mailbox.space, mailbox.up, id, read.seq, read.epoch, this.clock());
    }
    if (result) {
      const down = `/boxes/${mailbox.down}/messages/${id}`;
      await this.send(space, token, "PUT", down, result);
      // A local CLI can change the role while the network write is in flight.
      if (context.projectionRead && deviceAccess(this.sql, mailbox.device!)?.role_revision !== context.projectionRead.revision) {
        await this.remove(space, token, down, 404);
      }
    }
    if (context.projectionRead && projectionHead(this.sql).urgent > context.projectionRead.seq) this.projectionPending = true;
    await this.remove(space, token, up, 404);
    this.sql.transaction(() => {
      this.sql.prepare("DELETE FROM relay_receipts WHERE space=? AND up=? AND id=?").run(mailbox.space, mailbox.up, id);
      if (discarded) this.sql.prepare("UPDATE relay_spaces SET discarded=discarded+1 WHERE space=?").run(mailbox.space);
    }).immediate();
    if (result && context.replyDelivered) setTimeout(context.replyDelivered, 0);
  }
}
