import { afterEach, beforeEach, expect, test, spyOn } from "bun:test";
import { existsSync, readFileSync, readdirSync, writeFileSync, mkdirSync, symlinkSync } from "node:fs";
import { join } from "node:path";
import { runPlugin } from "../src/run-plugin.ts";
import { createHandler, startServer } from "../src/server.ts";
import { fixture, setup, networkDenied } from "./helpers.ts";

const bindDenied = await networkDenied();

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

function bufferFile() {
  mkdirSync(join(ctx.dir, "buffer"), { recursive: true });
  const file = join(ctx.dir, "buffer/shell.pending.jsonl");
  writeFileSync(file, "合成缓冲");
  return file;
}

test.skipIf(bindDenied)("HTTP 真实 hub 接收 500 条以内批次后保存 state 并清理 release", async () => {
  const file = bufferFile(), r = fixture();
  const server = startServer({ db: ctx.db, token: ctx.config.token, port: 0 });
  const sizes: number[] = [], ingest = ctx.db.ingest.bind(ctx.db);
  ctx.db.ingest = (batch) => { sizes.push(batch.length); return ingest(batch); };
  try {
    const result = await runPlugin({ hub: `http://127.0.0.1:${server.port}`, dataDir: ctx.dir, name: "fake",
      command: fakePlugin([...Array.from({ length: 501 }, () => ({ type: "record", record: r })), { ...checkpoint, release: [file] }]) });
    expect(sizes).toEqual([500, 1]);
    expect(result).toMatchObject({ accepted: 1, duplicates: 500, released: 1, releaseErrors: 0, stateWritten: true });
    expect(ctx.db.get(r.id)).not.toBeNull();
    expect(existsSync(file)).toBe(false);
    expect(JSON.parse(readFileSync(join(ctx.dir, "plugins/fake/state.json"), "utf8"))).toEqual(checkpoint.state);
  } finally { await server.stop(true); }
});

test.skipIf(bindDenied)("HTTP rejected、500、认证失败和异常响应均保留原 state 与 release", async () => {
  const file = bufferFile();
  await run(fakePlugin([checkpoint]));
  const state = join(ctx.dir, "plugins/fake/state.json"), old = readFileSync(state, "utf8");
  for (const mode of ["rejected", "500", "unauthorized", "malformed"]) {
    const ingest = ctx.db.ingest;
    if (mode === "500") ctx.db.ingest = () => { throw new Error("合成失败"); };
    const server = mode === "malformed" ? Bun.serve({ hostname: "127.0.0.1", port: 0, fetch: () => Response.json({}) })
      : startServer({ db: ctx.db, token: mode === "unauthorized" ? "other-token" : ctx.config.token, port: 0 });
    try {
      const result = await runPlugin({ hub: `http://127.0.0.1:${server.port}`, dataDir: ctx.dir, name: "fake",
        command: fakePlugin([{ type: "record", record: mode === "rejected" ? {} : fixture() }, { type: "checkpoint", state: { offset: 99 }, release: [file] }]) });
      expect(result.rejected).toBe(1); expect(result.stateWritten).toBe(false); expect(result.released).toBe(0);
      expect(existsSync(file)).toBe(true); expect(readFileSync(state, "utf8")).toBe(old);
    } finally { ctx.db.ingest = ingest; await server.stop(true); }
  }
});

test("release 拒绝外部路径、../、外部符号链接和目录；缺失文件忽略", async () => {
  const file = bufferFile(), outside = join(ctx.dir, "outside.jsonl"), link = join(ctx.dir, "buffer/link.jsonl");
  writeFileSync(outside, "合成外部数据"); symlinkSync(outside, link);
  const result = await run(fakePlugin([{ ...checkpoint, release: [file, outside, join(ctx.dir, "buffer/../outside.jsonl"), link, join(ctx.dir, "buffer"), join(ctx.dir, "buffer/missing")] }]));
  expect(result).toMatchObject({ stateWritten: true, released: 1, releaseErrors: 4, accepted: 0 });
  expect(existsSync(file)).toBe(false); expect(existsSync(outside)).toBe(true); expect(existsSync(link)).toBe(true);
});

test("插件非零退出及非法 release 协议不会清理缓冲", async () => {
  const file = bufferFile();
  for (const [release, exit] of [[[file], 2], [[42], 0]] as const) {
    const result = await run(fakePlugin([{ ...checkpoint, release }], exit));
    expect(result.stateWritten).toBe(false); expect(result.released).toBe(0); expect(existsSync(file)).toBe(true);
  }
});

test("HTTP 传输使用真实 handler，超时与连接失败均不提交 state 或 release", async () => {
  const file = bufferFile(), handler = createHandler({ db: ctx.db, token: ctx.config.token });
  const timeout = spyOn(AbortSignal, "timeout");
  const fetchMock = spyOn(globalThis, "fetch").mockImplementation((async (input, init) => handler(new Request(input as URL, init))) as typeof fetch);
  const runHTTP = (record = fixture()) => runPlugin({ hub: "http://127.0.0.1:47823", dataDir: ctx.dir, name: "fake",
    command: fakePlugin([{ type: "record", record }, { ...checkpoint, release: [file] }]) });
  try {
    const result = await runHTTP();
    expect(result).toMatchObject({ accepted: 1, stateWritten: true, released: 1 });
    expect(timeout).toHaveBeenCalledWith(30_000);
    const stateFile = join(ctx.dir, "plugins/fake/state.json"), old = readFileSync(stateFile, "utf8");
    writeFileSync(file, "合成重试缓冲");
    for (const mode of ["rejected", "500", "unauthorized", "malformed"]) {
      const ingest = ctx.db.ingest;
      if (mode === "500") ctx.db.ingest = () => { throw new Error("合成失败"); };
      fetchMock.mockImplementation((async (input, init) => {
        if (mode === "malformed") return Response.json({});
        const request = new Request(input as URL, init);
        if (mode === "unauthorized") request.headers.set("authorization", "Bearer wrong");
        return handler(request);
      }) as typeof fetch);
      try {
        const failed = await runHTTP(mode === "rejected" ? {} as ReturnType<typeof fixture> : fixture());
        expect(failed).toMatchObject({ rejected: 1, stateWritten: false, released: 0 });
        expect(readFileSync(stateFile, "utf8")).toBe(old); expect(existsSync(file)).toBe(true);
      } finally { ctx.db.ingest = ingest; }
    }
    for (const error of [new DOMException("合成超时", "TimeoutError"), new Error("合成连接失败")]) {
      fetchMock.mockImplementation(Object.assign(async (): Promise<Response> => { throw error; }, { preconnect: fetch.preconnect }));
      const failed = await runHTTP();
      expect(failed).toMatchObject({ rejected: 1, stateWritten: false, released: 0 });
      expect(readFileSync(stateFile, "utf8")).toBe(old); expect(existsSync(file)).toBe(true);
    }
  } finally { fetchMock.mockRestore(); timeout.mockRestore(); }
});

test("state 原子写入失败时保留 release 且清理临时 state", async () => {
  const file = bufferFile();
  const dir = join(ctx.dir, "plugins/fake");
  mkdirSync(join(dir, "state.json"), { recursive: true });
  await expect(run(fakePlugin([{ ...checkpoint, release: [file] }]))).rejects.toThrow();
  expect(existsSync(file)).toBe(true); expect(readdirSync(dir)).toEqual(["state.json"]);
});

test("buffer 目录不存在时仍拒绝删除外部现存文件", async () => {
  const file = join(ctx.dir, "outside.jsonl"); writeFileSync(file, "合成外部数据");
  const result = await run(fakePlugin([{ ...checkpoint, release: [file] }]));
  expect(result).toMatchObject({ stateWritten: true, releaseErrors: 1, released: 0 });
  expect(existsSync(file)).toBe(true);
});
