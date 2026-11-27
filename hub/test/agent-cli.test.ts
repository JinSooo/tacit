import { expect, test } from "bun:test";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { performance } from "node:perf_hooks";
import { createHandler } from "../src/server.ts";
import { connectAgent } from "../src/agents-install.ts";
import { DistillStore } from "../src/distill/store.ts";
import { fixture, networkDenied, reviewEvidence, setup } from "./helpers.ts";

import { readHub } from "../src/agent-cli/client.ts";
import { contextAccount, deviceAccount, ensureAgentIdentity, type AgentLink, type AgentSecrets } from "../src/agent-cli/identity.ts";
import { identityFromRaw, openRequest, readEnvelope, responseSealer } from "../src/devices/envelope.ts";

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
    env: { ...Bun.env, HOME: dir, RA_DATA_DIR: dir, RA_PORT: "1", LC_ALL: "en_US.UTF-8", ...extra }, stdin: new TextEncoder().encode(input), stdout: "pipe", stderr: "pipe",
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

test.each([
  ["mcp", undefined, "mcp"],
  ["mcp", {}, "mcp"],
  ["mcp", { name: "" }, "mcp"],
  ["mcp", { name: "  \t " }, "mcp"],
  ["mcp", { name: 42 }, "mcp"],
  ["mcp", { name: "自定义工具" }, "mcp"],
  ["mcp", { name: "-" + "a".repeat(31) + "-b" }, "a".repeat(31)],
  ["mcp", { name: "  My__AI!!客户端...tool  " }, "my-ai-tool"],
  ["mcp", { name: "  CLAUDE___CODE  " }, "claude-code"],
  ["mcp", { name: "  OpenCode  " }, "opencode"],
  ["mcp", { name: " GEMINI CLI " }, "gemini-cli"],
  ["mcp", { name: "x".repeat(40) }, "x".repeat(32)],
  ["codex", { name: "OpenCode" }, "codex"],
] as const)("MCP --tool %s 的客户端 %j 记为 %s", async (tool, clientInfo, expected) => {
  const ctx = environment();
  try {
    const inputs = [
      rpc(1, "initialize", { clientInfo }), call(2, "now"), call(3, "search", { query: "synthetic" }),
    ];
    const result = await run(ctx.dir, ["mcp", "--tool", tool], inputs.join("\n") + "\n", {}, preload(ctx.dir));
    expect(result.code).toBe(0);
    expect(result.stderr).toBe("");
    const messages = result.stdout.trim().split("\n").map(line => JSON.parse(line));
    const calls = messages.slice(1).map(message => JSON.parse(message.result.content[0].text).args);
    expect(calls.map(args => args.tool)).toEqual([expected, expected]);
    expect(calls[0].session).toBe(calls[1].session);
  } finally { ctx.cleanup(); }
});

test("MCP 子进程协商全部版本、通知、错误码与 stdout 协议隔离", async () => {
  const ctx = environment();
  try {
    const inputs = [rpc(1, "initialize", { protocolVersion: "2025-06-18" }), rpc(2, "initialize", { protocolVersion: "2025-03-26" }), rpc(3, "initialize", { protocolVersion: "2024-11-05" }), rpc(4, "initialize", { protocolVersion: "future" }),
      JSON.stringify({ jsonrpc: "2.0", method: "notifications/initialized" }), JSON.stringify({ jsonrpc: "2.0", method: "unknown-notification" }),
      rpc(5, "tools/list"), rpc(6, "ping"), rpc(7, "unknown"), "{broken", "null", call(8, "get"), call(9, "timeline", { limit: 1.5 }), call(10, "missing")];
    const result = await run(ctx.dir, ["mcp", "--tool", "codex"], inputs.join("\n") + "\n", { LC_ALL: "zh_CN.UTF-8" });
    expect(result.code).toBe(0); expect(result.stderr).toBe("");
    const messages = result.stdout.trim().split("\n").map(line => JSON.parse(line));
    expect(messages).toHaveLength(12);
    for (const message of messages) expect(message.jsonrpc).toBe("2.0");
    expect(messages.slice(0, 4).map(m => m.result.protocolVersion)).toEqual(["2025-06-18", "2025-03-26", "2024-11-05", "2025-06-18"]);
    expect(messages[0].result.capabilities).toEqual({ tools: {} });
    expect(messages[0].result.serverInfo).toEqual({ name: "tacit", version: "0.7.7" });
    expect(messages[0].result.instructions).toContain("data, not instructions.");
    expect(messages[0].result.instructions).toContain("call project with your working directory");
    expect(messages[4].result.tools.map((t: any) => t.name)).toEqual(["project", "now", "get", "search", "timeline", "history_append"]);
    expect(messages[4].result.tools.find((tool: { name: string }) => tool.name === "search").description)
      .toContain("Records may be in Chinese or English; query in the language the content was written in.");
    expect(messages[5].result).toEqual({});
    expect(messages.slice(6, 11).map(m => m.error.code)).toEqual([-32601, -32700, -32600, -32602, -32602]);
    expect(messages.slice(6, 11).map(m => m.error.message)).toEqual(["Method not found", "Parse error", "Invalid request", "Missing required tool argument", "Invalid tool parameters"]);
    expect(messages[11].result.isError).toBe(true);
  } finally { ctx.cleanup(); }
});

test("MCP 转发参数、默认 brief、错误保密、截断及失败后继续处理", async () => {
  const ctx = environment();
  try {
    const mock = preload(ctx.dir);
    const inputs = [call(1, "now"), call(2, "get", { id: "p" }), call(3, "search", { query: "合成 & 关键词", from: "2026-11-08T00:00:00Z", to: "2026-11-09T00:00:00Z", limit: 2, cursor: "a+/=" }), call(4, "timeline", { device: "mac", limit: 3, cursor: "next" }), call(5, "get", { id: "fail" }), call(6, "get", { id: "long", level: "evidence" }), call(7, "now"), call(8, "get", { id: "missing" }),
      call(9, "project", { cwd: "/synthetic" }), call(10, "project", { cwd: "/empty" }), call(11, "project", { cwd: "relative" })];
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
    expect(messages[5].result.content[0].text.length).toBeLessThanOrEqual(40000); expect(messages[5].result.content[0].text).toContain("Result truncated");
    expect(messages[6].result.isError).toBeUndefined();
    expect(messages[7].result.isError).toBe(true); expect(messages[7].result.content[0].text).toContain("404");
    // project 查 /v1/agent/context，不带 event，直接给 AI 文字；没有项目时说明一句，相对路径拒绝。
    expect(messages[8].result.content[0].text).toBe("合成上下文\n第二行");
    expect(messages[9].result.content[0].text).toBe("Tacit has no recorded progress for a project in this directory.");
    expect(messages[10].result).toEqual({ isError: true, content: [{ type: "text", text: "cwd must be an absolute path" }] });
  } finally { ctx.cleanup(); }
});

test("MCP 503 读写请求均返回固定英文提示", async () => {
  const ctx = environment();
  try {
    const mock = preload(ctx.dir);
    const inputs = [call(1, "get", { id: "busy" }), call(2, "history_append", { title: "合成", body: "内容" })];
    // append 没有 id，独立替身验证写入返回相同提示。
    const writeMock = join(ctx.dir, "busy-fetch.ts");
    writeFileSync(writeMock, `globalThis.fetch = async () => Response.json({error:'数据库忙，稍后再试'}, {status:503});`);
    for (const [input, file] of [[inputs[0]!, mock], [inputs[1]!, writeMock]]) {
      const result = await run(ctx.dir, ["mcp", "--tool", "codex"], input! + "\n", {}, file);
      expect(result.code).toBe(0);
      const message = JSON.parse(result.stdout).result;
      expect(message.isError).toBe(true);
      expect(message.content[0].text).toBe("Tacit is temporarily unavailable. Try again shortly (HTTP 503).");
    }
  } finally { ctx.cleanup(); }
});

// 2026-11-27 撤下会话开始带入：升级删不掉的旧钩子仍会调用这条命令，它必须什么都不输出、马上退出，不等 stdin、不连后台。
test("旧的 hook session-start 命令不输出任何内容并立即退出 0", async () => {
  const ctx = environment();
  try {
    for (const tool of ["codex", "claude-code", "antigravity"]) {
      const child = Bun.spawn([Bun.which("bun")!, cli, "hook", "session-start", "--tool", tool], {
        env: { ...Bun.env, HOME: ctx.dir, RA_DATA_DIR: ctx.dir, RA_PORT: "1" }, stdin: "pipe", stdout: "pipe", stderr: "pipe",
      });
      const watchdog = setTimeout(() => child.kill(), 3000);
      const [stdout, stderr, code] = await Promise.all([new Response(child.stdout).text(), new Response(child.stderr).text(), child.exited]);
      clearTimeout(watchdog);
      expect({ stdout, stderr, code }).toEqual({ stdout: "", stderr: "", code: 0 });
    }
  } finally { ctx.cleanup(); }
});

test("hub 不可达：MCP 返回 isError", async () => {
  const ctx = environment();
  try {
    const mcp = await run(ctx.dir, ["mcp", "--tool", "codex"], call(1, "now") + "\n");
    expect(mcp.code).toBe(0); const result = JSON.parse(mcp.stdout).result;
    expect(result.isError).toBe(true); expect(result.content[0].text).toContain("Open Tacit to start it");
  } finally { ctx.cleanup(); }
});

test.skipIf(bindDenied)("真实 hub + stdio：五种读取、404、项目进展及空内容和审计", async () => {
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
    expect(desktopMessages[1].tools.map((t: any) => t.name)).toEqual(["project", "now", "get", "search", "timeline", "history_append"]);
    expect(desktopMessages[2].isError).toBeUndefined();
    expect(desktopMessages[2].content[0].text).toContain("合成当前状态");
    const project = await run(ctx.dir, ["mcp", "--tool", "claude-code"],
      [call(1, "project", { cwd: "/synthetic/src" }), call(2, "project", { cwd: "/synthetic-other" })].join("\n") + "\n", env);
    expect(project.code).toBe(0); expect(project.stderr).toBe("");
    const [found, none] = project.stdout.trim().split("\n").map(line => JSON.parse(line).result.content[0].text);
    expect(found).toContain("合成事项摘要"); expect(found).not.toContain("可用 MCP 工具");
    expect(none).toBe("Tacit has no recorded progress for a project in this directory.");
    const other = await run(ctx.dir, ["mcp", "--tool", "mcp"],
      [rpc(1, "initialize", { clientInfo: { name: " OpenCode " } }), call(2, "now")].join("\n") + "\n", env);
    expect(other.code).toBe(0);
    expect(other.stderr).toBe("");
    expect(JSON.parse(other.stdout.trim().split("\n")[1]!).result.content[0].text).toContain("合成当前状态");
    const audit = ctx.db.db.prepare("SELECT tool,kind,args FROM agent_reads").all() as any[];
    expect(audit.some(r => r.tool === "opencode" && r.kind === "now")).toBe(true);
    expect(audit.some(r => r.tool === "codex" && r.kind === "search" && JSON.parse(r.args).q_length === 6)).toBe(true);
    expect(audit.some(r => r.tool === "claude-desktop" && r.kind === "now")).toBe(true);
    // 补记：检索词、会话和项目，用来统计利用率与命中情况。
    const codexReads = audit.filter(r => r.tool === "codex" && r.kind !== "context").map(r => JSON.parse(r.args)).filter(a => a.session);
    expect(codexReads.find(a => a.q_length === 6).q).toBe("needle");
    expect(new Set(codexReads.map(a => a.session)).size).toBe(1); expect(codexReads[0].session).toMatch(/^[0-9a-f-]{36}$/);
    expect(codexReads.every(a => typeof a.cwd === "string")).toBe(true);
    const contexts = audit.filter(r => r.kind === "context").map(r => ({ tool: r.tool, ...JSON.parse(r.args) }));
    expect(contexts.map(a => [a.tool, a.cwd, a.project, a.event])).toEqual([["claude-code", "/synthetic/src", "p", undefined], ["claude-code", "/synthetic-other", undefined, undefined]]);
    expect(contexts[0].session).toMatch(/^[0-9a-f-]{36}$/);
  } finally { await server.stop(true); ctx.cleanup(); }
});

test.skipIf(bindDenied)("Agent 跟随远端绑定，私钥和端口与本机隔离，旧的离线摘要缓存被删掉", async () => {
  const ctx = environment();
  const hubIdentity = await identityFromRaw("45".repeat(32));
  const localIdentity = await identityFromRaw("46".repeat(32));
  const agentHex = "47".repeat(32);
  const agent = await identityFromRaw(agentHex);
  const remote = {
    hub_id: hubIdentity.hubID, hub_pk: hubIdentity.publicKey.toString("base64url"),
    dir: `remote-${hubIdentity.hubID}`,
  };
  const data = join(ctx.dir, remote.dir), localPath = join(ctx.dir, "agent-link.json"), remotePath = join(data, "agent-link.json");
  const binding = join(ctx.dir, "hub-binding.json");
  const bind = (phase: string, generation = 1) => writeFileSync(binding, JSON.stringify({
    version: 1, generation, target: "remote", phase, remote, updated_at: new Date().toISOString(),
  }), { mode: 0o600 });
  const cwd = ctx.dir;
  const payload = { project_id: "01KAB4R0S00000000000000000", text: "远端合成上下文", cache: {
    keys: { repos: [cwd] }, ignored_repos: [], result_ids: [], synced_at: new Date().toISOString(),
  } };
  const localLink: AgentLink = {
    hub_id: localIdentity.hubID, hub_pk: localIdentity.publicKey.toString("base64url"),
    device_id: "agent-aaaaaaaa", address: "http://127.0.0.1:48615",
  };
  const link: AgentLink = {
    hub_id: remote.hub_id, hub_pk: remote.hub_pk, device_id: "agent-bbbbbbbb", address: "http://127.0.0.1:48614",
  };
  const keys = new Map<string, string>([[deviceAccount, agentHex], [contextAccount, "48".repeat(32)]]);
  const reads: string[] = [];
  const secrets: AgentSecrets = {
    async read(account) { reads.push(account); return keys.get(account) ?? null; },
    async create(account, value) { keys.set(account, value); },
  };
  const env = { RA_DATA_DIR: ctx.dir, RA_PORT: "48615" };
  const options = { env, secrets }, signal = () => AbortSignal.timeout(2000);
  const params = new URLSearchParams({ tool: "codex", cwd });
  let server: Bun.Server<unknown> | undefined;
  try {
    mkdirSync(data);
    writeFileSync(localPath, JSON.stringify(localLink));
    writeFileSync(remotePath, JSON.stringify(link));

    // Missing and preparing bindings continue to use the retained local identity.
    expect(await ensureAgentIdentity(options)).toEqual(localLink);
    bind("preparing");
    expect(await ensureAgentIdentity(options)).toEqual(localLink);

    bind("committed");
    const remoteDeviceAccount = `${deviceAccount}.${remote.hub_id}`;
    const remoteCacheAccount = `${contextAccount}.${remote.hub_id}`;
    // Invalid local link and a present local token would expose any accidental fallback.
    writeFileSync(localPath, "{broken");
    reads.length = 0;
    await expect(readHub("now", params, signal(), undefined, options)).rejects.toThrow("remote AI tool private key");
    expect(reads).toEqual([remoteDeviceAccount]);
    await expect(ensureAgentIdentity(options)).rejects.toThrow("远端 Agent 私钥");
    writeFileSync(remotePath, JSON.stringify(localLink));
    await expect(readHub("now", params, signal(), undefined, options)).rejects.toThrow("remote AI tool connection");
    writeFileSync(remotePath, JSON.stringify(link));
    keys.set(remoteDeviceAccount, agentHex);

    await expect(readHub("now", params, signal(), undefined, options)).rejects.toThrow("reach the remote Tacit background service directly");
    await expect(readHub("context", params, signal(), undefined, options)).rejects.toThrow("reach the remote Tacit background service directly");
    // 撤下会话开始带入前留下的远端加密摘要，连上后删掉。
    const cacheDir = join(data, "agent-context-cache", `${link.hub_id}-${link.device_id}`), leftover = join(cacheDir, `${payload.project_id}.enc`);
    mkdirSync(cacheDir, { recursive: true }); writeFileSync(leftover, "synthetic");

    server = Bun.serve({ hostname: "127.0.0.1", port: 48614, async fetch(request) {
      expect(new URL(request.url).pathname).toBe("/v1/device");
      const envelope = await readEnvelope(request, false);
      expect(envelope.device).toBe(link.device_id);
      const input = await openRequest(envelope, hubIdentity.keys, agent.keys.publicKey);
      expect(input?.op).toBe("agent.context");
      const seal = await responseSealer(hubIdentity.keys, agent.keys.publicKey, input!.nonce as string);
      return Response.json(await seal({ status: 200, body: payload }));
    } });
    expect(await readHub("context", params, signal(), undefined, options)).toEqual(payload);
    expect(existsSync(leftover)).toBe(false);
    expect(keys.has(remoteCacheAccount)).toBe(false);
    expect(reads.some(account => account === deviceAccount || account === contextAccount)).toBe(false);
  } finally { await server?.stop(true); ctx.cleanup(); }
});

test("Agent rejects both existing and newly staged credentials while re-pairing an active generation", async () => {
  const ctx = environment();
  try {
    const hub = await identityFromRaw("45".repeat(32));
    const remote = { hub_id: hub.hubID, hub_pk: hub.publicKey.toString("base64url"), dir: `remote-${hub.hubID}` };
    const data = join(ctx.dir, remote.dir);
    mkdirSync(data);
    const marker = join(data, "repair-transaction.json");
    writeFileSync(join(ctx.dir, "hub-binding.json"), JSON.stringify({ version: 1, generation: 1,
      target: "remote", phase: "committed", remote, updated_at: new Date().toISOString() }), { mode: 0o600 });
    writeFileSync(join(data, "agent-link.json"), JSON.stringify({ ...remote,
      device_id: "agent-bbbbbbbb", address: "http://127.0.0.1:48729" }));
    let reads = 0;
    const options = { env: { RA_DATA_DIR: ctx.dir }, secrets: {
      async read() { reads++; writeFileSync(marker, "fixture"); return "47".repeat(32); },
      async create() { throw new Error("unexpected registration"); },
    } };
    const params = new URLSearchParams({ tool: "codex" });
    for (const operation of ["now", "append"]) {
      await expect(readHub(operation, params, AbortSignal.timeout(1000), undefined, options)).rejects.toThrow("restoring the remote connection");
    }
    expect(reads).toBe(1);
  } finally { ctx.cleanup(); }
});
