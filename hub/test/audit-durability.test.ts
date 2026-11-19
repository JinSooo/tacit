import { expect, spyOn, test } from "bun:test";
import { createCipheriv, createHash, randomBytes } from "node:crypto";
import { readdirSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { HubDB } from "../src/db.ts";
import { createHandler } from "../src/server.ts";
import { AgentReads } from "../src/agent.ts";
import { setup, fixture } from "./helpers.ts";
import { ulid } from "../../packages/record/index.ts";

test("重开数据库时丢弃坏审计暂存，恢复真实子进程的加密暂存且不重复入库", async () => {
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
    writeFileSync(join(pending, `${ulid()}.enc`), Buffer.alloc(3));
    writeFileSync(join(pending, `${ulid()}.enc`), Buffer.alloc(100));
    const key = createHash("sha256").update("record-anything:agent-audit:v1\0").update(ctx.config.dbKey).digest();
    const iv = randomBytes(12), cipher = createCipheriv("aes-256-gcm", key, iv);
    const invalid = Buffer.concat([cipher.update("{synthetic-invalid-json"), cipher.final()]);
    writeFileSync(join(pending, `${ulid()}.enc`), Buffer.concat([iv, cipher.getAuthTag(), invalid]));
    const diagnostics = spyOn(console, "error").mockImplementation(() => {});
    try {
      for (let i = 0; i < 2; i++) {
        const recovered = new HubDB(ctx.file, ctx.config.dbKey);
        try { expect(recovered.db.prepare("SELECT COUNT(*) n FROM agent_reads").get()).toEqual({ n: 1 }); }
        finally { recovered.close(); }
      }
      expect(readdirSync(pending)).toEqual([]);
      expect(diagnostics.mock.calls.map(([line]) => JSON.parse(line))).toEqual([
        { location: "audit.restore", name: "Error", code: "audit_pending_corrupt", count: 3 },
      ]);
    } finally { diagnostics.mockRestore(); }
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

test("检索词横跨审计长度边界时，落盘前应先识别完整凭据", async () => {
  const ctx = setup(), reads = new AgentReads(ctx.db);
  try {
    const syntheticToken = "A1b2".repeat(6);
    const prefix = "测".repeat(180) + " Bearer ";
    const q = prefix + syntheticToken + " 额外搜索文字";
    expect((await reads.handle("search", new URLSearchParams({ tool: "codex", q }))).status).toBe(200);
    const args = reads.audit(new URLSearchParams()).reads[0]!.args;
    expect(args).toEqual({ q_length: q.length, q: prefix + "[已脱敏:Bearer]" });
  } finally { ctx.cleanup(); }
});

test("审计接口到期即隐藏检索词，保留参数和未到期的检索词", async () => {
  const ctx = setup(), reads = new AgentReads(ctx.db);
  try {
    for (const tool of ["old", "fresh"]) {
      const query = new URLSearchParams({ tool, q: "合成检索", session: "synthetic-session" });
      expect((await reads.handle("search", query)).status).toBe(200);
    }
    const now = Date.now();
    ctx.db.db.prepare("UPDATE agent_reads SET at=? WHERE tool='old'")
      .run(new Date(now - 7 * 86_400_000).toISOString());
    const time = spyOn(Date, "now").mockReturnValue(now);
    try {
      const handler = createHandler({ db: ctx.db, token: ctx.config.token });
      const response = await handler(new Request("http://127.0.0.1:47823/v1/audit", {
        headers: { host: "127.0.0.1:47823", authorization: `Bearer ${ctx.config.token}` },
      }));
      expect(response.status).toBe(200);
      const audit = (await response.json()).reads;
      expect(audit.find((row: { tool: string }) => row.tool === "old").args)
        .toEqual({ q_length: 4, session: "synthetic-session" });
      expect(audit.find((row: { tool: string }) => row.tool === "fresh").args)
        .toEqual({ q_length: 4, session: "synthetic-session", q: "合成检索" });
    } finally { time.mockRestore(); }
  } finally { ctx.cleanup(); }
});

test("另一个后台连接重放已缓存的待写审计时，不恢复真删前的检索词", async () => {
  const ctx = setup(), r = fixture(); ctx.db.ingest([r]);
  const output = spyOn(console, "error").mockImplementation(() => {});
  let other: HubDB | undefined;
  try {
    ctx.db.db.exec("CREATE TRIGGER reject_audit BEFORE INSERT ON agent_reads BEGIN SELECT RAISE(ABORT,'synthetic'); END");
    const reads = new AgentReads(ctx.db);
    const search = new URLSearchParams({ tool: "codex", q: "合成检索", session: "synthetic-session" });
    expect((await reads.handle("search", search)).status).toBe(200);
    expect(readdirSync(`${ctx.file}.audit-pending`).filter(f => f.endsWith(".enc"))).toHaveLength(1);
    other = new HubDB(ctx.file, ctx.config.dbKey);
    expect(ctx.db.delete(r.id)).toBe(true);
    ctx.db.db.exec("DROP TRIGGER reject_audit");
    const audit = new AgentReads(other).audit(new URLSearchParams()).reads;
    expect(audit).toHaveLength(1);
    expect(audit[0]!.args).toEqual({ q_length: 4, session: "synthetic-session" });
  } finally {
    other?.close();
    ctx.cleanup();
    output.mockRestore();
  }
});
