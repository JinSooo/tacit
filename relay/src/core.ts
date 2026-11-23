// 中转信箱的核心逻辑（docs/contracts.md 6.8）。只用 Web 标准 API，Bun 和 Cloudflare 两种部署共用。
// 信箱不解密、不解析信封，只按令牌存取不透明的字节。

export interface Sql {
  all<T = Record<string, unknown>>(sql: string, ...params: unknown[]): T[];
  run(sql: string, ...params: unknown[]): void;
  tx<T>(fn: () => T): T;
}

export interface Limits {
  message_bytes: number;
  space_bytes: number;
  retention_days: number;
  idle_days: number;
  daily_requests: number;
  spaces_per_ip: number;
}

export const defaultLimits: Limits = {
  message_bytes: 1024 * 1024,
  space_bytes: 100 * 1024 * 1024,
  retention_days: 30,
  idle_days: 90,
  daily_requests: 20_000,
  spaces_per_ip: 3,
};

/** 从环境变量读限额；没设或无效时用公共信箱的默认值。 */
export function limitsFrom(env: Record<string, string | undefined>): Limits {
  const pick = (name: string, fallback: number) => {
    const value = Number(env[`TACIT_RELAY_${name.toUpperCase()}`]);
    return Number.isSafeInteger(value) && value > 0 ? value : fallback;
  };
  return Object.fromEntries(Object.entries(defaultLimits).map(([k, v]) => [k, pick(k, v)])) as unknown as Limits;
}

const DAY = 86_400_000;
const idPattern = /^[A-Za-z0-9_-]{22}$/;
const tokenIDPattern = /^[0-9a-f]{16}$/;

export const schema = `
CREATE TABLE IF NOT EXISTS spaces (id TEXT PRIMARY KEY, created_at INTEGER NOT NULL, hub_seen_at INTEGER NOT NULL);
CREATE TABLE IF NOT EXISTS tokens (
  id TEXT PRIMARY KEY, space TEXT NOT NULL, hash TEXT NOT NULL UNIQUE, kind TEXT NOT NULL,
  can_write TEXT NOT NULL, can_read TEXT NOT NULL, expires_at INTEGER
);
CREATE INDEX IF NOT EXISTS tokens_space ON tokens(space);
CREATE TABLE IF NOT EXISTS boxes (space TEXT NOT NULL, id TEXT NOT NULL, PRIMARY KEY(space, id));
CREATE TABLE IF NOT EXISTS messages (
  seq INTEGER PRIMARY KEY AUTOINCREMENT, space TEXT NOT NULL, box TEXT NOT NULL, id TEXT NOT NULL,
  size INTEGER NOT NULL, at INTEGER NOT NULL, body BLOB NOT NULL, UNIQUE(space, box, id)
);
CREATE INDEX IF NOT EXISTS messages_at ON messages(at);
CREATE TABLE IF NOT EXISTS usage (space TEXT NOT NULL, day TEXT NOT NULL, requests INTEGER NOT NULL, PRIMARY KEY(space, day));
`;

export function randomID(bytes = 16): string {
  const raw = crypto.getRandomValues(new Uint8Array(bytes));
  return btoa(String.fromCharCode(...raw)).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

export async function sha256(text: string): Promise<string> {
  const digest = new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(text)));
  return Array.from(digest, b => b.toString(16).padStart(2, "0")).join("");
}

export const utcDay = (ms: number) => new Date(ms).toISOString().slice(0, 10);

export class RelayError extends Error {
  constructor(readonly status: number, message: string) { super(message); }
}

type Scope = { kind: "space" } | { kind: "box"; write: Set<string>; read: Set<string> };

/** 一个或多个空间的存储。Cloudflare 上每个空间一个 Durable Object，里面只有它自己。 */
export class SpaceStore {
  constructor(private readonly sql: Sql, readonly limits: Limits, private readonly now: () => number = Date.now) {
    for (const statement of schema.split(";").map(s => s.trim()).filter(Boolean)) sql.run(statement);
  }

  exists(space: string): boolean {
    return this.sql.all("SELECT 1 FROM spaces WHERE id=?", space).length > 0;
  }

  async createSpace(space: string): Promise<string> {
    const token = randomID(32), hash = await sha256(token), at = this.now();
    this.sql.tx(() => {
      this.sql.run("INSERT INTO spaces(id, created_at, hub_seen_at) VALUES (?,?,?)", space, at, at);
      this.sql.run("INSERT INTO tokens(id, space, hash, kind, can_write, can_read, expires_at) VALUES (?,?,?,?,?,?,NULL)",
        randomHex(), space, hash, "space", "[]", "[]");
    });
    return token;
  }

  async authorize(space: string, header: string | null): Promise<Scope> {
    const token = /^Bearer ([A-Za-z0-9_-]{20,200})$/.exec(header ?? "")?.[1];
    if (!token) throw new RelayError(401, "令牌无效");
    const row = this.sql.all<{ kind: string; can_write: string; can_read: string; expires_at: number | null }>(
      "SELECT kind, can_write, can_read, expires_at FROM tokens WHERE hash=? AND space=?", await sha256(token), space)[0];
    const now = this.now();
    if (!row || (row.expires_at !== null && row.expires_at <= now)) throw new RelayError(401, "令牌无效");
    this.count(space, now);
    if (row.kind === "space") {
      this.sql.run("UPDATE spaces SET hub_seen_at=? WHERE id=?", now, space);
      return { kind: "space" };
    }
    return { kind: "box", write: new Set(JSON.parse(row.can_write)), read: new Set(JSON.parse(row.can_read)) };
  }

  private count(space: string, now: number) {
    const day = utcDay(now);
    const used = this.sql.all<{ requests: number }>("SELECT requests FROM usage WHERE space=? AND day=?", space, day)[0]?.requests ?? 0;
    if (used >= this.limits.daily_requests) throw new RelayError(429, "今天的请求次数已用完");
    this.sql.run("INSERT INTO usage(space, day, requests) VALUES (?,?,1) ON CONFLICT(space, day) DO UPDATE SET requests=requests+1", space, day);
  }

  createBoxes(space: string, boxes: string[]) {
    this.sql.tx(() => { for (const box of boxes) this.sql.run("INSERT OR IGNORE INTO boxes(space, id) VALUES (?,?)", space, box); });
  }

  deleteBox(space: string, box: string) {
    this.sql.tx(() => {
      this.sql.run("DELETE FROM messages WHERE space=? AND box=?", space, box);
      this.sql.run("DELETE FROM boxes WHERE space=? AND id=?", space, box);
    });
  }

  async createToken(space: string, write: string[], read: string[], expiresAt: number | null) {
    const token = randomID(32), id = randomHex();
    this.sql.run("INSERT INTO tokens(id, space, hash, kind, can_write, can_read, expires_at) VALUES (?,?,?,?,?,?,?)",
      id, space, await sha256(token), "box", JSON.stringify(write), JSON.stringify(read), expiresAt);
    return { id, token };
  }

  revokeToken(space: string, id: string): boolean {
    const before = this.sql.all("SELECT 1 FROM tokens WHERE id=? AND space=? AND kind='box'", id, space).length;
    this.sql.run("DELETE FROM tokens WHERE id=? AND space=? AND kind='box'", id, space);
    return before > 0;
  }

  deleteSpace(space: string) {
    this.sql.tx(() => {
      for (const table of ["messages", "boxes", "tokens", "usage"]) this.sql.run(`DELETE FROM ${table} WHERE space=?`, space);
      this.sql.run("DELETE FROM spaces WHERE id=?", space);
    });
  }

  private boxExists(space: string, box: string) {
    return this.sql.all("SELECT 1 FROM boxes WHERE space=? AND id=?", space, box).length > 0;
  }

  /** 新建返回 true；同 id 已存在返回 false，不覆盖。 */
  put(space: string, box: string, id: string, body: Uint8Array): boolean {
    return this.sql.tx(() => {
      if (!this.boxExists(space, box)) throw new RelayError(404, "信箱不存在");
      if (this.sql.all("SELECT 1 FROM messages WHERE space=? AND box=? AND id=?", space, box, id).length) return false;
      const used = this.sql.all<{ n: number | null }>("SELECT SUM(size) AS n FROM messages WHERE space=?", space)[0]?.n ?? 0;
      if (used + body.byteLength > this.limits.space_bytes) throw new RelayError(507, "空间已满");
      this.sql.run("INSERT INTO messages(space, box, id, size, at, body) VALUES (?,?,?,?,?,?)",
        space, box, id, body.byteLength, this.now(), body);
      return true;
    });
  }

  list(space: string, box: string, after: number, limit: number) {
    if (!this.boxExists(space, box)) throw new RelayError(404, "信箱不存在");
    const rows = this.sql.all<{ seq: number; id: string; size: number }>(
      "SELECT seq, id, size FROM messages WHERE space=? AND box=? AND seq>? ORDER BY seq LIMIT ?", space, box, after, limit);
    const messages = rows.map(r => ({ id: r.id, size: r.size, cursor: String(r.seq) }));
    return { messages, next: rows.length === limit ? String(rows[rows.length - 1]!.seq) : null };
  }

  get(space: string, box: string, id: string): Uint8Array | null {
    const row = this.sql.all<{ body: Uint8Array | ArrayBuffer }>(
      "SELECT body FROM messages WHERE space=? AND box=? AND id=?", space, box, id)[0];
    return row ? (row.body instanceof Uint8Array ? row.body : new Uint8Array(row.body)) : null;
  }

  remove(space: string, box: string, id: string) {
    this.sql.run("DELETE FROM messages WHERE space=? AND box=? AND id=?", space, box, id);
  }

  /** 清掉过期消息、长期没人用的空间、过期令牌和旧的计数。 */
  sweep() {
    const now = this.now();
    this.sql.tx(() => {
      this.sql.run("DELETE FROM messages WHERE at<?", now - this.limits.retention_days * DAY);
      this.sql.run("DELETE FROM tokens WHERE expires_at IS NOT NULL AND expires_at<=?", now);
      this.sql.run("DELETE FROM usage WHERE day<?", utcDay(now - DAY));
    });
    for (const { id } of this.sql.all<{ id: string }>("SELECT id FROM spaces WHERE hub_seen_at<?", now - this.limits.idle_days * DAY)) {
      this.deleteSpace(id);
    }
  }
}

function randomHex() {
  return Array.from(crypto.getRandomValues(new Uint8Array(8)), b => b.toString(16).padStart(2, "0")).join("");
}

export function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status, headers: { "Content-Type": "application/json", "Cache-Control": "no-store" },
  });
}
export const failure = (error: unknown) => error instanceof RelayError
  ? json({ error: error.message }, error.status)
  : json({ error: "信箱服务内部错误" }, 500);

/** 按上限读请求体，超出即 413，不把整个大请求读进内存。 */
export async function readBody(request: Request, max: number): Promise<Uint8Array> {
  if (Number(request.headers.get("content-length")) > max) throw new RelayError(413, "消息超过上限");
  if (!request.body) return new Uint8Array();
  const reader = request.body.getReader();
  const chunks: Uint8Array[] = [];
  let size = 0;
  for (;;) {
    const { done, value } = await reader.read();
    if (done) break;
    size += value.byteLength;
    if (size > max) {
      void reader.cancel().catch(() => {});
      throw new RelayError(413, "消息超过上限");
    }
    chunks.push(value);
  }
  const out = new Uint8Array(size);
  let offset = 0;
  for (const chunk of chunks) { out.set(chunk, offset); offset += chunk.byteLength; }
  return out;
}

async function readJSON(request: Request): Promise<Record<string, unknown>> {
  try {
    const value = JSON.parse(new TextDecoder().decode(await readBody(request, 64 * 1024)));
    if (value && typeof value === "object" && !Array.isArray(value)) return value;
  } catch (error) {
    if (error instanceof RelayError) throw error;
  }
  throw new RelayError(400, "请求格式错误");
}

const ids = (value: unknown, pattern = idPattern): string[] => {
  if (!Array.isArray(value) || value.length > 100 || !value.every(v => typeof v === "string" && pattern.test(v))) {
    throw new RelayError(400, "信箱编号无效");
  }
  return value as string[];
};

export const hello = (limits: Limits) => json({ tacit_relay: 1, limits: {
  space_bytes: limits.space_bytes, message_bytes: limits.message_bytes, retention_days: limits.retention_days,
} });

/** 开通空间前的检查：开通码和同一 IP 当天的次数。IP 只以“当天 + IP”的哈希出现，不落原文。 */
export interface Creation {
  allow(ip: string, code: unknown): Promise<void>;
}

export function creationGate(code: string | undefined, limits: Limits, counter: {
  take(key: string, day: string, max: number): boolean;
}, now: () => number = Date.now): Creation {
  return {
    async allow(ip, given) {
      if (code && given !== code) throw new RelayError(403, "开通码不对");
      const day = utcDay(now());
      if (!counter.take(await sha256(`${day}|${ip}`), day, limits.spaces_per_ip)) throw new RelayError(429, "今天开通的空间太多了");
    },
  };
}

export type SpaceRoute = { space: string; rest: string[] };

export function parseSpacePath(pathname: string): SpaceRoute | null {
  const parts = pathname.split("/").filter(Boolean);
  if (parts[0] !== "v1" || parts[1] !== "spaces" || !parts[2] || !idPattern.test(parts[2])) return null;
  return { space: parts[2], rest: parts.slice(3) };
}

/**
 * 处理 /v1/spaces/:space/... 下除 watch 以外的请求。
 * notify 在新消息写入后调用，部署层据此通知连着 watch 的中枢。
 */
export async function handleSpace(request: Request, store: SpaceStore, route: SpaceRoute, notify: (box: string) => void): Promise<Response> {
  try {
    const { space, rest } = route;
    if (!store.exists(space)) throw new RelayError(401, "令牌无效");
    const scope = await store.authorize(space, request.headers.get("authorization"));
    const method = request.method;
    const needSpace = () => { if (scope.kind !== "space") throw new RelayError(403, "权限不够"); };
    if (rest.length === 0 && method === "DELETE") {
      needSpace();
      store.deleteSpace(space);
      return json({ ok: true });
    }
    if (rest[0] === "boxes" && rest.length === 1 && method === "POST") {
      needSpace();
      store.createBoxes(space, ids((await readJSON(request)).boxes));
      return json({ ok: true });
    }
    if (rest[0] === "tokens" && rest.length === 1 && method === "POST") {
      needSpace();
      const body = await readJSON(request);
      const expires = body.expires_at;
      if (expires !== undefined && (typeof expires !== "string" || !Number.isFinite(Date.parse(expires)))) {
        throw new RelayError(400, "expires_at 无效");
      }
      return json(await store.createToken(space, ids(body.write ?? []), ids(body.read ?? []),
        expires === undefined ? null : Date.parse(expires as string)), 201);
    }
    if (rest[0] === "tokens" && rest.length === 2 && method === "DELETE") {
      needSpace();
      if (!tokenIDPattern.test(rest[1]!)) throw new RelayError(400, "令牌编号无效");
      store.revokeToken(space, rest[1]!);
      return json({ ok: true });
    }
    if (rest[0] !== "boxes" || !rest[1] || !idPattern.test(rest[1])) throw new RelayError(404, "接口不存在");
    const box = rest[1];
    if (rest.length === 2 && method === "DELETE") {
      needSpace();
      store.deleteBox(space, box);
      return json({ ok: true });
    }
    if (rest[2] !== "messages") throw new RelayError(404, "接口不存在");
    const canRead = scope.kind === "space" || scope.read.has(box);
    const canWrite = scope.kind === "space" || scope.write.has(box);
    if (rest.length === 3 && method === "GET") {
      if (!canRead) throw new RelayError(403, "权限不够");
      const url = new URL(request.url);
      const after = url.searchParams.get("after") ?? "0", limit = url.searchParams.get("limit") ?? "100";
      if (!/^\d{1,15}$/.test(after) || !/^\d{1,3}$/.test(limit) || +limit < 1 || +limit > 100) throw new RelayError(400, "参数无效");
      return json(store.list(space, box, +after, +limit));
    }
    const id = rest[3];
    if (rest.length !== 4 || !id || !idPattern.test(id)) throw new RelayError(404, "接口不存在");
    if (method === "PUT") {
      if (!canWrite) throw new RelayError(403, "权限不够");
      const body = await readBody(request, store.limits.message_bytes);
      if (!body.byteLength) throw new RelayError(400, "消息为空");
      const created = store.put(space, box, id, body);
      if (created) notify(box);
      return json({ ok: true }, created ? 201 : 200);
    }
    if (!canRead) throw new RelayError(403, "权限不够");
    if (method === "GET") {
      const body = store.get(space, box, id);
      if (!body) throw new RelayError(404, "消息不存在");
      return new Response(body as unknown as BodyInit, { headers: { "Content-Type": "application/json", "Cache-Control": "no-store" } });
    }
    if (method === "DELETE") {
      store.remove(space, box, id);
      return json({ ok: true });
    }
    throw new RelayError(404, "接口不存在");
  } catch (error) {
    return failure(error);
  }
}

/** watch 只给空间令牌；鉴权通过后由部署层升级成 WebSocket。 */
export async function authorizeWatch(request: Request, store: SpaceStore, route: SpaceRoute) {
  if (!store.exists(route.space)) throw new RelayError(401, "令牌无效");
  const scope = await store.authorize(route.space, request.headers.get("authorization"));
  if (scope.kind !== "space") throw new RelayError(403, "权限不够");
}
