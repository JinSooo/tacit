import { expect, test } from "bun:test";
import { readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import { setup, fixture } from "./helpers.ts";

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
