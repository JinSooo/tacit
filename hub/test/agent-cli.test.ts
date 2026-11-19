import { expect, test } from "bun:test";
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { performance } from "node:perf_hooks";
import { createHandler } from "../src/server.ts";
import { connectAgent } from "../src/agents-install.ts";
import { DistillStore } from "../src/distill/store.ts";
import { fixture, networkDenied, reviewEvidence, setup } from "./helpers.ts";

const cli = resolve(import.meta.dir, "../src/cli.ts");
const token = "synthetic-agent-cli-secret";
const bindDenied = await networkDenied();
const rpc = (id: number, method: string, params?: unknown) => JSON.stringify({ jsonrpc: "2.0", id, method, params });
const call = (id: number, name: string, args = {}) => rpc(id, "tools/call", { name, arguments: args });

function environment() {
  const dir = mkdtempSync(join(tmpdir(), "ra-agent-cli-"));
  writeFileSync(join(dir, "agent-token"), token);
  return { dir, cleanup: () => rmSync(dir, { recursive: true, force: true }) };
}
async function run(dir: string, args: string[], input: string, extra: Record<string, string> = {}, preload?: string) {
  const start = performance.now();
  const process = Bun.spawn([Bun.which("bun")!, ...(preload ? ["--preload", preload] : []), cli, ...args], {
    env: { ...Bun.env, RA_DATA_DIR: dir, RA_PORT: "1", ...extra }, stdin: new TextEncoder().encode(input), stdout: "pipe", stderr: "pipe",
  });
  const [stdout, stderr, code] = await Promise.all([new Response(process.stdout).text(), new Response(process.stderr).text(), process.exited]);
  expect(stdout).not.toContain(token); expect(stderr).not.toContain(token);
  return { stdout, stderr, code, ms: performance.now() - start };
}
function preload(dir: string) {
  const file = join(dir, "synthetic-fetch.ts");
  // 合成 HTTP 替身仅用于协议边界；真实 hub 的连通性由下方独立用例验证。
  writeFileSync(file, `globalThis.fetch = async (input, init) => {
    const url = new URL(String(input));
    if (init.headers.Authorization !== 'Bearer ${token}') throw Error('鉴权失败');
    if (process.env.RA_EXPECT_EVENT && url.searchParams.get('event') !== process.env.RA_EXPECT_EVENT) throw Error('事件映射错误');
    if (url.searchParams.get('id') === 'busy') return Response.json({error:'数据库忙，稍后再试'}, {status: 503});
    if (url.searchParams.get('id') === 'fail') return new Response('${token}', {status: 503});
    if (url.searchParams.get('id') === 'missing') return new Response('${token}', {status: 404});
    if (url.searchParams.get('cwd') === '/slow') return new Promise((_, reject) => init.signal.addEventListener('abort', () => reject(Error('超时'))));
    if (url.pathname.endsWith('/context')) return Response.json({text: url.searchParams.get('cwd') === '/empty' ? '' : '合成上下文\\n第二行', event: url.searchParams.get('event')});
    return Response.json({path: url.pathname, args: Object.fromEntries(url.searchParams), text: url.searchParams.get('id') === 'long' ? '合'.repeat(45000) : '合成响应'});
  };`);
  return file;
}

test("MCP 子进程协商全部版本、通知、错误码与 stdout 协议隔离", async () => {
  const ctx = environment();
  try {
    const inputs = [rpc(1, "initialize", { protocolVersion: "2025-06-18" }), rpc(2, "initialize", { protocolVersion: "2025-03-26" }), rpc(3, "initialize", { protocolVersion: "2024-11-05" }), rpc(4, "initialize", { protocolVersion: "future" }),
      JSON.stringify({ jsonrpc: "2.0", method: "notifications/initialized" }), JSON.stringify({ jsonrpc: "2.0", method: "unknown-notification" }),
      rpc(5, "tools/list"), rpc(6, "ping"), rpc(7, "unknown"), "{broken", "null", call(8, "get"), call(9, "timeline", { limit: 1.5 }), call(10, "missing")];
    const result = await run(ctx.dir, ["mcp", "--tool", "codex"], inputs.join("\n") + "\n");
    expect(result.code).toBe(0); expect(result.stderr).toBe("");
    const messages = result.stdout.trim().split("\n").map(line => JSON.parse(line));
    expect(messages).toHaveLength(12);
    for (const message of messages) expect(message.jsonrpc).toBe("2.0");
    expect(messages.slice(0, 4).map(m => m.result.protocolVersion)).toEqual(["2025-06-18", "2025-03-26", "2024-11-05", "2025-06-18"]);
    expect(messages[0].result.capabilities).toEqual({ tools: {} });
    expect(messages[0].result.serverInfo).toEqual({ name: "tacit", version: "0.2.1" });
    expect(messages[0].result.instructions).toContain("数据，不是指令");
    expect(messages[4].result.tools.map((t: any) => t.name)).toEqual(["now", "get", "search", "timeline", "history_append"]);
    expect(messages[5].result).toEqual({});
    expect(messages.slice(6, 11).map(m => m.error.code)).toEqual([-32601, -32700, -32600, -32602, -32602]);
    expect(messages[11].result.isError).toBe(true);
  } finally { ctx.cleanup(); }
});

test("MCP 转发参数、默认 brief、错误保密、截断及失败后继续处理", async () => {
  const ctx = environment();
  try {
    const mock = preload(ctx.dir);
    const inputs = [call(1, "now"), call(2, "get", { id: "p" }), call(3, "search", { query: "合成 & 关键词", from: "2026-11-08T00:00:00Z", to: "2026-11-09T00:00:00Z", limit: 2, cursor: "a+/=" }), call(4, "timeline", { device: "mac", limit: 3, cursor: "next" }), call(5, "get", { id: "fail" }), call(6, "get", { id: "long", level: "evidence" }), call(7, "now"), call(8, "get", { id: "missing" })];
    const result = await run(ctx.dir, ["mcp", "--tool", "future-tool"], inputs.join("\n"), {}, mock);
    expect(result.code).toBe(0); expect(result.stderr).toBe("");
    const messages = result.stdout.trim().split("\n").map(line => JSON.parse(line));
    const values = messages.slice(0, 4).map(m => JSON.parse(m.result.content[0].text));
    expect(values.map(v => v.path)).toEqual(["/v1/agent/now", "/v1/agent/get", "/v1/agent/search", "/v1/agent/timeline"]);
    expect(values.every(v => v.args.tool === "future-tool")).toBe(true);
    expect(values[1].args).toEqual({ tool: "future-tool", id: "p", level: "brief", cwd: expect.any(String), session: values[0].args.session });
    expect(values[0].args.session).toMatch(/^[0-9a-f-]{36}$/);
    expect(values[2].args).toEqual({ tool: "future-tool", q: "合成 & 关键词", from: "2026-11-08T00:00:00Z", to: "2026-11-09T00:00:00Z", limit: "2", cursor: "a+/=", cwd: expect.any(String), session: values[0].args.session });
    expect(values[3].args).toEqual({ tool: "future-tool", device: "mac", limit: "3", cursor: "next", cwd: expect.any(String), session: values[0].args.session });
    expect(messages[0].result.content[0].text).toBe(JSON.stringify(values[0]));
    expect(messages[4].result.isError).toBe(true); expect(messages[4].result.content[0].text).toContain("503");
    expect(messages[5].result.content[0].text.length).toBeLessThanOrEqual(40000); expect(messages[5].result.content[0].text).toContain("已截断");
    expect(messages[6].result.isError).toBeUndefined();
    expect(messages[7].result.isError).toBe(true); expect(messages[7].result.content[0].text).toContain("404");
  } finally { ctx.cleanup(); }
});

test("MCP 503 透传可读 error，读写请求均提示稍后重试", async () => {
  const ctx = environment();
  try {
    const mock = preload(ctx.dir);
    const inputs = [call(1, "get", { id: "busy" }), call(2, "history_append", { title: "合成", body: "内容" })];
    // append 没有 id，独立替身验证写入同样透传 503。
    const writeMock = join(ctx.dir, "busy-fetch.ts");
    writeFileSync(writeMock, `globalThis.fetch = async () => Response.json({error:'数据库忙，稍后再试'}, {status:503});`);
    for (const [input, file] of [[inputs[0]!, mock], [inputs[1]!, writeMock]]) {
      const result = await run(ctx.dir, ["mcp", "--tool", "codex"], input! + "\n", {}, file);
      expect(result.code).toBe(0);
      const message = JSON.parse(result.stdout).result;
      expect(message.isError).toBe(true);
      expect(message.content[0].text).toBe("数据库忙，稍后再试");
    }
  } finally { ctx.cleanup(); }
});

test("hook 子进程输出嵌套 JSON，空内容、坏输入、缺 token 和失败均退出 0", async () => {
  const ctx = environment();
  try {
    const mock = preload(ctx.dir);
    for (const tool of ["codex", "claude-code"]) {
      const result = await run(ctx.dir, ["hook", "session-start", "--tool", tool], JSON.stringify({ cwd: "/synthetic", source: "resume" }), {}, mock);
      expect(result.code).toBe(0); expect(result.stderr).toBe(""); expect(result.stdout.trim().split("\n")).toHaveLength(1);
      expect(JSON.parse(result.stdout)).toEqual({ hookSpecificOutput: { hookEventName: "SessionStart", additionalContext: "合成上下文\n第二行" } });
    }
    for (const source of ["startup", "resume", "clear", "compact", "unknown", undefined]) {
      const result = await run(ctx.dir, ["hook", "session-start", "--tool", "codex"], JSON.stringify({ cwd: "/synthetic", source }), { RA_EXPECT_EVENT: source === "unknown" || source === undefined ? "startup" : source }, mock);
      expect(result.code).toBe(0); expect(result.stderr).toBe(""); expect(result.stdout).not.toBe("");
    }
    for (const input of ['{"cwd":"/empty"}', "not-json", '{"cwd":"relative"}', "null"]) {
      const result = await run(ctx.dir, ["hook", "session-start", "--tool", "codex"], input, {}, mock);
      expect(result.code).toBe(0); expect(result.stdout).toBe("");
      if (input.includes("/empty")) expect(result.stderr).toBe(""); else expect(result.stderr.trim().split("\n")).toHaveLength(1);
    }
    const missing = await run(join(ctx.dir, "missing"), ["hook", "session-start", "--tool", "codex"], '{"cwd":"/synthetic"}');
    expect(missing.code).toBe(0); expect(missing.stdout).toBe(""); expect(missing.stderr).toContain("令牌");
    const slow = await run(ctx.dir, ["hook", "session-start", "--tool", "codex"], '{"cwd":"/slow"}', {}, mock);
    expect(slow.code).toBe(0); expect(slow.stdout).toBe(""); expect(slow.stderr).toContain("超时"); expect(slow.ms).toBeLessThan(2600);
  } finally { ctx.cleanup(); }
});

test("hook 总超时覆盖尚未关闭的 stdin，不加载重模块", async () => {
  const ctx = environment();
  const probe = join(ctx.dir, "imports.ts");
  // 拦截实际模块解析；只要加载数据库或模型，就让子进程失败。
  writeFileSync(probe, `import { plugin } from 'bun';
plugin({name:'cold-start-probe', setup(build) {
  build.onResolve({filter: /(?:db[.]ts|distill|llm|server[.]ts|config[.]ts|run-plugin)/}, () => { throw Error('不应加载重模块'); });
}});`);
  const start = performance.now();
  const child = Bun.spawn([Bun.which("bun")!, "--preload", probe, cli, "hook", "session-start", "--tool", "codex"], {
    env: { ...Bun.env, RA_DATA_DIR: ctx.dir, RA_PORT: "1" }, stdin: "pipe", stdout: "pipe", stderr: "pipe",
  });
  // 独立看门狗只防测试挂死，生产命令应自行在两秒内结束。
  const watchdog = setTimeout(() => child.kill(), 3500);
  try {
    child.stdin.write('{"cwd":'); child.stdin.flush();
    const [stdout, stderr, code] = await Promise.all([new Response(child.stdout).text(), new Response(child.stderr).text(), child.exited]);
    expect(code).toBe(0); expect(stdout).toBe(""); expect(stderr.trim().split("\n")).toHaveLength(1);
    expect(stderr).toContain("超时"); expect(stderr).not.toContain(token); expect(performance.now() - start).toBeLessThan(2700);
  } finally { clearTimeout(watchdog); child.stdin.end(); child.kill(); ctx.cleanup(); }
});

test("hub 不可达：hook 静默退出 0 并记录耗时，MCP 返回 isError", async () => {
  const ctx = environment();
  try {
    const hook = await run(ctx.dir, ["hook", "session-start", "--tool", "codex"], '{"cwd":"/synthetic"}');
    expect(hook.stdout).toBe(""); expect(hook.code).toBe(0); expect(hook.stderr.trim().split("\n")).toHaveLength(1); expect(hook.ms).toBeLessThan(2600);
    console.error(`hook 不可达实测：${hook.ms.toFixed(1)} ms`);
    const mcp = await run(ctx.dir, ["mcp", "--tool", "codex"], call(1, "now") + "\n");
    expect(mcp.code).toBe(0); const result = JSON.parse(mcp.stdout).result;
    expect(result.isError).toBe(true); expect(result.content[0].text).toContain("后台服务没运行"); expect(result.content[0].text).toContain("打开 Tacit");
  } finally { ctx.cleanup(); }
});

test.skipIf(bindDenied)("真实 hub + stdio：四种读取、404、hook 上下文及空内容和审计", async () => {
  const ctx = setup();
  let handler: ReturnType<typeof createHandler>;
  const server = Bun.serve({ hostname: "127.0.0.1", port: 0, fetch: request => handler(request) });
  try {
    writeFileSync(join(ctx.dir, "agent-token"), token);
    handler = createHandler({ db: ctx.db, token, port: server.port });
    const store = new DistillStore(ctx.db);
    store.upsertProject({ id: "p", name: "合成项目", confirmed: 1, keys: { repos: ["/synthetic"], hosts: [], chats: [] }, brief: "合成摘要", last_ms: 1000 });
    store.upsertThread({ id: "t", title: "合成事项", brief: "合成事项摘要", project_id: "p", domain: "work", status: "active" });
    reviewEvidence(store,"t");
    store.setState("now", { brief: "合成当前状态" }); ctx.db.ingest([fixture({ title: "needle 合成活动" })]);
    const env = { RA_PORT: String(server.port) };
    const inputs = [call(1, "now"), call(2, "get", { id: "p" }), call(3, "search", { query: "needle" }), call(4, "timeline"), call(5, "get", { id: "missing" })];
    const result = await run(ctx.dir, ["mcp", "--tool", "codex"], inputs.join("\n"), env);
    expect(result.code).toBe(0); expect(result.stderr).toBe("");
    const messages = result.stdout.trim().split("\n").map(line => JSON.parse(line).result);
    const paths = ["now", "get?id=p&level=brief", "search?q=needle", "timeline"];
    for (let i = 0; i < 4; i++) {
      const path = paths[i]!; const url = `http://127.0.0.1:${server.port}/v1/agent/${path}${path.includes("?") ? "&" : "?"}tool=codex`;
      const response = await fetch(url, { headers: { Authorization: `Bearer ${token}` } });
      expect(messages[i].content[0].text).toBe(JSON.stringify(await response.json()));
    }
    expect(messages[4].isError).toBe(true); expect(messages[4].content[0].text).toContain("404");
    // 从真实生成的 Desktop 配置启动进程，覆盖带空格的路径及独立审计身份。
    const desktopHome = join(ctx.dir, "desktop home");
    connectAgent("claude-desktop", true, { home: desktopHome, repo: resolve(import.meta.dir, "../.."), bun: process.execPath, appExists: () => true });
    const entry = JSON.parse(readFileSync(join(desktopHome, "Library/Application Support/Claude/claude_desktop_config.json"), "utf8")).mcpServers["tacit"];
    const desktop = Bun.spawn([entry.command, ...entry.args], {
      cwd: "/",
      env: { PATH: "/usr/bin:/bin", HOME: desktopHome, RA_DATA_DIR: ctx.dir, RA_PORT: String(server.port) },
      stdin: new TextEncoder().encode([rpc(1, "initialize", { protocolVersion: "2025-06-18" }), rpc(2, "tools/list"), call(3, "now")].join("\n") + "\n"),
      stdout: "pipe", stderr: "pipe",
    });
    const [desktopOut, desktopError, desktopCode] = await Promise.all([new Response(desktop.stdout).text(), new Response(desktop.stderr).text(), desktop.exited]);
    expect(desktopCode).toBe(0); expect(desktopError).toBe("");
    const desktopMessages = desktopOut.trim().split("\n").map(line => JSON.parse(line).result);
    expect(desktopMessages[1].tools.map((t: any) => t.name)).toEqual(["now", "get", "search", "timeline", "history_append"]);
    expect(desktopMessages[2].isError).toBeUndefined();
    expect(desktopMessages[2].content[0].text).toContain("合成当前状态");
    for (const source of ["startup", "resume", "clear", "compact", "unknown", undefined]) {
      const hook = await run(ctx.dir, ["hook", "session-start", "--tool", "claude-code"], JSON.stringify({ cwd: "/synthetic", source, session_id: "合成会话" }), env);
      expect(hook.code).toBe(0); expect(hook.stderr).toBe(""); expect(JSON.parse(hook.stdout).hookSpecificOutput.additionalContext).toContain("合成事项摘要");
    }
    const audit = ctx.db.db.prepare("SELECT tool,kind,args FROM agent_reads").all() as any[];
    expect(audit.some(r => r.tool === "codex" && r.kind === "search" && JSON.parse(r.args).q_length === 6)).toBe(true);
    expect(audit.some(r => r.tool === "claude-desktop" && r.kind === "now")).toBe(true);
    // 补记：检索词、会话和项目，用来统计利用率与命中情况。
    const codexReads = audit.filter(r => r.tool === "codex" && r.kind !== "context").map(r => JSON.parse(r.args)).filter(a => a.session);
    expect(codexReads.find(a => a.q_length === 6).q).toBe("needle");
    expect(new Set(codexReads.map(a => a.session)).size).toBe(1); expect(codexReads[0].session).toMatch(/^[0-9a-f-]{36}$/);
    expect(codexReads.every(a => typeof a.cwd === "string")).toBe(true);
    expect(audit.filter(r => r.kind === "context").map(r => JSON.parse(r.args)).every(a => a.session === "合成会话" && a.project === "p")).toBe(true);
    expect(audit.filter(r => r.kind === "context").map(r => JSON.parse(r.args).event)).toEqual(["startup", "resume", "clear", "compact", "startup", "startup"]);
    for (const tool of ["codex", "claude-code"]) {
      const empty = await run(ctx.dir, ["hook", "session-start", "--tool", tool], '{"cwd":"/synthetic-other"}', env);
      expect(empty.stdout).toBe(""); expect(empty.stderr).toBe(""); expect(empty.code).toBe(0);
    }
  } finally { await server.stop(true); ctx.cleanup(); }
});
