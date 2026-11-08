import { afterEach, beforeEach, expect, test } from "bun:test";
import { existsSync, readFileSync, readdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { runPlugin } from "../src/run-plugin.ts";
import { fixture, setup } from "./helpers.ts";

let ctx: ReturnType<typeof setup>;
beforeEach(() => { ctx = setup(); });
afterEach(() => ctx.cleanup());
function fakePlugin(lines: unknown[], exitCode = 0): string[] {
  const file = join(ctx.dir, "fake-plugin.ts");
  writeFileSync(file, `const lines = ${JSON.stringify(lines)};
const args = process.argv.slice(2);
if (args[args.indexOf('--device') + 1] !== 'mac' || !args[args.indexOf('--state') + 1]?.endsWith('/plugins/fake/state.json')) process.exit(9);
for (const line of lines) console.log(JSON.stringify(line));
process.exit(${exitCode});\n`);
  return [process.execPath, file];
}
function run(command: string[]) { return runPlugin({ db: ctx.db, dataDir: ctx.dir, name: "fake", command }); }
const checkpoint = { type: "checkpoint", state: { offset: 42 } };

test("插件非零退出，已发记录保留但不创建或覆盖 state；重跑靠幂等恢复", async () => {
  const r = fixture({ source: "mac.shell", source_ref: "fake-event" });
  const lines = [{ type: "record", record: r }, checkpoint];
  const failed = await run(fakePlugin(lines, 2));
  const state = join(ctx.dir, "plugins/fake/state.json");
  expect(failed.accepted).toBe(1);
  expect(failed.exitCode).toBe(2);
  expect(existsSync(state)).toBe(false);
  expect(ctx.db.get(r.id)).not.toBeNull();
  const success = await run(fakePlugin(lines));
  expect(success.duplicates).toBe(1);
  expect(success.stateWritten).toBe(true);
  expect(JSON.parse(readFileSync(state, "utf8"))).toEqual({ offset: 42 });
  const oldState = readFileSync(state, "utf8");
  await run(fakePlugin([{ type: "checkpoint", state: { offset: 99 } }], 1));
  expect(readFileSync(state, "utf8")).toBe(oldState);
});

test("批次最大 500、所有成功后原子保存最后 checkpoint", async () => {
  const records = Array.from({ length: 1001 }, (_, i) => ({ type: "record", record: fixture({ source_ref: `synthetic-${i}` }) }));
  const sizes: number[] = [];
  const ingest = ctx.db.ingest.bind(ctx.db);
  ctx.db.ingest = (batch: unknown[]) => { sizes.push(batch.length); return ingest(batch); };
  const result = await run(fakePlugin([checkpoint, ...records, { type: "checkpoint", state: { offset: 1001 } }]));
  expect(sizes).toEqual([500, 500, 1]);
  expect(result.accepted).toBe(1001);
  expect(result.stateWritten).toBe(true);
  const dir = join(ctx.dir, "plugins/fake");
  expect(readdirSync(dir)).toEqual(["state.json"]);
  expect(JSON.parse(readFileSync(join(dir, "state.json"), "utf8"))).toEqual({ offset: 1001 });
});

test("拒绝记录或非法协议行阻止 checkpoint，合法记录仍入库", async () => {
  for (const line of [{ type: "record", record: { bad: true } }, { type: "unknown" }]) {
    const r = fixture();
    const result = await run(fakePlugin([{ type: "record", record: r }, line, checkpoint]));
    expect(result.accepted).toBe(1);
    expect(result.stateWritten).toBe(false);
    expect(existsSync(join(ctx.dir, "plugins/fake/state.json"))).toBe(false);
  }
});

test("存储失败不写 checkpoint，无 checkpoint 时不创建 state，启动失败可报告", async () => {
  const ingest = ctx.db.ingest;
  ctx.db.ingest = () => { throw new Error("合成存储失败"); };
  const failed = await run(fakePlugin([{ type: "record", record: fixture() }, checkpoint]));
  expect(failed.rejected).toBe(1);
  expect(failed.stateWritten).toBe(false);
  ctx.db.ingest = ingest;
  expect((await run(fakePlugin([{ type: "record", record: fixture() }]))).stateWritten).toBe(false);
  await expect(run([join(ctx.dir, "not-an-executable")])).rejects.toThrow();
  await expect(runPlugin({ db: ctx.db, dataDir: ctx.dir, name: "../outside", command: ["bad"] })).rejects.toThrow();
});
