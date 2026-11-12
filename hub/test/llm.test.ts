import { afterEach, expect, test } from "bun:test";
import { spawn as nodeSpawn } from "node:child_process";
import { chmod, mkdtemp, readFile, readdir, realpath, rm, stat, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { createLLM, type LLMRequest, type Spawn, type UsageRow } from "../src/llm/index.ts";
import { loadConfig } from "../src/llm/config.ts";
import { resetCodexCatalog } from "../src/llm/codex-cli.ts";

const dirs: string[] = [];
const originalFetch = globalThis.fetch;
afterEach(async () => { globalThis.fetch = originalFetch; await Promise.all(dirs.splice(0).map(dir => rm(dir, { recursive: true, force: true }))); });
const schema = { type: "object", properties: { text: { type: "string" } }, required: ["text"], additionalProperties: false };
const request: LLMRequest = { tier: "minute", system: "只返回合成结果", prompt: "把合成词语你好译成英文", schema };

async function directory() { const dir = await realpath(await mkdtemp(join(tmpdir(), "llm-test-"))); dirs.push(dir); return dir; }
async function configure(dir: string, provider: string, extra = {}) {
  const entry = { provider, model: "synthetic-model", ...extra };
  await writeFile(join(dir, "models.json"), JSON.stringify({ tiers: { minute: entry, hour: entry, day: entry } }));
}
async function fixture(provider = "claude-cli", mode = "success") {
  const dir = await directory();
  if (provider !== "claude-cli") await configure(dir, provider);
  const log = join(dir, "calls.jsonl"), script = join(dir, provider === "codex-cli" ? "codex" : "claude");
  // 独立可执行脚本记录真实 argv、stdin、cwd 和进程时序；全部内容是合成数据。
  await writeFile(script, `#!${process.execPath}
import { appendFileSync, writeFileSync, readFileSync, statSync } from "node:fs";
import { dirname } from "node:path";
const args = process.argv.slice(2), mode = process.env.TEST_MODE, log = process.env.TEST_LOG;
if (args[0] === "login") { console.log(mode === "nocatalog" ? "Logged in using an API key" : "Logged in using ChatGPT"); process.exit(0); }
if (args[0] === "debug") { console.log(mode === "nocatalog" ? "not json" : JSON.stringify({models:[{slug:"synthetic-model", tool_mode:"code_mode_only", multi_agent_version:"v1", experimental_supported_tools:["clock"], context_window:1000}]})); process.exit(0); }
const stdin = await Bun.stdin.text();
appendFileSync(log, JSON.stringify({event:"start", pid:process.pid, args, stdin, cwd:process.cwd(), mode:statSync(process.cwd()).mode & 0o777, at:Date.now()})+"\\n");
if (mode === "timeout") await new Promise(() => setInterval(() => {}, 1000));
await Bun.sleep(50);
if (mode === "limit") { console.log(JSON.stringify({type:"result", subtype:"success", is_error:true, result:"You've hit your 5-hour limit · resets 7:20pm"})); process.exit(1); }
if (mode === "exit" || mode === "echo") { console.error(mode === "echo" ? JSON.parse(stdin).prompt : "x".repeat(900)); process.exit(2); }
const data = mode === "schema" ? {text:42} : {text:"hello"};
if (args[0] === "exec") {
  const schemaFile = args[args.indexOf("--output-schema")+1];
  const opt = (k) => { const a = args.find(x => x.startsWith(k + "=")); return a && JSON.parse(a.slice(k.length + 1)); };
  const catalogFile = opt("model_catalog_json");
  appendFileSync(log, JSON.stringify({event:"files", instructions:readFileSync(opt("model_instructions_file"),"utf8"), catalog: catalogFile ? JSON.parse(readFileSync(catalogFile,"utf8")) : null})+"\\n");
  appendFileSync(log, JSON.stringify({event:"schema", file:schemaFile, schema:JSON.parse(readFileSync(schemaFile,"utf8")), mode:statSync(dirname(schemaFile)).mode & 0o777})+"\\n");
  writeFileSync(args[args.indexOf("-o")+1], mode === "json" ? "not json" : JSON.stringify(data));
  console.log(JSON.stringify({type:"turn.completed", usage:{input_tokens:12, output_tokens:3}}));
} else console.log(mode === "json" ? "not json" : JSON.stringify({type:"result", subtype: mode === "envelope" ? "error_during_execution" : "success", is_error:false, structured_output:data, usage:{input_tokens:12, output_tokens:3}}));
appendFileSync(log, JSON.stringify({event:"end", at:Date.now()})+"\\n");
`);
  await chmod(script, 0o700);
  const rows: UsageRow[] = [];
  const spawn: Spawn = (command, args, options) => nodeSpawn(script, args, { ...options, env: { ...options.env, TEST_MODE: mode, TEST_LOG: log } });
  const llm = createLLM({ dataDir: dir, recordUsage: row => { rows.push(row); }, spawn });
  const logs = async () => (await readFile(log, "utf8")).trim().split("\n").map(s => JSON.parse(s));
  return { dir, rows, llm, logs, spawn };
}

test("默认档位；缺档、未知 provider/字段、非法 URL 和 JSON 清楚报错", async () => {
  const dir = await directory();
  expect(await loadConfig(dir)).toEqual({ minute: { provider: "claude-cli", model: "haiku" }, hour: { provider: "claude-cli", model: "sonnet" }, day: { provider: "claude-cli", model: "sonnet" } });
  await writeFile(join(dir, "models.json"), "{");
  await expect(loadConfig(dir)).rejects.toThrow("不是合法 JSON");
  await writeFile(join(dir, "models.json"), '{"tiers":{}}');
  await expect(loadConfig(dir)).rejects.toThrow("tiers.minute");
  for (const [provider, extra, error] of [
    ["unknown", {}, "provider"], ["anthropic", { model: "" }, "model"], ["anthropic", { api_key: "synthetic-key" }, "未知字段"],
    ["anthropic", { base_url: "file:///tmp/x" }, "base_url"], ["anthropic", { base_url: "https://u:p@example.invalid" }, "base_url"], ["claude-cli", { base_url: "https://example.invalid" }, "只适用于 HTTP"],
  ] as const) { await configure(dir, provider, extra); await expect(loadConfig(dir)).rejects.toThrow(error); }
});

test("Claude：安全参数、stdin、cwd、权限、结构化输出和 usage", async () => {
  const f = await fixture();
  const result = await f.llm.complete<{ text: string }>(request);
  expect(result.ok).toBe(true);
  if (result.ok) expect(result.data).toEqual({ text: "hello" });
  const [start] = await f.logs();
  for (const flag of ["-p", "--no-session-persistence", "--strict-mcp-config", "--safe-mode"]) expect(start.args).toContain(flag);
  for (const [flag, value] of [["--output-format", "json"], ["--json-schema", JSON.stringify(schema)], ["--tools", ""], ["--setting-sources", ""], ["--model", "haiku"], ["--permission-prompts", "none"]]) expect(start.args[start.args.indexOf(flag) + 1]).toBe(value);
  expect(start.args).not.toContain("--bare");
  expect(start.args.join(" ")).not.toContain(request.prompt);
  expect(start.args.join(" ")).not.toContain(request.system);
  expect(JSON.parse(start.stdin)).toEqual({ system: request.system, prompt: request.prompt });
  expect(start.cwd).toBe(join(f.dir, "distill-work")); expect(start.mode).toBe(0o700);
  expect(f.rows).toHaveLength(1);
  expect(f.rows[0]).toMatchObject({ tier: "minute", provider: "claude-cli", model: "haiku", ok: 1, input_tokens: 12, output_tokens: 3, output_chars: 16, error: null });
  expect(f.rows[0]!.input_chars).toBe(Array.from(request.system + request.prompt).length);
});

test("Codex：安全参数、临时 schema 与输出、stdin 和 finally 清理", async () => {
  resetCodexCatalog();
  const f = await fixture("codex-cli");
  expect((await f.llm.complete(request)).ok).toBe(true);
  const logs = await f.logs(), start = logs[0], schemaLog = logs.find(l => l.event === "schema");
  // 不带 codex 自己的编程 Agent 说明和工具：换成一句说明，模型目录去掉强制的代码执行模式和多 Agent 工具（2026-11-12 实测：每次调用固定开销 1.1 万 token）。
  const files = logs.find(l => l.event === "files");
  expect(files.instructions).toContain("JSON schema");
  expect(files.catalog.models[0]).toEqual({ slug: "synthetic-model", experimental_supported_tools: [], context_window: 1000 });
  for (const flag of ["include_permissions_instructions=false", "include_environment_context=false", "include_collaboration_mode_instructions=false", "features.collaboration_modes=false"]) expect(start.args).toContain(flag);
  // 回归（2026-11-12）：WebSocket 连不上时每次调用先重连约 110 秒；ChatGPT 登录时直接走 HTTPS。
  expect(start.args).toContain('model_provider="ra-https"');
  expect(start.args.find((a: string) => a.startsWith("model_providers.ra-https="))).toContain("supports_websockets=false");
  for (const flag of ["exec", "--ephemeral", "--skip-git-repo-check", "--ignore-user-config", "--ignore-rules", "--json"]) expect(start.args).toContain(flag);
  for (const [flag, value] of [["--sandbox", "read-only"], ["-C", join(f.dir, "distill-work")], ["-m", "synthetic-model"]]) expect(start.args[start.args.indexOf(flag) + 1]).toBe(value);
  expect(start.args).toContain('approval_policy="never"');
  expect(start.args).toContain("features.hooks=false"); expect(start.args).toContain("features.plugins=false");
  expect(start.args).toContain("features.shell_tool=false"); expect(start.args.at(-1)).toBe("-");
  expect(start.args.join(" ")).not.toContain(request.prompt); expect(JSON.parse(start.stdin).prompt).toBe(request.prompt);
  expect(start.cwd).toBe(join(f.dir, "distill-work")); expect(start.mode).toBe(0o700);
  expect(schemaLog.schema).toEqual(schema); expect(schemaLog.mode).toBe(0o700);
  expect(await Bun.file(schemaLog.file).exists()).toBe(false);
  expect(f.rows).toHaveLength(1); expect(f.rows[0]).toMatchObject({ ok: 1, input_tokens: 12, output_tokens: 3 });
});

test("Codex：读不到模型目录、不是 ChatGPT 登录时不覆盖，照常调用", async () => {
  resetCodexCatalog();
  const f = await fixture("codex-cli", "nocatalog");
  expect((await f.llm.complete(request)).ok).toBe(true);
  const logs = await f.logs();
  expect(logs.find(l => l.event === "files").catalog).toBeNull();
  expect(logs[0].args.some((a: string) => a.startsWith("model_catalog_json="))).toBe(false);
  // 不是 ChatGPT 登录时不改 provider。
  expect(logs[0].args.some((a: string) => a.startsWith("model_provider"))).toBe(false);
  resetCodexCatalog();
});

for (const provider of ["claude-cli", "codex-cli"]) {
  for (const mode of ["json", "schema", "exit"]) test(`${provider}：${mode} 失败也只写一行 usage`, async () => {
    const f = await fixture(provider, mode);
    const result = await f.llm.complete(request);
    expect(result.ok).toBe(false); expect(f.rows).toHaveLength(1); expect(f.rows[0]!.ok).toBe(0);
    if (!result.ok) {
      expect(result.error).not.toContain(request.prompt);
      expect(result.error.length).toBeLessThan(600);
      if (mode === "json") expect(result.error).toContain("非法 JSON");
      if (mode === "schema") expect(result.error).toContain("不符合 schema");
    }
    if (provider === "codex-cli") {
      const start = (await f.logs())[0]; const file = start.args[start.args.indexOf("--output-schema") + 1];
      expect(await Bun.file(file).exists()).toBe(false);
      await expect(stat(dirname(file))).rejects.toThrow();
    }
  });
  test(`${provider}：超时确实杀死进程`, async () => {
    const f = await fixture(provider, "timeout");
    const result = await f.llm.complete({ ...request, timeoutMs: 250 });
    expect(result.ok).toBe(false); if (!result.ok) expect(result.error).toContain("超时");
    const [start] = await f.logs();
    // 等待操作系统回收子进程，再核验 PID；不是仅检查返回值。
    for (let i = 0; i < 50; i++) {
      try { process.kill(start.pid, 0); } catch { break; }
      await Bun.sleep(10);
    }
    expect(() => process.kill(start.pid, 0)).toThrow(); expect(f.rows).toHaveLength(1);
    if (provider === "codex-cli") await expect(stat(dirname(start.args[start.args.indexOf("--output-schema") + 1]))).rejects.toThrow();
  });
}

test("Claude 不把包含提示词的 stderr 写入错误或 usage（含超过截断长度的输入）", async () => {
  const f = await fixture("claude-cli", "echo");
  for (const prompt of [request.prompt, "synthetic-private-prompt ".repeat(100)]) {
    const result = await f.llm.complete({ ...request, prompt });
    expect(result.ok).toBe(false); expect(JSON.stringify([result, f.rows])).not.toContain(prompt.slice(0, 20));
  }
});

test("Claude 外层失败不能因含 structured_output 而成功", async () => {
  const f = await fixture("claude-cli", "envelope");
  expect((await f.llm.complete(request)).ok).toBe(false); expect(f.rows[0]!.ok).toBe(0);
});

test("并发调用跨 createLLM 实例串行，失败之后继续处理", async () => {
  const f = await fixture();
  const other = createLLM({ dataDir: f.dir, spawn: f.spawn, recordUsage: row => { f.rows.push(row); } });
  const results = await Promise.all([f.llm.complete(request), other.complete(request)]);
  expect(results.every(r => r.ok)).toBe(true);
  expect((await f.logs()).map(l => l.event)).toEqual(["start", "end", "start", "end"]);
  expect(f.rows).toHaveLength(2); expect(f.rows[0]!.id).not.toBe(f.rows[1]!.id);
  await configure(f.dir, "invalid"); expect((await f.llm.complete(request)).ok).toBe(false);
  await configure(f.dir, "claude-cli"); expect((await f.llm.complete(request)).ok).toBe(true);
  expect(f.rows).toHaveLength(4);
});

test("配置和 schema 失败也记录用量，错误不带 schema 正文", async () => {
  const f = await fixture();
  expect((await f.llm.complete({ ...request, schema: { type: "synthetic-invalid" } })).ok).toBe(false);
  expect((await f.llm.complete({ ...request, timeoutMs: 180001 })).ok).toBe(false);
  expect(f.rows).toHaveLength(2); expect((await readdir(f.dir)).includes("calls.jsonl")).toBe(false);
});

test("usage 回调失败明确返回失败，队列仍可继续", async () => {
  const f = await fixture(); let calls = 0;
  const llm = createLLM({ dataDir: f.dir, spawn: f.spawn, recordUsage() { calls++; throw new Error("synthetic"); } });
  const result = await llm.complete(request); expect(result.ok).toBe(false);
  if (!result.ok) expect(result.error).toBe("模型用量记录失败");
  expect(calls).toBe(1); expect((await f.llm.complete(request)).ok).toBe(true);
});

test("HTTP 的 key 读取也受总超时约束，超时后不会发出延迟请求", async () => {
  const dir = await directory(); await configure(dir, "anthropic");
  const rows: UsageRow[] = []; let fetched = false, resolveKey!: (key: string) => void;
  globalThis.fetch = (async () => { fetched = true; return Response.json({}); }) as unknown as typeof fetch;
  const llm = createLLM({ dataDir: dir, readKey: () => new Promise(resolve => { resolveKey = resolve; }), recordUsage: row => { rows.push(row); } });
  const result = await llm.complete({ ...request, timeoutMs: 30 });
  expect(result.ok).toBe(false); if (!result.ok) expect(result.error).toContain("超时");
  resolveKey("synthetic-key"); await Bun.sleep(0);
  expect(fetched).toBe(false); expect(rows).toHaveLength(1);
});

for (const provider of ["anthropic", "openai-compatible"]) {
  test(`${provider}：HTTP 请求格式、注入 key 和 token 用量`, async () => {
    const dir = await directory(); await configure(dir, provider, { base_url: "https://synthetic.invalid/v1/" });
    const rows: UsageRow[] = [], reads: string[] = [];
    globalThis.fetch = (async (url: any, options: any) => {
      expect(String(url)).toBe(`https://synthetic.invalid/v1/${provider === "anthropic" ? "messages" : "chat/completions"}`);
      expect(options.redirect).toBe("error"); expect(options.signal).toBeInstanceOf(AbortSignal);
      const body = JSON.parse(options.body); expect(body.model).toBe("synthetic-model");
      if (provider === "anthropic") {
        expect(options.headers["x-api-key"]).toBe("synthetic-key"); expect(options.headers["anthropic-version"]).toBe("2023-06-01");
        expect(body.system).toBe(request.system); expect(body.messages[0].content).toBe(request.prompt);
        expect(body.tools[0].input_schema).toEqual(schema); expect(body.tool_choice).toEqual({ type: "tool", name: "emit_result" });
        return Response.json({ stop_reason: "tool_use", content: [{ type: "tool_use", name: "emit_result", input: { text: "hello" } }], usage: { input_tokens: 4, output_tokens: 2 } });
      }
      expect(options.headers.authorization).toBe("Bearer synthetic-key");
      expect(body.messages).toEqual([{ role: "system", content: request.system }, { role: "user", content: request.prompt }]);
      expect(body.response_format).toEqual({ type: "json_schema", json_schema: { name: "result", strict: true, schema } });
      return Response.json({ choices: [{ finish_reason: "stop", message: { content: '{"text":"hello"}' } }], usage: { prompt_tokens: 4, completion_tokens: 2 } });
    }) as typeof fetch;
    const llm = createLLM({ dataDir: dir, readKey: p => { reads.push(p); return "synthetic-key"; }, recordUsage: row => { rows.push(row); } });
    expect((await llm.complete(request)).ok).toBe(true); expect(reads).toEqual([provider]);
    expect(rows).toHaveLength(1); expect(rows[0]).toMatchObject({ ok: 1, input_tokens: 4, output_tokens: 2, output_chars: 16 });
  });
  test(`${provider}：HTTP 状态、非法 JSON、schema、截断和超时均失败`, async () => {
    const dir = await directory(); await configure(dir, provider);
    const rows: UsageRow[] = [];
    const llm = createLLM({ dataDir: dir, readKey: () => "synthetic-key", recordUsage: row => { rows.push(row); } });
    for (const mode of ["status", "json", "schema", "truncated", "timeout"]) {
      globalThis.fetch = (async (_url: any, opts: any) => {
        if (mode === "status") return new Response(request.prompt, { status: 401 });
        if (mode === "json") return new Response("bad json");
        if (mode === "timeout") return new Promise((_, reject) => opts.signal.addEventListener("abort", () => reject(new Error("aborted"))));
        return provider === "anthropic" ? Response.json({ stop_reason: mode === "truncated" ? "max_tokens" : "tool_use", content: [{ type: "tool_use", name: "emit_result", input: { text: 42 } }] }) : Response.json({ choices: [{ finish_reason: mode === "truncated" ? "length" : "stop", message: { content: '{"text":42}' } }] });
      }) as typeof fetch;
      const result = await llm.complete({ ...request, timeoutMs: 50 });
      expect(result.ok).toBe(false); if (!result.ok) expect(result.error).not.toContain(request.prompt);
    }
    expect(rows).toHaveLength(5); expect(rows.every(r => r.ok === 0)).toBe(true);
  });
}

// 本机模型（Ollama、LM Studio）不需要 key；钥匙串里给中转站的 key 也不能发给本机服务。
test("OpenAI 兼容后端指向本机地址时不读也不发 API key", async () => {
  const dir = await directory(); await configure(dir, "openai-compatible", { base_url: "http://127.0.0.1:11434/v1" });
  const reads: string[] = []; let auth: string | undefined = "unset";
  globalThis.fetch = (async (url: any, options: any) => {
    expect(String(url)).toBe("http://127.0.0.1:11434/v1/chat/completions");
    auth = options.headers.authorization;
    return Response.json({ choices: [{ finish_reason: "stop", message: { content: '{"text":"hello"}' } }] });
  }) as typeof fetch;
  const llm = createLLM({ dataDir: dir, readKey: p => { reads.push(p); return "relay-key"; }, recordUsage: () => {} });
  expect((await llm.complete(request)).ok).toBe(true);
  expect(reads).toEqual([]); expect(auth).toBeUndefined();
});

// 回归：CLI 后端曾继承调用方的 ANTHROPIC_BASE_URL 等变量，手动运行时走了中转站（2026-11-08 实测发现）。
test("CLI 后端只继承白名单环境变量", async () => {
  const { cliEnv } = await import("../src/llm/process.ts");
  const env = cliEnv({ HOME: "/h", PATH: "/p", LANG: "zh_CN.UTF-8", ANTHROPIC_BASE_URL: "https://relay.invalid", ANTHROPIC_AUTH_TOKEN: "x", ANTHROPIC_DEFAULT_HAIKU_MODEL: "m", CLAUDE_CODE_SESSION_ID: "s", CLAUDECODE: "1", CMUX_CLAUDE_PID: "1", OPENAI_API_KEY: "k" });
  expect(env).toEqual({ HOME: "/h", PATH: "/p", LANG: "zh_CN.UTF-8", CI: "1" });
});

// 回归：claude -p 把出错原因写在 stdout 的 JSON 里、stderr 为空，曾经只显示"退出失败（1）："（2026-11-08 首次真实运行发现）。
test("Claude 出错原因从 stdout 的 result 取出", async () => {
  const f = await fixture("claude-cli", "limit");
  const r = await f.llm.complete({ tier: "minute", system: "合成", prompt: "合成", schema: { type: "object" } });
  expect(r.ok).toBe(false);
  expect(r.ok ? "" : r.error).toContain("5-hour limit");
});
