import { afterEach, beforeEach, expect, test } from "bun:test";
import { writeFileSync } from "node:fs";
import { join } from "node:path";
import { toLocalIso, ulid } from "../../packages/record/index.ts";
import { GENERAL_DEFAULTS, updateGeneral } from "../src/general-settings.ts";
import { createHandler } from "../src/server.ts";
import { hubStatus } from "../src/status.ts";
import { fixture, setup } from "./helpers.ts";

let ctx: ReturnType<typeof setup>;
beforeEach(() => { ctx = setup(); });
afterEach(() => ctx.cleanup());

const now = Date.parse("2026-11-09T15:00:00+08:00");
const snapshot = () => hubStatus(ctx.db, { port: 47823, now });
const writeCollector = (text: string) => writeFileSync(join(ctx.dir, "collector-status.json"), text);
const completeTokens = { input_tokens_incomplete: false, output_tokens_incomplete: false };
const incompleteTokens = { input_tokens_incomplete: true, output_tokens_incomplete: true };

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
  usage.run(ulid(), new Date(now - 1_800_000).toISOString(), "minute", "codex-cli", "m2", 10, 0, null, null, 500, 0, "timeout");
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
  state.run("last_round_at", JSON.stringify(toLocalIso(now - 5_000)));
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

  expect(status.listen).toEqual({ host: "127.0.0.1", port: 47823, localhost_only: true, lan_port: null });
  // 2026-11-22：已配对手机时局域网端口开着，状态页却写死“只监听本机”。
  expect(hubStatus(ctx.db, { port: 47823, lanPort: 47824, now }).listen).toEqual({ host: "127.0.0.1", port: 47823, localhost_only: false, lan_port: 47824 });
  expect(status.database.bytes).toBeGreaterThan(0);
  expect(status.records.total).toBe(3);
  expect(status.records.by_source).toEqual([
    { source: "mac.screen", count: 2, last_received: expect.any(String) },
    { source: "mac.browser", count: 1, last_received: expect.any(String) },
  ]);
  expect(status.records.by_device.map(d => [d.device, d.count])).toEqual([["mac", 2], ["phone", 1]]);
  expect(status.distill.frames).toEqual({ new: 1, assigned: 2 });
  expect(status.distill.last_round_at).toBe(toLocalIso(now - 5_000));
  expect(status.distill.enabled_at).toBe(toLocalIso(now - 86_400_000));
  expect(status.distill.heartbeat_at).toBeNull();
  expect(status.distill.pending_open).toEqual({ thread_done: 1 });
  expect(status.distill.last_error).toMatchObject({ tier: "minute", error: "timeout", recovered: false });
  // 最近按调用开始顺序（ULID）取，与 at 的写法无关。
  expect(status.distill.last_ok_at).toBe(toLocalIso(now - 86_400_000));
  expect(status.llm_today.total).toEqual({ calls: 3, ok: 2, failed: 1, input_tokens: 107, output_tokens: 23, ms: 3500, ...incompleteTokens });
  expect(status.llm_today.by_tier).toEqual([
    { tier: "minute", models: ["m1", "m2"], calls: 2, ok: 1, failed: 1, input_tokens: 100, output_tokens: 20, ms: 1500, ...incompleteTokens },
    { tier: "hour", models: ["m1"], calls: 1, ok: 1, failed: 0, input_tokens: 7, output_tokens: 3, ms: 2000, ...completeTokens },
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
  expect(body.language).toBe(GENERAL_DEFAULTS.language);
  const language = body.language === "en" ? "zh" : "en";
  updateGeneral(ctx.db, { language });
  expect(await (await request(`Bearer ${ctx.config.token}`)).json()).toMatchObject({ language });
  expect(body.listen.port).toBe(5000);
  expect(body.records).toEqual({ total: 0, tombstones: 0, by_source: [], by_device: [] });
  expect(body.distill.last_round_at).toBeNull();
  expect(body.distill.last_error).toBeNull();
  expect(body.distill.last_ok_at).toBeNull();
  expect(body.llm_today.total.calls).toBe(0);
  expect(body.distill.requests).toEqual({ total: 0, by_status: {}, recent: [] });
});

test("心跳是 ISO 字符串；手动整理保留总数、最近 5 项进度和安全的失败原因", () => {
  const sql = ctx.db.db;
  const beat = toLocalIso(now - 5_000);
  sql.prepare("INSERT INTO distill_state VALUES(?,?)").run("heartbeat_at", JSON.stringify(beat));
  const add = sql.prepare(`
    INSERT INTO distill_requests(id,kind,status,created_at,started_at,finished_at,progress_done,progress_total,error)
    VALUES(?,'round',?,?,?,?,?,?,?)
  `);
  const earlier = toLocalIso(now - 60_000);
  const started = toLocalIso(now - 4_000);
  const finished = toLocalIso(now - 1_000);
  const privateError = "network: 错误中附带的合成正文";
  add.run("a", "queued", earlier, null, null, null, null, null);
  for (const id of ["b", "c"]) add.run(id, "queued", beat, null, null, null, null, null);
  add.run("d", "running", beat, started, null, 1, 3, null);
  add.run("e", "failed", beat, started, finished, 2, 3, privateError);
  add.run("f", "failed", beat, started, finished, 2, 3, "rate_limited:429");
  const status = snapshot();
  expect(status.distill.heartbeat_at).toBe(beat);
  expect(status.distill.requests).toEqual({ total: 6, by_status: { queued: 3, running: 1, failed: 2 }, recent: [
    { id: "f", status: "failed", done: 2, total: 3, error: "rate_limited:429", created_at: beat, updated_at: finished },
    { id: "e", status: "failed", done: 2, total: 3, error: "unknown", created_at: beat, updated_at: finished },
    { id: "d", status: "running", done: 1, total: 3, error: null, created_at: beat, updated_at: started },
    { id: "c", status: "queued", done: null, total: null, error: null, created_at: beat, updated_at: beat },
    { id: "b", status: "queued", done: null, total: null, error: null, created_at: beat, updated_at: beat },
  ] });
  expect(JSON.stringify(status)).not.toContain(privateError);
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

test("最近错误只有同一档位和用途的后续调用成功才显示恢复，且不泄露旧错误原文", () => {
  const usage = ctx.db.db.prepare("INSERT INTO llm_usage(id,at,tier,task,ok,error) VALUES(?,?,?,?,?,?)");
  const save = (age: number, tier: string, task: string | null, error: string | null = null) =>
    usage.run(ulid(now - age), toLocalIso(now - age), tier, task, error === null ? 1 : 0, error);
  const privateError = "服务响应带有合成密钥 abc";
  save(7_200_000, "minute", "assign");
  save(3_600_000, "minute", "assign", privateError);
  expect(snapshot().distill.last_error).toMatchObject({ error: "unknown", recovered: false });
  expect(JSON.stringify(snapshot())).not.toContain(privateError);
  save(600_000, "hour", "assign");
  expect(snapshot().distill.last_error?.recovered).toBe(false);
  save(480_000, "minute", "other");
  expect(snapshot().distill.last_error?.recovered).toBe(false);
  save(120_000, "minute", "assign");
  save(60_000, "day", "other");
  expect(snapshot().distill.last_error?.recovered).toBe(true);
  expect(snapshot().distill.last_ok_at).toBe(toLocalIso(now - 60_000));
  save(30_000, "minute", null, "timeout");
  save(10_000, "minute", null);
  expect(snapshot().distill.last_error?.recovered).toBe(false);
});

test.each(["cli_not_logged_in:401", "cli_outdated", "cli_model_unavailable", "cli_network", "cli_runtime_missing"])("状态保留固定的 CLI 错误类别 %s", error => {
  ctx.db.db.prepare("INSERT INTO llm_usage(id,at,tier,task,ok,error) VALUES(?,?,?,?,0,?)")
    .run(ulid(now), toLocalIso(now), "minute", "assign", error);
  expect(snapshot().distill.last_error?.error).toBe(error);
});

test("今天用量同时按 task 汇总，NULL 旧行、失败和未知 token 均保留", () => {
  seed();
  ctx.db.db.exec("UPDATE llm_usage SET task=CASE WHEN input_tokens=100 THEN 'assign' WHEN ok=0 THEN 'assign' WHEN input_tokens=999 THEN 'yesterday' ELSE NULL END");
  const status = hubStatus(ctx.db, { port: 1, now });
  expect(status.llm_today.by_task).toEqual([
    { task: null, calls: 1, ok: 1, failed: 0, input_tokens: 7, output_tokens: 3, ms: 2000, ...completeTokens },
    { task: "assign", calls: 2, ok: 1, failed: 1, input_tokens: 100, output_tokens: 20, ms: 1500, ...incompleteTokens },
  ]);
  expect(status.llm_today.by_tier).toHaveLength(2);
  ctx.db.db.exec("UPDATE llm_usage SET input_tokens=NULL,output_tokens=NULL WHERE task='assign'");
  expect(hubStatus(ctx.db, { port: 1, now }).llm_today.by_task[1]).toMatchObject({ input_tokens: null, output_tokens: null });
});

test.each([
  ["文件缺失", null],
  ["JSON 无法解析", "{"],
  ["旧采集端没有队列字段", JSON.stringify({ time: toLocalIso(now), queue: 10 })],
  ["缺少采集时间", JSON.stringify({ transcription: { pending: 3, failed: 1 }, outboxBytes: 256, outboxDropped: 0, outboxDegraded: false })],
])("采集快照安全降级：%s", (_label, contents) => {
  if (contents !== null) writeCollector(contents);
  const status = snapshot();
  expect(status.audio.transcription).toBeNull();
  expect(status.audio.transcription_disabled).toBe(false);
  expect(status.collector).toBeNull();
});

test("采集快照只公开本机队列计数，超过两分钟后标记过期", () => {
  const updated_at = toLocalIso(now - 120_000);
  writeCollector(JSON.stringify({
    time: updated_at, transcription: { pending: 3, failed: 1 }, outboxBytes: 1024, outboxDropped: 2, outboxDegraded: true,
    hubError: "采集端错误中的合成密钥",
  }));
  const status = snapshot();
  expect(status.audio.transcription).toEqual({ pending: 3, failed: 1, updated_at, stale: false });
  expect(status.collector).toEqual({ outbox_bytes: 1024, outbox_dropped: 2, outbox_degraded: true, updated_at, stale: false });
  expect(JSON.stringify(status)).not.toContain("采集端错误中的合成密钥");
  const next = hubStatus(ctx.db, { port: 47823, now: now + 1 });
  expect(next.audio.transcription?.stale).toBe(true);
  expect(next.collector?.stale).toBe(true);
});

test("明确关闭录音与转写状态缺失可区分，待发送积压独立读取", () => {
  const time = toLocalIso(now);
  const outbox = { outboxBytes: 0, outboxDropped: 0, outboxDegraded: false };
  writeCollector(JSON.stringify({ time, transcription: null, ...outbox }));
  expect(snapshot().audio).toMatchObject({ transcription: null, transcription_disabled: true });
  expect(snapshot().collector).toEqual({ outbox_bytes: 0, outbox_dropped: 0, outbox_degraded: false, updated_at: time, stale: false });

  writeCollector(JSON.stringify({ time, transcription: { pending: 2 }, ...outbox }));
  expect(snapshot().audio).toMatchObject({ transcription: null, transcription_disabled: false });
  expect(snapshot().collector?.outbox_bytes).toBe(0);
});

test("只公开未到期的模型暂停状态和已知原因", () => {
  const save = ctx.db.db.prepare("INSERT OR REPLACE INTO distill_state VALUES('llm_cooldown',?)");
  const until = new Date(now + 60_000).toISOString();
  save.run(JSON.stringify({ until, kind: "quota", detail: "合成错误正文" }));
  expect(snapshot().distill.cooldown).toEqual({ until, kind: "quota" });
  expect(hubStatus(ctx.db, { port: 47823, now: now + 60_000 }).distill.cooldown).toBeNull();
  save.run(JSON.stringify({ until, kind: "其他错误原文" }));
  expect(snapshot().distill.cooldown).toBeNull();
  save.run("{");
  expect(snapshot().distill.cooldown).toBeNull();
});
