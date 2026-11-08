import { timingSafeEqual } from "node:crypto";
import { HubDB, InputError } from "./db.ts";

function authorized(request: Request, token: string): boolean {
  const actual = Buffer.from(request.headers.get("authorization") ?? "");
  const expected = Buffer.from(`Bearer ${token}`);
  return actual.length === expected.length && timingSafeEqual(actual, expected);
}

export function createHandler(options: { db: HubDB; token: string }) {
  if (!options.token) throw new Error("本地 token 不能为空");
  const { db, token } = options;
  return async (request: Request): Promise<Response> => {
    const url = new URL(request.url);
    const method = request.method;
    if (method === "GET" && url.pathname === "/v1/health") return Response.json({ ok: true });
    if (!authorized(request, token)) return Response.json({ error: "需要有效的 Bearer token" }, { status: 401 });
    const readJSON = async (): Promise<unknown> => {
      try { return await request.json(); } catch { throw new InputError("请求体必须是 JSON"); }
    };
    try {
      if (method === "POST" && url.pathname === "/v1/ingest") {
        const body = await readJSON();
        if (!body || typeof body !== "object" || !Array.isArray((body as { records?: unknown }).records)
          || typeof (body as { device?: unknown }).device !== "string" || !/^[a-z0-9][a-z0-9-]{0,62}$/.test((body as { device: string }).device)) {
          throw new InputError("需要 device 和 records 数组");
        }
        return Response.json(db.ingest((body as { records: unknown[] }).records));
      }
      if (method === "GET" && url.pathname === "/v1/records") return Response.json(db.list(url.searchParams));
      if (method === "POST" && url.pathname === "/v1/records") {
        const record = await readJSON();
        if (!record || typeof record !== "object" || typeof (record as { source?: unknown }).source !== "string"
          || !(record as { source: string }).source.startsWith("manual.")) throw new InputError("手动记录的 source 必须是 manual.*");
        return Response.json(db.ingest([record]));
      }
      const match = /^\/v1\/records\/([0-9A-HJKMNP-TV-Z]{26})$/.exec(url.pathname);
      if (match && method === "GET") {
        const record = db.get(match[1]!);
        return record ? Response.json(record) : Response.json({ error: "记录不存在" }, { status: 404 });
      }
      if (match && method === "DELETE") {
        return db.delete(match[1]!) ? Response.json({ deleted: true }) : Response.json({ error: "记录不存在" }, { status: 404 });
      }
      return Response.json({ error: "接口不存在" }, { status: 404 });
    } catch (e) {
      if (e instanceof InputError) return Response.json({ error: e.message }, { status: 400 });
      // 不把异常对象或原始请求写到日志，防止密钥经过错误通道泄漏。
      return Response.json({ error: "存储操作失败" }, { status: 500 });
    }
  };
}

export function startServer(options: { db: HubDB; token: string; port?: number }) {
  return Bun.serve({ hostname: "127.0.0.1", port: options.port ?? 47823, fetch: createHandler(options) });
}
