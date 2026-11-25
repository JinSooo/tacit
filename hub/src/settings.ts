import { acknowledgeSecurityEvent, auditSecurity, pendingSecurityEvents, securityAudit, securityEventID } from "./security-audit.ts";
// 设置接口：/v1/settings/{hub,models,keys/:provider,models/test,general,agents}。契约见 docs/contracts.md 第 3.1 节。
// API key 只进钥匙串：不进响应、错误信息、日志和文件。
import { createServer } from "node:net";
import { InputError, type HubDB } from "./db.ts";
import { hubModeOf, resolvePort, writeHubPort, PORT_MIN, PORT_MAX, type HubMode } from "./hub-json.ts";
import { friendlyConfigError, DEFAULT_TIERS, KEY_PROVIDERS, PROVIDERS, TIERS, isCliProvider, loadConfig, saveConfig, validateTier, validateTiers, type KeyProvider } from "./llm/config.ts";
import { KEY_PATTERN, systemKeychain, type Keychain } from "./llm/keychain.ts";
import { createLLM, type ModelConfig, type ReadKey, type Spawn, type Tier } from "./llm/index.ts";
import { GENERAL_DEFAULTS, GENERAL_RANGES, readGeneral, updateGeneral } from "./general-settings.ts";
import { readModelUsage } from "./model-usage.ts";
import { redactString } from "./redact.ts";
import { RuntimeLog, appliedCall } from "./runtime-log.ts";
import { isLoopback, localModels } from "./llm/local.ts";
import { agentStatus, connectAgent, type AgentTool, type InstallEnvironment } from "./agents-install.ts";

export interface SettingsDeps {
  dataDir: string;
  env?: NodeJS.ProcessEnv;
  mode?: HubMode;
  keychain?: Keychain;
  /** 试绑定端口，失败时抛出（code 为 EADDRINUSE 表示被占用）。 */
  probePort?: (port: number) => Promise<void>;
  /** PUT /v1/settings/hub 写入成功、响应发出后调用；中枢据此退出，由 launchd 用新端口拉起。 */
  restart?: () => void;
  /** 测试连接用的后端注入（测试里替换成合成进程）。 */
  llm?: { spawn?: Spawn; readKey?: ReadKey };
  /** 接入 AI 工具时的家目录、命令查找和外部命令（测试里换成临时目录和假命令）。 */
  agents?: InstallEnvironment;
}

export const PROVIDER_INFO = [
  { id: "claude-cli", label: "Claude Code 账号", needs_key: false, base_url: false },
  { id: "codex-cli", label: "Codex 账号", needs_key: false, base_url: false },
  { id: "anthropic", label: "Anthropic API", needs_key: true, base_url: true },
  { id: "openai-compatible", label: "OpenAI 兼容 API 或中转站", needs_key: true, base_url: true },
] as const satisfies readonly { id: typeof PROVIDERS[number]; label: string; needs_key: boolean; base_url: boolean }[];

/** 按 distill/run.ts 里各档的实际调用写。 */
export const TIER_INFO: Record<Tier, { label: string; description: string }> = {
  minute: { label: "实时整理", description: "每 15 分钟把新记录归到事项和项目里，调用最多，适合选快一些的模型。" },
  hour: { label: "每小时汇总", description: "每小时把事项的新进展写进详细记录，并汇总每个项目。" },
  day: { label: "每日时间线", description: "写时间线和当天概述，整理启用前的历史也用它。" },
};

const TEST_SCHEMA = { type: "object", properties: { ok: { type: "boolean", enum: [true] } }, required: ["ok"], additionalProperties: false };
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
/** 模型设置的校验错误换成用户能看懂的说法。 */
function asConfigInput<T>(fn: () => T): T {
  try { return fn(); } catch (error) { throw new InputError(friendlyConfigError(error)); }
}
const fail = (status: number, error: string) => Response.json({ error }, { status });

export function createSettings(deps: SettingsDeps) {
  const env = deps.env ?? process.env;
  const mode = deps.mode ?? hubModeOf(env);
  const providers = mode === "server" ? PROVIDER_INFO.filter(p => !isCliProvider(p.id)) : PROVIDER_INFO;
  const keychain = deps.keychain ?? systemKeychain;
  let testing = false;

  async function keyStatus(): Promise<Record<KeyProvider, boolean | null>> {
    const entries = await Promise.all(KEY_PROVIDERS.map(async p => [p, await keychain.has(p).catch(() => null)] as const));
    return Object.fromEntries(entries) as Record<KeyProvider, boolean | null>;
  }
  async function models() {
    let tiers: Record<Tier, ModelConfig> | null = mode === "server" ? null : structuredClone(DEFAULT_TIERS);
    let config_error: string | null = null;
    try { tiers = await loadConfig(deps.dataDir, { mode }); } catch (error) { config_error = error instanceof Error ? error.message : "models.json 无效"; }
    return { tiers, config_error, keys: await keyStatus(), providers, tier_info: TIER_INFO };
  }
  function general(hub: HubDB) {
    return { ...readGeneral(hub), defaults: GENERAL_DEFAULTS, ranges: GENERAL_RANGES, model_usage: readModelUsage(hub) };
  }

  return async function handle(method: string, url: URL, ctx: { db: HubDB; port: number; readJSON: () => Promise<unknown>; lan: boolean; actor?: string; remoteActor?: boolean; deferRestart?: boolean }): Promise<Response | null> {
    const { pathname } = url;
    if (!pathname.startsWith("/v1/settings/")) return null;

    if (pathname === "/v1/settings/hub") {
      const locked = env.RA_PORT !== undefined;
      if (method === "GET") return Response.json({ port: ctx.port, listen: "127.0.0.1", lan: ctx.lan, locked });
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
        if (deps.restart && !ctx.deferRestart) setTimeout(deps.restart, 300);
        return Response.json({ port, restarting: Boolean(deps.restart) });
      }
    }

    if (pathname === "/v1/settings/models") {
      if (method === "GET") return Response.json(await models());
      if (method === "PUT") {
        const body = object(await ctx.readJSON());
        if (Object.keys(body).some(k => k !== "tiers")) throw new InputError("只接受 tiers");
        // 先校验（和读取 models.json 同一套规则），通过了才写文件。
        const tiers = asConfigInput(() => validateTiers(body.tiers, "tiers", { mode }));
        try { await saveConfig(deps.dataDir, tiers, { mode }); }
        catch { return fail(500, "保存模型设置失败，请重试。"); }
        return Response.json(await models());
      }
    }

    if (pathname === "/v1/settings/models/local" && method === "POST") {
      const body = object(await ctx.readJSON());
      if (Object.keys(body).some(k => k !== "base_url") || typeof body.base_url !== "string") throw new InputError("只接受 base_url");
      const config = asConfigInput(() => validateTier({ provider: "openai-compatible", model: "list", base_url: body.base_url }, "config", { mode }));
      if (!isLoopback(config.base_url)) throw new InputError("模型列表只接受本机 HTTP(S) 地址");
      try { return Response.json({ models: await localModels(config.base_url!) }); }
      catch (error) { return fail(503, error instanceof Error ? error.message : "读取本机模型列表失败"); }
    }

    if (pathname === "/v1/settings/models/test" && method === "POST") {
      const body = object(await ctx.readJSON());
      if (Object.keys(body).some(k => k !== "tier" && k !== "config")) throw new InputError("只接受 tier 和 config");
      if (!TIERS.includes(body.tier as Tier)) throw new InputError("tier 必须是 minute、hour 或 day");
      const tier = body.tier as Tier;
      let config: ModelConfig;
      if (body.config !== undefined) config = asConfigInput(() => validateTier(body.config, "config", { mode }));
      else {
        try { config = (await loadConfig(deps.dataDir, { mode }))[tier]; }
        catch (error) { throw new InputError(friendlyConfigError(error)); }
      }
      if (testing) return fail(409, "上一次测试还没结束");
      testing = true;
      try {
        // 不记进 llm_usage：用量表统计的是提炼的消耗，测试调用不混进去。
        const llm = createLLM({
          dataDir: deps.dataDir, mode, recordUsage: () => {}, journal: new RuntimeLog(ctx.db), ...deps.llm,
          configs: async () => ({ minute: config, hour: config, day: config }),
        });
        const result = await llm.complete<{ ok: boolean }>({ tier, task: "connection_test", system: "这是连接测试。只按 schema 返回 {\"ok\": true}。", prompt: "连接测试：返回 ok=true。", schema: TEST_SCHEMA, timeoutMs: TEST_TIMEOUT_MS });
        if (result.ok) appliedCall(ctx.db,result.call_id);
        return Response.json({ ok: result.ok, ms: result.ms, provider: config.provider, model: config.model, error: result.ok ? null : redactString(result.error).text.slice(0, 300) });
      } finally { testing = false; }
    }

    if (pathname === "/v1/settings/security-audit" && method === "GET") {
      return Response.json({ events: securityAudit(ctx.db.db) }, { headers: { "Cache-Control": "no-store" } });
    }

    if (pathname === "/v1/settings/security-events" && method === "GET") {
      return Response.json({ events: pendingSecurityEvents(ctx.db.db, ctx.actor) }, { headers: { "Cache-Control": "no-store" } });
    }
    const securityEvent = /^\/v1\/settings\/security-events\/([^/]+)\/ack$/.exec(pathname)?.[1];
    if (securityEvent && method === "POST") {
      if (!securityEventID(securityEvent)) throw new InputError("安全事件 ID 无效");
      if (!acknowledgeSecurityEvent(ctx.db.db, securityEvent, ctx.actor)) return fail(404, "安全事件不存在");
      return Response.json({ ok: true });
    }

    const key = /^\/v1\/settings\/keys\/([^/]+)$/.exec(pathname);
    if (key && (method === "PUT" || method === "DELETE")) {
      const provider = key[1] as KeyProvider;
      if (!KEY_PROVIDERS.includes(provider)) throw new InputError("只能为 anthropic、openai-compatible 设置 API key");
      // The key store can await while the authenticated device is removed.
      const audit = { actor: ctx.actor, remoteActor: ctx.remoteActor, target: provider };
      if (method === "DELETE") {
        let deleted: boolean;
        try { deleted = await keychain.remove(provider); }
        catch {
          auditSecurity(ctx.db.db, "key.delete", { ...audit, ok: false, code: "secret_error" });
          return fail(500, "删除 API key 失败，请重试。");
        }
        auditSecurity(ctx.db.db, "key.delete", { ...audit, code: deleted ? "deleted" : "absent" });
        return Response.json({ provider, deleted });
      }
      const body = object(await ctx.readJSON());
      if (Object.keys(body).some(k => k !== "key")) throw new InputError("只接受 key");
      const value = typeof body.key === "string" ? body.key.trim() : "";
      if (!KEY_PATTERN.test(value)) throw new InputError("API key 格式不对：应为 8–1024 个英文字母、数字或符号，不能有空格、双引号或反斜杠。");
      try { await keychain.set(provider, value); }
      catch {
        auditSecurity(ctx.db.db, "key.set", { ...audit, ok: false, code: "secret_error" });
        return fail(500, "保存 API key 失败，请重试。");
      }
      auditSecurity(ctx.db.db, "key.set", audit);
      return Response.json({ provider, set: true });
    }

    if (pathname === "/v1/settings/agents" && method === "GET") return Response.json({ tools: agentStatus(deps.agents) });
    const agent = /^\/v1\/settings\/agents\/([^/]+)$/.exec(pathname);
    if (agent && method === "PUT") {
      const id = agent[1] as AgentTool;
      if (id !== "claude-code" && id !== "codex" && id !== "claude-desktop") throw new InputError("只能接入 claude-code、codex 或 claude-desktop");
      const body = object(await ctx.readJSON());
      if (Object.keys(body).some(k => k !== "connected") || typeof body.connected !== "boolean") throw new InputError("只接受 connected（true 或 false）");
      const tool = agentStatus(deps.agents).find(t => t.id === id)!;
      if (body.connected && !tool.installed) return fail(409, `这台 Mac 上没找到 ${tool.label}，装好并登录后再连接`);
      try { const result = connectAgent(id, body.connected, deps.agents); return Response.json({ tools: result.states, note: result.note }); }
      catch (error) {
        // 配置文件损坏、命令执行失败：原样给出原因（不含密钥，路径是用户自己的）。
        return fail(500, `${body.connected ? "连接" : "断开"} ${tool.label} 没有成功：${error instanceof Error ? redactString(error.message).text : "未知原因"}`);
      }
    }

    if (pathname === "/v1/settings/general") {
      if (method === "GET") return Response.json(general(ctx.db));
      if (method === "PUT") { updateGeneral(ctx.db, await ctx.readJSON()); return Response.json(general(ctx.db)); }
    }
    return null;
  };
}
