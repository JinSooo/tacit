import { afterEach, beforeEach, expect, test } from "bun:test";
import { mkdtempSync, mkdirSync, readFileSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { tmpdir, homedir } from "node:os";
import { join } from "node:path";
import { spawnSync } from "node:child_process";
import { pluginReadAccess, sandboxLaunch, validatePluginAccess } from "../src/plugin-sandbox.ts";
import { PluginManager } from "../src/plugin-manager.ts";
import { runPlugin } from "../src/run-plugin.ts";
import { fixture, setup } from "./helpers.ts";

let root: string, data: string, code: string, state: string, allowed: string, outside: string;
beforeEach(() => {
  root = mkdtempSync(join(tmpdir(), "ra-sandbox-test-")); data = join(root, "data"); code = join(data, "extensions/ext-example/code");
  mkdirSync(code, { recursive: true }); mkdirSync(join(data, "plugins/ext-example"), { recursive: true });
  state = join(data, "plugins/ext-example/state.json"); writeFileSync(state, '{"offset":1}');
  allowed = join(root, "allowed.txt"); outside = join(root, "outside.txt");
  writeFileSync(allowed, "allowed synthetic input"); writeFileSync(outside, "outside synthetic input"); writeFileSync(join(data, "token"), "synthetic-token-only");
});
afterEach(() => rmSync(root, { recursive: true, force: true }));
const manifest = { config: [{ key: "path", label: "文件", type: "string" }], access: { readFiles: ["path"] } };
function execute(source: string, extra?: string[], isolated = true) {
  const entry = join(code, "main.ts"); writeFileSync(entry, source);
  const launch = sandboxLaunch({ sandbox: { code, manifest, values: { path: allowed } }, dataDir: data, stateFile: state,
    command: [process.execPath, "--no-install", "--no-env-file", entry, ...(extra ?? [])] });
  const command = isolated ? launch.command : [process.execPath, entry, ...(extra ?? [])];
  const r = spawnSync(command[0]!, command.slice(1), { cwd: launch.cwd, env: launch.env, encoding: "utf8", timeout: 5000 });
  expect({status:r.status,stderr:r.stderr}).toEqual({status:0,stderr:""}); return JSON.parse(r.stdout);
}

test("access 仅引用文本配置，未知能力和重复授权均拒绝", () => {
  expect(() => validatePluginAccess(manifest)).not.toThrow();
  for (const access of [{ network: true }, { readFiles: ["missing"] }, { readFiles: ["path", "path"] }, { readFiles: "path" }])
    expect(() => validatePluginAccess({ config: manifest.config, access: access as any })).toThrow();
});

test("文件和目录授权解析真实路径，不能扩大到凭据或 Tacit 数据", () => {
  expect(pluginReadAccess(manifest, { path: allowed }, data).files).toEqual([require("node:fs").realpathSync(allowed)]);
  for (const path of [join(data, "token"), "/relative-is-abs-but-missing", "relative"])
    expect(() => pluginReadAccess(manifest, { path }, data)).toThrow();
  symlinkSync(join(data, "token"), join(root, "link"));
  expect(() => pluginReadAccess(manifest, { path: join(root, "link") }, data)).toThrow("不能授权");
  for (const path of [root, homedir(), "/"])
    expect(() => pluginReadAccess({ ...manifest, access: { readDirectories: ["path"] } }, { path }, data)).toThrow("不能授权");
});

test.skipIf(process.platform !== "darwin")("真实隔离：允许指定文件/代码/游标，拒绝越界读取、写入、子进程和钥匙串工具", () => {
  const result = execute(`
    import {readFileSync,writeFileSync} from 'node:fs';
    import {spawnSync} from 'node:child_process';
    const read = p => {try{return readFileSync(p,'utf8')}catch{return null}};
    const write = p => {try{writeFileSync(p,'modified');return true}catch{return false}};
    const child = spawnSync('/bin/echo',['unexpected']);
    const security = spawnSync('/usr/bin/security',['help']);
    console.log(JSON.stringify({allowed:read(${JSON.stringify(allowed)}), own:read(import.meta.path)!==null,
      state:read(${JSON.stringify(state)}), outside:read(${JSON.stringify(outside)}), token:read(${JSON.stringify(join(data, "token"))}),
      overwrite:write(${JSON.stringify(allowed)}), modifyCode:write(import.meta.path), modifyState:write(${JSON.stringify(state)}),
      child:child.status, security:security.status, env:process.env.RA_DATA_DIR??null}));`);
  expect(result).toEqual({ allowed: "allowed synthetic input", own: true, state: '{"offset":1}', outside: null, token: null,
    overwrite: false, modifyCode: false, modifyState: false, child: null, security: null, env: null });
  expect(readFileSync(allowed, "utf8")).toBe("allowed synthetic input");
});

test.skipIf(process.platform !== "darwin")("真实隔离：局域网/localhost 网络不能绕过 runner 访问管理端口", () => {
  // 一个真实的监听 socket；使用同步探针不需要父事件循环处理请求，connect 必须先被内核拒绝。
  const server = Bun.serve({ port: 0, hostname: "127.0.0.1", fetch: () => new Response("must not reach") });
  try {
    const source = `import net from 'node:net';
      const s=net.connect({port:${server.port},host:'127.0.0.1'});
      s.on('connect',()=>{console.log(JSON.stringify({connected:true}));s.destroy()});
      s.on('error',e=>console.log(JSON.stringify({connected:false,code:e.code})));
      setTimeout(()=>{s.destroy();process.exit(2)},2000).unref();`;
    expect(execute(source, [], false)).toEqual({connected:true});
    const result = execute(source);
    expect(result.connected).toBe(false); expect(["EPERM", "EACCES", "ECONNREFUSED"]).toContain(result.code);
  } finally { server.stop(true); }
});

test.skipIf(process.platform !== "darwin")("真实 runner：隔离后产出正常记录，游标只由 runner 在成功入库后写入", async () => {
  const ctx = setup();
  try {
    const ownCode = join(ctx.dir, "extensions/ext-example/code"); mkdirSync(ownCode, { recursive: true });
    const record = fixture({ source: "plugin.ext_example", source_ref: "sandbox-fixture" });
    const entry = join(ownCode, "main.ts");
    writeFileSync(entry, `console.log(JSON.stringify({type:'record',record:${JSON.stringify(record)}}));console.log(JSON.stringify({type:'checkpoint',state:{offset:7}}));`);
    const result = await runPlugin({ db: ctx.db, dataDir: ctx.dir, name: "ext-example", command: [process.execPath, "--no-install", "--no-env-file", entry],
      allowedSource: record.source, sandbox: { code: ownCode, manifest: { config: [] }, values: {} } });
    expect(result).toMatchObject({ exitCode: 0, accepted: 1, stateWritten: true });
    expect(ctx.db.get(record.id)?.body).toBe(record.body);
    expect(JSON.parse(readFileSync(join(ctx.dir, "plugins/ext-example/state.json"), "utf8"))).toEqual({ offset: 7 });
  } finally { ctx.cleanup(); }
});

test("安装和配置变更校验授权，旧自由文本权限不会变成任意读取", async () => {
  const source = join(root, "source"); mkdirSync(source); writeFileSync(join(source, "main.ts"), "console.log('')");
  writeFileSync(join(source, "plugin.json"), JSON.stringify({ schema: 1, id: "ext-example", name: "合成", version: "1", description: "合成数据源", entry: "main.ts", permissions: ["读取任意文件"], ...manifest }));
  rmSync(join(data, "extensions/ext-example"), {recursive:true});
  const manager = new PluginManager(data), preview = await manager.prepare(source);
  manager.install(preview.ticket, { path: allowed });
  expect(() => manager.configure("ext-example", { path: join(data, "token") })).toThrow("不能授权");
  expect(manager.installed("ext-example").values.path).toBe(require("node:fs").realpathSync(allowed));
  expect(pluginReadAccess({ config: [], access: undefined }, {}, data).files).toEqual([]);
});

test.skipIf(process.platform !== "darwin")("目录授权读取子文件但不能跟随链接逃到未授权内容", () => {
  const folder = join(root, "inputs"); mkdirSync(folder); writeFileSync(join(folder, "one.txt"), "nested input");
  symlinkSync(outside, join(folder, "outside-link")); symlinkSync(join(data, "token"), join(folder, "token-link"));
  const entry = join(code, "main.ts");
  writeFileSync(entry, `import {readFileSync} from 'node:fs';const read=p=>{try{return readFileSync(p,'utf8')}catch{return null}};console.log(JSON.stringify(${JSON.stringify([join(folder,"one.txt"),join(folder,"outside-link"),join(folder,"token-link")])}.map(read)));`);
  const launch = sandboxLaunch({ sandbox: { code, manifest: { config: manifest.config, access: { readDirectories: ["path"] } }, values: {path:folder} }, dataDir:data, stateFile:state,
    command:[process.execPath,"--no-install","--no-env-file",entry] });
  const r=spawnSync(launch.command[0]!,launch.command.slice(1),{cwd:launch.cwd,env:launch.env,encoding:"utf8",timeout:5000});
  expect(r.status).toBe(0); expect(JSON.parse(r.stdout)).toEqual(["nested input",null,null]);
});

test.skipIf(process.platform !== "darwin")("第三方不能借 checkpoint.release 让 runner 删除其他来源的缓冲", async () => {
  const ctx=setup();
  try {
    const ownCode=join(ctx.dir,"extensions/ext-example/code");mkdirSync(ownCode,{recursive:true});
    mkdirSync(join(ctx.dir,"buffer"));const buffer=join(ctx.dir,"buffer/shell.jsonl");writeFileSync(buffer,"synthetic buffer");
    const entry=join(ownCode,"main.ts");writeFileSync(entry,`console.log(JSON.stringify({type:'checkpoint',state:{},release:[${JSON.stringify(buffer)}]}));`);
    const result=await runPlugin({db:ctx.db,dataDir:ctx.dir,name:"ext-example",command:[process.execPath,entry],sandbox:{code:ownCode,manifest:{config:[]},values:{}}});
    expect(result).toMatchObject({protocolErrors:1,stateWritten:false,released:0});
    expect(readFileSync(buffer,"utf8")).toBe("synthetic buffer");
  } finally {ctx.cleanup();}
});

test.skipIf(process.platform !== "darwin")("已安装 plugin-run 真实 CLI 经隔离读取并通过 HTTP 入库，重复运行保持幂等", async () => {
  const { startServer } = await import("../src/server.ts");
  const ctx=setup(); const server=startServer({db:ctx.db,token:ctx.config.token,port:0});
  try {
    const source=join(root,"cli-plugin");mkdirSync(source);
    const record=fixture({source:"plugin.ext_example",source_ref:"installed-sandbox"});
    writeFileSync(join(source,"plugin.json"),JSON.stringify({schema:1,id:"ext-example",name:"合成",version:"1",description:"合成插件",entry:"main.ts",permissions:["读取配置文件"],...manifest}));
    writeFileSync(join(source,"main.ts"),`import {readFileSync} from 'node:fs';
      const c=JSON.parse(process.env.RA_PLUGIN_CONFIG);if(readFileSync(c.path,'utf8')!=='allowed synthetic input')throw Error('allowed input missing');
      let denied=false;try{readFileSync(${JSON.stringify(outside)},'utf8')}catch{denied=true}if(!denied)throw Error('sandbox missing');
      console.log(JSON.stringify({type:'record',record:${JSON.stringify(record)}}));console.log(JSON.stringify({type:'checkpoint',state:{offset:1}}));`);
    const manager=new PluginManager(ctx.dir), p=await manager.prepare(source);manager.install(p.ticket,{path:allowed});
    for(const expected of [{accepted:1,duplicates:0},{accepted:0,duplicates:1}]) {
      const child=Bun.spawn([process.execPath,new URL('../src/cli.ts',import.meta.url).pathname,'plugin-run','ext-example','--hub',`http://127.0.0.1:${server.port}`],{env:{...process.env,RA_DATA_DIR:ctx.dir},stdout:'pipe',stderr:'pipe'});
      const [output,error,code]=await Promise.all([new Response(child.stdout).text(),new Response(child.stderr).text(),child.exited]);
      expect({code,error}).toEqual({code:0,error:""}); expect(JSON.parse(output)).toMatchObject({...expected,stateWritten:true,exitCode:0});
    }
  } finally {server.stop(true);ctx.cleanup();}
});
