import { currentNow } from "./now-status.ts";
import { logFailure } from "./diagnostics.ts";
import { BusyResponses, isDatabaseBusy } from "./db-busy.ts";
import { AudioStore } from "./audio.ts";
import { AgentReads } from "./agent.ts";
import { DistillStore, type Fact } from "./distill/store.ts";
import { DistillRequests } from "./distill/requests.ts";
import { ulid } from "../../packages/record/index.ts";
import { timingSafeEqual } from "node:crypto";
import { realpath, stat } from "node:fs/promises";
import { resolve, extname, sep, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import { HubDB, InputError } from "./db.ts";
import { historySegments } from "./history.ts";
import { conversationDetail } from "./conversations.ts";
import { hubStatus } from "./status.ts";
import { DEFAULT_LAN_PORT, DEFAULT_PORT, dataDirOf, resolveLanPort } from "./hub-json.ts";
import { createSettings, type SettingsDeps } from "./settings.ts";
import { DeviceService, type DeviceDeps } from "./devices/service.ts";
import { RuntimeLog, backgroundLog } from "./runtime-log.ts";
import { correctTimelineSegment, deleteTimelineSegment, timelineDays, timelineRecord } from "./timeline.ts";

const defaultWebDir = fileURLToPath(new URL("../../web/dist/", import.meta.url));
const csp = "default-src 'self'; img-src 'self' data:; style-src 'self' 'unsafe-inline'; connect-src 'self'; media-src 'self' blob:; frame-ancestors 'none'";
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

/** settings 不传时用默认数据目录和系统钥匙串，不会重启进程。 */
export function createHandler(options: { db: HubDB; token: string; agentToken?: string; port?: number; webDir?: string; settings?: SettingsDeps; devices?: DeviceService }) {
  if (!options.token) throw new Error("本地 token 不能为空");
  const { db, token } = options;
  const settings = createSettings(options.settings ?? { dataDir: dataDirOf() });
  const busy = new BusyResponses();
  const handle = async (request: Request): Promise<Response> => {
    const url = new URL(request.url);
    const method = request.method;
    const host = request.headers.get("host");
    const port = options.port ?? DEFAULT_PORT;
    // 被拒的请求不写审计：未鉴权的来源（例如 DNS 重绑定的网页）不能往库里写东西。
    if (host !== `127.0.0.1:${port}` && host !== `localhost:${port}`) return new Response("Host 不被允许", { status: 421 });
    if (method === "GET" && url.pathname === "/v1/health") return Response.json({ ok: true });
    if (method === "GET" && url.pathname !== "/v1" && !url.pathname.startsWith("/v1/")) return serveWeb(url.pathname, options.webDir ?? defaultWebDir);
    const admin = authorized(request, token);
    const agent = !!options.agentToken && authorized(request, options.agentToken);
    if (!admin && !agent) return Response.json({ error: "需要有效的 Bearer token" }, { status: 401 });
    if (!admin && !(method === "GET" && /^\/v1\/agent\/(now|get|search|timeline|context)$/.test(url.pathname)
      || method === "POST" && url.pathname === "/v1/agent/append")) return Response.json({ error: "此令牌仅允许 AI 查询与追加" }, { status: 403 });
    const readJSON = async (): Promise<unknown> => {
      try { return await request.json(); } catch { throw new InputError("请求体必须是 JSON"); }
    };
    try {
      if (method === "GET" && url.pathname.startsWith("/v1/agent/")) return await new AgentReads(db).handle(url.pathname.slice("/v1/agent/".length),url.searchParams);
      if (method === "POST" && url.pathname === "/v1/agent/append") return new AgentReads(db).append(url.searchParams,await readJSON());
      if (method === "GET" && url.pathname === "/v1/status") return Response.json(hubStatus(db, { port, busy: busy.snapshot() }));
      if (url.pathname.startsWith("/v1/settings/")) {
        const deviceResponse = await options.devices?.settings(method, url.pathname);
        if (deviceResponse) return deviceResponse;
        const response = await settings(request, url, { db, port, readJSON, lan: options.devices?.open ?? false });
        if (response) return response;
      }
      if (method === "GET" && url.pathname === "/v1/audit") return Response.json(new AgentReads(db).audit(url.searchParams));
      if (method === "GET" && url.pathname === "/v1/runtime/models") return Response.json(new RuntimeLog(db).models(url.searchParams));
      if (method === "GET" && url.pathname === "/v1/runtime/background") return Response.json(backgroundLog(options.settings?.dataDir ?? dataDirOf(),url.searchParams.get("source") ?? "hub"));
      const runtime = /^\/v1\/runtime\/calls\/([\w-]{1,128})$/.exec(url.pathname);
      if (method === "GET" && runtime) {
        const detail = new RuntimeLog(db).detail(runtime[1]!);
        return Response.json(detail ?? { error: "当时未保存正文" },{ status: detail ? 200 : 404, headers: { "Cache-Control": "no-store" } });
      }
      const audio = new AudioStore(db);
      if (method === "GET" && url.pathname === "/v1/audio/sync") return Response.json(audio.sync(url.searchParams.get("device")));
      if (method === "POST" && url.pathname === "/v1/audio/sync/ack") return Response.json(audio.ack(await readJSON()));
      if (method === "POST" && url.pathname === "/v1/audio/embeddings") return Response.json(audio.embeddings(await readJSON()));
      if (method === "GET" && url.pathname === "/v1/audio/settings") return Response.json(audio.settings());
      if (method === "PUT" && url.pathname === "/v1/audio/settings") return Response.json(audio.updateSettings(await readJSON()));
      if (method === "POST" && url.pathname === "/v1/audio/purge") return Response.json(audio.purge());
      if (method === "GET" && url.pathname === "/v1/speakers") return Response.json(audio.speakers());
      if (method === "POST" && url.pathname === "/v1/audio/samples") return Response.json(audio.uploadSamples(await readJSON()));
      if (method === "POST" && url.pathname === "/v1/audio/lines") return Response.json(audio.lines(await readJSON()));
      const sample = /^\/v1\/audio\/samples\/([^/]+)$/.exec(url.pathname);
      if (method === "GET" && sample) {
        const clip = audio.sample(sample[1]!);
        return clip ? new Response(new Uint8Array(clip.data), { headers: { "Content-Type": clip.mime, "Cache-Control": "no-store", "X-Content-Type-Options": "nosniff" } }) : Response.json({ error: "样本不存在" }, { status: 404 });
      }
      const skipped = /^\/v1\/audio\/conversations\/([^/]+)\/skipped$/.exec(url.pathname);
      if (method === "POST" && skipped) {
        let ref: string;
        try { ref = decodeURIComponent(skipped[1]!); } catch { throw new InputError("对话键无效"); }
        return Response.json(audio.skipped(ref));
      }
      const store = new DistillStore(db);
      const respond = (value: unknown) => value === null ? Response.json({ error: "内容不存在" }, { status: 404 }) : Response.json(value);
      if (url.pathname === "/v1/distill/requests") {
        const requests = new DistillRequests(db);
        if (method === "GET") return Response.json({ requests: requests.list() });
        if (method === "POST") {
          const { request: r, created } = requests.create(await readJSON());
          return Response.json(r, { status: created ? 202 : 200 });
        }
      }
      if (method === "GET" && url.pathname === "/v1/now") return Response.json({ now: currentNow(db) });
      if (method === "GET" && url.pathname === "/v1/threads") return Response.json(store.threads(url.searchParams));
      if (method === "GET" && url.pathname === "/v1/projects") return Response.json({ projects: store.projectSummaries() });
      if (method === "GET" && url.pathname === "/v1/pending") return Response.json({ pending: store.pending().filter(item => item.kind !== "thread_done") });
      if (method === "GET" && url.pathname === "/v1/timeline") return Response.json(timelineDays(db,url.searchParams));
      const timelineMember = /^\/v1\/timeline\/record\/([0-9A-HJKMNP-TV-Z]{26})$/.exec(url.pathname);
      if (method === "GET" && timelineMember) return respond(timelineRecord(db,timelineMember[1]!));
      const projectContext = /^\/v1\/projects\/([\w-]{1,128})\/context$/.exec(url.pathname);
      if (method === "GET" && projectContext) {
        const project = store.project(projectContext[1]!);
        if (!project) return respond(null);
        const { threads } = new AgentReads(db).projectContext(project);
        return Response.json({ threads: threads.map(({ detail: _detail, ...brief }) => brief) });
      }
      const entity = /^\/v1\/(threads|projects)\/([^/]+)$/.exec(url.pathname);
      if (method === "GET" && entity) {
        const level = url.searchParams.get("level") ?? "brief";
        if (entity[1] === "threads" && level !== "brief") store.wantDigest(entity[2]!);
        return respond(store.view(entity[1] as "threads" | "projects",entity[2]!,level));
      }
      if (method === "DELETE" && entity?.[1] === "projects") {
        return store.removeProject(entity[2]!) ? Response.json({ removed: true }) : Response.json({ error: "项目不存在" }, { status: 404 });
      }
      const day = /^\/v1\/days\/(\d{4}-\d{2}-\d{2})$/.exec(url.pathname);
      if (method === "GET" && day) return respond(store.dayView(day[1]!));
      const segment = /^\/v1\/days\/(\d{4}-\d{2}-\d{2})\/segments\/([\w:%.-]{1,200})$/.exec(url.pathname);
      if (segment && (method === "PATCH" || method === "DELETE")) {
        let id: string;
        try { id = decodeURIComponent(segment[2]!); } catch { throw new InputError("段编号无效"); }
        if (method === "PATCH") return respond(correctTimelineSegment(store,segment[1]!,id,await readJSON()));
        const deleted = deleteTimelineSegment(store,segment[1]!,id,await readJSON());
        return deleted?.changed ? Response.json({ error: "这段记录已更新，请刷新后再确认删除" }, { status: 409 }) : respond(deleted);
      }
      const pending = /^\/v1\/pending\/([^/]+)$/.exec(url.pathname);
      if (method === "POST" && pending) {
        const body = await readJSON() as Record<string,unknown> | null;
        if (!body || typeof body !== "object" || typeof body.action !== "string" || body.name !== undefined && typeof body.name !== "string" || body.target !== undefined && typeof body.target !== "string") throw new InputError("待确认操作参数无效");
        store.resolvePending(pending[1]!,body.action,body.name as string | undefined,body.target as string | undefined);
        return Response.json({ resolved: true });
      }
      const detach = /^\/v1\/facts\/([^/]+)\/detach$/.exec(url.pathname);
      if (method === "POST" && detach) return Response.json(store.detachFact(detach[1]!));
      if (method === "POST" && url.pathname === "/v1/facts") {
        const body = await readJSON() as Record<string,unknown> | null;
        if (!body || typeof body !== "object" || !["decision","rejected","open","next","inference"].includes(String(body.kind)) || typeof body.text !== "string" || !body.text.trim() || !Array.isArray(body.evidence) || !body.evidence.every(id => typeof id === "string")) throw new InputError("事实参数无效");
        // 网页把已有 fact 的字段原样回传，没有归属的字段是 null，按未提供处理。
        for (const field of ["thread_id","project_id","reason","supersedes","valid_at"]) {
          if (body[field] === null) delete body[field];
          if (body[field] !== undefined && typeof body[field] !== "string") throw new InputError("事实字段类型无效");
        }
        if (body.confidence !== undefined && (typeof body.confidence !== "number" || !Number.isFinite(body.confidence) || body.confidence < 0 || body.confidence > 1)) throw new InputError("置信度无效");
        if (body.valid_at !== undefined && !Number.isFinite(Date.parse(body.valid_at as string))) throw new InputError("事实时间无效");
        const at = new Date().toISOString();
        const fact: Fact = { id: ulid(),kind: body.kind as Fact["kind"],text: body.text,evidence: body.evidence as string[],origin: "user",valid_at: body.valid_at as string ?? at,created_at: at,thread_id: body.thread_id as string | undefined,project_id: body.project_id as string | undefined,reason: body.reason as string | undefined,confidence: body.confidence as number | undefined };
        store.writeFact(fact,body.supersedes as string | undefined);
        return Response.json(fact);
      }
      if (method === "POST" && url.pathname === "/v1/ingest") {
        const body = await readJSON();
        if (!body || typeof body !== "object" || !Array.isArray((body as { records?: unknown }).records)
          || typeof (body as { device?: unknown }).device !== "string" || !/^[a-z0-9][a-z0-9-]{0,62}$/.test((body as { device: string }).device)) {
          throw new InputError("需要 device 和 records 数组");
        }
        return Response.json(db.ingest((body as { records: unknown[] }).records));
      }
      if (method === "DELETE" && url.pathname === "/v1/records") {
        const body = await readJSON() as { ids?: unknown };
        if (!body || !Array.isArray(body.ids) || body.ids.length < 1 || body.ids.length > 100
          || body.ids.some(id => typeof id !== "string" || !/^[0-9A-HJKMNP-TV-Z]{26}$/.test(id))) throw new InputError("每次删除需要 1–100 个有效记录 id");
        return Response.json({ deleted: db.deleteMany(body.ids) });
      }
      if (method === "GET" && url.pathname === "/v1/records") return Response.json(db.list(url.searchParams));
      if (method === "GET" && url.pathname === "/v1/history/segments") return Response.json(historySegments(db,url.searchParams));
      const conversation = /^\/v1\/conversations\/([0-9A-HJKMNP-TV-Z]{26})$/.exec(url.pathname);
      if (method === "GET" && conversation) return Response.json(conversationDetail(db,conversation[1]!));
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
      if (isDatabaseBusy(e)) return Response.json({ error: "数据库忙，稍后再试" }, { status: 503 });
      logFailure("server.request", e);
      return Response.json({ error: "存储操作失败" }, { status: 500 });
    }
  };
  return async (request: Request): Promise<Response> => {
    const response = await handle(request);
    // Agent 内部也会捕获库忙并返回响应，统一在出口计数，避免漏计或重复计数。
    if (response.status === 503) busy.record(new URL(request.url).pathname);
    return response;
  };
}

export function startServer(options: {
  db: HubDB; token: string; agentToken?: string; port?: number; settings?: SettingsDeps; deviceDeps?: DeviceDeps;
}) {
  const databaseFile = options.db.db.name;
  const dataDir = options.settings?.dataDir ?? (databaseFile === ":memory:" ? null : dirname(databaseFile));
  const devices = new DeviceService(options.db, dataDir === null ? DEFAULT_LAN_PORT : resolveLanPort(dataDir), options.deviceDeps);
  let handler: ReturnType<typeof createHandler>;
  const server = Bun.serve({ hostname: "127.0.0.1", port: options.port ?? DEFAULT_PORT, fetch(request, server) {
    handler ??= createHandler({ ...options, devices, port: server.port });
    // 测试连接最长等 60 秒，超过 Bun 默认的 10 秒空闲超时。
    if (new URL(request.url).pathname === "/v1/settings/models/test") server.timeout(request, 75);
    return handler(request);
  } });
  devices.start();
  return {
    port: server.port, hostname: server.hostname, url: server.url,
    async stop(force?: boolean) { await Promise.all([server.stop(force), devices.stop(force)]); },
  };
}
