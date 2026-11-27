import { ModelError } from "./error-category.ts";
import { mkdtemp, writeFile, readFile, rm } from "node:fs/promises";
import { join } from "node:path";
import { homedir, tmpdir } from "node:os";
import { cliEnv, parseJSON, run, tokens } from "./process.ts";
import type { BackendContext } from "./types.ts";

// codex exec 默认给每次调用带上编程 Agent 的整套说明和工具（代码执行、多 Agent 协作、协作模式、技能清单），
// 一个只回 "ok" 的调用也要约 1.1 万输入 token，占提炼总用量一半以上（2026-11-12 实测）。
// 提炼只需要按 schema 回 JSON：换成一句说明，关掉这些附加内容，同样的调用降到约 1800 token。
const INSTRUCTIONS = "用户消息是一个 JSON 对象：system 是任务说明，prompt 是任务输入。按 system 完成 prompt，只输出符合给定 JSON schema 的结果，不调用任何工具。";

// 代码执行模式和多 Agent 工具由模型目录里的 tool_mode / multi_agent_version 强制打开，配置项关不掉；
// 用本机 codex 自己的目录去掉这几项后作为覆盖传入。读不到或格式不认识时不覆盖，照常调用。
const PROBE_TTL = 60 * 60_000;
const FAILED_PROBE_TTL = 30_000;
type Probe<T> = { until: number; result: Promise<T> };
let catalog: Probe<string | null> | null = null;

function cacheProbe<T>(pending: Promise<T>, succeeded: (result: T) => boolean = Boolean): Probe<T> {
  // 并发调用复用正在进行的探测。得到结果后才开始计算有效期。
  const entry = { until: Infinity, result: pending };
  entry.result = pending.then(result => {
    entry.until = Date.now() + (succeeded(result) ? PROBE_TTL : FAILED_PROBE_TTL);
    return result;
  });
  return entry;
}

export function trimCatalog(raw: string): string | null {
  try {
    const parsed = JSON.parse(raw) as { models?: Record<string, unknown>[] };
    if (!Array.isArray(parsed?.models) || !parsed.models.length) return null;
    for (const m of parsed.models) {
      if (!m || typeof m !== "object") return null;
      delete m.tool_mode; delete m.multi_agent_version;
      m.experimental_supported_tools = [];
    }
    return JSON.stringify(parsed);
  } catch { return null; }
}

function readCatalog(ctx: BackendContext): Promise<string | null> {
  return new Promise(resolve => {
    let out = "", done = false;
    let timer: ReturnType<typeof setTimeout> | undefined;
    const finish = (v: string | null) => { if (!done) { done = true; clearTimeout(timer); resolve(v); } };
    let child;
    try { child = ctx.spawn("codex", ["debug", "models"], { cwd: ctx.cwd, stdio: "pipe", env: cliEnv() }); }
    catch { finish(null); return; }
    timer = setTimeout(() => { child.kill("SIGKILL"); finish(null); }, 10_000);
    child.stdout.setEncoding("utf8");
    child.stdout.on("data", (c: string) => { out += c; if (out.length > 4 * 1024 * 1024) { child.kill("SIGKILL"); finish(null); } });
    child.on("error", () => finish(null));
    child.on("close", code => finish(code === 0 ? trimCatalog(out) : null));
    child.stdin.end();
  });
}

function cachedCatalog(ctx: BackendContext): Promise<string | null> {
  if (!catalog || Date.now() >= catalog.until) catalog = cacheProbe(readCatalog(ctx));
  return catalog.result;
}

// codex 默认先走 WebSocket，连不上要超时重连 5 次（约 110 秒）才退回 HTTPS（2026-11-12 实测：用户换了代理后
// 每次提炼调用从约 10 秒变成约 115 秒，接近 180 秒上限）。用 ChatGPT 账号登录时，提炼改用一个只走 HTTPS 的
// provider，仍由 codex 自己的登录认证，不读也不存令牌。用户 2026-11-12 确认。其他登录方式不改。
const CHATGPT_HTTPS = '{name="OpenAI",base_url="https://chatgpt.com/backend-api/codex",wire_api="responses",requires_openai_auth=true,supports_websockets=false}';
type LoginStatus = "chatgpt" | "other" | "none";
let login: Probe<LoginStatus> | null = null;

function readLogin(ctx: BackendContext): Promise<LoginStatus> {
  return new Promise(resolve => {
    let out = "", done = false;
    let timer: ReturnType<typeof setTimeout> | undefined;
    const finish = (v: LoginStatus) => { if (!done) { done = true; clearTimeout(timer); resolve(v); } };
    let child;
    try { child = ctx.spawn("codex", ["login", "status"], { cwd: ctx.cwd, stdio: "pipe", env: cliEnv() }); }
    catch { finish("other"); return; }
    timer = setTimeout(() => { child.kill("SIGKILL"); finish("other"); }, 10_000);
    child.stdout.setEncoding("utf8"); child.stderr.setEncoding("utf8");
    // CLI 可能写到 stdout 或 stderr。只取已知状态，其余内容不保留。
    const take = (c: string) => { out = (out + c).slice(-2000); };
    child.stdout.on("data", take); child.stderr.on("data", take);
    child.on("error", () => finish("other"));
    child.on("close", code => {
      if (code === 0 && /using ChatGPT/i.test(out)) finish("chatgpt");
      else if (code !== null && code !== 0 && /\bNot logged in\b/i.test(out)) finish("none");
      else finish("other");
    });
    child.stdin.end();
  });
}
function cachedLogin(ctx: BackendContext, refresh?: Probe<LoginStatus>): Probe<LoginStatus> {
  if (!login || login === refresh || Date.now() >= login.until) {
    login = cacheProbe(readLogin(ctx), status => status === "chatgpt");
  }
  return login;
}

function loginRequired(ctx: BackendContext): never {
  try { ctx.observer?.failure?.("codex login status: Not logged in"); }
  catch { throw new ModelError("usage_record_failed"); }
  throw new ModelError("cli_not_logged_in");
}
// 仍用 --ignore-user-config：用户自己的 MCP、钩子、通知、推理强度、服务档位这些不该带进每次整理。
// 但“怎么连上模型”跟着用户走：用户在 config.toml 里选的 provider（中转站、自定义 base_url）、ChatGPT 地址和登录凭据存放位置
// 原样用 -c 传回去（2026-11-27：用户 codex 走自己的中转站配置，终端里正常、Tacit 里调用失败）。
const CONNECTION_KEYS = ["chatgpt_base_url", "openai_base_url", "cli_auth_credentials_store", "forced_chatgpt_workspace_id"] as const;

function tomlValue(value: unknown): string | null {
  if (typeof value === "string") return JSON.stringify(value);
  if (typeof value === "boolean" || (typeof value === "number" && Number.isFinite(value))) return String(value);
  if (Array.isArray(value)) {
    const items = value.map(tomlValue);
    return items.every(i => i !== null) ? `[${items.join(",")}]` : null;
  }
  if (value && typeof value === "object" && Object.getPrototypeOf(value) === Object.prototype) {
    const parts: string[] = [];
    for (const [k, v] of Object.entries(value)) {
      const text = tomlValue(v);
      if (text === null) return null;
      parts.push(`${/^[A-Za-z0-9_-]+$/.test(k) ? k : JSON.stringify(k)}=${text}`);
    }
    return `{${parts.join(",")}}`;
  }
  return null;
}

/** 从用户的 config.toml 取出连接相关的设置；读不到或看不懂时返回空，照旧用 codex 默认连接。 */
export async function connectionOverrides(env: NodeJS.ProcessEnv): Promise<{ args: string[]; custom: boolean }> {
  const home = env.CODEX_HOME || join(env.HOME || homedir(), ".codex");
  let config: Record<string, any>;
  try { config = Bun.TOML.parse(await readFile(join(home, "config.toml"), "utf8")) as Record<string, any>; }
  catch { return { args: [], custom: false }; }
  const profile = typeof config.profile === "string" ? config.profiles?.[config.profile] : undefined;
  const pick = (key: string) => profile && Object.hasOwn(profile, key) ? profile[key] : config[key];
  const args: string[] = [];
  const selected = pick("model_provider");
  const provider = typeof selected === "string" && selected ? selected : "openai";
  const table = config.model_providers?.[provider];
  const text = table === undefined ? null : tomlValue(table);
  if (text !== null) args.push("-c", `model_providers.${/^[A-Za-z0-9_-]+$/.test(provider) ? provider : JSON.stringify(provider)}=${text}`);
  if (selected === provider) args.push("-c", `model_provider=${JSON.stringify(provider)}`);
  for (const key of CONNECTION_KEYS) {
    const text = pick(key) === undefined ? null : tomlValue(pick(key));
    if (text !== null) args.push("-c", `${key}=${text}`);
  }
  // 用户自己选了非默认 provider 或改了服务地址时，保留这条连接。
  return { args, custom: provider !== "openai" || Boolean(table?.base_url || pick("openai_base_url") || pick("chatgpt_base_url")) };
}

/** 手动测试连接时，清掉上次的模型目录和登录探测结果。 */
export function resetCodexProbes() { catalog = null; login = null; }

export async function codexCLI(ctx: BackendContext): Promise<unknown> {
  const connection = await connectionOverrides(cliEnv());
  const probe = connection.custom ? undefined : cachedLogin(ctx);
  const status = await probe?.result;
  if (status === "none") loginRequired(ctx);
  const https = status === "chatgpt";
  const trimmed = await cachedCatalog(ctx);
  const dir = await mkdtemp(join(tmpdir(), "record-anything-llm-"));
  try {
    const schema = join(dir, "schema.json"), output = join(dir, "result.json"), instructions = join(dir, "instructions.md"), models = join(dir, "models.json");
    await writeFile(schema, JSON.stringify(ctx.req.schema), { mode: 0o600 });
    await writeFile(instructions, INSTRUCTIONS, { mode: 0o600 });
    if (trimmed) await writeFile(models, trimmed, { mode: 0o600 });
    const stdout = await run(ctx, "codex", ["exec", "--ephemeral", "--sandbox", "read-only", "--skip-git-repo-check", "-C", ctx.cwd, "--output-schema", schema, "-o", output, "-m", ctx.config.model,
      "--ignore-user-config", "--ignore-rules", "--json", "-c", 'approval_policy="never"', "-c", "project_doc_max_bytes=0", "-c", 'web_search="disabled"',
      "-c", `model_instructions_file=${JSON.stringify(instructions)}`, ...(trimmed ? ["-c", `model_catalog_json=${JSON.stringify(models)}`] : []),
      "-c", "include_permissions_instructions=false", "-c", "include_environment_context=false", "-c", "include_apps_instructions=false", "-c", "include_collaboration_mode_instructions=false",
      "-c", "features.shell_tool=false", "-c", "features.unified_exec=false", "-c", "features.view_image=false", "-c", "features.image_generation=false", "-c", "features.apps=false", "-c", "features.memories=false", "-c", "features.multi_agent=false", "-c", "features.multi_agent_v2=false", "-c", "features.sleep_tool=false", "-c", "features.tool_suggest=false", "-c", "features.plugins=false", "-c", "features.hooks=false",
      "-c", "features.goals=false", "-c", "features.collaboration_modes=false", "-c", "features.skill_search=false",
      ...connection.args,
      ...(https ? ["-c", `model_providers.ra-https=${CHATGPT_HTTPS}`, "-c", 'model_provider="ra-https"'] : []), "-"]).catch(async error => {
      if (probe && error instanceof ModelError && (error.code === "timeout" || error.code === "cli_network")) {
        if (await cachedLogin(ctx, probe).result === "none") loginRequired(ctx);
      }
      throw error;
    });
    // JSONL 事件只取用量，不把事件正文写入日志。
    for (const line of stdout.split("\n").filter(Boolean)) {
      try {
        const event = JSON.parse(line);
        if (event.type === "turn.completed") {
          ctx.metrics.inputTokens = tokens(event.usage?.input_tokens);
          ctx.metrics.outputTokens = tokens(event.usage?.output_tokens);
        }
      } catch { /* CLI 诊断行不属于模型结果。 */ }
    }
    let text: string;
    try { text = await readFile(output, "utf8"); } catch { throw new ModelError("cli_failed"); }
    ctx.metrics.outputChars = Array.from(text).length;
    try { ctx.observer?.response(text); } catch { throw new ModelError("usage_record_failed"); }
    return parseJSON(text);
  } finally { await rm(dir, { recursive: true, force: true }); }
}
