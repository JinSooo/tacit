import { afterEach, beforeEach, expect, test } from "bun:test";
import { spawn as nodeSpawn } from "node:child_process";
import { chmodSync, existsSync, mkdirSync, readFileSync, readdirSync, writeFileSync } from "node:fs";
import { createServer, type Server } from "node:net";
import { join } from "node:path";
import { createHandler } from "../src/server.ts";
import { resolvePort, writeHubPort } from "../src/hub-json.ts";
import { GENERAL_DEFAULTS, readGeneral } from "../src/general-settings.ts";
import { lifecycleStep } from "../src/distill/run.ts";
import { DistillStore } from "../src/distill/store.ts";
import { AgentReads } from "../src/agent.ts";
import { securityKeychain, type Keychain } from "../src/llm/keychain.ts";
import { createSettings, type SettingsDeps } from "../src/settings.ts";
import { createLLM, type Spawn } from "../src/llm/index.ts";
import { RuntimeLog } from "../src/runtime-log.ts";
import { fixture, networkDenied, reviewEvidence, setup } from "./helpers.ts";

const host = "127.0.0.1:47823";
const SECRET = "sk-synthetic-SECRET-0123456789abcdef";
let ctx: ReturnType<typeof setup>, keys: Map<string, string>, restarts: number;
beforeEach(() => { ctx = setup(); keys = new Map(); restarts = 0; });
afterEach(() => ctx.cleanup());

const fakeKeychain = (): Keychain => ({
  async has(p) { return keys.has(p); },
  async set(p, k) { keys.set(p, k); },
  async remove(p) { return keys.delete(p); },
});
function handler(deps: Partial<SettingsDeps> = {}) {
  return createHandler({ db: ctx.db, token: ctx.config.token, port: 47823, settings: { dataDir: ctx.dir, env: {}, keychain: fakeKeychain(), probePort: async () => {}, restart: () => { restarts++; }, ...deps } });
}
async function call(h: ReturnType<typeof handler>, method: string, path: string, body?: unknown, auth = true) {
  const response = await h(new Request(`http://${host}${path}`, {
    method, headers: { host, "content-type": "application/json", ...(auth ? { authorization: `Bearer ${ctx.config.token}` } : {}) },
    ...(body === undefined ? {} : { body: JSON.stringify(body) }),
  }));
  const text = await response.text();
  expect(text).not.toContain(SECRET);
  return { status: response.status, body: text ? JSON.parse(text) : null };
}
const tier = (provider: string, model = "synthetic-model", extra = {}) => ({ provider, model, ...extra });

test("Desktop 设置接口连接、断开、重启提示及鉴权；无需编程 CLI", async () => {
  const home = join(ctx.dir, "desktop-home");
  const agents = { home, repo: "/tmp/合成仓库", bun: "/tmp/bun", which: () => null, appExists: () => false };
  const h = handler({ agents });
  const path = "/v1/settings/agents/claude-desktop";
  expect((await call(h, "PUT", path, { connected: true }, false)).status).toBe(401);
  expect((await call(h, "PUT", path, { connected: true })).status).toBe(409);
  expect(existsSync(home)).toBe(false);
  agents.appExists = () => true;
  const connected = await call(h, "PUT", path, { connected: true });
  expect(connected.status).toBe(200);
  expect(connected.body.tools.find((t: any) => t.id === "claude-desktop")).toMatchObject({ connected: true, partial: false });
  expect(connected.body.note).toContain("完全退出");
  expect(existsSync(join(home, ".claude"))).toBe(false);
  expect((await call(h, "PUT", path, { connected: false })).body.tools.find((t: any) => t.id === "claude-desktop").connected).toBe(false);
  expect((await call(h, "PUT", "/v1/settings/agents/workbuddy", { connected: true })).status).toBe(400);
});

test("端口优先级：RA_PORT > hub.json > 47823；hub.json 无效时报错，写入保留其他字段", () => {
  expect(resolvePort({}, ctx.dir)).toEqual({ port: 47823, source: "default" });
  writeFileSync(join(ctx.dir, "hub.json"), JSON.stringify({ port: 50001, note: "保留" }));
  expect(resolvePort({}, ctx.dir)).toEqual({ port: 50001, source: "file" });
  expect(resolvePort({ RA_PORT: "50002" }, ctx.dir)).toEqual({ port: 50002, source: "env" });
  expect(resolvePort({ RA_PORT: "0" }, ctx.dir)).toEqual({ port: 0, source: "env" });
  expect(() => resolvePort({ RA_PORT: "" }, ctx.dir)).toThrow("RA_PORT");
  writeHubPort(ctx.dir, 50003);
  expect(JSON.parse(readFileSync(join(ctx.dir, "hub.json"), "utf8"))).toEqual({ port: 50003, note: "保留" });
  expect(() => writeHubPort(ctx.dir, 80)).toThrow("1024–65535");
  for (const bad of ['{"port":80}', '{"port":"50001"}', '{"port":1.5}', "[]", "{"]) {
    writeFileSync(join(ctx.dir, "hub.json"), bad);
    expect(() => resolvePort({}, ctx.dir)).toThrow("hub.json");
  }
  writeFileSync(join(ctx.dir, "hub.json"), "{}");
  expect(resolvePort({}, ctx.dir).source).toBe("default");
  expect(readdirSync(ctx.dir).filter(f => f.endsWith(".tmp"))).toEqual([]);
});

test("GET/PUT /v1/settings/hub：校验、写 hub.json 后重启；RA_PORT 锁定；需要鉴权", async () => {
  const h = handler();
  expect(await call(h, "GET", "/v1/settings/hub")).toEqual({ status: 200, body: { port: 47823, listen: "127.0.0.1", lan: false, locked: false } });
  expect((await call(h, "GET", "/v1/settings/hub", undefined, false)).status).toBe(401);
  expect((await call(h, "PUT", "/v1/settings/hub", { port: 50010 }, false)).status).toBe(401);
  for (const bad of [{ port: 1023 }, { port: 65536 }, { port: "50010" }, { port: 50010.5 }, {}, { port: 50010, lan: true }]) {
    expect((await call(h, "PUT", "/v1/settings/hub", bad)).status).toBe(400);
  }
  expect(existsSync(join(ctx.dir, "hub.json"))).toBe(false);
  expect(await call(h, "PUT", "/v1/settings/hub", { port: 47823 })).toEqual({ status: 200, body: { port: 47823, restarting: false } });
  expect(await call(h, "PUT", "/v1/settings/hub", { port: 50010 })).toEqual({ status: 200, body: { port: 50010, restarting: true } });
  expect(JSON.parse(readFileSync(join(ctx.dir, "hub.json"), "utf8"))).toEqual({ port: 50010 });
  expect(restarts).toBe(0);
  await Bun.sleep(400);
  expect(restarts).toBe(1);

  const locked = handler({ env: { RA_PORT: "47823" } });
  expect((await call(locked, "GET", "/v1/settings/hub")).body.locked).toBe(true);
  const refused = await call(locked, "PUT", "/v1/settings/hub", { port: 50020 });
  expect(refused.status).toBe(409); expect(refused.body.error).toContain("环境变量 RA_PORT");
  expect(JSON.parse(readFileSync(join(ctx.dir, "hub.json"), "utf8"))).toEqual({ port: 50010 });
});

test("PUT /v1/settings/hub 新端口被占用时 409，不写 hub.json、不重启", async () => {
  if (await networkDenied()) return;
  const busy: Server = createServer();
  await new Promise<void>(resolve => busy.listen(0, "127.0.0.1", resolve));
  const port = (busy.address() as { port: number }).port;
  try {
    // 用真实的试绑定，不注入 probePort。
    const h = handler({ probePort: undefined });
    const result = await call(h, "PUT", "/v1/settings/hub", { port });
    expect(result.status).toBe(409); expect(result.body.error).toBe(`端口 ${port} 已被占用，请换一个`);
    expect(existsSync(join(ctx.dir, "hub.json"))).toBe(false);
  } finally { await new Promise(resolve => busy.close(resolve)); }
  await Bun.sleep(400);
  expect(restarts).toBe(0);
});
test("models：GET 给默认值、说明和 key 状态；PUT 严格校验后原子写回，坏文件报 config_error", async () => {
  const h = handler();
  const initial = (await call(h, "GET", "/v1/settings/models")).body;
  expect(initial.tiers).toEqual({ minute: tier("claude-cli", "haiku"), hour: tier("claude-cli", "sonnet"), day: tier("claude-cli", "sonnet") });
  expect(initial.config_error).toBeNull();
  expect(initial.keys).toEqual({ anthropic: false, "openai-compatible": false });
  expect(initial.providers.map((p: { id: string }) => p.id)).toEqual(["claude-cli", "codex-cli", "anthropic", "openai-compatible"]);
  expect(Object.keys(initial.tier_info)).toEqual(["minute", "hour", "day"]);
  for (const t of ["minute", "hour", "day"]) expect(initial.tier_info[t].description.length).toBeGreaterThan(10);

  const good = { minute: tier("codex-cli", "gpt-mini"), hour: tier("anthropic", "claude-x", { base_url: "https://relay.invalid/v1" }), day: tier("openai-compatible", "gpt-x") };
  const saved = await call(h, "PUT", "/v1/settings/models", { tiers: good });
  expect(saved.status).toBe(200); expect(saved.body.tiers).toEqual(good);
  expect(JSON.parse(readFileSync(join(ctx.dir, "models.json"), "utf8"))).toEqual({ tiers: good });
  const before = readFileSync(join(ctx.dir, "models.json"), "utf8");
  // 2026-11-25：设置页把 tiers.minute.base_url 这类字段路径原样显示，改成用户能看懂的一句话。
  for (const [body, error] of [
    [{ tiers: { minute: good.minute, hour: good.hour } }, "模型设置有问题，请检查后重新保存。"],
    [{ tiers: { ...good, week: good.day } }, "模型设置有问题，请检查后重新保存。"],
    [{ tiers: { ...good, minute: tier("unknown") } }, "不支持这个提供商。"],
    [{ tiers: { ...good, minute: tier("anthropic", " ") } }, "请填写模型名。"],
    [{ tiers: { ...good, minute: tier("anthropic", "m", { api_key: SECRET }) } }, "模型设置有问题，请检查后重新保存。"],
    [{ tiers: { ...good, minute: tier("codex-cli", "m", { base_url: "https://x.invalid" }) } }, "这个提供商不用填地址。"],
    [{ tiers: { ...good, minute: tier("anthropic", "m", { base_url: "https://user:pw@x.invalid" }) } }, "地址要是完整的 http 或 https 链接"],
    [{ tiers: { ...good, minute: tier("anthropic", "m", { base_url: "ftp://x.invalid" }) } }, "地址要是完整的 http 或 https 链接"],
    [{ tiers: good, extra: 1 }, "只接受 tiers"],
    [[], "对象"],
  ] as const) {
    const r = await call(h, "PUT", "/v1/settings/models", body);
    expect(r.status).toBe(400); expect(r.body.error).toContain(error);
  }
  expect(readFileSync(join(ctx.dir, "models.json"), "utf8")).toBe(before);
  expect(readdirSync(ctx.dir).filter(f => f.endsWith(".tmp"))).toEqual([]);

  writeFileSync(join(ctx.dir, "models.json"), "{");
  const broken = (await call(h, "GET", "/v1/settings/models")).body;
  expect(broken.config_error).toContain("不是合法 JSON"); expect(broken.tiers.minute).toEqual(tier("claude-cli", "haiku"));
});

test("keys：PUT/DELETE 只接受两种 provider，key 从不出现在响应、错误和 models.json 里", async () => {
  const h = handler();
  expect(await call(h, "PUT", "/v1/settings/keys/anthropic", { key: `  ${SECRET}\n` })).toEqual({ status: 200, body: { provider: "anthropic", set: true } });
  expect(keys.get("anthropic")).toBe(SECRET);
  expect((await call(h, "GET", "/v1/settings/models")).body.keys).toEqual({ anthropic: true, "openai-compatible": false });
  for (const [path, body] of [
    ["/v1/settings/keys/claude-cli", { key: SECRET }], ["/v1/settings/keys/unknown", { key: SECRET }],
    ["/v1/settings/keys/openai-compatible", { key: "short" }], ["/v1/settings/keys/openai-compatible", { key: `${SECRET} tail` }],
    ["/v1/settings/keys/openai-compatible", { key: `${SECRET}"` }], ["/v1/settings/keys/openai-compatible", { key: `${SECRET}\\` }],
    ["/v1/settings/keys/openai-compatible", { key: SECRET, provider: "x" }], ["/v1/settings/keys/openai-compatible", { key: 123 }],
  ] as const) expect((await call(h, "PUT", path, body)).status).toBe(400);
  expect(keys.has("openai-compatible")).toBe(false);
  expect(await call(h, "DELETE", "/v1/settings/keys/anthropic")).toEqual({ status: 200, body: { provider: "anthropic", deleted: true } });
  expect(await call(h, "DELETE", "/v1/settings/keys/anthropic")).toEqual({ status: 200, body: { provider: "anthropic", deleted: false } });
  expect((await call(h, "DELETE", "/v1/settings/keys/codex-cli")).status).toBe(400);
  expect((await call(h, "PUT", "/v1/settings/keys/anthropic", { key: SECRET }, false)).status).toBe(401);

  // 钥匙串失败：500 + 固定文字，不带 key 和底层错误。
  const failing = handler({ keychain: { has: async () => { throw new Error(SECRET); }, set: async () => { throw new Error(SECRET); }, remove: async () => { throw new Error(SECRET); } } });
  expect(await call(failing, "PUT", "/v1/settings/keys/anthropic", { key: SECRET })).toEqual({ status: 500, body: { error: "保存 API key 失败，请重试。" } });
  expect(await call(failing, "DELETE", "/v1/settings/keys/anthropic")).toEqual({ status: 500, body: { error: "删除 API key 失败，请重试。" } });
  expect((await call(failing, "GET", "/v1/settings/models")).body.keys).toEqual({ anthropic: null, "openai-compatible": null });
  const audit = await call(h, "GET", "/v1/settings/security-audit");
  expect(audit.body.events).toEqual(expect.arrayContaining([
    expect.objectContaining({ action: "key.set", target: "anthropic", ok: 1 }),
    expect.objectContaining({ action: "key.delete", target: "anthropic", ok: 1 }),
    expect.objectContaining({ action: "key.set", target: "anthropic", ok: 0, detail_code: "secret_error" }),
    expect.objectContaining({ action: "key.delete", target: "anthropic", ok: 0, detail_code: "secret_error" }),
  ]));
  expect(JSON.stringify(audit)).not.toContain(SECRET);
  for (const file of readdirSync(ctx.dir)) if (!file.startsWith("history.db")) expect(readFileSync(join(ctx.dir, file), "utf8")).not.toContain(SECRET);
});

test("models/test：用未保存的配置调一次，不写 llm_usage；错误已脱敏；参数非法 400", async () => {
  const script = join(ctx.dir, "fake-claude");
  writeFileSync(script, `#!${process.execPath}
const input = await Bun.stdin.text();
if (process.env.TEST_MODE === "rate") { console.error("HTTP 429"); process.exit(3); }
if (process.env.TEST_MODE === "fail") { console.error("synthetic failure token=${SECRET}"); process.exit(3); }
if (process.env.TEST_MODE === "login") { console.log(JSON.stringify({ type: "result", subtype: "error", is_error: true, result: "Not logged in · Please run /login" })); process.exit(0); }
console.log(JSON.stringify({ type: "result", subtype: "success", is_error: false, structured_output: { ok: true }, usage: {} }));
`);
  chmodSync(script, 0o700);
  const calls: string[][] = [];
  const spawnWith = (mode: string): Spawn => (_cmd, args, options) => { calls.push(args); return nodeSpawn(script, args, { ...options, env: { ...options.env, TEST_MODE: mode } }); };
  const usage = () => (ctx.db.db.prepare("SELECT count(*) n FROM llm_usage").get() as { n: number }).n;

  const cooldown = JSON.stringify({ until: new Date(Date.now() + 3600_000).toISOString(), kind: "quota" });
  const state = () => ctx.db.db.prepare("SELECT v FROM distill_state WHERE k='llm_cooldown'").get();
  ctx.db.db.prepare("INSERT INTO distill_state(k,v) VALUES('llm_cooldown',?)").run(cooldown);
  const ok = await call(handler({ llm: { spawn: spawnWith("ok") } }), "POST", "/v1/settings/models/test", { tier: "hour", config: tier("claude-cli", "unsaved-model") });
  expect(ok.status).toBe(200);
  expect(ok.body).toMatchObject({ ok: true, provider: "claude-cli", model: "unsaved-model", error: null, detail: null });
  expect(typeof ok.body.ms).toBe("number");
  expect(calls[0]).toContain("unsaved-model");
  expect(existsSync(join(ctx.dir, "models.json"))).toBe(false);

  const failed = await call(handler({ llm: { spawn: spawnWith("fail") } }), "POST", "/v1/settings/models/test", { tier: "minute" });
  expect(failed.status).toBe(200);
  expect(failed.body.ok).toBe(false); expect(failed.body.model).toBe("haiku");
  expect(failed.body.error).toBe("cli_failed");
  expect(failed.body.detail).toBe("synthetic failure token=[已脱敏:OpenAI]");
  const rate = await call(handler({ llm: { spawn: spawnWith("rate") } }), "POST", "/v1/settings/models/test", { tier: "minute" });
  expect(rate.body).toMatchObject({ ok: false, error: "rate_limited:429", detail: "HTTP 429" });
  expect(state()).toEqual({ v: cooldown });
  expect(usage()).toBe(0);

  const h = handler();
  const store = new DistillStore(ctx.db);
  store.writeUsage({ tier: "day", task: "day", provider: "claude-cli", model: "synthetic-model",
    input_tokens: 1, output_tokens: 1, ms: 1, ok: 1 });
  expect((await call(h, "PUT", "/v1/settings/general", { daily_token_limit: 2 })).status).toBe(200);
  const status = (await call(h, "GET", "/v1/status")).body;
  expect(status.distill.cooldown.kind).toBe("budget");
  const afterBudget = await call(handler({ llm: { spawn: spawnWith("ok") } }), "POST", "/v1/settings/models/test", { tier: "hour" });
  expect(afterBudget.body.ok).toBe(true);
  expect(calls).toHaveLength(4);
  expect(usage()).toBe(1);
  expect(state()).toEqual({ v: cooldown });

  const summary = createLLM({ dataDir: ctx.dir, spawn: spawnWith("login"), journal: new RuntimeLog(ctx.db),
    recordUsage: ({ error, ...row }) => store.writeUsage({ ...row, error: error ?? undefined }) });
  const result = await summary.complete({ tier: "hour", task: "thread_digest", system: "test", prompt: "test", schema: { type: "object" } });
  expect(result).toMatchObject({ ok: false, error: "cli_not_logged_in" });
  expect((await call(h, "GET", "/v1/settings/models")).body.last_failure_detail)
    .toEqual({ minute: null, hour: "Not logged in · Please run /login", day: null });
  expect((await call(h, "GET", "/v1/settings/models", undefined, false)).status).toBe(401);
  const remote = createSettings({ dataDir: ctx.dir, keychain: fakeKeychain(), llm: { spawn: spawnWith("fail") } });
  const remoteCtx = { db: ctx.db, port: 47823, lan: true, remoteActor: true, readJSON: async () => ({ tier: "hour" }) };
  const remoteModels = await remote("GET", new URL(`http://${host}/v1/settings/models`), remoteCtx);
  expect((await remoteModels!.json()).last_failure_detail).toEqual({ minute: null, hour: null, day: null });
  const remoteTest = await remote("POST", new URL(`http://${host}/v1/settings/models/test`), remoteCtx);
  expect(await remoteTest!.json()).toMatchObject({ error: "cli_failed", detail: null });
  ctx.db.db.prepare("UPDATE runtime_calls SET at_ms=? WHERE id=?").run(Date.now() - 7 * 86400_000, result.call_id!);
  expect((await call(h, "GET", "/v1/settings/models")).body.last_failure_detail.hour).toBeNull();

  for (const body of [{}, { tier: "week" }, { tier: "minute", config: tier("unknown") }, { tier: "minute", extra: 1 }]) expect((await call(h, "POST", "/v1/settings/models/test", body)).status).toBe(400);
  writeFileSync(join(ctx.dir, "models.json"), "{");
  expect((await call(h, "POST", "/v1/settings/models/test", { tier: "minute" })).body.error).toBe("模型设置有问题，请检查后重新保存。");
});

test("general：默认值、范围、只改给出的字段；注入上限和提炼生命周期现读", async () => {
  const h = handler();
  const initial = (await call(h, "GET", "/v1/settings/general")).body;
  const defaults = { inject_tokens: 800, ask_done_days: 3, archive_days: 7,
    timeline_polish: "after_segment", timeline_overview: "hourly", daily_token_limit: null, language: GENERAL_DEFAULTS.language } as const;
  expect(initial).toEqual({ ...defaults, defaults,
    ranges: { inject_tokens: [200, 4000], ask_done_days: [1, 30], archive_days: [1, 90], daily_token_limit: [1, 1_000_000_000] },
    model_usage: { days_with_usage: 0, average_daily_tokens: null, average_daily_timeline_tokens: null, today_tokens: 0 },
  });
  for (const body of [{}, [], { inject_tokens: 199 }, { inject_tokens: 4001 }, { ask_done_days: 0 }, { ask_done_days: 31 }, { archive_days: 91 }, { archive_days: 1.5 }, { archive_days: "7" }, { other: 1 }, { inject_tokens: 900, other: 1 }]) {
    expect((await call(h, "PUT", "/v1/settings/general", body)).status).toBe(400);
  }
  expect(readGeneral(ctx.db)).toEqual(defaults);
  const saved = await call(h, "PUT", "/v1/settings/general", { inject_tokens: 200, archive_days: 2 });
  expect(saved.status).toBe(200); expect(saved.body).toMatchObject({ inject_tokens: 200, ask_done_days: 3, archive_days: 2 });
  expect(await call(h, "PUT", "/v1/settings/general", { ask_done_days: 1 })).toMatchObject({ body: { inject_tokens: 200, ask_done_days: 1, archive_days: 2 } });
  // 库里存的值坏了（例如手改）时回落到默认值。
  ctx.db.db.prepare("UPDATE distill_state SET v=? WHERE k='general_settings'").run(JSON.stringify({ inject_tokens: 99999, ask_done_days: 2 }));
  expect(readGeneral(ctx.db)).toEqual({ ...defaults, ask_done_days: 2 });

  // 带入上限现读：800 时放得下两项，200 时两项都放不下。
  const store = new DistillStore(ctx.db);
  store.upsertProject({ id: "p", name: "合成项目", confirmed: 1, keys: { repos: ["/synthetic/foo"], hosts: [], chats: [] }, brief: "合成项目摘要", last_ms: 1000 });
  for (const id of ["new", "old"]) {
    store.upsertThread({ id, project_id: "p", title: `合成线程${id}`, domain: "work", status: "active",
      brief: `合成事项${id}` + "简".repeat(150) });
    reviewEvidence(store,id);
  }
  const inject = async () => ((await new AgentReads(ctx.db).handle("context", new URLSearchParams({ tool: "codex", cwd: "/synthetic/foo", event: "startup" }))).json()) as Promise<{ text: string; tokens_est: number }>;
  await call(h, "PUT", "/v1/settings/general", { inject_tokens: 800 });
  expect((await inject()).text).toContain("合成事项old");
  await call(h, "PUT", "/v1/settings/general", { inject_tokens: 200 });
  const small = await inject();
  expect(small).toMatchObject({ text: "", tokens_est: 0 });

  // 生命周期现读最新的归档天数，旧提问天数已退出日常整理。
  const now = Date.parse("2026-11-08T12:00:00+08:00"), DAY = 86_400_000;
  for (const id of ["new", "old"]) store.upsertThread({ ...store.thread(id)!, status: "done" });
  store.upsertThread({ id: "quiet", project_id: "p", title: "合成安静线程", brief: "合成", status: "paused", last_ms: now - 2 * DAY });
  expect(ctx.db.ingest([fixture({ t_start: new Date(now).toISOString() })]).accepted).toBe(1);
  await call(h, "PUT", "/v1/settings/general", { archive_days: 2 });
  expect(lifecycleStep(store, now)).toMatchObject({ archived: 0, asked: 0 });
  await call(h, "PUT", "/v1/settings/general", { archive_days: 1 });
  expect(lifecycleStep(store, now)).toMatchObject({ archived: 1, asked: 0 });
  expect(store.thread("quiet")?.status).toBe("archived");
});

test("general stores only resolved languages and applies invalid updates atomically", async () => {
  const h = handler();
  const path = "/v1/settings/general";
  for (const language of ["zh", "en"]) {
    expect(await call(h, "PUT", path, { language })).toMatchObject({ status: 200, body: { language } });
    expect(await call(h, "GET", path)).toMatchObject({ status: 200, body: { language } });
  }
  for (const language of ["auto", "zh-CN", "EN", "", null, 1]) {
    expect((await call(h, "PUT", path, { language, inject_tokens: 950 })).status).toBe(400);
  }
  expect(await call(h, "GET", path)).toMatchObject({ body: { language: "en", inject_tokens: 800 } });
});

test("general：时间线节奏和上限的保存、部分更新与整份校验", async () => {
  const h = handler();
  const path = "/v1/settings/general";
  const values = { timeline_polish: "hourly", timeline_overview: "every_3h", daily_token_limit: 30_001 };
  expect(await call(h, "PUT", path, values)).toMatchObject({ status: 200, body: values });
  for (const invalid of [
    { timeline_polish: "every_3h" }, { timeline_overview: "after_segment" }, { timeline_polish: null },
    { daily_token_limit: 0 }, { daily_token_limit: -1 }, { daily_token_limit: 1.5 },
    { daily_token_limit: true }, { daily_token_limit: "30000" }, { daily_token_limit: 1_000_000_001 },
    { model_usage: {} },
  ]) {
    expect((await call(h, "PUT", path, { timeline_polish: "nightly", ...invalid })).status).toBe(400);
  }
  expect(await call(h, "GET", path)).toMatchObject({ status: 200, body: values });
  expect(await call(h, "PUT", path, { daily_token_limit: null })).toMatchObject({
    status: 200, body: { ...values, daily_token_limit: null },
  });
});

test("设置路由：未知路径和方法 404，Host 校验照旧", async () => {
  const h = handler();
  expect((await call(h, "GET", "/v1/settings/unknown")).status).toBe(404);
  expect((await call(h, "DELETE", "/v1/settings/general")).status).toBe(404);
  expect((await call(h, "GET", "/v1/settings/keys/anthropic")).status).toBe(404);
  const wrongHost = await h(new Request(`http://${host}/v1/settings/hub`, { headers: { host: "evil.invalid", authorization: `Bearer ${ctx.config.token}` } }));
  expect(wrongHost.status).toBe(421);
});

test("钥匙串封装：key 经 stdin 交给 security -i，不进进程参数；退出码 44 视为不存在", async () => {
  const log = join(ctx.dir, "security.jsonl"), fake = join(ctx.dir, "fake-security");
  // 假的 security：记录 argv 和 stdin，按 FAKE_CODE 退出；不碰真实钥匙串。
  writeFileSync(fake, `#!${process.execPath}
import { appendFileSync } from "node:fs";
appendFileSync(${JSON.stringify(log)}, JSON.stringify({ args: process.argv.slice(2), stdin: await Bun.stdin.text() }) + "\\n");
process.exit(Number(process.env.FAKE_CODE ?? 0));
`);
  chmodSync(fake, 0o700);
  const chain = securityKeychain(fake);
  await chain.set("openai-compatible", SECRET);
  expect(await chain.has("anthropic")).toBe(true);
  expect(await chain.remove("anthropic")).toBe(true);
  const calls = readFileSync(log, "utf8").trim().split("\n").map(l => JSON.parse(l) as { args: string[]; stdin: string });
  expect(calls[0]!.args).toEqual(["-i"]);
  expect(calls[0]!.stdin).toBe(`add-generic-password -U -s record-anything -a provider:openai-compatible -w "${SECRET}"\n`);
  expect(calls[1]!.args).toEqual(["find-generic-password", "-s", "record-anything", "-a", "provider:anthropic"]);
  expect(calls[2]!.args).toEqual(["delete-generic-password", "-s", "record-anything", "-a", "provider:anthropic"]);
  for (const c of calls) expect(c.args.join(" ")).not.toContain(SECRET);
  await expect(chain.set("anthropic", 'bad"quote-0123456789')).rejects.toThrow("格式无效");
  expect(readFileSync(log, "utf8").trim().split("\n")).toHaveLength(3);

  process.env.FAKE_CODE = "44";
  try {
    expect(await chain.has("anthropic")).toBe(false);
    expect(await chain.remove("anthropic")).toBe(false);
    await expect(chain.set("anthropic", SECRET)).rejects.toThrow("写入钥匙串失败");
  } finally { delete process.env.FAKE_CODE; }
  await expect(securityKeychain(join(ctx.dir, "missing")).has("anthropic")).rejects.toThrow("无法查询钥匙串");
});

test("AI 工具接入：连接写入钩子并登记 MCP，状态随之变化；找不到工具时不写入", async () => {
  const home = join(ctx.dir, "home");
  mkdirSync(home);
  const calls: string[][] = [];
  const agents = {
    home, repo: "/tmp/合成仓库", bun: "/tmp/bun",
    appExists: () => false,
    which: (command: string) => command === "claude" ? "/fake/claude" : null,
    print: () => {},
    run: (command: string, args: string[]) => {
      calls.push([command, ...args]);
      // 合成的 claude：mcp add 写 ~/.claude.json，mcp get 按是否写过返回。
      const file = join(home, ".claude.json");
      if (args[1] === "add") writeFileSync(file, JSON.stringify({ mcpServers: { [args.at(-7)!]: { command: "bun" } } }));
      if (args[1] === "remove") writeFileSync(file, "{}");
      const registered = existsSync(file) && Object.hasOwn(JSON.parse(readFileSync(file, "utf8")).mcpServers ?? {}, args.at(-1)!);
      return args[1] === "get" ? { status: registered ? 0 : 1, stdout: "", stderr: registered ? "" : "No MCP server found" } : { status: 0, stdout: "", stderr: "" };
    },
  };
  const h = handler({ agents });
  const before = await call(h, "GET", "/v1/settings/agents");
  expect(before.body.tools.map((t: any) => [t.id, t.installed, t.connected])).toEqual([["claude-code", true, false], ["codex", false, false], ["claude-desktop", false, false]]);

  const connected = await call(h, "PUT", "/v1/settings/agents/claude-code", { connected: true });
  expect(connected.status).toBe(200);
  expect(connected.body.tools[0]).toMatchObject({ id: "claude-code", connected: true, partial: false });
  expect(readFileSync(join(home, ".claude/settings.json"), "utf8")).toContain("hook session-start --tool claude-code");

  const missing = await call(h, "PUT", "/v1/settings/agents/codex", { connected: true });
  expect(missing).toEqual({ status: 409, body: { error: "这台 Mac 上没找到 Codex，装好并登录后再连接。" } });
  expect(existsSync(join(home, ".codex"))).toBe(false);

  const disconnected = await call(h, "PUT", "/v1/settings/agents/claude-code", { connected: false });
  expect(disconnected.body.tools[0]).toMatchObject({ connected: false, partial: false });
  expect((await call(h, "PUT", "/v1/settings/agents/claude-code", { connected: "yes" })).status).toBe(400);
});


test("AI 工具设置的连接与断开错误只返回对应的用户提示", async () => {
  const home = join(ctx.dir, "home");
  mkdirSync(join(home, ".codex"), { recursive: true });
  const file = join(home, ".codex/hooks.json");
  writeFileSync(file, '{"hooks": []}');
  const path = "/v1/settings/agents/codex";
  let failingCommand = "";
  const h = handler({ agents: {
    home, which: () => "/fake/codex",
    run: (_command, args) => {
      if (args[1] === failingCommand) return { status: 1, stdout: "", stderr: "合成命令错误 /fake/config" };
      const registered = failingCommand === "remove" && args.at(-1) === "tacit";
      return registered ? { status: 0, stdout: "", stderr: "" } : { status: 1, stdout: "", stderr: "No server found" };
    },
  } });
  expect(await call(h, "PUT", path, { connected: true })).toEqual({
    status: 500, body: { error: "没能更新 Codex 的配置文件，请检查它是否损坏后重试。" },
  });

  writeFileSync(file, "{}");
  // 2026-11-25：失败提示固定后日志里什么都没有；现在只记固定类别，不记路径和原文。
  const logs: string[] = [], original = console.error;
  console.error = (line: unknown) => { logs.push(String(line)); };
  try {
  for (const [command, connected] of [["get", true], ["add", true], ["remove", false]] as const) {
    failingCommand = command;
    expect(await call(h, "PUT", path, { connected })).toEqual({
      status: 500, body: { error: `没能${connected ? "连接" : "断开"} Codex，请确认它能正常启动后重试。` },
    });
  }
  } finally { console.error = original; }
  expect(logs.some(line => line.includes('"location":"settings.agents"') && line.includes('"code":"agent_mcp_get_failed"'))).toBe(true);
  expect(logs.join("\n")).not.toContain(file);
});
