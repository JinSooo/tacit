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
