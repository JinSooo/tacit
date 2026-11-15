/** 独立验收：--live-copy 在只读事务内复制正式加密库，所有迁移/删除/模拟调用只发生在副本。
 * 不把正式内容交给模型；网络调用仅访问本脚本启动的 127.0.0.1 合成模型。
 * bun scripts/runtime-log-smoke.ts --live-copy
 */
import { createRequire } from "node:module";
import { mkdtempSync, copyFileSync, chmodSync, readdirSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { spawnSync } from "node:child_process";
import assert from "node:assert/strict";
import { HubDB } from "../hub/src/db.ts";
import { dataDirOf } from "../hub/src/hub-json.ts";
import { RuntimeLog, contentRevision, appliedCall, expireSnapshots } from "../hub/src/runtime-log.ts";
import { createLLM } from "../hub/src/llm/index.ts";
import { createHandler } from "../hub/src/server.ts";
import { AgentReads } from "../hub/src/agent.ts";
import { ulid } from "../packages/record/index.ts";

const live = process.argv.includes("--live-copy");
if (process.argv.slice(2).some(a => a !== "--live-copy")) throw new Error("只接受 --live-copy");
const root = mkdtempSync(join(tmpdir(),"tacit-runtime-smoke-")); chmodSync(root,0o700);
const file = join(root,"history.db");
let key = "synthetic-runtime-smoke-key", originalCount = 0, originalVersion = 0;
let hub: HubDB | undefined, model: ReturnType<typeof Bun.serve> | undefined, server: ReturnType<typeof Bun.serve> | undefined;
try {
  if (live) {
    if (process.env.RA_DB_KEY) key = process.env.RA_DB_KEY;
    else {
      const found = spawnSync("/usr/bin/security",["find-generic-password","-s","record-anything","-a","db-key","-w"],{encoding:"utf8"});
      if (found.status !== 0 || !found.stdout.trim()) throw new Error("无法只读获取现有密钥");
      key = found.stdout.trim();
    }
    const Database = createRequire(import.meta.url)("better-sqlite3-multiple-ciphers");
    const original = new Database(join(dataDirOf(),"history.db"),{readonly:true,fileMustExist:true});
    try {
      original.pragma("cipher='sqlcipher'"); original.pragma("legacy=4"); original.pragma(`key='${key.replaceAll("'","''")}'`); original.pragma("busy_timeout=5000");
      assert.equal(original.pragma("journal_mode",{simple:true}),"delete");
      original.exec("BEGIN");
      originalCount = original.prepare("SELECT COUNT(*) n FROM records").get().n;
      originalVersion = original.pragma("user_version",{simple:true});
      // SELECT 已持有共享锁，复制期间写者不能提交主文件。
      copyFileSync(join(dataDirOf(),"history.db"),file); chmodSync(file,0o600);
      original.exec("COMMIT");
    } finally { original.close(); }
  }
  hub = new HubDB(file,key);
  assert.equal(hub.db.pragma("user_version",{simple:true}),11);
  assert.equal(hub.db.pragma("integrity_check",{simple:true}),"ok");
  assert.equal((hub.db.prepare("SELECT COUNT(*) n FROM records").get() as {n:number}).n,originalCount);
  assert.equal(readdirSync(root).filter(s=>s.includes("migration-v")).length,0);
  const sample = hub.db.prepare("SELECT id FROM records ORDER BY t_start_ms DESC,id DESC LIMIT 100").all() as {id:string}[];
  let pages = 0;
  for (const {id} of sample) {
    let cursor: string | null = null, text = "";
    do {
      const response: Response = await new AgentReads(hub).handle("get",new URLSearchParams({tool:"runtime-smoke",id,level:"detail",...(cursor ? {cursor} : {})}));
      assert.equal(response.status,200);
      const data = await response.json(); text += data.item.body; cursor = data.next_cursor; pages++;
    } while (cursor);
    assert.equal(text,hub.effective(id)!.body);
  }
  const id = ulid();
  const record = {id,schema:1,device:"synthetic",source:"manual.note",kind:"event",t_start:new Date().toISOString(),title:"合成验收",body:"仅用于隔离副本的合成验收",capture:{method:"manual"},sensitivity:"normal"};
  assert.equal(hub.ingest([record]).accepted,1);
  const journal = new RuntimeLog(hub);
  let resolveStarted!: () => void, release!: () => void;
  const started = new Promise<void>(r=>resolveStarted=r), gate = new Promise<void>(r=>release=r);
  model = Bun.serve({hostname:"127.0.0.1",port:0,async fetch() {
    resolveStarted(); await gate;
    return Response.json({choices:[{finish_reason:"stop",message:{content:'{"ok":true}'}}],usage:{prompt_tokens:21,completion_tokens:4}});
  }});
  const config = {provider:"openai-compatible" as const,model:"synthetic-runtime",base_url:`http://127.0.0.1:${model.port}`};
  const llm = createLLM({dataDir:root,journal,recordUsage:()=>{},configs:async()=>({minute:config,hour:config,day:config})});
  const pending = llm.complete({tier:"minute",task:"smoke",system:"合成测试",prompt:record.body,schema:{type:"object",required:["ok"]},contentRevision:contentRevision(hub)});
  await started;
  server = Bun.serve({hostname:"127.0.0.1",port:0,fetch:()=>new Response("initializing")});
  server.reload({fetch:createHandler({db:hub,token:"synthetic-admin",agentToken:"synthetic-agent",port:server.port,settings:{dataDir:root}})});
  const headers={Authorization:"Bearer synthetic-admin"};
  const contextId=ulid(); journal.context(contextId,"合成自动带入",[id],contentRevision(hub));
  const deleted = await fetch(`http://127.0.0.1:${server.port}/v1/records/${id}`,{method:"DELETE",headers});
  assert.equal(deleted.status,200); release();
  const result = await pending;
  assert.deepEqual([journal.detail(result.call_id!)!.request,journal.detail(result.call_id!)!.response],[null,null]);
  assert.equal(journal.detail(contextId)!.content_state,"deleted");
  assert.equal(hub.get(id),null);
  const old=ulid(); journal.begin(old,{tier:"minute",system:"合成",prompt:"合成",schema:{}},config);
  hub.db.prepare("UPDATE runtime_calls SET at_ms=? WHERE id=?").run(Date.now()-7*86400_000,old);
  expireSnapshots(hub); assert.equal(journal.detail(old)!.request,null);
  server.stop(true); server=undefined; model.stop(true);model=undefined;
  hub.close();hub = new HubDB(file,key);
  assert.equal(new RuntimeLog(hub).detail(contextId)!.request,null);
  assert.equal(hub.db.pragma("integrity_check",{simple:true}),"ok");
  console.log(JSON.stringify({mode:live?"encrypted-live-copy":"synthetic",source_version:originalVersion,version:11,records_preserved:originalCount,records_read:sample.length,record_pages:pages,migration:"passed",http_delete_and_late_response:"passed",retention:"passed",reopen:"passed",original_database:"untouched"}));
} finally {
  server?.stop(true); model?.stop(true); hub?.close(); rmSync(root,{recursive:true,force:true});
}
