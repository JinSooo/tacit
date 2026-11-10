// 设置接口：/v1/settings/{hub,models,keys/:provider,models/test,general}。契约见 docs/contracts.md 第 3.1 节。
// API key 只进钥匙串：不进响应、错误信息、日志和文件。
import { createServer } from "node:net";
import { InputError, type HubDB } from "./db.ts";
import { resolvePort, writeHubPort, PORT_MIN, PORT_MAX } from "./hub-json.ts";
import { DEFAULT_TIERS, KEY_PROVIDERS, PROVIDERS, TIERS, loadConfig, saveConfig, validateTier, validateTiers, type KeyProvider } from "./llm/config.ts";
import { KEY_PATTERN, systemKeychain, type Keychain } from "./llm/keychain.ts";
import { createLLM, type ModelConfig, type ReadKey, type Spawn, type Tier } from "./llm/index.ts";
import { GENERAL_DEFAULTS, GENERAL_RANGES, readGeneral, updateGeneral } from "./general-settings.ts";
import { redactString } from "./redact.ts";

export interface SettingsDeps {
  dataDir: string;
  env?: NodeJS.ProcessEnv;
  keychain?: Keychain;
  /** 试绑定端口，失败时抛出（code 为 EADDRINUSE 表示被占用）。 */
  probePort?: (port: number) => Promise<void>;
  /** PUT /v1/settings/hub 写入成功、响应发出后调用；中枢据此退出，由 launchd 用新端口拉起。 */
  restart?: () => void;
  /** 测试连接用的后端注入（测试里替换成合成进程）。 */
  llm?: { spawn?: Spawn; readKey?: ReadKey };
}

export const PROVIDER_INFO = [
  { id: "claude-cli", label: "Claude Code（本机已登录的 claude -p）", needs_key: false, base_url: false },
  { id: "codex-cli", label: "Codex（本机已登录的 codex exec）", needs_key: false, base_url: false },
  { id: "anthropic", label: "Anthropic API", needs_key: true, base_url: true },
  { id: "openai-compatible", label: "OpenAI 兼容 API / 中转站", needs_key: true, base_url: true },
] as const satisfies readonly { id: typeof PROVIDERS[number]; label: string; needs_key: boolean; base_url: boolean }[];

/** 按 distill/run.ts 里各档的实际调用写。 */
export const TIER_INFO: Record<Tier, { label: string; description: string }> = {
  minute: { label: "分钟档", description: "每 15 分钟一轮：把新的活动片段归到线程，判断线程是工作还是生活、是否属于项目，并由详细版生成简略版。调用最频繁。" },
  hour: { label: "小时档", description: "每小时一轮：把线程的新片段写进线程详细版，并汇总项目摘要。输入最长。" },
  day: { label: "天档", description: "写每天的日记：当天每 3 小时刷新，过去的日子有变化时重写；整理启用前的历史也用这一档。" },
};

const TEST_SCHEMA = { type: "object", properties: { ok: { type: "boolean" } }, required: ["ok"], additionalProperties: false };
const TEST_TIMEOUT_MS = 60_000;

function defaultProbe(port: number): Promise<void> {
  return new Promise((resolve, reject) => {
    const probe = createServer();
    probe.once("error", reject);
    probe.listen({ port, host: "127.0.0.1", exclusive: true }, () => probe.close(() => resolve()));
  });
}
function object(value: unknown): Record<string, unknown> {
  if (!value || typeof value !== "object" || Array.isArray(value)) throw new InputError("请求体必须是对象");
  return value as Record<string, unknown>;
}
/** 校验函数抛的是普通 Error（加载 models.json 时也用），接口里转成 400。 */
function asInput<T>(fn: () => T): T {
  try { return fn(); } catch (error) { throw new InputError(error instanceof Error ? error.message : "参数无效"); }
}
const fail = (status: number, error: string) => Response.json({ error }, { status });

export function createSettings(deps: SettingsDeps) {
  const env = deps.env ?? process.env;
  const keychain = deps.keychain ?? systemKeychain;
  let testing = false;

  async function keyStatus(): Promise<Record<KeyProvider, boolean | null>> {
    const entries = await Promise.all(KEY_PROVIDERS.map(async p => [p, await keychain.has(p).catch(() => null)] as const));
    return Object.fromEntries(entries) as Record<KeyProvider, boolean | null>;
  }
  async function models() {
    let tiers: Record<Tier, ModelConfig> = structuredClone(DEFAULT_TIERS), config_error: string | null = null;
    try { tiers = await loadConfig(deps.dataDir); } catch (error) { config_error = error instanceof Error ? error.message : "models.json 无效"; }
    return { tiers, config_error, keys: await keyStatus(), providers: PROVIDER_INFO, tier_info: TIER_INFO };
  }
  function general(hub: HubDB) {
    return { ...readGeneral(hub), defaults: GENERAL_DEFAULTS, ranges: GENERAL_RANGES };
  }

  return async function handle(request: Request, url: URL, ctx: { db: HubDB; port: number; readJSON: () => Promise<unknown> }): Promise<Response | null> {
    const { pathname } = url, method = request.method;
    if (!pathname.startsWith("/v1/settings/")) return null;

    if (pathname === "/v1/settings/hub") {
      const locked = env.RA_PORT !== undefined;
      if (method === "GET") return Response.json({ port: ctx.port, listen: "127.0.0.1", lan: false, locked });
      if (method === "PUT") {
        const body = object(await ctx.readJSON());
        if (Object.keys(body).some(k => k !== "port")) throw new InputError("只接受 port");
        const port = body.port;
        if (typeof port !== "number" || !Number.isInteger(port) || port < PORT_MIN || port > PORT_MAX) throw new InputError(`端口必须是 ${PORT_MIN}–${PORT_MAX} 的整数`);
        if (locked) return fail(409, "端口由环境变量 RA_PORT 固定，不能在这里修改");
        if (port === ctx.port) {
          writeHubPort(deps.dataDir, port);
          return Response.json({ port, restarting: false });
        }
        try { await (deps.probePort ?? defaultProbe)(port); }
        catch (error) {
          return fail(409, (error as NodeJS.ErrnoException)?.code === "EADDRINUSE" ? `端口 ${port} 已被占用，请换一个` : `无法在 127.0.0.1 上使用端口 ${port}`);
        }
        try { writeHubPort(deps.dataDir, port); } catch { return fail(500, "无法写入 hub.json"); }
        // 响应发出后再退出；不在这里直接退出，免得网页收不到结果。
        if (deps.restart) setTimeout(deps.restart, 300);
        return Response.json({ port, restarting: Boolean(deps.restart) });
      }
    }

    if (pathname === "/v1/settings/models") {
      if (method === "GET") return Response.json(await models());
      if (method === "PUT") {
        const body = object(await ctx.readJSON());
        if (Object.keys(body).some(k => k !== "tiers")) throw new InputError("只接受 tiers");
        // 先校验（和读取 models.json 同一套规则），通过了才写文件。
        const tiers = asInput(() => validateTiers(body.tiers));
        try { await saveConfig(deps.dataDir, tiers); }
        catch { return fail(500, "无法写入 models.json"); }
        return Response.json(await models());
      }
    }

    if (pathname === "/v1/settings/models/test" && method === "POST") {
      const body = object(await ctx.readJSON());
      if (Object.keys(body).some(k => k !== "tier" && k !== "config")) throw new InputError("只接受 tier 和 config");
      if (!TIERS.includes(body.tier as Tier)) throw new InputError("tier 必须是 minute、hour 或 day");
      const tier = body.tier as Tier;
      let config: ModelConfig;
      if (body.config !== undefined) config = asInput(() => validateTier(body.config, "config"));
      else {
        try { config = (await loadConfig(deps.dataDir))[tier]; }
        catch (error) { throw new InputError(error instanceof Error ? error.message : "models.json 无效"); }
      }
      if (testing) return fail(409, "上一次测试还没结束");
      testing = true;
      try {
        // 不记进 llm_usage：用量表统计的是提炼的消耗，测试调用不混进去。
        const llm = createLLM({
          dataDir: deps.dataDir, recordUsage: () => {}, ...deps.llm,
          configs: async () => ({ ...structuredClone(DEFAULT_TIERS), [tier]: config }),
        });
        const result = await llm.complete<{ ok: boolean }>({ tier, system: "这是连接测试。只按 schema 返回 {\"ok\": true}。", prompt: "连接测试：返回 ok=true。", schema: TEST_SCHEMA, timeoutMs: TEST_TIMEOUT_MS });
        return Response.json({ ok: result.ok, ms: result.ms, provider: config.provider, model: config.model, error: result.ok ? null : redactString(result.error).text.slice(0, 300) });
      } finally { testing = false; }
    }

    const key = /^\/v1\/settings\/keys\/([^/]+)$/.exec(pathname);
    if (key && (method === "PUT" || method === "DELETE")) {
      const provider = key[1] as KeyProvider;
      if (!KEY_PROVIDERS.includes(provider)) throw new InputError("只能为 anthropic、openai-compatible 设置 API key");
      if (method === "DELETE") {
        try { return Response.json({ provider, deleted: await keychain.remove(provider) }); }
        catch { return fail(500, "删除钥匙串条目失败"); }
      }
      const body = object(await ctx.readJSON());
      if (Object.keys(body).some(k => k !== "key")) throw new InputError("只接受 key");
      const value = typeof body.key === "string" ? body.key.trim() : "";
      if (!KEY_PATTERN.test(value)) throw new InputError("API key 必须是 8–1024 个可见 ASCII 字符，不能含空格、双引号或反斜杠");
      try { await keychain.set(provider, value); }
      catch { return fail(500, "写入钥匙串失败"); }
      return Response.json({ provider, set: true });
    }

    if (pathname === "/v1/settings/general") {
      if (method === "GET") return Response.json(general(ctx.db));
      if (method === "PUT") { updateGeneral(ctx.db, await ctx.readJSON()); return Response.json(general(ctx.db)); }
    }
    return null;
  };
}
