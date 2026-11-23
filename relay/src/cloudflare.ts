// Cloudflare 部署：Worker 负责路由，每个空间一个 SQLite 存储的 Durable Object，
// 开通限流放在一个全局 Durable Object 里。只用 Workers 免费档就有的能力。
import { authorizeWatch, creationGate, failure, handleSpace, hello, json, limitsFrom, parseSpacePath,
  randomID, RelayError, SpaceStore, utcDay, type Sql } from "./core.ts";

/* 只声明这里用到的那一点 Workers 类型，免得仓库根目录的类型检查依赖 @cloudflare/workers-types。 */
interface SqlCursor { toArray(): Record<string, unknown>[] }
interface DOStorage {
  sql: { exec(query: string, ...bindings: unknown[]): SqlCursor };
  transactionSync<T>(fn: () => T): T;
  setAlarm(at: number): Promise<void>;
  getAlarm(): Promise<number | null>;
}
interface DOState {
  storage: DOStorage;
  acceptWebSocket(ws: WebSocket): void;
  getWebSockets(): WebSocket[];
}
interface DOStub { fetch(request: Request | string, init?: RequestInit): Promise<Response> }
interface DONamespace { idFromName(name: string): unknown; get(id: unknown): DOStub }
interface Env {
  SPACES: DONamespace;
  GATE: DONamespace;
  TACIT_RELAY_CREATE_CODE?: string;
  [key: string]: unknown;
}
declare const WebSocketPair: { new(): { 0: WebSocket; 1: WebSocket } };

function doSql(storage: DOStorage): Sql {
  return {
    all: <T>(query: string, ...params: unknown[]) => storage.sql.exec(query, ...params).toArray() as T[],
    run: (query: string, ...params: unknown[]) => { storage.sql.exec(query, ...params).toArray(); },
    tx: <T>(fn: () => T) => storage.transactionSync(fn),
  };
}

const envStrings = (env: Env) => Object.fromEntries(Object.entries(env).filter(([, v]) => typeof v === "string")) as Record<string, string>;
const SWEEP_MS = 6 * 3_600_000;

export class RelaySpace {
  private readonly store: SpaceStore;
  constructor(private readonly state: DOState, env: Env) {
    this.store = new SpaceStore(doSql(state.storage), limitsFrom(envStrings(env)));
  }

  private async schedule() {
    if (await this.state.storage.getAlarm() === null) await this.state.storage.setAlarm(Date.now() + SWEEP_MS);
  }

  async fetch(request: Request): Promise<Response> {
    const url = new URL(request.url);
    try {
      await this.schedule();
      if (url.pathname === "/internal/create") {
        const { space } = await request.json() as { space: string };
        if (this.store.exists(space)) throw new RelayError(409, "空间已存在");
        return json({ space, token: await this.store.createSpace(space) }, 201);
      }
      const route = parseSpacePath(url.pathname);
      if (!route) return json({ error: "接口不存在" }, 404);
      if (route.rest.length === 1 && route.rest[0] === "watch" && request.method === "GET") {
        await authorizeWatch(request, this.store, route);
        if (request.headers.get("upgrade")?.toLowerCase() !== "websocket") throw new RelayError(400, "需要 WebSocket");
        const pair = new WebSocketPair();
        this.state.acceptWebSocket(pair[1]);
        return new Response(null, { status: 101, webSocket: pair[0] } as ResponseInit);
      }
      return await handleSpace(request, this.store, route, box => {
        const note = JSON.stringify({ box });
        for (const ws of this.state.getWebSockets()) { try { ws.send(note); } catch { /* 连接已断 */ } }
      });
    } catch (error) {
      return failure(error);
    }
  }

  async alarm() {
    this.store.sweep();
    await this.state.storage.setAlarm(Date.now() + SWEEP_MS);
  }

  webSocketMessage() { /* 只下行通知 */ }
  webSocketClose(ws: WebSocket) { try { ws.close(); } catch { /* 已关闭 */ } }
}

/** 开通空间的每日限流。只存“当天 + IP”的哈希，次日清掉。 */
export class RelayGate {
  private readonly sql: Sql;
  constructor(private readonly state: DOState, private readonly env: Env) {
    this.sql = doSql(state.storage);
    this.sql.run("CREATE TABLE IF NOT EXISTS opened (key TEXT PRIMARY KEY, day TEXT NOT NULL, n INTEGER NOT NULL)");
  }

  async fetch(request: Request): Promise<Response> {
    try {
      const { ip, code } = await request.json() as { ip: string; code?: unknown };
      const limits = limitsFrom(envStrings(this.env));
      const counter = {
        take: (key: string, day: string, max: number) => this.sql.tx(() => {
          this.sql.run("DELETE FROM opened WHERE day<>?", day);
          const n = this.sql.all<{ n: number }>("SELECT n FROM opened WHERE key=?", key)[0]?.n ?? 0;
          if (n >= max) return false;
          this.sql.run("INSERT INTO opened(key, day, n) VALUES (?,?,1) ON CONFLICT(key) DO UPDATE SET n=n+1", key, day);
          return true;
        }),
      };
      await creationGate(this.env.TACIT_RELAY_CREATE_CODE || undefined, limits, counter).allow(ip, code);
      return json({ ok: true, day: utcDay(Date.now()) });
    } catch (error) {
      return failure(error);
    }
  }
}

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const url = new URL(request.url);
    try {
      if (url.protocol !== "https:" && url.hostname !== "localhost") throw new RelayError(400, "只接受 HTTPS");
      if (request.method === "GET" && url.pathname === "/v1/hello") return hello(limitsFrom(envStrings(env)));
      if (request.method === "POST" && url.pathname === "/v1/spaces") {
        let code: unknown;
        try { code = (await request.json() as Record<string, unknown> | null)?.code; } catch { code = undefined; }
        const ip = request.headers.get("cf-connecting-ip") ?? "";
        const gate = env.GATE.get(env.GATE.idFromName("gate"));
        const allowed = await gate.fetch("https://gate/allow", { method: "POST", body: JSON.stringify({ ip, code }) });
        if (!allowed.ok) return allowed;
        const space = randomID();
        return await env.SPACES.get(env.SPACES.idFromName(space))
          .fetch("https://space/internal/create", { method: "POST", body: JSON.stringify({ space }) });
      }
      const route = parseSpacePath(url.pathname);
      if (!route) return json({ error: "接口不存在" }, 404);
      return await env.SPACES.get(env.SPACES.idFromName(route.space)).fetch(request);
    } catch (error) {
      return failure(error);
    }
  },
};
