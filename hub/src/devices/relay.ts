import { randomBytes } from "node:crypto";
import type { HubDB } from "../db.ts";
import { logFailure } from "../diagnostics.ts";
import type { RelayKeyStorage } from "../keys.ts";
import { base64url, object, WireError } from "./envelope.ts";
import { dayMs, relayConfig, type Mailbox, type RelayRequest, type Space } from "./relay-store.ts";

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
type Move = (publicKey: Buffer, id: string, relay: ReturnType<typeof relayConfig> | null) => Promise<object>;
type Message = { id: string; size: number };

class RelayHTTPError extends Error {
  readonly code: string;
  constructor(readonly status: number) {
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
  private maintenance?: Promise<void>;

  constructor(hub: HubDB, private readonly keys: RelayKeyStorage, private readonly clock: () => number,
              private readonly receive: Receive, private readonly move: Move) {
    this.sql = hub.db;
  }

  run<T>(job: () => T | Promise<T>): Promise<T> {
    const next = this.serial.then(() => {
      if (this.shutdown.signal.aborted) throw new WireError(503, "中枢正在关闭");
      return job();
    });
    this.serial = next.catch(() => {});
    return next;
  }

  start() {
    this.sql.prepare("UPDATE relay_mailboxes SET state='revoked', token=NULL WHERE state IN ('invite','staging')").run();
    this.lastTick = this.clock();
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
      used_bytes: s.used_bytes, unprocessable: s.discarded,
      devices: this.boxes(s.space).filter(b => b.state === "active" && b.device)
        .map(b => ({ device: b.device!, pending: b.pending })),
    });
    return {
      mode: current ? "custom" as const : "off" as const,
      ...(current ? describe(current) : {
        url: null, connected: false, last_fetch_at: null, used_bytes: null, unprocessable: 0, devices: [],
      }),
      retiring: retiring.map(s => ({ ...describe(s), retire_at: at(s.retire_at) })),
    };
  }

  async settings(method: string, path: string, readJSON: () => Promise<unknown>) {
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
      await this.run(() => this.configure(url, url === null ? undefined : input.code as string | undefined));
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
    const response = await fetch(url, {
      method, redirect: "error", signal: AbortSignal.any([this.shutdown.signal, AbortSignal.timeout(timeout)]),
      headers: {
        ...(token === undefined ? {} : { Authorization: `Bearer ${token}` }),
        ...(body === undefined ? {} : { "Content-Type": "application/json" }),
      },
      body: body === undefined ? undefined : typeof body === "string" ? body : JSON.stringify(body),
    });
    if (!response.ok) {
      void response.body?.cancel().catch(() => {});
      throw new RelayHTTPError(response.status);
    }
    return response;
  }

  private async hello(url: string) {
    const response = await this.request(url + "/v1/hello", "GET");
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

  private async spaceRequest(space: Space, token: string, method: string, path: string, body?: unknown) {
    try {
      const timeout = /\/messages\/[^/?]+$/.test(path) ? messageTimeoutMs : tickMs;
      const response = await this.request(`${space.url}/v1/spaces/${space.space}${path}`, method, token, body, timeout);
      this.connected.set(space.space, true);
      return response;
    } catch (error) {
      this.connected.set(space.space, error instanceof RelayHTTPError && ![401, 403].includes(error.status));
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

  private async configure(url: string | null, code?: string) {
    const old = this.current();
    if (url !== null) await this.hello(url);
    if ((old?.url ?? null) === url) return;
    const devices = this.sql.prepare<[], { id: string; public_key: Buffer }>("SELECT id, public_key FROM devices").all();
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
          const body = await this.move(device.public_key, id, configs.get(device.id) ?? null);
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
    const socket = new RelayWebSocket(url, { headers: { Authorization: `Bearer ${token}` } });
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
            this.sql.prepare("SELECT 1 FROM relay_mailboxes WHERE space=? AND up=? AND state IN ('active','invite')").get(space.space, box)) {
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
        this.hints.clear();
        await this.round(all, hints);
      }).catch(error => {
        if (!this.shutdown.signal.aborted) logFailure("relay.poll", error);
      }).finally(() => {
        this.maintenance = undefined;
        if (this.full || this.hints.size) this.kick();
      });
    }
    return this.maintenance;
  }

  private async round(full: boolean, hints: Map<string, Set<string>>) {
    const now = this.clock();
    if (now - this.lastPrune >= pollMs) {
      this.sql.prepare("DELETE FROM device_nonces WHERE seen_at<?").run(now - 31 * dayMs);
      this.sql.prepare("DELETE FROM relay_receipts WHERE seen_at<?").run(now - 31 * dayMs);
      this.lastPrune = now;
    }
    const spaces = this.sql.prepare<[], Space>("SELECT * FROM relay_spaces").all();
    for (const space of spaces) {
      if (this.shutdown.signal.aborted) return;
      const id = space.space;
      const notify = hints.get(id);
      const due = now - (this.lastPoll.get(id) ?? -Infinity) >= pollMs;
      const inventory = now - (this.lastInventory.get(id) ?? -Infinity) >= inventoryMs;
      if (!(full || notify || due || inventory)) continue;
      if (due) this.lastPoll.set(id, now);
      if (inventory) this.lastInventory.set(id, now);
      try {
        if (space.state === "staging" || space.retire_at !== null && now >= space.retire_at) {
          if (full || due) await this.deleteSpace(space);
          continue;
        }
        const token = this.token(space);
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
          let waiting = false;
          for await (const message of this.messages(space, token, box.down)) {
            bytes += message.size;
            waiting = true;
          }
          if (box.state === "pair_reply" && !waiting &&
              !this.sql.prepare("SELECT 1 FROM relay_receipts WHERE space=? AND up=?").get(box.space, box.up)) {
            await this.deleteBoxes(space, token, box);
          }
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
    try {
      const response = await this.spaceRequest(space, token, "GET", up);
      try { result = await this.receive(response, { mailbox, id }); }
      finally { if (!response.bodyUsed) await response.body?.cancel().catch(() => {}); }
    } catch (error) {
      if (error instanceof WireError && [400, 401, 413].includes(error.status)) discarded = true;
      else if (!(error instanceof RelayHTTPError) || error.status !== 404) throw error;
    }
    if (result) await this.send(space, token, "PUT", `/boxes/${mailbox.down}/messages/${id}`, result);
    await this.remove(space, token, up, 404);
    this.sql.transaction(() => {
      this.sql.prepare("DELETE FROM relay_receipts WHERE space=? AND up=? AND id=?").run(mailbox.space, mailbox.up, id);
      if (discarded) this.sql.prepare("UPDATE relay_spaces SET discarded=discarded+1 WHERE space=?").run(mailbox.space);
    }).immediate();
  }
}
