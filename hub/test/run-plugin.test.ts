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

// 2026-11-12：AI 会话里带 U+2028 / U+2029 的 17 条记录被 readline 切断，导入全部历史时 117 个协议错误、state 不写。
test("记录正文含 U+2028 / U+2029 时按一行读入", async () => {
  const r = fixture({ body: `第一段${String.fromCharCode(0x2029)}第二段${String.fromCharCode(0x2028)}第三行` });
  const result = await run(fakePlugin([{ type: "record", record: r }, checkpoint]));
  expect(result.protocolErrors).toBe(0);
  expect(result.accepted).toBe(1);
  expect(result.stateWritten).toBe(true);
  expect(ctx.db.get(r.id)?.body).toBe(r.body);
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
  // 真实 fetch 会带 Host 头；直接 new Request 不会，hub 的 Host 校验会拒绝。
  const toRequest = (input: unknown, init?: RequestInit) => {
    const request = new Request(input as URL, init);
    request.headers.set("host", new URL(request.url).host);
    return request;
  };
  const fetchMock = spyOn(globalThis, "fetch").mockImplementation((async (input, init) => handler(toRequest(input, init))) as typeof fetch);
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
        const request = toRequest(input, init);
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

test.skipIf(bindDenied)("HTTP 中枢库忙返回 503 时退避重试，恢复后保存 state；一直忙则不保存", async () => {
  for (const busyTimes of [2, Infinity]) {
    let calls = 0, handler: ReturnType<typeof createHandler> | undefined;
    const server = Bun.serve({ hostname: "127.0.0.1", port: 0, fetch: (request) => ++calls <= busyTimes
      ? Response.json({ error: "数据库忙，稍后再试" }, { status: 503 }) : handler!(request) });
    handler = createHandler({ db: ctx.db, token: ctx.config.token, port: server.port });
    const r = fixture();
    try {
      const result = await runPlugin({ hub: `http://127.0.0.1:${server.port}`, dataDir: ctx.dir, name: "fake",
        command: fakePlugin([{ type: "record", record: r }, { type: "checkpoint", state: { busy: busyTimes } }]) });
      if (busyTimes === 2) {
        expect(calls).toBe(3); expect(result).toMatchObject({ accepted: 1, stateWritten: true });
        expect(ctx.db.get(r.id)).not.toBeNull();
      } else {
        expect(calls).toBe(6); expect(result.stateWritten).toBe(false); expect(ctx.db.get(r.id)).toBeNull();
        expect(JSON.parse(readFileSync(join(ctx.dir, "plugins/fake/state.json"), "utf8"))).toEqual({ busy: 2 });
      }
    } finally { await server.stop(true); }
  }
}, 15_000);


test("插件 stderr 持续排空，诊断只保留固定类别，不回显路径或正文", async () => {
  const file = join(ctx.dir, "diagnostic.ts");
  writeFileSync(file, `process.stderr.write("EACCES synthetic-secret " + "x".repeat(200000)); process.exitCode = 2;`);
  const result = await run([process.execPath, file]);
  expect(result.failure).toBe("permission");
  expect(JSON.stringify(result)).not.toContain("synthetic-secret");
  expect(result.stateWritten).toBe(false);
});
