import { afterEach, beforeEach, expect, test } from "bun:test";
import { randomBytes } from "node:crypto";
import { writeFileSync } from "node:fs";
import { join } from "node:path";
import { toLocalIso } from "../../packages/record/index.ts";
import { AudioStore } from "../src/audio.ts";
import { conversationDetail, conversationList, conversationsIn } from "../src/conversations.ts";
import { DeviceClient } from "../src/devices/client.ts";
import { identityFromRaw, suite } from "../src/devices/envelope.ts";
import { DeviceService } from "../src/devices/service.ts";
import { removeDevice } from "../src/devices/store.ts";
import { reviewPlan } from "../src/distill/day-review.ts";
import { DistillStore } from "../src/distill/store.ts";
import { createHandler, startServer } from "../src/server.ts";
import { hubStatus } from "../src/status.ts";
import { fixture, networkDenied, setup } from "./helpers.ts";

const bindDenied = await networkDenied();

function basis(index: number): number[] {
  const vector = Array<number>(512).fill(0);
  vector[index] = 1;
  return vector;
}

function memoryKeys() {
  let stored: string | null = null;
  return { read: () => stored, write: (hex: string) => { stored = hex; } };
}

async function bootstrapLocalMac(origin: string, token: string) {
  const mac = await identityFromRaw(randomBytes(32).toString("hex"));
  const agent = await identityFromRaw(randomBytes(32).toString("hex"));
  const res = await fetch(`${origin}/v1/settings/devices/local-bootstrap`, {
    method: "POST",
    headers: { authorization: `Bearer ${token}`, "content-type": "application/json" },
    body: JSON.stringify({
      mac_pk: mac.publicKey.toString("base64url"),
      agent_pk: agent.publicKey.toString("base64url"),
    }),
  });
  expect(res.status).toBe(200);
  const body = await res.json() as { mac_device_id: string; agent_device_id: string; hub_pk: string };
  const hubKey = await suite.kem.deserializePublicKey(Buffer.from(body.hub_pk, "base64url"));
  const macClient = new DeviceClient(hubKey, mac.keys, origin);
  macClient.device = body.mac_device_id;
  const agentClient = new DeviceClient(hubKey, agent.keys, origin);
  agentClient.device = body.agent_device_id;
  return { macClient, agentClient, macId: body.mac_device_id, agentId: body.agent_device_id };
}

async function pairRemoteMac(origin: string, token: string) {
  const res = await fetch(`${origin}/v1/settings/devices/pairing`, {
    method: "POST",
    headers: { authorization: `Bearer ${token}`, "content-type": "application/json" },
    body: JSON.stringify({ role: "collect" }),
  });
  expect(res.status).toBe(200);
  const { uri } = await res.json() as { uri: string };
  const invite = JSON.parse(Buffer.from(new URL(uri).searchParams.get("d")!, "base64url").toString("utf8"));
  const client = await DeviceClient.fromInvite(invite, origin);
  const paired = await client.pair(invite, "mac");
  expect(paired.status).toBe(200);
  return client;
}

let ctx: ReturnType<typeof setup>;
beforeEach(() => { ctx = setup(); });
afterEach(() => ctx.cleanup());

test.skipIf(bindDenied)("声纹与说话人连续性：旧 device=mac 切换到本机 mac-<id> 后我/命名说话人/待确认/同场对话/保留期清理均不断", async () => {
  const keys = memoryKeys();
  const server = startServer({ db: ctx.db, token: ctx.config.token, port: 0, lanPort: 0, deviceDeps: { keys } });
  const origin = `http://127.0.0.1:${server.port}`;
  try {
    const audio = new AudioStore(ctx.db);
    const distill = new DistillStore(ctx.db);
    const vMe = basis(0);
    const vLin = basis(1);
    const vOther = basis(2);
    const baseMs = Date.parse("2026-11-23T10:00:00+08:00");
    const t0 = toLocalIso(baseMs);
    const t1 = toLocalIso(baseMs + 4 * 60_000);

    // 1. 构造旧 device="mac" 下的已确认“我”、已起名说话人“林工”及已有对话记录。
    const oldEmb = audio.embeddings({
      device: "mac",
      conversation_ref: "conv-legacy-1",
      t_start: t0,
      t_end: t1,
      speakers: [
        { local: "S1", track: "mic", seconds: 60, centroid: vMe },
        { local: "S2", track: "sys", seconds: 50, centroid: vLin },
      ],
    });
    const meSpeaker = oldEmb.speakers.find(s => s.local === "S1")!;
    const linSpeaker = oldEmb.speakers.find(s => s.local === "S2")!;
    const pendingBefore = distill.pending().filter(p => p.kind === "voice");
    expect(pendingBefore.length).toBe(1);
    audio.resolve(meSpeaker.speaker_id, "me");
    ctx.db.db.prepare("UPDATE speakers SET name='林工', status='confirmed' WHERE id=?").run(linSpeaker.speaker_id);
    // 清理旧 pending 项的 resolved_at 保持一致。
    ctx.db.db.prepare("UPDATE pending SET resolved_at=? WHERE kind='voice'").run(new Date().toISOString());

    const clock = (ms: number) => toLocalIso(ms).slice(11, 19);
    const oldRecord = fixture({
      device: "mac",
      source: "mac.audio",
      source_ref: "conv-legacy-1",
      kind: "span",
      t_start: t0,
      t_end: t1,
      title: `对话 · ${clock(baseMs).slice(0, 5)}–${clock(baseMs + 4 * 60_000).slice(0, 5)} · 我、林工`,
      body: `[${clock(baseMs + 5_000)}] 我：今天先核对一下新接口的切换方案\n[${clock(baseMs + 60_000)}] 林工：好的，我这边已经把合成用例跑通了`,
    });
    expect(ctx.db.ingest([oldRecord]).accepted).toBe(1);

    // 2. 登记本机 Mac（mac-<id>, local_only=1）与一台远端 Mac（local_only=0）。
    const { macClient, macId } = await bootstrapLocalMac(origin, ctx.config.token);
    const remoteMac = await pairRemoteMac(origin, ctx.config.token);

    // 3. 本机 mac-<id> 经设备协议 audio.sync 能拿到旧“我”的声纹。
    const syncReply = await macClient.send<{
      retention_days: number;
      voiceprint: { vector: number[]; threshold: number } | null;
      delete_conversations: string[];
      purge_before: string | null;
    }>("audio.sync", {});
    expect(syncReply.status).toBe(200);
    expect(syncReply.body.voiceprint).not.toBeNull();
    expect(syncReply.body.voiceprint!.vector[0]).toBeCloseTo(1, 5);

    // 4. 本机 mac-<id> 在 2 分钟后（间隔 ≤ 10 分钟，覆盖率 ≥ 60%）上传新对话声纹与转写。
    const t2 = toLocalIso(baseMs + 6 * 60_000);
    const t3 = toLocalIso(baseMs + 10 * 60_000);
    const newEmb = await macClient.send<{
      speakers: { local: string; speaker_id: string; label: string; is_me: boolean }[];
    }>("audio.embeddings", {
      conversation_ref: "conv-new-2",
      t_start: t2,
      t_end: t3,
      speakers: [
        { local: "S1", track: "mic", seconds: 60, centroid: vMe },
        { local: "S2", track: "sys", seconds: 55, centroid: vLin },
        { local: "S3", track: "mic", seconds: 50, centroid: vOther },
      ],
    });
    expect(newEmb.status).toBe(200);
    // 断言：“我”被正确识别，复用旧 speaker_id。
    expect(newEmb.body.speakers.find(s => s.local === "S1")).toEqual({
      local: "S1",
      speaker_id: meSpeaker.speaker_id,
      label: "我",
      is_me: true,
    });
    // 断言：已起名的说话人名字沿用，复用旧 speaker_id。
    expect(newEmb.body.speakers.find(s => s.local === "S2")).toEqual({
      local: "S2",
      speaker_id: linSpeaker.speaker_id,
      label: "林工",
      is_me: false,
    });
    // 断言：待确认里不会冒出重复的“我”（或新的声音提问）。
    expect(distill.pending().filter(p => p.kind === "voice")).toEqual([]);

    const newRecord = fixture({
      device: macId,
      source: "mac.audio",
      source_ref: "conv-new-2",
      kind: "span",
      t_start: t2,
      t_end: t3,
      title: `对话 · ${clock(baseMs + 6 * 60_000).slice(0, 5)}–${clock(baseMs + 10 * 60_000).slice(0, 5)} · 我、林工`,
      body: `[${clock(baseMs + 6 * 60_000 + 10_000)}] 我：接下来把音频和插件也都切到设备协议\n[${clock(baseMs + 8 * 60_000 + 20_000)}] 林工：没问题，我看一下回归结果`,
    });
    const ingestReply = await macClient.send<{ accepted: number; rejected: unknown[] }>("ingest", { records: [newRecord] });
    expect(ingestReply.status).toBe(200);
    expect(ingestReply.body.accepted).toBe(1);
    expect(ingestReply.body.rejected).toEqual([]);

    // 远端 Mac 也在 2 分钟后上传一段录音，验证不会被错误并入本机对话。
    const remoteRecord = fixture({
      device: remoteMac.device!,
      source: "mac.audio",
      source_ref: "conv-remote-3",
      kind: "span",
      t_start: toLocalIso(baseMs + 12 * 60_000),
      t_end: toLocalIso(baseMs + 13 * 60_000),
      title: "远端合成对话",
      body: `[${clock(baseMs + 12 * 60_000 + 5_000)}] 我：这是另一台电脑的测试录音`,
    });
    expect((await remoteMac.send<{ accepted: number }>("ingest", { records: [remoteRecord] })).body.accepted).toBe(1);

    // 断言：相邻 10 分钟内的旧 device="mac" 与新 device=mac-<id> 算同一场对话，远端 Mac 独立成场。
    const groups = conversationsIn(ctx.db, baseMs - 60_000, baseMs + 20 * 60_000);
    expect(groups.length).toBe(2);
    const localGroup = groups.find(g => g.record_ids.includes(oldRecord.id))!;
    expect(localGroup.record_ids).toEqual([oldRecord.id, newRecord.id]);
    expect(conversationDetail(ctx.db, oldRecord.id).record_ids).toEqual([oldRecord.id, newRecord.id]);
    expect(conversationDetail(ctx.db, newRecord.id).record_ids).toEqual([oldRecord.id, newRecord.id]);
    expect(conversationDetail(ctx.db, newRecord.id).turns.map(t => t.speaker)).toContain("林工");
    expect(conversationDetail(ctx.db, newRecord.id).turns.map(t => t.speaker)).toContain("我");
    expect(conversationList(ctx.db, baseMs - 60_000, baseMs + 20 * 60_000, "mac").find(g => g.record_ids.includes(oldRecord.id))?.record_ids)
      .toEqual([oldRecord.id, newRecord.id]);

    // 每日回顾切段也视为同一场对话。
    const plan = reviewPlan(ctx.db, baseMs - 30 * 60_000, baseMs + 30 * 60_000);
    const localSeg = plan.segments.find(s => s.records.some(r => r.id === oldRecord.id))!;
    expect(localSeg.records.map(r => r.id)).toContain(newRecord.id);
    expect(localSeg.records.map(r => r.id)).not.toContain(remoteRecord.id);

    // 断言：旧记录本身未被改写（AGENTS：记录写入后不再修改）。
    expect(ctx.db.get(oldRecord.id)?.device).toBe("mac");
    expect(ctx.db.get(newRecord.id)?.device).toBe(macId);

    // 5. 本机 mac-<id> 可以对旧 device="mac" 对话执行 relabel（audio.embeddings + audio.lines），远端 Mac 被拒绝。
    const relabelEmb = await macClient.send("audio.embeddings", {
      conversation_ref: "conv-legacy-1",
      t_start: t0,
      t_end: t1,
      speakers: [
        { local: "S1", track: "mic", seconds: 60, centroid: vMe },
        { local: "S2", track: "sys", seconds: 50, centroid: vLin },
      ],
    });
    expect(relabelEmb.status).toBe(200);
    const relabelLines = await macClient.send<{ stored: number }>("audio.lines", {
      conversation_ref: "conv-legacy-1",
      lines: [
        { at: clock(baseMs + 5_000), speaker_id: meSpeaker.speaker_id, hidden: false },
        { at: clock(baseMs + 60_000), speaker_id: linSpeaker.speaker_id, hidden: false },
      ],
    });
    expect(relabelLines.status).toBe(200);
    expect(relabelLines.body.stored).toBe(2);

    const remoteHijack = await remoteMac.send("audio.lines", {
      conversation_ref: "conv-legacy-1",
      lines: [{ at: clock(baseMs + 5_000), speaker_id: meSpeaker.speaker_id, hidden: false }],
    });
    expect(remoteHijack.status).toBe(400);

    // 6. 保留期清理、删除队列与手动 purge：删旧 "mac" 记录，mac-<id> 收到删除指令并 ack，deletes_pending 归零。
    expect(ctx.db.delete(oldRecord.id)).toBe(true);
    const { purge_before } = audio.purge();
    const syncAfterDelete = await macClient.send<{
      delete_conversations: string[];
      purge_before: string | null;
    }>("audio.sync", {});
    expect(syncAfterDelete.status).toBe(200);
    expect(syncAfterDelete.body.delete_conversations).toContain("conv-legacy-1");
    expect(syncAfterDelete.body.purge_before).toBe(purge_before);
    expect(hubStatus(ctx.db, { port: server.port }).audio.deletes_pending).toBe(1);

    const ackReply = await macClient.send("audio.sync.ack", {
      deleted: ["conv-legacy-1"],
      purged_at: purge_before,
    });
    expect(ackReply.status).toBe(200);
    const syncAfterAck = await macClient.send<{
      delete_conversations: string[];
      purge_before: string | null;
    }>("audio.sync", {});
    expect(syncAfterAck.body.delete_conversations).toEqual([]);
    expect(syncAfterAck.body.purge_before).toBeNull();
    expect(hubStatus(ctx.db, { port: server.port }).audio.deletes_pending).toBe(0);
    // 旧 device="mac" 侧同步也已确认清理，不会重复下发。
    expect(audio.sync("mac").delete_conversations).toEqual([]);
    expect(audio.sync("mac").purge_before).toBeNull();
  } finally {
    await server.stop(true);
  }
});

test.skipIf(bindDenied)("旧 device=mac 留下的 sample_requests 可由本机 mac-<id> 拉取并补传试听样本，过期则照常清理", async () => {
  const keys = memoryKeys();
  const server = startServer({ db: ctx.db, token: ctx.config.token, port: 0, lanPort: 0, deviceDeps: { keys } });
  const origin = `http://127.0.0.1:${server.port}`;
  try {
    const audio = new AudioStore(ctx.db);
    const now = Date.now();
    audio.embeddings({
      device: "mac",
      conversation_ref: "conv-sample-legacy",
      t_start: toLocalIso(now - 120_000),
      t_end: toLocalIso(now - 60_000),
      speakers: [{ local: "S1", track: "mic", seconds: 60, centroid: basis(5) }],
    });
    const { macClient, macId } = await bootstrapLocalMac(origin, ctx.config.token);
    const syncReply = await macClient.send<{
      sample_requests: { id: string; speaker_id: string; conversation_ref: string; local: string }[];
    }>("audio.sync", {});
    expect(syncReply.status).toBe(200);
    expect(syncReply.body.sample_requests).toHaveLength(1);
    const req = syncReply.body.sample_requests[0]!;
    expect(req.conversation_ref).toBe("conv-sample-legacy");

    // 由 mac-<id> 补传记录与试听样本，验证 sampleContext 能跨 mac / mac-<id> 找到文字。
    const rec = fixture({
      device: macId,
      source: "mac.audio",
      source_ref: "conv-sample-legacy",
      kind: "span",
      t_start: toLocalIso(now - 120_000),
      t_end: toLocalIso(now - 60_000),
      body: "[10:00:05] 说话人 A：这是一段用于核验试听上下文的合成对白",
    });
    expect((await macClient.send<{ accepted: number }>("ingest", { records: [rec] })).body.accepted).toBe(1);
    const clip = Buffer.from("RIFFsynthetic-wav").toString("base64");
    const upload = await macClient.send<{ uploaded: number }>("audio.samples", {
      request_id: req.id,
      clips: [{ mime: "audio/wav", data: clip }],
    });
    expect(upload.status).toBe(200);
    expect(upload.body.uploaded).toBe(1);
    const payload = audio.pendingPayload(req.speaker_id);
    expect((payload?.samples as { said?: string }[])[0]?.said).toContain("合成对白");

    // 另一段已跳过对话的孤儿声纹在保留期过后照常清理。
    const oldSkip = await macClient.send("audio.embeddings", {
      conversation_ref: "conv-skip-old",
      t_start: toLocalIso(now - 20 * 86_400_000),
      t_end: toLocalIso(now - 20 * 86_400_000 + 30_000),
      speakers: [{ local: "S1", track: "mic", seconds: 4, centroid: basis(9) }],
    });
    expect(oldSkip.status).toBe(200);
    const skipped = await macClient.send("audio.skipped", { conversation_ref: "conv-skip-old" });
    expect(skipped.status).toBe(200);
    expect(ctx.db.db.prepare("SELECT COUNT(*) AS n FROM voice_embeddings WHERE conversation_ref='conv-skip-old'").get()).toEqual({ n: 0 });
  } finally {
    await server.stop(true);
  }
});

test.skipIf(bindDenied)("collector.status：设备上报、校验、权限、状态接口优先读上报与回落文件", async () => {
  const now = Date.parse("2026-11-23T15:00:00+08:00");
  const keys = memoryKeys();
  const server = startServer({
    db: ctx.db,
    token: ctx.config.token,
    port: 0,
    lanPort: 0,
    deviceDeps: { keys, now: () => now },
  });
  const origin = `http://127.0.0.1:${server.port}`;
  try {
    // 1. 尚无设备上报时，状态接口回落到 collector-status.json。
    const fileTime = toLocalIso(now - 30_000);
    writeFileSync(join(ctx.dir, "collector-status.json"), JSON.stringify({
      time: fileTime,
      transcription: { pending: 9, failed: 2 },
      outboxBytes: 4096,
      outboxDropped: 3,
      outboxDegraded: true,
    }));
    const fallback = hubStatus(ctx.db, { port: server.port, now });
    expect(fallback.collector).toEqual({
      outbox_bytes: 4096, outbox_dropped: 3, outbox_degraded: true, updated_at: fileTime, stale: false,
    });
    expect(fallback.audio.transcription).toEqual({ pending: 9, failed: 2, updated_at: fileTime, stale: false });

    // 2. 登记本机 Mac 与 Agent；Agent 调用 collector.status 返回 403。
    const { macClient, agentClient, macId } = await bootstrapLocalMac(origin, ctx.config.token);
    const reportTime = toLocalIso(now - 10_000);
    const validBody = {
      time: reportTime,
      transcription: { pending: 2, failed: 1 },
      outbox_bytes: 512,
      outbox_dropped: 0,
      outbox_degraded: false,
      hub_busy: 4,
      queue_peak: 17,
    };
    const ts = new Date(now).toISOString();
    expect((await agentClient.send("collector.status", validBody, { ts })).status).toBe(403);

    // 非法字段或负值返回 400。
    expect((await macClient.send("collector.status", { ...validBody, extra: 1 }, { ts })).status).toBe(400);
    expect((await macClient.send("collector.status", { ...validBody, outbox_bytes: -1 }, { ts })).status).toBe(400);
    expect((await macClient.send("collector.status", { ...validBody, time: "not-a-time" }, { ts })).status).toBe(400);

    // 3. 合法上报成功，状态接口优先读设备上报而不是 collector-status.json。
    const okReply = await macClient.send("collector.status", validBody, { ts });
    expect(okReply).toEqual({ status: 200, body: { ok: true } });

    const reported = hubStatus(ctx.db, { port: server.port, now });
    expect(reported.collector).toEqual({
      outbox_bytes: 512, outbox_dropped: 0, outbox_degraded: false,
      hub_busy: 4, queue_peak: 17, updated_at: reportTime, stale: false,
    });
    expect(reported.audio.transcription).toEqual({ pending: 2, failed: 1, updated_at: reportTime, stale: false });
    expect(reported.audio.transcription_disabled).toBe(false);

    // status.get 设备 op 同样看到上报值。
    const statusOp = await macClient.send<{ collector: { outbox_bytes: number; hub_busy: number } }>("status.get", {}, { ts });
    expect(statusOp.status).toBe(200);
    expect(statusOp.body.collector.outbox_bytes).toBe(512);
    expect(statusOp.body.collector.hub_busy).toBe(4);

    // 4. 录音关闭（transcription: null）和过期判定。
    expect((await macClient.send("collector.status", { ...validBody, transcription: null }, { ts })).status).toBe(200);
    expect(hubStatus(ctx.db, { port: server.port, now }).audio).toMatchObject({
      transcription: null,
      transcription_disabled: true,
    });
    expect(hubStatus(ctx.db, { port: server.port, now: now + 120_000 }).collector?.stale).toBe(true);
    expect(hubStatus(ctx.db, { port: server.port, now: now + 120_000 }).audio.transcription_disabled).toBe(false);

    // 5. 移除设备后清除其上报，状态接口自动回落到 collector-status.json。
    removeDevice(ctx.db.db, macId, { force: true });
    const afterRemove = hubStatus(ctx.db, { port: server.port, now });
    expect(afterRemove.collector?.outbox_bytes).toBe(4096);
    expect(afterRemove.audio.transcription?.pending).toBe(9);
  } finally {
    await server.stop(true);
  }
});
