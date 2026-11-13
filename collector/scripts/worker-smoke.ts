// 仅使用 vendor 样例，正文只在内存校验，不输出或落盘。
import { validateRecord } from "../../packages/record/index.ts";
import { spawn } from "node:child_process";
import { mkdtempSync, symlinkSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
const vendor = process.env.RA_WORKER_SMOKE_VENDOR ?? path.resolve(import.meta.dir, "../../experiments/02-audio/vendor");
const models = mkdtempSync(path.join(tmpdir(), "worker-models-"));
let embeddings = 0, ingested = 0;
try {
  symlinkSync(path.join(vendor, "sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2024-07-17"), path.join(models, "sense-voice"));
  symlinkSync(path.join(vendor, "3dspeaker_speech_eres2net_base_sv_zh-cn_3dspeaker_16k.onnx"), path.join(models, "3dspeaker_speech_eres2net_base_sv_zh-cn_3dspeaker_16k.onnx"));
  const server = Bun.serve({ hostname: "127.0.0.1", port: 0, async fetch(req) {
    if (req.headers.get("authorization") !== "Bearer synthetic-token") return new Response(null, { status: 401 });
    const route = new URL(req.url).pathname;
    if (route === "/v1/audio/sync") return Response.json({retention_days: 7, purge_before: null, delete_conversations: [], sample_requests: [], voiceprint: { vector: [1, ...Array(511).fill(0)], threshold: 0.49 }});
    const body = await req.json();
    if (route === "/v1/audio/embeddings") {
      if (!body.speakers.length || !body.speakers.every((s: {centroid: number[]}) => s.centroid.length === 512 && s.centroid.every(Number.isFinite) && Math.abs(s.centroid.reduce((n, v) => n + v*v, 0) - 1) < 0.001)) throw new Error("声纹形状错误");
      embeddings++;
      return Response.json({ speakers: body.speakers.map((s: {local: string}, i: number) => ({local: s.local, speaker_id: `synthetic-speaker-${i}`, label: `说话人 ${i}`, is_me: false})) });
    }
    if (route === "/v1/ingest") {
      const record = body.records[0];
      if (body.records.length !== 1 || !validateRecord(record).ok || record.source !== "mac.audio" || !record.body || !record.people.length) throw new Error("记录形状错误");
      ingested++;
      return Response.json({accepted: 1, duplicates: 0, rejected: []});
    }
    return new Response(null, {status: 404});
  }});
  try {
    const child = spawn("collector/swift.sh", ["test", "-c", "release", "--filter", "vendorWorkerSmoke"], {stdio: "inherit", env: {...process.env, RA_WORKER_SMOKE_MODELS: models, RA_WORKER_SMOKE_VENDOR: vendor, RA_WORKER_SMOKE_HUB: `http://127.0.0.1:${server.port}`}});
    const code = await new Promise<number | null>((resolve, reject) => {child.on("exit", resolve); child.on("error", reject);});
    if (code !== 0 || embeddings !== 1 || ingested !== 1) throw new Error("worker 集成验证失败");
    console.log("worker 集成验证通过：embeddings=1 ingest=1 done=1");
  } finally { server.stop(true); }
} finally { rmSync(models, {recursive: true, force: true}); }
