import { expect, test } from "bun:test";
import { createHandler } from "../src/server.ts";
import { createLLM } from "../src/llm/index.ts";
import { loadConfig, saveConfig, validateTier } from "../src/llm/config.ts";
import { isLoopback } from "../src/llm/local.ts";
import { setup } from "./helpers.ts";

const schema = { type: "object", properties: { ok: { type: "boolean", enum: [true] } }, required: ["ok"], additionalProperties: false };
function settings(ctx: ReturnType<typeof setup>) {
  const h = createHandler({ db: ctx.db, token: ctx.config.token, port: 47823, settings: {
    dataDir: ctx.dir, env: {}, keychain: { has: async () => false, set: async () => {}, remove: async () => false },
    llm: { readKey: () => { throw new Error("本机请求不应读取钥匙串"); } },
  } });
  return async (path: string, body: unknown, auth = true) => {
    const response = await h(new Request(`http://127.0.0.1:47823/v1/settings/models${path}`, {
      method: "POST", headers: { host: "127.0.0.1:47823", "content-type": "application/json", ...(auth ? { authorization: `Bearer ${ctx.config.token}` } : {}) }, body: JSON.stringify(body),
    }));
    return { status: response.status, body: await response.json() as any };
  };
}

test("本机列表：鉴权、空列表、服务错误、非法响应及重定向；不发送凭据", async () => {
  const ctx = setup(); let mode = "list", requests = 0, redirected = 0;
  const server = Bun.serve({ hostname: "127.0.0.1", port: 0, fetch(req) {
    requests++; expect(req.headers.has("authorization")).toBe(false);
    const path = new URL(req.url).pathname;
    if (path === "/elsewhere") { redirected++; return Response.json({ data: [] }); }
    expect(path).toBe("/v1/models");
    if (mode === "redirect") return Response.redirect(new URL("/elsewhere", req.url));
    if (mode === "error") return new Response("synthetic-private-body", { status: 500 });
    if (mode === "invalid") return Response.json({ data: [{ id: null }] });
    return Response.json({ data: mode === "empty" ? [] : [{ id: "qwen" }, { id: "a-model" }, { id: "qwen" }] });
  } });
  try {
    const call = settings(ctx), body = { base_url: `http://127.0.0.1:${server.port}/v1/` };
    expect((await call("/local", body, false)).status).toBe(401); expect(requests).toBe(0);
    expect(await call("/local", body)).toEqual({ status: 200, body: { models: ["a-model", "qwen"] } });
    mode = "empty"; expect((await call("/local", body)).body).toEqual({ models: [] });
    for (const next of ["error", "invalid", "redirect"]) {
      mode = next; const result = await call("/local", body);
      expect(result.status).toBe(503); expect(JSON.stringify(result.body)).not.toContain("synthetic-private-body");
    }
    expect(redirected).toBe(0);
    const before = requests;
    for (const base_url of ["https://example.invalid/v1", "http://127.example.invalid/v1", "http://localhost.example.invalid/v1", "http://user:secret@localhost/v1", "file:///tmp/models", "http://localhost/v1?token=secret"]) {
      expect((await call("/local", { base_url })).status).toBe(400);
    }
    expect(requests).toBe(before);
    server.stop(true);
    const unavailable = await call("/local", body);
    expect(unavailable.status).toBe(503); expect(unavailable.body.error).toContain("先打开服务");
  } finally { server.stop(true); ctx.cleanup(); }
});

test("思考参数保存并用于连接测试及实际整理；跟随模型不发送参数", async () => {
  const ctx = setup(), seen: any[] = [];
  const server = Bun.serve({ hostname: "127.0.0.1", port: 0, async fetch(req) {
    expect(req.headers.has("authorization")).toBe(false);
    seen.push(await req.json());
    return Response.json({ choices: [{ finish_reason: "stop", message: { content: '{"ok":true}' } }], usage: { prompt_tokens: 8, completion_tokens: 4 } });
  } });
  try {
    const entry = { provider: "openai-compatible" as const, model: "synthetic-local", base_url: `http://127.0.0.1:${server.port}/v1`, reasoning_effort: "none" as const };
    await saveConfig(ctx.dir, { minute: entry, hour: { ...entry, reasoning_effort: "high" }, day: { ...entry, reasoning_effort: undefined } });
    expect((await loadConfig(ctx.dir)).minute.reasoning_effort).toBe("none");
    const call = settings(ctx);
    expect((await call("/test", { tier: "minute" })).body.ok).toBe(true);
    const usage: any[] = [], llm = createLLM({ dataDir: ctx.dir, recordUsage: row => { usage.push(row); }, readKey: () => { throw new Error("不得读 key"); } });
    for (const tier of ["hour", "day"] as const) expect((await llm.complete({ tier, system: "合成整理", prompt: "ok", schema })).ok).toBe(true);
    expect(seen.map(x => x.reasoning_effort)).toEqual(["none", "high", undefined]);
    expect(Object.hasOwn(seen[2], "reasoning_effort")).toBe(false);
    expect(usage).toHaveLength(2);
    for (const effort of ["none", "low", "medium", "high"] as const) expect(validateTier({ ...entry, reasoning_effort: effort }, "test").reasoning_effort).toBe(effort);
    for (const effort of [true, null, "auto", "", 4]) expect(() => validateTier({ ...entry, reasoning_effort: effort }, "test")).toThrow("reasoning_effort");
    for (const provider of ["anthropic", "claude-cli", "codex-cli"]) expect(() => validateTier({ provider, model: "x", reasoning_effort: "none" }, "test")).toThrow("只适用于");
  } finally { server.stop(true); ctx.cleanup(); }
});

test("本机地址判断不把 127 开头的域名当回环地址", () => {
  for (const u of ["http://127.0.0.1:11434/v1", "http://localhost:1234/v1", "http://[::1]/v1"]) expect(isLoopback(u)).toBe(true);
  for (const u of ["http://127.attacker.invalid/v1", "http://localhost.attacker.invalid/v1", "http://u:p@localhost/v1", "file://localhost/x"]) expect(isLoopback(u)).toBe(false);
});
