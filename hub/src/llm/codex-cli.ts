import { mkdtemp, writeFile, readFile, rm } from "node:fs/promises";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { cliEnv, parseJSON, run, tokens } from "./process.ts";
import type { BackendContext } from "./types.ts";

// codex exec 默认给每次调用带上编程 Agent 的整套说明和工具（代码执行、多 Agent 协作、协作模式、技能清单），
// 一个只回 "ok" 的调用也要约 1.1 万输入 token，占提炼总用量一半以上（2026-11-12 实测）。
// 提炼只需要按 schema 回 JSON：换成一句说明，关掉这些附加内容，同样的调用降到约 1800 token。
const INSTRUCTIONS = "用户消息是一个 JSON 对象：system 是任务说明，prompt 是任务输入。按 system 完成 prompt，只输出符合给定 JSON schema 的结果，不调用任何工具。";

// 代码执行模式和多 Agent 工具由模型目录里的 tool_mode / multi_agent_version 强制打开，配置项关不掉；
// 用本机 codex 自己的目录去掉这几项后作为覆盖传入。读不到或格式不认识时不覆盖，照常调用。
const CATALOG_TTL = 60 * 60_000;
let catalog: { at: number; text: Promise<string | null> } | null = null;

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
    const finish = (v: string | null) => { if (!done) { done = true; clearTimeout(timer); resolve(v); } };
    let child;
    try { child = ctx.spawn("codex", ["debug", "models"], { cwd: ctx.cwd, stdio: "pipe", env: cliEnv() }); }
    catch { finish(null); return; }
    const timer = setTimeout(() => { child.kill("SIGKILL"); finish(null); }, 10_000);
    child.stdout.setEncoding("utf8");
    child.stdout.on("data", (c: string) => { out += c; if (out.length > 4 * 1024 * 1024) { child.kill("SIGKILL"); finish(null); } });
    child.on("error", () => finish(null));
    child.on("close", code => finish(code === 0 ? trimCatalog(out) : null));
    child.stdin.end();
  });
}

function cachedCatalog(ctx: BackendContext): Promise<string | null> {
  if (!catalog || Date.now() - catalog.at > CATALOG_TTL) catalog = { at: Date.now(), text: readCatalog(ctx) };
  return catalog.text;
}

// codex 默认先走 WebSocket，连不上要超时重连 5 次（约 110 秒）才退回 HTTPS（2026-11-12 实测：用户换了代理后
// 每次提炼调用从约 10 秒变成约 115 秒，接近 180 秒上限）。用 ChatGPT 账号登录时，提炼改用一个只走 HTTPS 的
// provider，仍由 codex 自己的登录认证，不读也不存令牌。用户 2026-11-12 确认。其他登录方式不改。
const CHATGPT_HTTPS = '{name="OpenAI",base_url="https://chatgpt.com/backend-api/codex",wire_api="responses",requires_openai_auth=true,supports_websockets=false}';
let login: { at: number; chatgpt: Promise<boolean> } | null = null;

function readLogin(ctx: BackendContext): Promise<boolean> {
  return new Promise(resolve => {
    let out = "", done = false;
    const finish = (v: boolean) => { if (!done) { done = true; clearTimeout(timer); resolve(v); } };
    let child;
    try { child = ctx.spawn("codex", ["login", "status"], { cwd: ctx.cwd, stdio: "pipe", env: cliEnv() }); }
    catch { finish(false); return; }
    const timer = setTimeout(() => { child.kill("SIGKILL"); finish(false); }, 10_000);
    child.stdout.setEncoding("utf8"); child.stderr.setEncoding("utf8");
    // 状态写在 stdout 或 stderr 里都有可能，只看是不是 ChatGPT 登录，不保留其他内容。
    const take = (c: string) => { out = (out + c).slice(-2000); };
    child.stdout.on("data", take); child.stderr.on("data", take);
    child.on("error", () => finish(false));
    child.on("close", code => finish(code === 0 && /using ChatGPT/i.test(out)));
    child.stdin.end();
  });
}
function cachedLogin(ctx: BackendContext): Promise<boolean> {
  if (!login || Date.now() - login.at > CATALOG_TTL) login = { at: Date.now(), chatgpt: readLogin(ctx) };
  return login.chatgpt;
}
/** 测试用：清掉缓存的模型目录和登录方式。 */
export function resetCodexCatalog() { catalog = null; login = null; }

export async function codexCLI(ctx: BackendContext): Promise<unknown> {
  const trimmed = await cachedCatalog(ctx), https = await cachedLogin(ctx);
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
      ...(https ? ["-c", `model_providers.ra-https=${CHATGPT_HTTPS}`, "-c", 'model_provider="ra-https"'] : []), "-"]);
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
    try { text = await readFile(output, "utf8"); } catch { throw new Error("Codex 未写入结果文件"); }
    ctx.metrics.outputChars = Array.from(text).length;
    return parseJSON(text);
  } finally { await rm(dir, { recursive: true, force: true }); }
}
