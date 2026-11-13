import { afterEach, beforeEach, expect, test } from "bun:test";
import { existsSync, mkdirSync, readFileSync, readdirSync, symlinkSync, writeFileSync } from "node:fs";
import { join, resolve } from "node:path";
import { PluginManager, type PluginManifest } from "../src/plugin-manager.ts";
import { runPlugin } from "../src/run-plugin.ts";
import { startServer } from "../src/server.ts";
import { fixture, setup } from "./helpers.ts";

let ctx: ReturnType<typeof setup>, manager: PluginManager, source: string;
const manifest: PluginManifest = { schema: 1, id: "ext-example", name: "合成来源", version: "1.0", description: "仅读取合成测试文件", entry: "main.ts", permissions: ["合成目录"], config: [
  { key: "directory", label: "文件夹", type: "string", required: true }, { key: "enabled_detail", label: "详细", type: "boolean", default: false }, { key: "limit", label: "数量", type: "number", default: 10 },
] };
function saveManifest(m = manifest) { writeFileSync(join(source, "plugin.json"), JSON.stringify(m)); }
beforeEach(() => {
  ctx = setup(); manager = new PluginManager(ctx.dir); source = join(ctx.dir, "source"); mkdirSync(source);
  saveManifest(); writeFileSync(join(source, "main.ts"), 'console.log(JSON.stringify({type:"checkpoint",state:{offset:1}}));');
});
afterEach(() => ctx.cleanup());

test("安装必须先预览；配置校验失败保留预览，不运行代码，复制的快照不受来源修改影响", async () => {
  writeFileSync(join(source, "main.ts"), `require('node:fs').writeFileSync(${JSON.stringify(join(ctx.dir, "executed"))},'bad');`);
  const p = await manager.prepare(source);
  expect(existsSync(join(ctx.dir, "executed"))).toBe(false);
  expect(manager.list()).toEqual([]);
  expect(() => manager.install(p.ticket, {})).toThrow("请填写文件夹");
  writeFileSync(join(source, "main.ts"), "throw new Error('changed')");
  const installed = manager.install(p.ticket, { directory: "/synthetic" });
  expect(installed.values).toEqual({ directory: "/synthetic", enabled_detail: false, limit: 10 });
  expect(manager.list()).toEqual([installed]);
  expect(readFileSync(join(manager.path(installed.manifest.id), "code/main.ts"), "utf8")).not.toContain("changed");
  expect(existsSync(join(ctx.dir, "executed"))).toBe(false);
  await expect(manager.prepare(source)).rejects.toThrow("已安装");
});

test("更新保留配置和游标；取消不改变已安装版本；权限变化需要新预览", async () => {
  const p = await manager.prepare(source); manager.install(p.ticket, { directory: "/synthetic", limit: 42 });
  const state = join(ctx.dir, "plugins/ext-example"); mkdirSync(state, { recursive: true }); writeFileSync(join(state, "state.json"), '{"offset":9}');
  saveManifest({ ...manifest, version: "2.0", permissions: ["新增读取范围"] });
  const update = await manager.prepare(source, manifest.id);
  expect(update.values.limit).toBe(42); expect(update.manifest.permissions).toEqual(["新增读取范围"]);
  await manager.dispatch({ action: "discard", ticket: update.ticket });
  expect(manager.installed(manifest.id).manifest.version).toBe("1.0");
  const next = await manager.prepare(source, manifest.id); manager.install(next.ticket, next.values);
  expect(manager.installed(manifest.id).manifest.version).toBe("2.0");
  expect(readFileSync(join(state, "state.json"), "utf8")).toBe('{"offset":9}');
  expect(readdirSync(manager.root).some(n => n.startsWith("."))).toBe(false);
  saveManifest({ ...manifest, version: "3.0", config: [...manifest.config.filter(f => f.key !== "limit"), { key: "limit", label: "数量", type: "string", default: "all" }] });
  const changedType = await manager.prepare(source, manifest.id);
  expect(changedType.values.limit).toBe("all");
  expect(changedType.values.directory).toBe("/synthetic");
  await manager.dispatch({ action: "discard", ticket: changedType.ticket });
});

test("拒绝路径逃逸、链接、内置 id、非法配置和预览被篡改", async () => {
  for (const m of [{ ...manifest, id: "browser" }, { ...manifest, entry: "../source/main.ts" }]) {
    saveManifest(m); await expect(manager.prepare(source)).rejects.toThrow();
  }
  saveManifest(); symlinkSync(join(source, "main.ts"), join(source, "link.ts"));
  await expect(manager.prepare(source)).rejects.toThrow("符号链接");
  const { unlinkSync } = await import("node:fs"); unlinkSync(join(source, "link.ts"));
  const p = await manager.prepare(source);
  expect(() => manager.install(p.ticket, { directory: "x", limit: "bad" })).toThrow("值不正确");
  expect(() => manager.install(p.ticket, { directory: "sk-" + "x".repeat(28) })).toThrow("密钥");
  writeFileSync(join(manager.stage(p.ticket), "code/main.ts"), "changed");
  expect(() => manager.install(p.ticket, { directory: "x" })).toThrow("发生变化");
  expect(manager.list()).toEqual([]);
});

test("第三方记录必须属于自身来源，黑名单不入库，密钥过滤后入库，合法输出推进游标", async () => {
  const normal = fixture({ source: "plugin.ext_example", source_ref: "one", body: "synthetic sk-" + "x".repeat(28) });
  const blocked = fixture({ source: normal.source, source_ref: "two", context: { app: "com.apple.Passwords" } });
  const privateWindow = fixture({ source: normal.source, source_ref: "three", context: { window: "Chrome Incognito" } });
  const code = join(source, "main.ts");
  const lines = [{ type: "record", record: normal }, { type: "record", record: blocked }, { type: "record", record: privateWindow }, { type: "checkpoint", state: { offset: 3 } }];
  writeFileSync(code, `for(const line of ${JSON.stringify(lines)}) console.log(JSON.stringify(line));`);
  const result = await runPlugin({ db: ctx.db, name: manifest.id, dataDir: ctx.dir, command: [process.execPath, code], allowedSource: normal.source });
  expect(result).toMatchObject({ accepted: 1, filtered: 2, rejected: 0, stateWritten: true });
  expect(ctx.db.get(normal.id)?.body).toContain("已脱敏"); expect(ctx.db.get(blocked.id)).toBeNull(); expect(ctx.db.get(privateWindow.id)).toBeNull();
  const forged = fixture({ source: "mac.shell", source_ref: "forged" });
  writeFileSync(code, `console.log(JSON.stringify(${JSON.stringify({ type: "record", record: forged })}));console.log(JSON.stringify({type:'checkpoint',state:{offset:4}}));`);
  const invalid = await runPlugin({ db: ctx.db, name: manifest.id, dataDir: ctx.dir, command: [process.execPath, code], allowedSource: normal.source });
  expect(invalid).toMatchObject({ rejected: 1, stateWritten: false }); expect(ctx.db.get(forged.id)).toBeNull();
});

test("卸载保留/真删两条链路走真实 HTTP，删除不碰其他来源且墓碑阻止重新导入", async () => {
  const p = await manager.prepare(source); manager.install(p.ticket, { directory: "/synthetic" });
  const a = fixture({ source: "plugin.ext_example", source_ref: "one" }), b = fixture();
  expect(ctx.db.ingest([a, b]).accepted).toBe(2);
  await manager.uninstall(manifest.id, false);
  expect(ctx.db.get(a.id)).not.toBeNull(); expect(manager.list()).toEqual([]);
  const second = await manager.prepare(source); manager.install(second.ticket, { directory: "/synthetic" });
  const server = startServer({ db: ctx.db, token: ctx.config.token, port: 0 });
  try {
    expect(await manager.uninstall(manifest.id, true, `http://127.0.0.1:${server.port}`)).toEqual({ deleted: 1 });
    expect(ctx.db.get(a.id)).toBeNull(); expect(ctx.db.get(b.id)).not.toBeNull();
    expect(ctx.db.db.prepare("SELECT id FROM tombstones WHERE id=?").get(a.id)).toBeTruthy();
    expect(ctx.db.ingest([a]).duplicates).toBe(1);
  } finally { await server.stop(true); }
});

test("删除服务失败时保留插件以供重试", async () => {
  const p = await manager.prepare(source); manager.install(p.ticket, { directory: "/synthetic" });
  const server = Bun.serve({ port: 0, hostname: "127.0.0.1", fetch: () => Response.json({}, { status: 503 }) });
  try {
    await expect(manager.uninstall(manifest.id, true, `http://127.0.0.1:${server.port}`)).rejects.toThrow("删除未完成");
    expect(manager.list()).toHaveLength(1);
  } finally { await server.stop(true); }
});

// 回归：采集端暂停/停用 runner 后，插件子进程以前仍会存活并继续读取。
test("停止 runner 会终止忽略 SIGTERM 的插件，不提交中断游标", async () => {
  const childFile = join(source, "wait.ts"), pidFile = join(ctx.dir, "child.pid"), runnerFile = join(ctx.dir, "runner.ts");
  writeFileSync(childFile, `import {writeFileSync} from 'node:fs';
process.on('SIGTERM',()=>{});
console.log(JSON.stringify({type:'checkpoint',state:{shouldNotCommit:true}}));
writeFileSync(${JSON.stringify(pidFile)},String(process.pid));
setInterval(()=>{},100);`);
  writeFileSync(runnerFile, `import { runPlugin } from ${JSON.stringify(resolve(import.meta.dir, "../src/run-plugin.ts"))};
import { HubDB } from ${JSON.stringify(resolve(import.meta.dir, "../src/db.ts"))};
const db=new HubDB(${JSON.stringify(ctx.file)},${JSON.stringify(ctx.config.dbKey)});
try { console.log(JSON.stringify(await runPlugin({db,name:'ext-example',dataDir:${JSON.stringify(ctx.dir)},command:[process.execPath,${JSON.stringify(childFile)}]}))); } finally {db.close()}`);
  const p = Bun.spawn([process.execPath, runnerFile], { stdout: "pipe", stderr: "pipe" });
  let pid: number | undefined;
  try {
    const deadline = Date.now() + 4000;
    while (!existsSync(pidFile) && Date.now() < deadline) await Bun.sleep(25);
    expect(existsSync(pidFile)).toBe(true); pid = Number(readFileSync(pidFile, "utf8"));
    p.kill("SIGTERM");
    await p.exited;
    const output = JSON.parse(await new Response(p.stdout).text());
    expect(output).toMatchObject({ exitCode: 143, stateWritten: false });
    expect(existsSync(join(ctx.dir, "plugins/ext-example/state.json"))).toBe(false);
    expect(() => process.kill(pid!, 0)).toThrow();
  } finally {
    p.kill("SIGKILL");
    if (pid) { try { process.kill(pid, "SIGKILL"); } catch {} }
  }
}, 10_000);
