import { afterEach, beforeEach, expect, test } from "bun:test";
import { AudioStore } from "../src/audio.ts";
import { HubDB } from "../src/db.ts";
import { DistillStore } from "../src/distill/store.ts";
import { frameKey, sliceFrames } from "../src/distill/frames.ts";
import { createHandler } from "../src/server.ts";
import { ulid } from "../../packages/record/index.ts";
import { fixture, setup } from "./helpers.ts";

let ctx: ReturnType<typeof setup>;
let audio: AudioStore;
let handler: ReturnType<typeof createHandler>;
let sampleStart: string;
let sampleEnd: string;
beforeEach(() => {
  ctx = setup(); audio = new AudioStore(ctx.db); handler = createHandler({ db: ctx.db, token: ctx.config.token });
  const recordedAt = Date.now() - 3_600_000;
  sampleStart = new Date(recordedAt).toISOString();
  sampleEnd = new Date(recordedAt + 180_000).toISOString();
});
afterEach(() => ctx.cleanup());
// 仅用坐标轴上的合成向量和文本字节，不读取用户音频。
function vector(axis = 0, other = 0) { const v = Array<number>(512).fill(0); v[axis] = 1; if (other) v[1] = other; return v; }
function body(ref: string, seconds = 40, axis = 0, device = "mac", track = "mic") {
  return { device, conversation_ref: ref, t_start: sampleStart, t_end: sampleEnd, speakers: [{ local: "S1", track, seconds, centroid: vector(axis) }] };
}
function upload(ref: string, seconds = 40, axis = 0, device = "mac", track = "mic") { return audio.embeddings(body(ref,seconds,axis,device,track)).speakers[0]!; }
function pending() { return new DistillStore(ctx.db).pending().filter(p => p.kind === "voice"); }
// 模拟升级前已积累的确认项，继续覆盖旧数据的确认、重命名与归并。
function legacyQuestion(speakerId: string) {
  const existing = pending().find(p => p.payload.speaker_id === speakerId);
  if (existing) return existing.id;
  const id = ulid();
  ctx.db.db.prepare("UPDATE speakers SET status='asked' WHERE id=? AND status='new'").run(speakerId);
  new DistillStore(ctx.db).createPending({ id, kind: "voice", payload: { speaker_id: speakerId }, created_at: new Date().toISOString() });
  return id;
}
function resolve(action: string, axis = 0, name?: string, target?: string) {
  const s = upload(`resolve-${axis}`,120,axis);
  new DistillStore(ctx.db).resolvePending(legacyQuestion(s.speaker_id),action,name,target);
  return s;
}
function call(path: string, method = "GET", data?: unknown) {
  return handler(new Request(`http://127.0.0.1:47823${path}`, { method, headers: { host: "127.0.0.1:47823", authorization: `Bearer ${ctx.config.token}`, "Content-Type": "application/json" }, ...(data === undefined ? {} : { body: JSON.stringify(data) }) }));
}

test("v4 加密库事务升级 v5，保留旧数据并可重复打开", () => {
  const record = fixture(); ctx.db.ingest([record]);
  ctx.db.db.exec("DROP TABLE speakers; DROP TABLE voice_embeddings; DROP TABLE voice_samples; DROP TABLE sample_requests; DROP TABLE audio_settings; DROP TABLE runtime_calls; PRAGMA user_version=4;");
  for (let i=0;i<2;i++) {
    const upgraded = new HubDB(ctx.file,ctx.config.dbKey);
    try {
      expect(upgraded.db.pragma("user_version",{ simple: true })).toBe(11);
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

test("系统声音 3 段且至少 30 秒或 120 秒只提问一次，同对话重复上传与覆盖不增加次数", () => {
  const sys = (ref: string, seconds: number, axis = 0) => upload(ref,seconds,axis,"mac","sys");
  const a = sys("one",10);
  sys("one",10); sys("one",20);
  expect(audio.speaker(a.speaker_id)?.seconds).toBe(20);
  expect(audio.speaker(a.speaker_id)?.conversations).toBe(1);
  sys("two",20); expect(pending()).toHaveLength(0);
  sys("three",30); sys("four",10);
  expect(pending()).toHaveLength(1);
  const requests = audio.sync("mac").sample_requests as { conversation_ref: string }[];
  expect(requests.map(r => r.conversation_ref).sort()).toEqual(["one","three","two"]);
  expect(pending()[0]!.payload).toMatchObject({ label: "说话人 A", conversations: 4, seconds: 80, samples: [], samples_pending: true });
  const long = sys("long",120,2);
  expect(pending()).toHaveLength(1);
  new DistillStore(ctx.db).resolvePending(pending()[0]!.id,"ignore");
  expect(audio.sync("mac").voiceprint).toBeNull();
  expect(pending().map(p => p.payload.speaker_id)).toEqual([long.speaker_id]);
});

test("麦克风说话人 2 段且至少 15 秒或 45 秒提问；同步时补问", () => {
  upload("m1",10); expect(pending()).toHaveLength(0);
  upload("m2",10); expect(pending()).toHaveLength(1);
  const long = upload("long-mic",45,2); expect(pending()).toHaveLength(1);
  const store = new DistillStore(ctx.db);
  store.resolvePending(pending()[0]!.id,"ignore");
  audio.sync("mac");
  expect(pending().map(p => p.payload.speaker_id)).toEqual([long.speaker_id]);
  store.resolvePending(pending()[0]!.id,"ignore");
  // 模拟旧门槛下已累计到 2 段、但一直没被问的麦克风说话人。
  const old = upload("old-1",15,3);
  ctx.db.db.prepare("UPDATE speakers SET conversations=2 WHERE id=?").run(old.speaker_id);
  expect(pending().some(p => p.payload.speaker_id === old.speaker_id)).toBe(false);
  audio.sync("mac");
  expect(pending().some(p => p.payload.speaker_id === old.speaker_id)).toBe(true);
});

test("只排队一次本人确认，已有本人声纹时不再产生新声音确认", () => {
  const me = upload("initial-self", 45);
  const other = upload("another-eligible", 45, 2);
  expect(pending().map(p => p.payload.speaker_id)).toEqual([me.speaker_id]);
  const queue = new DistillStore(ctx.db);
  queue.resolvePending(pending()[0]!.id, "me");
  upload("eligible-after-me", 45, 3);
  expect(audio.sync("mac").voiceprint).not.toBeNull();
  expect(pending()).toEqual([]);
  expect(audio.speaker(other.speaker_id)?.status).toBe("new");
  expect(audio.speaker(me.speaker_id)?.status).toBe("confirmed");
});

test.each([
  ["mic", 2, 14, false], ["mic", 2, 15, true],
  ["mic", 1, 44, false], ["mic", 1, 45, true],
  ["sys", 3, 29, false], ["sys", 3, 30, true],
  ["sys", 1, 119, false], ["sys", 1, 120, true],
] as const)("新声音门槛：%s %i 段累计 %i 秒，提问=%p", (track, conversations, seconds, asked) => {
  let id = "";
  for (let i = 0; i < conversations; i++) {
    id = upload(`boundary-${i}`, i === 0 ? seconds : 0, 0, "mac", track).speaker_id;
  }
  expect(audio.speaker(id)).toMatchObject({ conversations, seconds, status: asked ? "asked" : "new" });
  audio.sync("mac");
  expect(pending()).toHaveLength(asked ? 1 : 0);
});

test("skipped 清掉全部逐条声纹后，同步及系统声音上传仍按麦克风门槛", () => {
  const a = upload("mic-skipped",20);
  audio.skipped("mic-skipped");
  expect(ctx.db.db.prepare("SELECT 1 FROM voice_embeddings").get()).toBeUndefined();
  // 模拟仍未提问但已累计两段的旧说话人，sync 没有逐条声纹可查。
  ctx.db.db.prepare("UPDATE speakers SET conversations=2 WHERE id=?").run(a.speaker_id);
  audio.sync("mac");
  expect(pending().some(p => p.payload.speaker_id === a.speaker_id)).toBe(true);
  new DistillStore(ctx.db).resolvePending(pending()[0]!.id,"ignore");

  const b = upload("mic-before-sys",14,2);
  audio.skipped("mic-before-sys");
  expect(pending().some(p => p.payload.speaker_id === b.speaker_id)).toBe(false);
  expect(upload("sys-after-skip",1,2,"mac","sys").speaker_id).toBe(b.speaker_id);
  expect(pending().some(p => p.payload.speaker_id === b.speaker_id)).toBe(true);
});

test("麦克风碎片并入系统声音说话人后保留来源", () => {
  const b = body("mixed-tracks",11,0,"mac","sys");
  const mic = vector(2); mic[0] = 0.4; mic[2] = Math.sqrt(0.84);
  b.speakers.push({ local: "S2", track: "mic", seconds: 4, centroid: mic });
  const result = audio.embeddings(b).speakers;
  expect(result[0]!.speaker_id).toBe(result[1]!.speaker_id);
  const id = result[0]!.speaker_id;
  expect(audio.speaker(id)).toMatchObject({ mic: 1, seconds: 15, conversations: 1, status: "new" });
  audio.skipped("mixed-tracks");
  expect(upload("merged-sys",0,0,"mac","sys").speaker_id).toBe(id);
  expect(pending().some(p => p.payload.speaker_id === id)).toBe(true);
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
  const id = legacyQuestion(b.speaker_id);
  const store = new DistillStore(ctx.db);
  for (const target of [b.speaker_id,"missing"]) expect(() => store.resolvePending(id,"merge_into",undefined,target)).toThrow();
  store.resolvePending(id,"merge_into",undefined,a.speaker_id);
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

test("样本带上录到的时间和这个人当时说的话", async () => {
  // 用户报告：只有一段模糊录音时认不出是谁，需要时间和当时说的话来对照。
  const s = upload("context-ref",120);
  ctx.db.ingest([fixture({ source: "mac.audio", source_ref: "context-ref", t_start: sampleStart,
    title: "对话 · 10:00–10:03 · 说话人 A、我",
    body: "[10:00:02] 我：先过一下进度\n[10:00:09] 说话人 A：这个方案下周再定，我先把数据补齐" })]);
  const request = (audio.sync("mac").sample_requests as { id: string }[])[0]!;
  audio.uploadSamples({ request_id: request.id, clips: [{ mime: "audio/wav", data: Buffer.from("x").toString("base64") }] });
  const sample = (pending()[0]!.payload.samples as { at?: string; said?: string }[])[0]!;
  expect(sample.at).toBe(sampleStart);
  expect(sample.said).toBe("这个方案下周再定，我先把数据补齐");
  // 对话记录里的说话人写法是转写当时的标签，填了名字后也认得出来。
  audio.resolve(s.speaker_id, "rename", "刘朝刚");
  expect(pending()).toHaveLength(0);
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
  for (const value of [null,{}, { retention_days: "7" },{ retention_days: -1 },{ retention_days: 366 },{ retention_days: 1.5 }]) expect((await call("/v1/audio/settings","PUT",value)).status).toBe(400);
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
  expect(pending()).toHaveLength(0);
  // 零秒声纹仍可归类，补足有效时长后才进待确认。
  upload("zero-four",45);
  const p = pending()[0]!;
  new DistillStore(ctx.db).resolvePending(p.id,"me");
  const voiceprint = audio.sync("mac").voiceprint!;
  expect(voiceprint.vector).toEqual(vector());
  expect(Math.hypot(...voiceprint.vector)).toBeCloseTo(1,6);
});

// 2026-11-11 实测：和李家辰两个人的对话被拆成 70 个"说话人"，界面上出现一串"对方 1""对方 2"。
test("一段对话里拆碎的说话人并回确认过的人；确认过的不同人不并；在别的对话出现过的要整体像才并", () => {
  const v = (x: number, y = 0, z = 0) => { const a = Array<number>(512).fill(0); a[0] = x; a[1] = y; a[2] = z; return a; };
  const conv = (ref: string, speakers: { local: string; seconds: number; centroid: number[] }[]) =>
    audio.embeddings({ device: "mac", conversation_ref: ref, t_start: "2026-11-11T07:46:00Z", t_end: "2026-11-11T08:17:00Z", speakers: speakers.map(s => ({ ...s, track: "mic" })) }).speakers;
  // 先有两个确认过的人
  const [me, li] = conv("seed", [{ local: "S1", seconds: 200, centroid: v(1) }, { local: "S2", seconds: 200, centroid: v(0, 1) }]);
  for (const [s, name] of [[me!, "我"], [li!, "李家辰"]] as const) {
    new DistillStore(ctx.db).resolvePending(legacyQuestion(s.speaker_id), name === "我" ? "me" : "rename", name === "我" ? undefined : name);
  }
  // 新的一段：一个长的"我"、一个长的李家辰（中心偏一点，没对上），加几个短窗口
  const out = conv("talk", [
    { local: "S1", seconds: 120, centroid: v(1, 0.1) }, { local: "S2", seconds: 90, centroid: v(0.2, 1, 0.9) },
    { local: "S3", seconds: 3, centroid: v(0.8, 0.5) }, { local: "S4", seconds: 2, centroid: v(0.3, 1, 0.6) }, { local: "S5", seconds: 2, centroid: v(0, 0, -1) },
  ]);
  const names = Object.fromEntries(out.map(s => [s.local, s.is_me ? "我" : s.label]));
  expect(names.S1).toBe("我"); expect(names.S3).toBe("我");
  // S2 那个长的没对上李家辰（相似度不到 0.5）时自成一个人，短的 S4 跟它走；S5 谁都不像，留着。
  expect(names.S4).toBe(names.S2);
  expect(names.S5).not.toBe(names.S2);
  // 已确认的人不会被并走
  expect(audio.speaker(li!.speaker_id)!.status).toBe("confirmed");
  expect(audio.speaker(me!.speaker_id)!.status).toBe("confirmed");
});

test("同名的已确认说话人并成一个，“我”按 is_me 并", () => {
  const vec = (axis: number) => { const a = Array<number>(512).fill(0); a[axis] = 1; return a; };
  const ids = [3, 4, 5, 6].map(axis => audio.embeddings({ device: "mac", conversation_ref: `n${axis}`, t_start: "2026-11-11T01:00:00Z", t_end: "2026-11-11T01:10:00Z", speakers: [{ local: "S1", track: "mic", seconds: 60 * axis, centroid: vec(axis) }] }).speakers[0]!.speaker_id);
  const decide = (id: string, action: string, name?: string) => new DistillStore(ctx.db).resolvePending(legacyQuestion(id), action, name);
  decide(ids[0]!, "rename", "刘朝刚"); decide(ids[1]!, "rename", " 刘朝刚 "); decide(ids[2]!, "me"); decide(ids[3]!, "me");
  // 确认时就已并好，再整理一遍没有可并的。
  expect(audio.mergeSameNames()).toBe(0);
  const active = audio.speakers().speakers.filter(s => s.confirmed);
  expect(active.map(s => s.name).sort()).toEqual(["刘朝刚", "我"].sort());
  expect(active.find(s => s.name === "刘朝刚")!.seconds).toBe(60 * 3 + 60 * 4);
});

test("录音过了保留期的试听请求删掉，不再显示还在路上", () => {
  upload("old-ref", 120);
  const before = (audio.sync("mac").sample_requests as unknown[]).length;
  expect(before).toBe(1);
  audio.expireSampleRequests(Date.parse(sampleEnd) + 8 * 86_400_000);
  expect(audio.sync("mac").sample_requests).toHaveLength(0);
  expect(pending()[0]!.payload.samples_pending).toBe(false);
});

// 回归（2026-11-12）：跳过的对话留下 217 个没有声纹的未确认说话人，一直参与匹配、永远到不了待确认。
test("没有逐条声纹的未确认碎片和过了保留期的空壳删掉，编号不重用", () => {
  const tiny = upload("tiny-skip",3,5), kept = upload("kept-skip",20,6);
  audio.skipped("tiny-skip"); audio.skipped("kept-skip");
  expect(audio.speaker(tiny.speaker_id)).toBeUndefined();
  expect(audio.speaker(kept.speaker_id)).toMatchObject({ seconds: 20, status: "new" });
  // 过了保留期的空壳在同步时清掉。
  ctx.db.db.prepare("UPDATE speakers SET updated_at='2026-01-01T00:00:00Z' WHERE id=?").run(kept.speaker_id);
  audio.sync("mac");
  expect(audio.speaker(kept.speaker_id)).toBeUndefined();
  const labels = new Set([tiny.label, kept.label]);
  expect(labels.has(upload("after-prune",40,7).label)).toBe(false);
});

// 回归（2026-11-12）：用户标了 8 次"我"，之后标的不会并到已有的"我"上，最后剩 3 个。
test("再标一次我、或起了已有的名字，并到已确认的那个人", () => {
  const first = resolve("me",0), second = resolve("me",2);
  expect(audio.speaker(second.speaker_id)).toMatchObject({ status: "merged", merged_into: first.speaker_id });
  const a = resolve("rename",3,"李家辰"), b = resolve("rename",4,"李家辰");
  expect([audio.speaker(a.speaker_id)!.status, audio.speaker(b.speaker_id)!.status].sort()).toEqual(["confirmed","merged"]);
  expect(audio.speakers().speakers.filter(s => s.is_me)).toHaveLength(1);
});


test("不自动清除通过 HTTP 保存并同步，旧录音试听请求仍可获取，手动清理仍生效", async () => {
  expect(await (await call("/v1/audio/settings", "PUT", { retention_days: 0 })).json()).toEqual({ retention_days: 0 });
  const speaker = upload("unlimited-old", 120);
  const afterRetention = Date.parse(sampleEnd) + 8 * 86_400_000;
  audio.expireSampleRequests(afterRetention);
  expect(audio.pendingPayload(speaker.speaker_id)?.samples_pending).toBe(true);
  expect(audio.sync("mac").retention_days).toBe(0);
  const purge = await (await call("/v1/audio/purge", "POST")).json();
  expect(audio.sync("mac").purge_before).toBe(purge.purge_before);
  audio.updateSettings({ retention_days: 7 });
  audio.expireSampleRequests(afterRetention);
  expect(audio.pendingPayload(speaker.speaker_id)?.samples_pending).toBe(false);
});
