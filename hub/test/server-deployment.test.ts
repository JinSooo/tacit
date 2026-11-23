import { afterEach, expect, test } from "bun:test";
import { EventEmitter } from "node:events";
import { chmodSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { createServer } from "node:net";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import { randomBytes } from "node:crypto";
import { createHandler, startServer } from "../src/server.ts";
import { hubStatus } from "../src/status.ts";
import {
  applyTimezone, hubModeOf, isValidTimeZone, resolveLanPort, resolveTimezone,
  timezoneStatus, UTC_TIMEZONE_WARNING,
} from "../src/hub-json.ts";
import { inspectModelConfig, loadConfig as loadModelConfig, SERVER_CLI_ERROR } from "../src/llm/config.ts";
import { createLLM } from "../src/llm/index.ts";
import { distillRound, distillTick, type LoopState } from "../src/distill/run.ts";
import { DeviceClient, decodePairing } from "../src/devices/client.ts";
import { importDbKey } from "../src/keys.ts";
import { openSecretStore } from "../src/secrets/index.ts";
import { runSupervisor, type SupervisedChild, type SupervisedExit } from "../src/supervisor.ts";
import { HubDB } from "../src/db.ts";
import { fixture, networkDenied, setup } from "./helpers.ts";

const bindDenied = await networkDenied();
const cli = fileURLToPath(new URL("../src/cli.ts", import.meta.url));
const cleanups: (() => void | Promise<void>)[] = [];

afterEach(async () => {
  for (const fn of cleanups.splice(0).reverse()) await fn();
});

function sealedEnv(rootDir: string, extra: Record<string, string> = {}) {
  const dataDir = join(rootDir, "data");
  const keyFile = join(rootDir, "master.key");
  writeFileSync(keyFile, randomBytes(32).toString("hex") + "\n", { mode: 0o400 });
  chmodSync(keyFile, 0o400);
  return {
    dataDir,
    keyFile,
    env: {
      ...process.env,
      RA_HUB_MODE: "server",
      RA_SECRET_BACKEND: "sealed-file",
      RA_DATA_DIR: dataDir,
      RA_MASTER_KEY_FILE: keyFile,
      ...extra,
    } as Record<string, string>,
  };
}

function makeTempDir() {
  const dir = mkdtempSync(join(tmpdir(), "ra-server-deploy-"));
  cleanups.push(() => rmSync(dir, { recursive: true, force: true }));
  return dir;
}

async function freePort(): Promise<number> {
  return await new Promise((resolve, reject) => {
    const s = createServer();
    s.once("error", reject);
    s.listen(0, "127.0.0.1", () => {
      const port = (s.address() as { port: number }).port;
      s.close(err => err ? reject(err) : resolve(port));
    });
  });
}

test("hubModeOf 与 RA_LAN_PORT 解析规则", () => {
  expect(hubModeOf({}, "darwin")).toBe("mac");
  expect(hubModeOf({}, "linux")).toBe("server");
  expect(hubModeOf({ RA_HUB_MODE: "server" }, "darwin")).toBe("server");
  expect(hubModeOf({ RA_HUB_MODE: "mac" }, "linux")).toBe("mac");
  expect(() => hubModeOf({ RA_HUB_MODE: "invalid" }, "darwin")).toThrow("RA_HUB_MODE");

  const dir = makeTempDir();
  expect(resolveLanPort(dir, {})).toBe(47824);
  writeFileSync(join(dir, "hub.json"), JSON.stringify({ lan_port: 49100 }));
  expect(resolveLanPort(dir, {})).toBe(49100);
  expect(resolveLanPort(dir, { RA_LAN_PORT: "49200" })).toBe(49200);
  expect(resolveLanPort(dir, { RA_LAN_PORT: "0" })).toBe(0);
  expect(() => resolveLanPort(dir, { RA_LAN_PORT: "70000" })).toThrow("RA_LAN_PORT");
});

test.skipIf(bindDenied)("server 模式不监听 127.0.0.1 管理端口，0.0.0.0 仅开放设备端点且 /v1/status、/v1/settings/* 返回 404", async () => {
  const ctx = setup();
  cleanups.push(() => ctx.cleanup());
  const unusedLocalPort = await freePort();
  let key: string | null = null;
  const server = startServer({
    db: ctx.db, token: ctx.config.token, port: unusedLocalPort,
    mode: "server", lanPort: 0,
    settings: { dataDir: ctx.dir, mode: "server", env: { RA_HUB_MODE: "server", TZ: "Asia/Shanghai" } },
    deviceDeps: { keys: { read: () => key, write: v => { key = v; } } },
  });
  cleanups.push(() => server.stop(true));

  expect(server.mode).toBe("server");
  expect(server.port).toBeNull();
  expect(server.url).toBeNull();
  expect(server.lanPort).toBeGreaterThan(0);

  // 未显式传 localStatusPort 时，127.0.0.1 管理端口不应在监听。
  await expect(fetch(`http://127.0.0.1:${unusedLocalPort}/v1/health`)).rejects.toThrow();

  // 设备端口常开，且管理与设置路由一律返回 404（绝不暴露 Bearer token 管理接口）。
  const base = `http://127.0.0.1:${server.lanPort}`;
  for (const [method, path] of [
    ["GET", "/v1/status"],
    ["GET", "/v1/settings/models"],
    ["PUT", "/v1/settings/models"],
    ["GET", "/v1/settings/hub"],
    ["GET", "/v1/settings/devices"],
    ["GET", "/v1/settings/security-audit"],
    ["GET", "/v1/health"],
    ["GET", "/"],
  ] as const) {
    const res = await fetch(base + path, { method, headers: { Authorization: `Bearer ${ctx.config.token}` } });
    expect(res.status).toBe(404);
  }
  // 未创建设备身份时 /v1/device/hello 返回 401（属于设备端点，而非 404）。
  expect((await fetch(base + "/v1/device/hello")).status).toBe(401);

  // 显式传 localStatusPort 时，仅在 127.0.0.1 上开放排障接口。
  const withLocal = startServer({
    db: ctx.db, token: ctx.config.token, mode: "server", lanPort: 0, localStatusPort: 0,
    settings: { dataDir: ctx.dir, mode: "server", env: { RA_HUB_MODE: "server", TZ: "Asia/Shanghai" } },
    deviceDeps: { keys: { read: () => key, write: v => { key = v; } } },
  });
  cleanups.push(() => withLocal.stop(true));
  expect(withLocal.port).not.toBeNull();
  expect(withLocal.hostname).toBe("127.0.0.1");
  const statusRes = await fetch(`http://127.0.0.1:${withLocal.port}/v1/status`, {
    headers: { Authorization: `Bearer ${ctx.config.token}` },
  });
  expect(statusRes.status).toBe(200);
  const statusBody = await statusRes.json() as { hub: { mode: string }; distill: { config_error: string | null } };
  expect(statusBody.hub.mode).toBe("server");
  expect(statusBody.distill.config_error).toContain("models.json");
});

test("server 模式禁用 CLI 提供方，无 models.json 时返回 config_error 且暂停整理，local 仍限 loopback", async () => {
  const ctx = setup();
  cleanups.push(() => ctx.cleanup());
  const env = { RA_HUB_MODE: "server", TZ: "Asia/Shanghai" };
  const host = "127.0.0.1:47823";
  const handler = createHandler({
    db: ctx.db, token: ctx.config.token, port: 47823, mode: "server", env,
    settings: {
      dataDir: ctx.dir, mode: "server", env,
      keychain: { has: async () => false, set: async () => {}, remove: async () => false },
    },
  });
  const call = async (method: string, path: string, body?: unknown) => {
    const res = await handler(new Request(`http://${host}${path}`, {
      method,
      headers: { host, authorization: `Bearer ${ctx.config.token}`, "content-type": "application/json" },
      ...(body === undefined ? {} : { body: JSON.stringify(body) }),
    }));
    return { status: res.status, body: await res.json() as any };
  };

  // 1. 没有 models.json 时不回退到 claude-cli，返回 config_error，providers 只剩两种 API。
  const initial = await call("GET", "/v1/settings/models");
  expect(initial.status).toBe(200);
  expect(initial.body.providers.map((p: { id: string }) => p.id)).toEqual(["anthropic", "openai-compatible"]);
  expect(initial.body.tiers).toBeNull();
  expect(initial.body.config_error).toContain("models.json");
  await expect(loadModelConfig(ctx.dir, { mode: "server" })).rejects.toThrow("models.json");

  // 2. PUT 和 test 拒绝 claude-cli / codex-cli，文案严格为“服务端中枢仅支持 API 模型”。
  const apiTier = { provider: "anthropic", model: "claude-sonnet-4-5" };
  for (const cliProvider of ["claude-cli", "codex-cli"]) {
    const putRes = await call("PUT", "/v1/settings/models", {
      tiers: { minute: { provider: cliProvider, model: "synthetic" }, hour: apiTier, day: apiTier },
    });
    expect(putRes.status).toBe(400);
    expect(putRes.body.error).toBe(SERVER_CLI_ERROR);

    const testRes = await call("POST", "/v1/settings/models/test", {
      tier: "minute", config: { provider: cliProvider, model: "synthetic" },
    });
    expect(testRes.status).toBe(400);
    expect(testRes.body.error).toBe(SERVER_CLI_ERROR);
  }

  // 3. models/local 仍拒绝非 loopback 地址。
  const nonLoopback = await call("POST", "/v1/settings/models/local", { base_url: "https://example.invalid/v1" });
  expect(nonLoopback.status).toBe(400);
  expect(nonLoopback.body.error).toContain("本机");

  // 4. createLLM 与 distill 在无 models.json 时返回 config_error、整理暂停，并在状态里写明原因。
  const llm = createLLM({ dataDir: ctx.dir, mode: "server", recordUsage: () => {} });
  const direct = await llm.complete({
    tier: "minute", system: "s", prompt: "p",
    schema: { type: "object", properties: { ok: { type: "boolean" } }, required: ["ok"] },
  });
  expect(direct.ok).toBe(false);
  if (!direct.ok) expect(direct.error).toBe("config_error");

  ctx.db.ingest([fixture({ source: "manual.note", capture: { method: "manual" }, body: "合成记录，验证整理暂停" })]);
  let llmCalls = 0;
  const checkModelConfig = () => {
    const r = inspectModelConfig(ctx.dir, { mode: "server" });
    return r.ok ? null : r.error;
  };
  const round = await distillRound({
    db: ctx.db,
    llm: { async complete() { llmCalls++; return { ok: false, error: "config_error", ms: 0 }; } },
    checkModelConfig,
  }, { slow: true, days: "all" });
  expect(round.stopped).toBe("config_error");
  expect(llmCalls).toBe(0);

  const tickState: LoopState = { lastRound: Date.now(), enabledDefault: Date.now() };
  expect(await distillTick({ db: ctx.db, llm, checkModelConfig }, tickState, Date.now())).toBe("idle");

  const statusBefore = hubStatus(ctx.db, { port: null, lanPort: 47824, mode: "server", env, dataDir: ctx.dir });
  expect(statusBefore.distill.config_error).toContain("models.json");
  expect(statusBefore.distill.paused_reason).toContain("models.json");

  // 5. 写入合法 API 模型后恢复正常。
  const saved = await call("PUT", "/v1/settings/models", {
    tiers: { minute: apiTier, hour: apiTier, day: { provider: "openai-compatible", model: "gpt-synthetic", base_url: "https://api.example.invalid/v1" } },
  });
  expect(saved.status).toBe(200);
  expect(saved.body.config_error).toBeNull();
  const statusAfter = hubStatus(ctx.db, { port: null, lanPort: 47824, mode: "server", env, dataDir: ctx.dir });
  expect(statusAfter.distill.config_error).toBeNull();
  expect(statusAfter.distill.paused_reason).toBeNull();
});

test("runSupervisor：转发 SIGTERM/SIGINT 并等待子进程退出，子进程崩溃按 1x/2x/4x 退避重启并设上限", async () => {
  // 1. 崩溃退避（注入子进程与时钟）
  const signals = new EventEmitter();
  const delays: number[] = [];
  let launches = 0;
  const active: { name: string; killed: NodeJS.Signals[]; resolve: (exit: SupervisedExit) => void }[] = [];
  const supervisor = runSupervisor({
    specs: [{ name: "serve", command: ["fake-serve"] }, { name: "distill", command: ["fake-distill"] }],
    initialBackoffMs: 20,
    maxBackoffMs: 50,
    stableMs: 10_000,
    signalTarget: signals as any,
    log: msg => {
      const m = /(\d+)ms 后重启/.exec(msg);
      if (m) delays.push(Number(m[1]));
    },
    spawn: (spec): SupervisedChild => {
      launches++;
      let resolveExit!: (exit: SupervisedExit) => void;
      const exited = new Promise<SupervisedExit>(r => { resolveExit = r; });
      const entry = { name: spec.name, killed: [] as NodeJS.Signals[], resolve: resolveExit };
      active.push(entry);
      if (spec.name === "distill" && launches <= 4) {
        // 前 3 次立即以非零退出码崩溃，验证 20 -> 40 -> 50（上限）退避
        queueMicrotask(() => resolveExit({ code: 1, signal: null }));
      }
      return {
        pid: 1000 + launches,
        kill(sig = "SIGTERM") {
          entry.killed.push(sig);
          resolveExit({ code: 0, signal: sig });
          return true;
        },
        exited,
      };
    },
  });

  // 等待 3 次退避重启完成、第 4 次 distill 已运行起来（20 + 40 + 50 = 110ms，留余量）
  const deadline = Date.now() + 2_000;
  while ((delays.length < 3 || active.filter(a => a.name === "distill").length < 4) && Date.now() < deadline) {
    await Bun.sleep(15);
  }
  expect(delays.slice(0, 3)).toEqual([20, 40, 50]);

  // 发送 SIGTERM，确认两个在跑的子进程都收到 SIGTERM 后 supervisor 才返回
  signals.emit("SIGTERM");
  await supervisor;
  const serveEntry = active.find(a => a.name === "serve")!;
  const lastDistill = active.filter(a => a.name === "distill").at(-1)!;
  expect(serveEntry.killed).toEqual(["SIGTERM"]);
  expect(lastDistill.killed).toEqual(["SIGTERM"]);

  // 2. SIGINT 同样转发并等待退出
  const signals2 = new EventEmitter();
  const received: NodeJS.Signals[] = [];
  const run2 = runSupervisor({
    specs: [{ name: "serve", command: ["fake-serve"] }],
    signalTarget: signals2 as any,
    log: () => {},
    spawn: (): SupervisedChild => {
      let resolveExit!: (exit: SupervisedExit) => void;
      const exited = new Promise<SupervisedExit>(r => { resolveExit = r; });
      return {
        pid: 2001,
        kill(sig = "SIGTERM") {
          received.push(sig);
          setTimeout(() => resolveExit({ code: 0, signal: sig }), 15);
          return true;
        },
        exited,
      };
    },
  });
  await Bun.sleep(10);
  signals2.emit("SIGINT");
  await run2;
  expect(received).toEqual(["SIGINT"]);
});

test.skipIf(bindDenied)("CLI pair --role admin 邀请 5 分钟有效，且另一个运行中的 serve 进程可直接完成配对并调用 status.get", async () => {
  const dir = makeTempDir();
  const { env } = sealedEnv(dir, { RA_LAN_PORT: "0", TZ: "Asia/Shanghai" });

  // 先启动 serve（server 模式）
  const child = Bun.spawn([process.execPath, cli, "serve"], { env, stdout: "pipe", stderr: "pipe" });
  cleanups.push(async () => { child.kill("SIGTERM"); await child.exited; });

  const reader = new Response(child.stdout).body!.getReader();
  let lanPort = 0;
  try {
    const chunk = await reader.read();
    const out = new TextDecoder().decode(chunk.value);
    const match = /设备端口 0\.0\.0\.0:(\d+)/.exec(out);
    expect(match).not.toBeNull();
    lanPort = Number(match![1]);
  } finally { reader.releaseLock(); }

  // 在另一个进程里执行 CLI pair --role admin
  const before = Date.now();
  const pairRes = spawnSync(process.execPath, [cli, "pair", "--role", "admin"], { env, encoding: "utf8" });
  const after = Date.now();
  expect(pairRes.status).toBe(0);
  const uri = pairRes.stdout.trim();
  expect(uri.startsWith("tacit://pair?d=")).toBe(true);
  const pairing = decodePairing(uri);
  expect(pairing.role).toBe("admin");
  const ttl = Date.parse(pairing.expires_at) - before;
  expect(ttl).toBeGreaterThanOrEqual(5 * 60_000 - 2_000);
  expect(Date.parse(pairing.expires_at) - after).toBeLessThanOrEqual(5 * 60_000 + 2_000);

  // 客户端经设备端口完成配对并调 status.get
  const client = await DeviceClient.fromInvite(pairing, `http://127.0.0.1:${lanPort}`);
  const paired = await client.pair(pairing, "mac");
  expect(paired.status).toBe(200);
  expect(client.device).toMatch(/^mac-/);

  const status = await client.send<{ hub: { mode: string }; timezone: { current: string; warning: string | null } }>("status.get", {});
  expect(status.status).toBe(200);
  expect(status.body.hub.mode).toBe("server");
  expect(status.body.timezone.warning).toBeNull();

  // 同一邀请不能复用第二次
  const second = await DeviceClient.fromInvite(pairing, `http://127.0.0.1:${lanPort}`);
  expect((await second.pair(pairing, "mac")).status).toBe(403);
});

test("时区校验与 UTC 告警：hub.json timezone 校验、状态接口提示、启动 stderr 告警", async () => {
  const dir = makeTempDir();
  expect(isValidTimeZone("Asia/Shanghai")).toBe(true);
  expect(isValidTimeZone("UTC")).toBe(true);
  expect(isValidTimeZone("+08:00")).toBe(false);
  expect(isValidTimeZone("Invalid/Zone")).toBe(false);
  expect(isValidTimeZone("")).toBe(false);

  // 未设置且进程时区为 UTC -> server 模式告警，mac 模式不告警
  const utcWarn = timezoneStatus({ env: { RA_HUB_MODE: "server" }, dataDir: dir, mode: "server", processTimezone: "UTC" });
  expect(utcWarn).toEqual({ current: "UTC", configured: null, source: "unset", warning: UTC_TIMEZONE_WARNING });
  expect(timezoneStatus({ env: {}, dataDir: dir, mode: "mac", processTimezone: "UTC" }).warning).toBeNull();

  // 显式设 TZ=UTC 时不再告警
  expect(timezoneStatus({ env: { TZ: "UTC", RA_HUB_MODE: "server" }, dataDir: dir, mode: "server", processTimezone: "UTC" }).warning).toBeNull();

  // hub.json 配合法 timezone 时 applyTimezone 生效且不告警
  writeFileSync(join(dir, "hub.json"), JSON.stringify({ timezone: "Asia/Shanghai" }));
  expect(resolveTimezone({}, dir)).toEqual({ timezone: "Asia/Shanghai", source: "file" });
  const envCopy: NodeJS.ProcessEnv = {};
  applyTimezone(envCopy, dir);
  expect(envCopy.TZ).toBe("Asia/Shanghai");
  expect(timezoneStatus({ env: { RA_HUB_MODE: "server" }, dataDir: dir, mode: "server", processTimezone: "UTC" }).warning).toBeNull();

  // hub.json 配非法 timezone 时报错
  writeFileSync(join(dir, "hub.json"), JSON.stringify({ timezone: "Mars/Olympus" }));
  expect(() => resolveTimezone({}, dir)).toThrow("IANA");

  // 状态接口里的 UTC 告警
  const ctx = setup();
  cleanups.push(() => ctx.cleanup());
  const st = hubStatus(ctx.db, { port: null, lanPort: 47824, mode: "server", env: { RA_HUB_MODE: "server" }, dataDir: ctx.dir, processTimezone: "Etc/UTC" });
  expect(st.timezone.warning).toBe(UTC_TIMEZONE_WARNING);

  // 真实 serve 子进程：未配置时区（TZ="" 在 POSIX 下对应 UTC）时向 stderr 打一行告警
  if (!bindDenied) {
    const dir2 = makeTempDir();
    const { env } = sealedEnv(dir2, { RA_LAN_PORT: "0", TZ: "" });
    const child = Bun.spawn([process.execPath, cli, "serve"], { env, stdout: "pipe", stderr: "pipe" });
    cleanups.push(async () => { child.kill("SIGTERM"); await child.exited; });
    const outReader = new Response(child.stdout).body!.getReader();
    try { await outReader.read(); } finally { outReader.releaseLock(); }
    child.kill("SIGTERM");
    await child.exited;
    const errText = await new Response(child.stderr).text();
    expect(errText).toContain(UTC_TIMEZONE_WARNING);
  }
});

test("keys import-db-key：从 stdin 导入原 db-key，校验现有库，绝不打印密钥且不覆盖不同密钥", () => {
  const dir = makeTempDir();
  const { dataDir, env } = sealedEnv(dir, { TZ: "Asia/Shanghai" });
  const keyHex = randomBytes(32).toString("hex");
  const otherHex = randomBytes(32).toString("hex");

  // 先用 keyHex 建一个真实的加密 history.db（模拟从旧 Mac 拷过来）
  const dbPath = join(dataDir, "history.db");
  const { mkdirSync } = require("node:fs");
  mkdirSync(dataDir, { recursive: true, mode: 0o700 });
  new HubDB(dbPath, keyHex).close();

  // 错误密钥拒绝导入
  const bad = spawnSync(process.execPath, [cli, "keys", "import-db-key"], { env, input: otherHex + "\n", encoding: "utf8" });
  expect(bad.status).toBe(1);
  expect(bad.stdout + bad.stderr).not.toContain(otherHex);
  expect(bad.stderr).toContain("无法打开现有 history.db");

  // 正确密钥导入成功，且不打印密钥
  const ok = spawnSync(process.execPath, [cli, "keys", "import-db-key"], { env, input: keyHex + "\n", encoding: "utf8" });
  expect(ok.status).toBe(0);
  expect(ok.stdout + ok.stderr).not.toContain(keyHex);
  expect(openSecretStore({ env, dataDir }).read("db-key")).toBe(keyHex);

  // 重复导入同一密钥幂等成功；导入不同密钥被拒绝
  expect(importDbKey(keyHex, { env, dataDir }).status).toBe("unchanged");
  expect(() => importDbKey(otherHex, { env, dataDir: makeTempDir(), store: openSecretStore({ env, dataDir }) })).toThrow("已有不同的数据库密钥");
});
