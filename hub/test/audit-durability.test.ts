import { expect, test } from "bun:test";
import { readdirSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { HubDB } from "../src/db.ts";
import { createHandler } from "../src/server.ts";
import { setup, fixture } from "./helpers.ts";

test("真实子进程在写锁期间返回读取后退出，重开数据库仍能恢复加密审计且不重复", async () => {
  const ctx = setup(), original = fixture(); ctx.db.ingest([original]);
  const child = Bun.spawn([process.execPath, "-e", `
    import {HubDB} from './hub/src/db.ts'; import {AgentReads} from './hub/src/agent.ts';
    const db=new HubDB(process.env.PROBE_DB!,process.env.PROBE_KEY!);
    console.log('ready'); await Bun.stdin.text();
    const r=await new AgentReads(db).handle('timeline',new URLSearchParams({tool:'codex'}));
    console.log(JSON.stringify({status:r.status,hasRecord:(await r.text()).includes(process.env.PROBE_RECORD!)}));
    process.exit(0);
  `], { cwd: new URL("../../", import.meta.url).pathname, env: { ...process.env, PROBE_DB: ctx.file, PROBE_KEY: ctx.config.dbKey, PROBE_RECORD: original.id }, stdin: "pipe", stdout: "pipe", stderr: "pipe" });
  const reader = child.stdout.getReader();
  try {
    expect(new TextDecoder().decode((await reader.read()).value)).toContain("ready");
    ctx.db.db.exec("BEGIN IMMEDIATE"); child.stdin.write("go"); child.stdin.end();
    let output = "";
    for (;;) { const r = await reader.read(); if (r.done) break; output += new TextDecoder().decode(r.value); }
    expect(await child.exited).toBe(0);
    expect(JSON.parse(output)).toEqual({ status: 200, hasRecord: true });
    ctx.db.db.exec("ROLLBACK");
    const pending = `${ctx.file}.audit-pending`;
    const files = readdirSync(pending).filter(f => f.endsWith(".enc"));
    expect(files).toHaveLength(1);
    expect(readFileSync(join(pending, files[0]!)).includes(Buffer.from(original.id))).toBe(false);
    const recovered = new HubDB(ctx.file, ctx.config.dbKey);
    expect(recovered.db.prepare("SELECT COUNT(*) n FROM agent_reads").get()).toEqual({ n: 1 });
    recovered.close();
    const again = new HubDB(ctx.file, ctx.config.dbKey);
    expect(again.db.prepare("SELECT COUNT(*) n FROM agent_reads").get()).toEqual({ n: 1 }); again.close();
    expect(readdirSync(pending)).toEqual([]);
  } finally {
    child.kill(); if (ctx.db.db.inTransaction) ctx.db.db.exec("ROLLBACK"); ctx.cleanup();
  }
});

test("加密审计也不能写入时，不向 Agent 返回未经审计的内容", async () => {
  const ctx = setup(), r = fixture(); ctx.db.ingest([r]);
  try {
    writeFileSync(`${ctx.file}.audit-pending`, "synthetic blocking file");
    const handler = createHandler({ db: ctx.db, token: ctx.config.token });
    const response = await handler(new Request("http://127.0.0.1:47823/v1/agent/timeline?tool=codex", { headers: { host: "127.0.0.1:47823", authorization: `Bearer ${ctx.config.token}` } }));
    expect(response.status).toBe(500); expect(await response.text()).not.toContain(r.body);
  } finally { ctx.cleanup(); }
});
