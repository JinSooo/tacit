// 自部署：Bun + SQLite 单进程。所有空间放在同一个库里。
import { Database } from "bun:sqlite";
import { authorizeWatch, creationGate, failure, handleSpace, hello, json, limitsFrom, parseSpacePath,
  randomID, RelayError, SpaceStore, type Limits, type Sql } from "./core.ts";

export function bunSql(db: Database): Sql {
  return {
    all: <T>(sql: string, ...params: unknown[]) => db.query(sql).all(...(params as never[])) as T[],
    run: (sql: string, ...params: unknown[]) => { db.query(sql).run(...(params as never[])); },
    tx: <T>(fn: () => T) => db.transaction(fn)() as T,
  };
}

/** 开通限流的计数只在内存里，按天清空，重启即清。 */
function memoryCounter() {
  let current = "";
  const counts = new Map<string, number>();
  return {
    take(key: string, day: string, max: number) {
      if (day !== current) { counts.clear(); current = day; }
      const n = counts.get(key) ?? 0;
      if (n >= max) return false;
      counts.set(key, n + 1);
      return true;
    },
  };
}

export interface RelayOptions {
  db?: string;
  port?: number;
  hostname?: string;
  limits?: Limits;
  createCode?: string;
  now?: () => number;
  /** 反向代理后面时，从哪个请求头取访问方 IP。 */
  ipHeader?: string;
}

export function startRelay(options: RelayOptions = {}) {
  const db = new Database(options.db ?? ":memory:", { create: true });
  db.exec("PRAGMA journal_mode=WAL; PRAGMA busy_timeout=5000;");
  const now = options.now ?? Date.now;
  const limits = options.limits ?? limitsFrom({});
  const store = new SpaceStore(bunSql(db), limits, now);
  const gate = creationGate(options.createCode, limits, memoryCounter(), now);
  const sweeper = setInterval(() => { try { store.sweep(); } catch { /* 下一轮再清 */ } }, 60 * 60_000);
  sweeper.unref?.();
  store.sweep();

  const server = Bun.serve<{ space: string }>({
    hostname: options.hostname ?? "0.0.0.0",
    port: options.port ?? 8787,
    maxRequestBodySize: limits.message_bytes + 64 * 1024,
    async fetch(request, server) {
      const url = new URL(request.url);
      try {
        if (request.method === "GET" && url.pathname === "/v1/hello") return hello(limits);
        if (request.method === "POST" && url.pathname === "/v1/spaces") {
          let code: unknown;
          try { code = (await request.json() as Record<string, unknown> | null)?.code; } catch { code = undefined; }
          const ip = (options.ipHeader && request.headers.get(options.ipHeader)?.split(",")[0]?.trim()) || server.requestIP(request)?.address || "";
          await gate.allow(ip, code);
          const space = randomID();
          return json({ space, token: await store.createSpace(space) }, 201);
        }
        const route = parseSpacePath(url.pathname);
        if (!route) return json({ error: "接口不存在" }, 404);
        if (route.rest.length === 1 && route.rest[0] === "watch" && request.method === "GET") {
          await authorizeWatch(request, store, route);
          if (server.upgrade(request, { data: { space: route.space } })) return undefined;
          throw new RelayError(400, "需要 WebSocket");
        }
        return await handleSpace(request, store, route, box => server.publish(route.space, JSON.stringify({ box })));
      } catch (error) {
        return failure(error);
      }
    },
    websocket: {
      open(ws) { ws.subscribe(ws.data.space); },
      message() { /* 只下行通知，不收消息 */ },
    },
  });
  return { server, store, stop: (force?: boolean) => { clearInterval(sweeper); void server.stop(force); db.close(); } };
}

if (import.meta.main) {
  const env = process.env;
  const relay = startRelay({
    db: env.TACIT_RELAY_DB ?? "/data/relay.db",
    port: Number(env.PORT) || 8787,
    limits: limitsFrom(env),
    createCode: env.TACIT_RELAY_CREATE_CODE || undefined,
    ipHeader: env.TACIT_RELAY_IP_HEADER || undefined,
  });
  console.log(`tacit relay listening on :${relay.server.port}`);
}
