import { afterEach, beforeEach, expect, test } from "bun:test";
import { AudioStore } from "../src/audio.ts";
import { HubDB } from "../src/db.ts";
import { DistillStore } from "../src/distill/store.ts";
import { frameKey, sliceFrames } from "../src/distill/frames.ts";
import { createHandler } from "../src/server.ts";
import { fixture, setup } from "./helpers.ts";

let ctx: ReturnType<typeof setup>;
let audio: AudioStore;
let handler: ReturnType<typeof createHandler>;
beforeEach(() => { ctx = setup(); audio = new AudioStore(ctx.db); handler = createHandler({ db: ctx.db, token: ctx.config.token }); });
afterEach(() => ctx.cleanup());
// 仅用坐标轴上的合成向量和文本字节，不读取用户音频。
function vector(axis = 0, other = 0) { const v = Array<number>(512).fill(0); v[axis] = 1; if (other) v[1] = other; return v; }
function body(ref: string, seconds = 40, axis = 0, device = "mac") {
  return { device, conversation_ref: ref, t_start: "2026-11-09T01:00:00Z", t_end: "2026-11-09T01:03:00Z", speakers: [{ local: "S1", track: "mic", seconds, centroid: vector(axis) }] };
}
function upload(ref: string, seconds = 40, axis = 0, device = "mac") { return audio.embeddings(body(ref,seconds,axis,device)).speakers[0]!; }
function pending() { return new DistillStore(ctx.db).pending().filter(p => p.kind === "voice"); }
function resolve(action: string, axis = 0, name?: string, target?: string) {
  const s = upload(`resolve-${axis}`,120,axis);
  const p = pending().find(p => p.payload.speaker_id === s.speaker_id)!;
  new DistillStore(ctx.db).resolvePending(p.id,action,name,target);
  return s;
}
function call(path: string, method = "GET", data?: unknown) {
  return handler(new Request(`http://127.0.0.1:47823${path}`, { method, headers: { host: "127.0.0.1:47823", authorization: `Bearer ${ctx.config.token}`, "Content-Type": "application/json" }, ...(data === undefined ? {} : { body: JSON.stringify(data) }) }));
}

test("v4 加密库事务升级 v5，保留旧数据并可重复打开", () => {
  const record = fixture(); ctx.db.ingest([record]);
  ctx.db.db.exec("DROP TABLE speakers; DROP TABLE voice_embeddings; DROP TABLE voice_samples; DROP TABLE sample_requests; DROP TABLE audio_settings; PRAGMA user_version=4;");
  for (let i=0;i<2;i++) {
    const upgraded = new HubDB(ctx.file,ctx.config.dbKey);
    try {
      expect(upgraded.db.pragma("user_version",{ simple: true })).toBe(5);
      expect(upgraded.get(record.id)?.body).toBe(record.body);
      expect(new AudioStore(upgraded).settings()).toEqual({ retention_days: 7 });
    } finally { upgraded.close(); }
  }
});

test("跨对话按余弦聚类，同人归一、异人分开、中心按秒数归一化", () => {
  const a = upload("a",10);
  const b = body("b",30); b.speakers[0]!.centroid = vector(0,0.5);
  expect(audio.embeddings(b).speakers[0]!.speaker_id).toBe(a.speaker_id);
  expect(upload("c",10,2).speaker_id).not.toBe(a.speaker_id);
  const s = audio.speaker(a.speaker_id)!;
  expect(s.conversations).toBe(2); expect(s.seconds).toBe(40); expect(s.centroid.length).toBe(512*4);
  const v = new Float32Array(Uint8Array.from(s.centroid).buffer);
  const expected = 30 * 0.5 / Math.sqrt(1.25) / (10 + 30 / Math.sqrt(1.25));
  expect(v[1]! / v[0]!).toBeCloseTo(expected,6);
  expect(Math.hypot(...v)).toBeCloseTo(1,6);
});

test("3 段或 120 秒只提问一次，同对话重复上传与覆盖不增加次数", () => {
  const a = upload("one",10);
  upload("one",10); upload("one",20);
  expect(audio.speaker(a.speaker_id)?.seconds).toBe(20);
  expect(audio.speaker(a.speaker_id)?.conversations).toBe(1);
  upload("two",20); expect(pending()).toHaveLength(0);
  upload("three",30); upload("four",10);
  expect(pending()).toHaveLength(1);
  const requests = audio.sync("mac").sample_requests as { conversation_ref: string }[];
  expect(requests.map(r => r.conversation_ref).sort()).toEqual(["one","three","two"]);
  expect(pending()[0]!.payload).toMatchObject({ label: "说话人 A", conversations: 4, seconds: 80, samples: [], samples_pending: true });
  upload("long",120,2);
  expect(pending()).toHaveLength(2);
  expect(audio.sync("mac").voiceprint).toBeNull();
});

test("同对话多个标签归到同人只计一段，并只向相应设备请求样本", () => {
  const b = body("multi",60,0,"ipad"); b.speakers.push({ ...b.speakers[0]!, local: "S2" });
  const result = audio.embeddings(b);
  expect(result.speakers[0]!.speaker_id).toBe(result.speakers[1]!.speaker_id);
  expect(audio.speaker(result.speakers[0]!.speaker_id)?.conversations).toBe(1);
  expect(audio.sync("mac").sample_requests).toHaveLength(0);
  expect(audio.sync("ipad").sample_requests).toHaveLength(1);
});

test("me、rename、ignore 实际落库，标出我才下发 voiceprint，阈值取设置", () => {
  expect(audio.sync("mac").voiceprint).toBeNull();
  const a = resolve("me");
  expect(audio.speaker(a.speaker_id)).toMatchObject({ is_me: 1, name: "我", status: "confirmed" });
  expect(audio.sync("mac").voiceprint).toEqual({ vector: vector(), threshold: 0.49 });
  ctx.db.db.prepare("INSERT INTO audio_settings VALUES('me_threshold','0.61')").run();
  expect(audio.sync("mac").voiceprint?.threshold).toBe(0.61);
  const b = resolve("rename",2,"合成同事");
  const c = resolve("ignore",3);
  expect(audio.speaker(b.speaker_id)).toMatchObject({ name: "合成同事", status: "confirmed" });
  expect(audio.speaker(c.speaker_id)?.status).toBe("ignored");
  upload("ignored-again",120,3); expect(pending()).toHaveLength(0);
  expect(audio.sync("mac").sample_requests).toHaveLength(0);
  expect(audio.speakers().speakers.find(s => s.id === b.speaker_id)?.confirmed).toBe(true);
});

test("merge_into 重指向逐条声纹、按秒数加权中心并隐藏来源", () => {
  const a = resolve("me");
  const b = upload("merge-source",240,2);
  const p = pending()[0]!;
  const store = new DistillStore(ctx.db);
  for (const target of [b.speaker_id,"missing"]) expect(() => store.resolvePending(p.id,"merge_into",undefined,target)).toThrow();
  store.resolvePending(p.id,"merge_into",undefined,a.speaker_id);
  expect(audio.speaker(b.speaker_id)).toMatchObject({ status: "merged", merged_into: a.speaker_id });
  expect(audio.speaker(a.speaker_id)).toMatchObject({ seconds: 360, conversations: 2, is_me: 1 });
  const center = audio.sync("mac").voiceprint!.vector;
  expect(center[2]! / center[0]!).toBeCloseTo(2,6);
  expect((ctx.db.db.prepare("SELECT speaker_id FROM voice_embeddings WHERE conversation_ref='merge-source'").get() as { speaker_id: string }).speaker_id).toBe(a.speaker_id);
  expect(audio.speakers().speakers).toHaveLength(1);
  expect(pending()).toHaveLength(0);
});

test("多个我按秒数合并下发，已处理 pending 不可重用，非法操作回滚", () => {
  const first = upload("invalid",120);
  const p = pending()[0]!;
  for (const action of ["invalid","rename","merge_into"]) expect(() => new DistillStore(ctx.db).resolvePending(p.id,action)).toThrow();
  expect(audio.speaker(first.speaker_id)?.status).toBe("asked");
  new DistillStore(ctx.db).resolvePending(p.id,"me");
  resolve("me",2);
  const v = audio.sync("mac").voiceprint!.vector;
  expect(v[0]).toBeCloseTo(Math.SQRT1_2,6); expect(v[2]).toBeCloseTo(Math.SQRT1_2,6);
  expect(() => new DistillStore(ctx.db).resolvePending(p.id,"ignore")).toThrow();
});

test("样本上传、下载、重传和处理后删除，迟到上传不能恢复样本", async () => {
  upload("samples",120);
  const request = (audio.sync("mac").sample_requests as { id: string }[])[0]!;
  const payload = { request_id: request.id, clips: [{ mime: "audio/mp4", data: Buffer.from("合成样本字节").toString("base64") }] };
  expect((await call("/v1/audio/samples","POST",payload)).status).toBe(200);
  expect((await call("/v1/audio/samples","POST",payload)).status).toBe(200);
  const p = (await (await call("/v1/pending")).json()).pending[0];
  expect(p.payload.samples_pending).toBe(false); expect(p.payload.samples).toHaveLength(1);
  const sampleId = p.payload.samples[0].id;
  const response = await call(`/v1/audio/samples/${sampleId}`);
  expect(response.headers.get("content-type")).toBe("audio/mp4");
  expect(response.headers.get("cache-control")).toBe("no-store");
  expect(await response.text()).toBe("合成样本字节");
  expect((await call(`/v1/pending/${p.id}`,"POST",{ action: "me" })).status).toBe(200);
  expect((await call(`/v1/audio/samples/${sampleId}`)).status).toBe(404);
  expect((await call("/v1/audio/samples","POST",payload)).status).toBe(400);
  expect(audio.sync("mac").sample_requests).toHaveLength(0);
});

test("样本限制单段 2MB、MIME、base64 和每人最多三段，错误不部分写入", () => {
  upload("sample-limits",120);
  const request = (audio.sync("mac").sample_requests as { id: string }[])[0]!;
  const clip = { mime: "audio/wav", data: Buffer.from("synthetic").toString("base64") };
  for (const clips of [[],Array(4).fill(clip),[{ ...clip,mime: "text/html" }],[{ ...clip,data: "@@@@" }],[{ ...clip,data: "Zh==" }],[{ ...clip,data: Buffer.alloc(2*1024*1024+1).toString("base64") }]]) {
    expect(() => audio.uploadSamples({ request_id: request.id, clips })).toThrow();
  }
  expect(pending()[0]!.payload.samples).toEqual([]);
  expect(audio.uploadSamples({ request_id: request.id, clips: [{ ...clip,data: Buffer.alloc(2*1024*1024,1).toString("base64") }] }).uploaded).toBe(1);
  expect(audio.uploadSamples({ request_id: request.id, clips: Array(3).fill(clip) }).uploaded).toBe(3);
  // 再一个请求也不能突破说话人总数上限。
  ctx.db.db.prepare("INSERT INTO sample_requests(id,speaker_id,device,conversation_ref,local,created_at) SELECT 'extra',speaker_id,device,conversation_ref,local,created_at FROM sample_requests WHERE id=?").run(request.id);
  expect(() => audio.uploadSamples({ request_id: "extra", clips: [clip] })).toThrow();
});

test("删 mac.audio 联动声纹和样本、按设备下发删除，ack 后不再下发", async () => {
  const s = upload("delete-ref",120);
  const request = (audio.sync("mac").sample_requests as { id: string }[])[0]!;
  audio.uploadSamples({ request_id: request.id, clips: [{ mime: "audio/wav", data: "YWJj" }] });
  const sample = (pending()[0]!.payload.samples as { id: string }[])[0]!;
  const r = fixture({ source: "mac.audio", source_ref: "delete-ref", kind: "span", t_end: "2026-11-08T10:01:00+08:00" });
  ctx.db.ingest([r]);
  expect((await call(`/v1/records/${r.id}`,"DELETE")).status).toBe(200);
  expect(ctx.db.db.prepare("SELECT 1 FROM voice_embeddings WHERE conversation_ref=?").get("delete-ref")).toBeUndefined();
  expect(audio.sample(sample.id)).toBeUndefined();
  expect(audio.sync("mac").delete_conversations).toEqual(["delete-ref"]);
  expect(audio.sync("ipad").delete_conversations).toEqual([]);
  expect(audio.speaker(s.speaker_id)?.seconds).toBe(120);
  const reopened = new HubDB(ctx.file,ctx.config.dbKey);
  try { expect(new AudioStore(reopened).sync("mac").delete_conversations).toEqual(["delete-ref"]); } finally { reopened.close(); }
  expect((await call("/v1/audio/sync/ack","POST",{ device: "mac",deleted: ["unrelated"] })).status).toBe(200);
  expect(audio.sync("mac").delete_conversations).toEqual(["delete-ref"]);
  await call("/v1/audio/sync/ack","POST",{ device: "mac",deleted: ["delete-ref"] });
  expect(audio.sync("mac").delete_conversations).toEqual([]);
  expect(() => upload("delete-ref",120)).toThrow();
});

test("删除失败时声纹与下发队列和记录一起回滚", () => {
  upload("rollback",120);
  const r = fixture({ source: "mac.audio", source_ref: "rollback" }); ctx.db.ingest([r]);
  ctx.db.db.exec("CREATE TRIGGER fail_delete BEFORE DELETE ON records BEGIN SELECT RAISE(ABORT,'合成失败'); END;");
  expect(() => ctx.db.delete(r.id)).toThrow();
  expect(ctx.db.get(r.id)).not.toBeNull();
  expect(ctx.db.db.prepare("SELECT 1 FROM voice_embeddings WHERE conversation_ref='rollback'").get()).toBeDefined();
  expect(audio.sync("mac").delete_conversations).toEqual([]);
});

test("skipped 删除逐条声纹但保留说话人聚合中心，可重复调用", async () => {
  const s = upload("skip-ref",20);
  for (let i=0;i<2;i++) expect((await call("/v1/audio/conversations/skip-ref/skipped","POST")).status).toBe(200);
  expect(ctx.db.db.prepare("SELECT 1 FROM voice_embeddings").get()).toBeUndefined();
  expect(audio.speaker(s.speaker_id)).toMatchObject({ seconds: 20, conversations: 1 });
});

test("sync/settings/purge HTTP 及设备独立 ack，不用未来 ack 吞掉后续清理", async () => {
  expect(await (await call("/v1/audio/settings")).json()).toEqual({ retention_days: 7 });
  for (const value of [null,{}, { retention_days: "7" },{ retention_days: 0 },{ retention_days: 366 },{ retention_days: 1.5 }]) expect((await call("/v1/audio/settings","PUT",value)).status).toBe(400);
  expect(await (await call("/v1/audio/settings","PUT",{ retention_days: 365 })).json()).toEqual({ retention_days: 365 });
  const purge = await (await call("/v1/audio/purge","POST")).json();
  expect((await (await call("/v1/audio/sync?device=mac")).json()).purge_before).toBe(purge.purge_before);
  audio.ack({ device: "mac",purged_at: "2000-01-01T00:00:00Z" });
  expect(audio.sync("mac").purge_before).toBe(purge.purge_before);
  audio.ack({ device: "mac",purged_at: "2099-01-01T00:00:00Z" });
  expect(audio.sync("mac").purge_before).toBeNull();
  expect(audio.sync("ipad").purge_before).toBe(purge.purge_before);
  const next = new Date(Date.parse(purge.purge_before)+1000).toISOString();
  ctx.db.db.prepare("UPDATE audio_settings SET v=? WHERE k='purge_before'").run(JSON.stringify(next));
  expect(audio.sync("mac").purge_before).toBe(next);
  expect((await call("/v1/audio/sync")).status).toBe(400);
  for (const data of [{device:"mac",deleted:[1]},{device:"mac",purged_at:"bad"},{device:"../bad"}]) expect((await call("/v1/audio/sync/ack","POST",data)).status).toBe(400);
});

test("embeddings 校验维度、有限数、非负秒数、时间、设备、track 且全批回滚", async () => {
  for (const centroid of [[],Array(511).fill(1),Array(513).fill(1),Array(512).fill(0),Array(512).fill(NaN),Array(512).fill(Infinity),Array(512).fill(1e100)]) {
    const b = body("bad"); b.speakers[0]!.centroid = centroid;
    expect(() => audio.embeddings(b)).toThrow();
  }
  for (const change of [{seconds:-1},{seconds:NaN},{seconds:Infinity},{track:"invalid"}]) {
    const b = body("bad"); Object.assign(b.speakers[0]!,change); expect(() => audio.embeddings(b)).toThrow();
  }
  for (const change of [{device:"../bad"},{t_start:"no-date"},{t_end:"2020-01-01T00:00:00Z"},{speakers:[]}]) expect((await call("/v1/audio/embeddings","POST",{...body("bad"),...change})).status).toBe(400);
  const b = body("bad"); b.speakers.push({...b.speakers[0]!});
  expect(() => audio.embeddings(b)).toThrow();
  expect(audio.speakers().speakers).toHaveLength(0);
  expect((await call("/v1/audio/embeddings","POST",body("valid"))).status).toBe(200);
  expect((await call("/v1/speakers")).status).toBe(200);
  expect(() => upload("valid",40,0,"ipad")).toThrow();
});

test("所有音频端点沿用 Bearer 和 Host 校验", async () => {
  for (const [method,path] of [["GET","/v1/audio/sync?device=mac"],["POST","/v1/audio/sync/ack"],["POST","/v1/audio/embeddings"],["POST","/v1/audio/conversations/a/skipped"],["POST","/v1/audio/samples"],["GET","/v1/audio/samples/a"],["GET","/v1/audio/settings"],["PUT","/v1/audio/settings"],["POST","/v1/audio/purge"],["GET","/v1/speakers"]]) {
    expect((await handler(new Request(`http://127.0.0.1:47823${path}`,{method,headers:{host:"127.0.0.1:47823"}}))).status).toBe(401);
    expect((await handler(new Request(`http://127.0.0.1:47823${path}`,{method,headers:{host:"evil.invalid",authorization:`Bearer ${ctx.config.token}`}}))).status).toBe(421);
  }
});

test("音频按 source_ref 独立切片，优先于 repo/chat", () => {
  const a = fixture({source:"mac.audio",source_ref:"a",context:{repo:"/synthetic",chat:"same"}});
  const b = fixture({source:"mac.audio",source_ref:"b",context:{repo:"/synthetic",chat:"same"}});
  expect(frameKey(a)).toBe("audio:a");
  expect(sliceFrames([a,b],0,Date.parse(a.t_start)+3600000).frames.map(f => f.key).sort()).toEqual(["audio:a","audio:b"]);
});


test("多段中心及覆盖上传按逐条秒数重算，不反减已归一化的均值", () => {
  const first = upload("weighted-first",40);
  const second = body("weighted-second",40); second.speakers[0]!.centroid = vector(0,0.8);
  audio.embeddings(second);
  upload("weighted-first",80);
  const third = body("weighted-third",20); third.speakers[0]!.centroid = vector(0,0.2);
  audio.embeddings(third);
  const v = new Float32Array(Uint8Array.from(audio.speaker(first.speaker_id)!.centroid).buffer);
  const x = 80 + 40/Math.hypot(1,0.8) + 20/Math.hypot(1,0.2);
  const y = 40*0.8/Math.hypot(1,0.8) + 20*0.2/Math.hypot(1,0.2);
  expect(v[1]!/v[0]!).toBeCloseTo(y/x,6);
  expect(audio.speaker(first.speaker_id)).toMatchObject({seconds:140,conversations:3});
});

test("零秒声纹可归类并标我，下发仍是归一化向量", () => {
  upload("zero-one",0); upload("zero-two",0); upload("zero-three",0);
  const p = pending()[0]!;
  new DistillStore(ctx.db).resolvePending(p.id,"me");
  const voiceprint = audio.sync("mac").voiceprint!;
  expect(voiceprint.vector).toEqual(vector());
  expect(Math.hypot(...voiceprint.vector)).toBeCloseTo(1,6);
});
