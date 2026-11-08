import { timingSafeEqual } from "node:crypto";
import { realpath, stat } from "node:fs/promises";
import { resolve, extname, sep } from "node:path";
import { fileURLToPath } from "node:url";
import { HubDB, InputError } from "./db.ts";

const defaultWebDir = fileURLToPath(new URL("../../web/dist/", import.meta.url));
const csp = "default-src 'self'; img-src 'self' data:; style-src 'self' 'unsafe-inline'; connect-src 'self'; frame-ancestors 'none'";
const contentTypes: Record<string, string> = {
  ".html": "text/html; charset=utf-8", ".js": "text/javascript; charset=utf-8",
  ".css": "text/css; charset=utf-8", ".json": "application/json; charset=utf-8",
  ".svg": "image/svg+xml", ".png": "image/png", ".ico": "image/x-icon",
  ".jpg": "image/jpeg", ".jpeg": "image/jpeg", ".webp": "image/webp", ".woff2": "font/woff2",
};

async function serveWeb(pathname: string, directory: string): Promise<Response> {
  let decoded: string;
  try { decoded = decodeURIComponent(pathname); } catch { return new Response("路径无效", { status: 400 }); }
  if (decoded.includes("\\") || decoded.includes("\0") || decoded.split("/").some(part => part === ".." || part === ".")) {
    return new Response("禁止目录穿越", { status: 403 });
  }
  let root: string;
  try { root = await realpath(directory); } catch {
    return new Response("网页尚未构建，请运行 bunx vite build --config web/vite.config.ts", { headers: { "Content-Type": "text/plain; charset=utf-8" } });
  }
  const findFile = async (file: string) => {
    try {
      const actual = await realpath(file);
      if (actual !== root && !actual.startsWith(root + sep)) throw new InputError("禁止目录穿越");
      return (await stat(actual)).isFile() ? actual : null;
    } catch (error) { if (error instanceof InputError) throw error; return null; }
  };
  try {
    const file = await findFile(resolve(root, "." + decoded)) ?? await findFile(resolve(root, "index.html"));
    if (!file) return new Response("网页缺少 index.html", { status: 404 });
    const type = contentTypes[extname(file).toLowerCase()] ?? Bun.file(file).type;
    return new Response(Bun.file(file), { headers: {
      "Content-Type": type, "X-Content-Type-Options": "nosniff", "Cache-Control": "no-cache",
      ...(type.startsWith("text/html") ? { "Content-Security-Policy": csp } : {}),
    } });
  } catch (error) {
    return new Response(error instanceof InputError ? error.message : "读取网页失败", { status: error instanceof InputError ? 403 : 500 });
  }
}

function authorized(request: Request, token: string): boolean {
  const actual = Buffer.from(request.headers.get("authorization") ?? "");
  const expected = Buffer.from(`Bearer ${token}`);
  return actual.length === expected.length && timingSafeEqual(actual, expected);
}

export function createHandler(options: { db: HubDB; token: string; port?: number; webDir?: string }) {
  if (!options.token) throw new Error("本地 token 不能为空");
  const { db, token } = options;
  return async (request: Request): Promise<Response> => {
    const url = new URL(request.url);
    const method = request.method;
    const host = request.headers.get("host");
    const port = options.port ?? 47823;
    if (host !== `127.0.0.1:${port}` && host !== `localhost:${port}`) return new Response("Host 不被允许", { status: 421 });
    if (method === "GET" && url.pathname === "/v1/health") return Response.json({ ok: true });
    if (method === "GET" && url.pathname !== "/v1" && !url.pathname.startsWith("/v1/")) return serveWeb(url.pathname, options.webDir ?? defaultWebDir);
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
  let handler: ReturnType<typeof createHandler>;
  return Bun.serve({ hostname: "127.0.0.1", port: options.port ?? 47823, fetch(request, server) {
    handler ??= createHandler({ ...options, port: server.port });
    return handler(request);
  } });
}
