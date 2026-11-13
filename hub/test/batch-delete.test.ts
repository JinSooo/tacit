import { expect, test } from "bun:test";
import { DistillStore } from "../src/distill/store.ts";
import { startServer } from "../src/server.ts";
import { fixture, setup } from "./helpers.ts";

test("批量真删一次撤下派生内容，连带修正，保留其他记录并阻止重导入", async () => {
  const ctx = setup(), store = new DistillStore(ctx.db);
  const records = Array.from({length: 100}, (_, i) => fixture({source_ref: `bulk-${i}`}));
  const keep = fixture({body:"保留的记录"});
  ctx.db.ingest([...records, keep]);
  const correction = fixture({source:"manual.correction", corrects:records[0]!.id, capture:{method:"manual"}});
  ctx.db.ingest([correction]);
  store.upsertThread({id:"bulk", title:"待删除派生文字", brief:"待删除摘要", status:"active", needs_regen:0});
  store.createFrame({id:"bulk-frame", key:"bulk", record_ids:records.map(r=>r.id).concat(keep.id), t_start_ms:0,t_end_ms:1, chars:100,private:0,status:"new"});
  store.assign("bulk-frame","bulk","user",1);
  const before = store.getState<number>("content_revision") ?? 0;
  const server = startServer({db:ctx.db,token:ctx.config.token,agentToken:"limited",port:0});
  try {
    const call = (token:string, ids:unknown) => fetch(`http://127.0.0.1:${server.port}/v1/records`, {method:"DELETE",headers:{authorization:`Bearer ${token}`,"content-type":"application/json"},body:JSON.stringify({ids})});
    expect((await call("limited",records.map(r=>r.id))).status).toBe(403);
    expect((await call(ctx.config.token,[records[0]!.id,"bad"])).status).toBe(400);
    expect(ctx.db.get(records[0]!.id)).not.toBeNull();
    const result = await call(ctx.config.token,records.map(r=>r.id));
    expect(result.status).toBe(200); expect(await result.json()).toEqual({deleted:101});
    expect(ctx.db.get(correction.id)).toBeNull(); expect(ctx.db.get(keep.id)?.body).toBe(keep.body);
    expect(store.thread("bulk")?.brief).toBeNull();
    expect(store.frames()[0]?.record_ids).toEqual([keep.id]);
    expect(store.getState("content_revision")).toBe(before+1);
    expect(ctx.db.ingest([...records,correction]).duplicates).toBe(101);
    expect(ctx.db.db.pragma("integrity_check",{simple:true})).toBe("ok");
  } finally { await server.stop(true);ctx.cleanup(); }
});
