import { afterEach, beforeEach, expect, test } from "bun:test";
import { toLocalIso, ulid } from "../../packages/record/index.ts";
import { createHandler } from "../src/server.ts";
import { hubStatus } from "../src/status.ts";
import { fixture, setup } from "./helpers.ts";

let ctx: ReturnType<typeof setup>;
beforeEach(() => { ctx = setup(); });
afterEach(() => ctx.cleanup());

const now = Date.parse("2026-11-09T15:00:00+08:00");
function seed() {
  const secret = "这段正文不应出现在状态里";
  ctx.db.ingest([
    fixture({ device: "mac", source: "mac.screen", title: "合成标题甲", body: secret }),
    fixture({ device: "mac", source: "mac.browser", source_ref: "ref-1", title: "合成标题乙", body: secret }),
    fixture({ device: "phone", source: "mac.screen", title: "合成标题丙", body: secret }),
  ]);
  const sql = ctx.db.db;
  const usage = sql.prepare("INSERT INTO llm_usage(id,at,tier,provider,model,input_chars,output_chars,input_tokens,output_tokens,ms,ok,error) VALUES(?,?,?,?,?,?,?,?,?,?,?,?)");
  usage.run(ulid(), toLocalIso(now - 3_600_000), "minute", "codex-cli", "m1", 10, 5, 100, 20, 1000, 1, null);
  usage.run(ulid(), new Date(now - 1_800_000).toISOString(), "minute", "codex-cli", "m2", 10, 0, null, null, 500, 0, "超时");
  usage.run(ulid(), toLocalIso(now - 600_000), "hour", "codex-cli", "m1", 10, 5, 7, 3, 2000, 1, null);
  // 昨天的调用不计入今天。
  usage.run(ulid(), toLocalIso(now - 86_400_000), "minute", "codex-cli", "m1", 10, 5, 999, 999, 9999, 1, null);
  const frame = sql.prepare("INSERT INTO frames(id,t_start_ms,t_end_ms,key,record_ids,chars,private,status) VALUES(?,?,?,?,?,?,?,?)");
  frame.run(ulid(), now, now, "k", "[]", 1, 0, "new");
  frame.run(ulid(), now, now, "k", "[]", 1, 0, "assigned");
  frame.run(ulid(), now, now, "k", "[]", 1, 0, "assigned");
  const state = sql.prepare("INSERT INTO distill_state VALUES(?,?)");
  state.run("enabled_ms", JSON.stringify(now - 86_400_000));
  state.run("now", JSON.stringify({ brief: secret, detail: {}, updated_at: toLocalIso(now - 60_000) }));
  sql.prepare("INSERT INTO pending(id,kind,payload,created_at) VALUES(?,?,?,?)").run(ulid(), "thread_done", JSON.stringify({ title: secret }), toLocalIso(now));
  sql.prepare("INSERT INTO audio_settings VALUES(?,?)").run("delete:mac", JSON.stringify(["a", "b"]));
  return secret;
}

test("状态只读、只给计数，按来源和设备统计，今天用量按档位汇总", () => {
  const secret = seed();
  const before = (ctx.db.db.prepare("SELECT total_changes() AS n").get() as { n: number }).n;
  const status = hubStatus(ctx.db, { port: 47823, now });
  expect((ctx.db.db.prepare("SELECT total_changes() AS n").get() as { n: number }).n).toBe(before);
  const json = JSON.stringify(status);
  for (const text of [secret, "合成标题"]) expect(json).not.toContain(text);

  expect(status.listen).toEqual({ host: "127.0.0.1", port: 47823, localhost_only: true });
  expect(status.database.bytes).toBeGreaterThan(0);
  expect(status.records.total).toBe(3);
  expect(status.records.by_source).toEqual([
    { source: "mac.screen", count: 2, last_received: expect.any(String) },
    { source: "mac.browser", count: 1, last_received: expect.any(String) },
  ]);
  expect(status.records.by_device.map(d => [d.device, d.count])).toEqual([["mac", 2], ["phone", 1]]);
  expect(status.distill.frames).toEqual({ new: 1, assigned: 2 });
  expect(status.distill.last_round_at).toBe(toLocalIso(now - 60_000));
  expect(status.distill.enabled_at).toBe(toLocalIso(now - 86_400_000));
  expect(status.distill.heartbeat_at).toBeNull();
  expect(status.distill.pending_open).toEqual({ thread_done: 1 });
  expect(status.distill.last_error).toMatchObject({ tier: "minute", error: "超时" });
  expect(status.llm_today.total).toEqual({ calls: 3, ok: 2, failed: 1, input_tokens: 107, output_tokens: 23, ms: 3500 });
  expect(status.llm_today.by_tier).toEqual([
    { tier: "minute", models: ["m1", "m2"], calls: 2, ok: 1, failed: 1, input_tokens: 100, output_tokens: 20, ms: 1500 },
    { tier: "hour", models: ["m1"], calls: 1, ok: 1, failed: 0, input_tokens: 7, output_tokens: 3, ms: 2000 },
  ]);
  expect(status.audio.deletes_pending).toBe(2);
});

test("GET /v1/status 需要 token；空库也能返回", async () => {
  const handler = createHandler({ db: ctx.db, token: ctx.config.token, port: 5000 });
  const request = (auth?: string) => handler(new Request("http://127.0.0.1:5000/v1/status", { headers: { host: "127.0.0.1:5000", ...(auth ? { authorization: auth } : {}) } }));
  expect((await request()).status).toBe(401);
  const response = await request(`Bearer ${ctx.config.token}`);
  expect(response.status).toBe(200);
  const body = await response.json();
  expect(body.listen.port).toBe(5000);
  expect(body.records).toEqual({ total: 0, tombstones: 0, by_source: [], by_device: [] });
  expect(body.distill.last_round_at).toBeNull();
  expect(body.distill.last_error).toBeNull();
  expect(body.llm_today.total.calls).toBe(0);
  expect(body.distill.requests).toEqual({ total: 0, by_status: {} });
});

test("心跳是 ISO 字符串；提炼请求按状态计数", () => {
  const sql = ctx.db.db;
  const beat = toLocalIso(now - 5_000);
  sql.prepare("INSERT INTO distill_state VALUES(?,?)").run("heartbeat_at", JSON.stringify(beat));
  const add = sql.prepare("INSERT INTO distill_requests(id,kind,status,created_at) VALUES(?,'round',?,?)");
  for (const [id, st] of [["a", "queued"], ["b", "queued"], ["c", "failed"]]) add.run(id, st, beat);
  const status = hubStatus(ctx.db, { port: 47823, now });
  expect(status.distill.heartbeat_at).toBe(beat);
  expect(status.distill.requests).toEqual({ total: 3, by_status: { queued: 2, failed: 1 } });
});

test("来源计数缓存：新增时增量累加，删除后重算", () => {
  const a = fixture({ device: "mac", source: "mac.screen" });
  ctx.db.ingest([a, fixture({ device: "mac", source: "mac.shell", source_ref: "s1" })]);
  const pick = () => {
    const s = hubStatus(ctx.db, { port: 1, now });
    return { total: s.records.total, tombstones: s.records.tombstones, sources: s.records.by_source.map(r => [r.source, r.count]), devices: s.records.by_device.map(r => [r.device, r.count]) };
  };
  expect(pick()).toEqual({ total: 2, tombstones: 0, sources: [["mac.screen", 1], ["mac.shell", 1]], devices: [["mac", 2]] });
  ctx.db.ingest([fixture({ device: "phone", source: "mac.screen" })]);
  expect(pick()).toEqual({ total: 3, tombstones: 0, sources: [["mac.screen", 2], ["mac.shell", 1]], devices: [["mac", 2], ["phone", 1]] });
  const phone = hubStatus(ctx.db, { port: 1, now }).records.by_device.find(r => r.device === "phone")!;
  expect(phone.last_received).toBe((ctx.db.db.prepare("SELECT MAX(t_received) AS t FROM records WHERE device='phone'").get() as { t: string }).t);
  expect(ctx.db.delete(a.id)).toBe(true);
  expect(pick()).toEqual({ total: 2, tombstones: 1, sources: [["mac.screen", 1], ["mac.shell", 1]], devices: [["mac", 1], ["phone", 1]] });
});
