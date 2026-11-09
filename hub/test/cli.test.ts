import { expect, test } from "bun:test";
import { readFileSync, writeFileSync, mkdirSync, existsSync } from "node:fs";
import { join } from "node:path";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import { startServer } from "../src/server.ts";
import { setup, fixture, networkDenied } from "./helpers.ts";

const bindDenied = await networkDenied();

const cli = fileURLToPath(new URL("../src/cli.ts", import.meta.url));
test("CLI run-plugin 真实子进程返回汇总、保存 state，错误命令非零退出", () => {
  const ctx = setup();
  try {
    const record = fixture();
    const plugin = join(ctx.dir, "cli-fake.ts");
    writeFileSync(plugin, `console.log(JSON.stringify({type:'record',record:${JSON.stringify(record)}}));
console.log(JSON.stringify({type:'checkpoint',state:{offset:1}}));`);
    const env = { ...process.env, RA_DATA_DIR: ctx.dir, RA_DB_KEY: ctx.config.dbKey };
    const result = spawnSync(process.execPath, [cli, "run-plugin", "fake", "--", process.execPath, plugin], { env, encoding: "utf8" });
    expect(result.status).toBe(0);
    const summary = JSON.parse(result.stdout);
    expect(summary).toMatchObject({ accepted: 1, duplicates: 0, rejected: 0, stateWritten: true });
    expect(JSON.parse(readFileSync(join(ctx.dir, "plugins/fake/state.json"), "utf8"))).toEqual({ offset: 1 });
    expect(ctx.db.get(record.id)?.body).toBe(record.body);
    const invalid = spawnSync(process.execPath, [cli, "not-a-command"], { env, encoding: "utf8" });
    expect(invalid.status).toBe(1);
  } finally { ctx.cleanup(); }
});

test.skipIf(bindDenied)("CLI HTTP 模式支持 token-file，不打开本地数据库或读取密钥；清理错误返回非零", async () => {
  const ctx = setup();
  let server: ReturnType<typeof startServer> | undefined;
  try {
    server = startServer({ db: ctx.db, token: ctx.config.token, port: 0 });
    const clientDir = join(ctx.dir, "client"); mkdirSync(clientDir);
    const plugin = join(ctx.dir, "http-fake.ts"), outside = join(ctx.dir, "outside");
    writeFileSync(outside, "合成数据");
    writeFileSync(plugin, `console.log(JSON.stringify({type:'record',record:${JSON.stringify(fixture())}}));
console.log(JSON.stringify({type:'checkpoint',state:{version:2},release:[${JSON.stringify(outside)}]}));`);
    const child = Bun.spawn([process.execPath, cli, "run-plugin", "fake", "--hub", `http://127.0.0.1:${server.port}`, "--token-file", join(ctx.dir, "token"), "--", process.execPath, plugin], {
      env: { ...process.env, RA_DATA_DIR: clientDir, RA_DB_KEY: "" }, stdout: "pipe", stderr: "pipe",
    });
    const output = await new Response(child.stdout).text();
    expect(await child.exited).toBe(1);
    expect(JSON.parse(output)).toMatchObject({ accepted: 1, stateWritten: true, releaseErrors: 1 });
    expect(existsSync(join(clientDir, "history.db"))).toBe(false); expect(existsSync(join(clientDir, "token"))).toBe(false);
    expect(existsSync(outside)).toBe(true);
  } finally { await server?.stop(true); ctx.cleanup(); }
});

test("CLI open --print 读取已有 token 和端口，不访问数据库密钥", () => {
  const ctx = setup();
  try {
    const env = { ...process.env, RA_DATA_DIR: ctx.dir, RA_PORT: "48901", RA_DB_KEY: "" };
    const result = spawnSync(process.execPath, [cli, "open", "--print"], { env, encoding: "utf8" });
    expect(result.status).toBe(0);
    expect(result.stdout.trim()).toBe(`http://127.0.0.1:48901/#token=${ctx.config.token}`);
    expect(result.stderr).toBe("");
  } finally { ctx.cleanup(); }
});

test("CLI 数据库迁移错误保留中文首行并输出真实 name/message，不输出堆栈或密钥", () => {
  const ctx = setup();
  try {
    // 合成的不完整 v2 结构让打开阶段产生可识别的迁移错误。
    ctx.db.db.exec("DROP TABLE agent_reads; PRAGMA user_version=2;");
    const result = spawnSync(process.execPath, [cli, "init"], { env: { ...process.env, RA_DATA_DIR: ctx.dir, RA_DB_KEY: ctx.config.dbKey }, encoding: "utf8" });
    expect(result.status).toBe(1);
    expect(result.stderr.split("\n")[0]).toBe("Hub 执行失败，请检查命令、数据目录、密钥及插件状态。");
    expect(result.stderr).toContain("SqliteError: duplicate column name: domain");
    expect(result.stderr).not.toContain(ctx.config.dbKey);
    expect(result.stderr).not.toContain("at ");
    expect(ctx.db.db.pragma("user_version", { simple: true })).toBe(2);
    expect(ctx.db.db.prepare("SELECT name FROM sqlite_master WHERE name='agent_reads'").get()).toBeUndefined();
  } finally { ctx.cleanup(); }
});

test("CLI 非数据库错误只打印 name/code，不打印可能夹带正文的 message", async () => {
  const { cliErrorDetail } = await import("../src/cli.ts");
  const error = Object.assign(new Error("合成记录正文 token=synthetic-sensitive-value"), { code: "EACCES" });
  expect(cliErrorDetail(error)).toBe("Error (EACCES)");
  expect(cliErrorDetail(new TypeError("合成正文"))).toBe("TypeError (UNKNOWN)");
  expect(cliErrorDetail("合成正文")).toBe("Error (UNKNOWN)");
  const ctx = setup();
  try {
    const result = spawnSync(process.execPath, [cli, "open", "--print"], { env: { ...process.env, RA_DATA_DIR: join(ctx.dir, "合成隐私路径"), RA_DB_KEY: "" }, encoding: "utf8" });
    expect(result.status).toBe(1);
    expect(result.stderr).toContain("Error (ENOENT)");
    expect(result.stderr).not.toContain("合成隐私路径");
  } finally { ctx.cleanup(); }
});

test("keys export 输出两个密钥的恢复命令，缺失或格式不对时不拼进命令", async () => {
  const { exportKeys } = await import("../src/keys.ts");
  const fake = "ab".repeat(32);
  const ok = exportKeys(() => ({ status: 0, value: fake }), new Date("2026-11-10T00:00:00Z"));
  expect(ok.missing).toEqual([]);
  expect(ok.text).toContain(`-a db-key -w '${fake}'`);
  expect(ok.text).toContain(`-a audio-key-hex -w '${fake}'`);
  const bad = exportKeys(account => account === "db-key" ? { status: 0, value: "x'; rm -rf ~" } : { status: 44, value: "" });
  expect(bad.missing).toEqual(["数据库", "音频"]);
  expect(bad.text).not.toContain("rm -rf");
  expect(bad.text).not.toContain("add-generic-password -U");
});
