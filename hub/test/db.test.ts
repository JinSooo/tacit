import { afterEach, beforeEach, expect, test } from "bun:test";
import { readFileSync, writeFileSync } from "node:fs";
import { AudioStore } from "../src/audio.ts";
import { HubDB } from "../src/db.ts";
import { fixture, setup } from "./helpers.ts";
import { ulid } from "../../packages/record/index.ts";

let ctx: ReturnType<typeof setup>;
beforeEach(() => { ctx = setup(); });
afterEach(() => ctx.cleanup());

test("SQLCipher 实际文件加密，错误密钥拒绝，正确密钥重开及迁移版本保留", () => {
  const record = fixture();
  ctx.db.ingest([record]);
  expect(readFileSync(ctx.file).subarray(0, 16).toString()).not.toStartWith("SQLite format 3");
  expect(() => new HubDB(ctx.file, "wrong-key")).toThrow();
  const reopened = new HubDB(ctx.file, ctx.config.dbKey);
  try {
    expect(reopened.get(record.id)?.body).toBe(record.body);
    expect(reopened.db.pragma("user_version", { simple: true })).toBe(11);
  } finally { reopened.close(); }
});

test("逐条校验、id 和来源键幂等，不影响批内其他记录", () => {
  const a = fixture({ source: "mac.browser", source_ref: "visit-1" });
  const b = fixture();
  const result = ctx.db.ingest([a, a, fixture({ source: a.source, source_ref: a.source_ref }), { ...fixture(), kind: "span" }, b]);
  expect(result.accepted).toBe(2);
  expect(result.duplicates).toBe(2);
  expect(result.rejected).toHaveLength(1);
  expect(result.rejected[0]?.index).toBe(3);
  expect(ctx.db.get(b.id)?.t_received).toBeString();
  expect(ctx.db.ingest([a]).duplicates).toBe(1);
});

test("真实删除记录和全文索引，仅留无内容墓碑，双重身份不能重放", () => {
  const a = fixture({ title: "唯一删除标题", body: "删除秘密正文", source_ref: "synthetic-ref" });
  ctx.db.ingest([a]);
  expect(ctx.db.list(new URLSearchParams({ q: "删除" })).records).toHaveLength(1);
  expect(ctx.db.delete(a.id)).toBe(true);
  expect(ctx.db.get(a.id)).toBeNull();
  const decrypted = ctx.db.db.serialize();
  expect(decrypted.includes(Buffer.from(a.title))).toBe(false);
  expect(decrypted.includes(Buffer.from(a.body))).toBe(false);
  expect(ctx.db.list(new URLSearchParams({ q: "删除" })).records).toHaveLength(0);
  expect(ctx.db.db.prepare("SELECT count(*) n FROM records_fts").get()).toEqual({ n: 0 });
  const tombstone = ctx.db.db.prepare("SELECT * FROM tombstones").get() as Record<string, unknown>;
  expect(Object.keys(tombstone).sort()).toEqual(["content_hash", "deleted_at", "id", "source", "source_ref"]);
  expect(tombstone.content_hash).toMatch(/^[a-f0-9]{64}$/);
  expect(JSON.stringify(tombstone)).not.toContain(a.title);
  expect(ctx.db.ingest([{ ...a, source_ref: "new-ref" }, { ...a, id: ulid() }])).toEqual({ accepted: 0, duplicates: 2, rejected: [] });
  expect(ctx.db.delete(a.id)).toBe(false);
});

test("修正挂在原记录上，原文保持不变", () => {
  const original = fixture();
  const correction = fixture({ source: "manual.correction", corrects: original.id, body: "合成修正内容", capture: { method: "manual" } });
  ctx.db.ingest([original, correction]);
  expect(ctx.db.get(original.id)?.body).toBe(original.body);
  expect(ctx.db.get(original.id)?.corrections.map(r => r.id)).toEqual([correction.id]);
});

// 回归：删除原记录后修正记录曾残留（2026-11-08 验收发现）；修正是关于原记录的内容，必须一起真删。
test("删除原记录时连带删除其修正，修正也留墓碑且搜不到", () => {
  const original = fixture();
  const correction = fixture({ source: "manual.correction", corrects: original.id, body: "合成修正独有词汇", capture: { method: "manual" } });
  ctx.db.ingest([original, correction]);
  expect(ctx.db.delete(original.id)).toBe(true);
  expect(ctx.db.get(correction.id)).toBeNull();
  expect(ctx.db.list(new URLSearchParams({ q: "独有词汇" })).records).toHaveLength(0);
  expect(ctx.db.ingest([correction]).duplicates).toBe(1);
});

test("跨时区时间排序、同时间分页、所有过滤条件和默认正文隐藏", () => {
  const records = [
    fixture({ t_start: "2026-11-08T09:00:00+08:00", source: "mac.browser", source_ref: "filter-1" }),
    fixture({ t_start: "2026-11-08T02:00:00Z", source: "mac.browser", source_ref: "filter-2" }),
    fixture({ t_start: "2026-11-08T02:00:00Z", device: "tablet" }),
    fixture({ t_start: "2026-11-08T02:30:00Z" }),
  ];
  ctx.db.ingest(records);
  const ids: string[] = [];
  let cursor: string | null = null;
  do {
    const params = new URLSearchParams({ limit: "1", ...(cursor ? { cursor } : {}) });
    const page = ctx.db.list(params);
    expect(page.records[0]).not.toHaveProperty("body");
    ids.push(page.records[0]!.id!); cursor = page.next_cursor;
  } while (cursor);
  expect(ids).toEqual([...records].sort((a, b) => Date.parse(b.t_start) - Date.parse(a.t_start) || b.id.localeCompare(a.id)).map(r => r.id));
  const filtered = ctx.db.list(new URLSearchParams({ device: "mac", source: "mac.browser", from: "2026-11-08T10:00:00+08:00", to: "2026-11-08T02:15:00Z", body: "1" }));
  expect(filtered.records.map(r => r.id)).toEqual([records[1]!.id]);
  expect(filtered.records[0]?.body).toBe(records[1]?.body);
  const invalidParams: Record<string, string>[] = [{ limit: "0" }, { limit: "501" }, { cursor: "invalid" }, { from: "invalid" }];
  for (const params of invalidParams) expect(() => ctx.db.list(new URLSearchParams(params))).toThrow();
});

// 保留 00-storage 实验的全部 11 个查询，正文为合成 fixture。
const docs = [
  "下午和张三讨论华刚大屏的 mock 数据，决定换节点",
  "在 Cursor 里修改 ruilin-mock 的 mock.ts，提交了 3 个文件",
  "微信项目群：明天上午十点开会，记得带上设计稿",
  "浏览 Graphiti 文档，了解双时态知识图谱",
];
const queries = ["节点", "大屏", "开会", "设计稿", "双时态", "mock", "ruilin", "张三", "华刚大屏", "大屏的mock", "十点开会"];
for (const q of queries) test(`实验 bigram 查询：${q}`, () => {
  const records = docs.map(body => fixture({ body }));
  ctx.db.ingest(records);
  const actual = ctx.db.list(new URLSearchParams({ q })).records.map(r => r.id).sort();
  const expected = records.filter(r => r.body.replace(/\s/g, "").includes(q)).map(r => r.id).sort();
  expect(actual).toEqual(expected);
});

test("索引标题、单字 LIKE 回退、搜索引号和语法不报错", () => {
  const r = fixture({ title: "宇宙探测", body: "其他正文" });
  ctx.db.ingest([r]);
  for (const q of ["宇宙", "宇"]) expect(ctx.db.list(new URLSearchParams({ q })).records.map(r => r.id)).toEqual([r.id]);
  for (const q of ['"', "OR NOT", "*", "NEAR(宇宙)"]) expect(() => ctx.db.list(new URLSearchParams({ q }))).not.toThrow();
});

test("来源稳定键、修正目标和不可排序的日期逐条拒绝", () => {
  const invalid = [
    fixture({ source: "mac.browser" }), fixture({ source: "manual.correction" }),
    fixture({ t_start: "2016-12-31T23:59:60Z" }),
  ];
  const result = ctx.db.ingest([...invalid, fixture()]);
  expect(result.accepted).toBe(1);
  expect(result.rejected.map(r => r.index)).toEqual([0, 1, 2]);
});

// 两个进程都先读到旧版本，再同时继续，稳定覆盖旧版本快照竞争。
test("两个子进程并发迁移 v2，等锁后复读版本并跳过已完成迁移（10 次）", async () => {
  const script = new URL("./fixtures/migrate-worker.ts", import.meta.url).pathname;
  for (let round = 0; round < 10; round++) {
    ctx.db.db.exec("DROP TABLE speakers; DROP TABLE voice_embeddings; DROP TABLE voice_samples; DROP TABLE sample_requests; DROP TABLE audio_settings; DROP TABLE agent_reads; DROP TABLE distill_requests; ALTER TABLE threads DROP COLUMN domain; ALTER TABLE threads DROP COLUMN project_hint; DROP TABLE runtime_calls; PRAGMA user_version=2;");
    const gate = `${ctx.dir}/gate-${round}`;
    const children = [0, 1].map(index => Bun.spawn([process.execPath, script, ctx.file, ctx.config.dbKey, gate, String(index)], { stdout: "pipe", stderr: "pipe" }));
    try {
      const deadline = Date.now() + 10000;
      while (![0, 1].every(i => { try { return readFileSync(`${gate}-${i}`, "utf8") === "ready"; } catch { return false; } })) {
        if (Date.now() > deadline) throw new Error("迁移子进程未就绪");
        await Bun.sleep(10);
      }
      writeFileSync(gate, "go");
      const results = await Promise.all(children.map(async child => ({ code: await child.exited, error: await new Response(child.stderr).text(), output: await new Response(child.stdout).text() })));
      expect(results).toEqual([{ code: 0, error: "", output: "11\n" }, { code: 0, error: "", output: "11\n" }]);
      expect(ctx.db.db.pragma("user_version", { simple: true })).toBe(11);
      expect(ctx.db.db.pragma("table_info(threads)")).toEqual(expect.arrayContaining([expect.objectContaining({ name: "domain" }), expect.objectContaining({ name: "project_hint" })]));
      expect(ctx.db.db.pragma("table_info(agent_reads)")).toHaveLength(8);
      expect(ctx.db.db.prepare("SELECT name FROM sqlite_master WHERE type='index' AND name LIKE 'agent_reads_%'").all()).toHaveLength(2);
    } finally {
      for (const child of children) child.kill();
      await Promise.all(children.map(child => child.exited));
    }
  }
}, 30000);

test("v8 用量升级到 v9：task 列可空，旧行不变，重开幂等", () => {
  ctx.db.db.exec("ALTER TABLE llm_usage DROP COLUMN task; DROP TABLE runtime_calls; PRAGMA user_version=8;");
  ctx.db.db.prepare("INSERT INTO llm_usage(id, tier, input_tokens, ok) VALUES(?,?,?,?)").run("legacy-usage", "hour", 123, 1);
  for (let i = 0; i < 2; i++) {
    const upgraded = new HubDB(ctx.file, ctx.config.dbKey);
    try {
      expect(upgraded.db.pragma("user_version", { simple: true })).toBe(11);
      expect((upgraded.db.pragma("table_info(llm_usage)") as { name: string; type: string }[]).filter(c => c.name === "task")).toMatchObject([{ name: "task", type: "TEXT" }]);
      expect(upgraded.db.prepare("SELECT id,tier,input_tokens,ok,task FROM llm_usage WHERE id=?").get("legacy-usage")).toEqual({ id: "legacy-usage", tier: "hour", input_tokens: 123, ok: 1, task: null });
    } finally { upgraded.close(); }
  }
});

test("v9 声纹升级 v10：mic 列按现有声纹回填，重开及已有列幂等", () => {
  const audio = new AudioStore(ctx.db);
  const add = (ref: string, track: string, axis: number) => {
    const centroid = Array<number>(512).fill(0); centroid[axis] = 1;
    return audio.embeddings({ device: "mac", conversation_ref: ref,
      t_start: "2026-11-12T01:00:00Z", t_end: "2026-11-12T01:03:00Z",
      speakers: [{ local: "S1", track, seconds: 10, centroid }] }).speakers[0]!.speaker_id;
  };
  const mic = add("legacy-mic", "mic", 0), sys = add("legacy-sys", "sys", 2);
  add("legacy-mixed", "sys", 0);
  // 还原 v9 结构，保留真实声纹行供升级回填。
  if ((ctx.db.db.pragma("table_info(speakers)") as { name: string }[]).some(c => c.name === "mic")) {
    ctx.db.db.exec("ALTER TABLE speakers DROP COLUMN mic;");
  }
  ctx.db.db.exec("DROP TABLE runtime_calls; PRAGMA user_version=9;");
  for (let i = 0; i < 3; i++) {
    const upgraded = new HubDB(ctx.file, ctx.config.dbKey);
    try {
      expect(upgraded.db.pragma("user_version", { simple: true })).toBe(11);
      expect((upgraded.db.pragma("table_info(speakers)") as { name: string }[]).filter(c => c.name === "mic"))
        .toMatchObject([{ name: "mic", type: "INTEGER", notnull: 1, dflt_value: "0" }]);
      expect(upgraded.db.prepare("SELECT mic FROM speakers WHERE id=?").get(mic)).toEqual({ mic: 1 });
      expect(upgraded.db.prepare("SELECT mic FROM speakers WHERE id=?").get(sys)).toEqual({ mic: 0 });
      // 已有列但版本号尚旧时也能迁移；声纹清理后重开不能丢掉 mic。
      upgraded.db.prepare("DELETE FROM voice_embeddings WHERE track='mic'").run();
      if (i === 0) upgraded.db.exec("DROP TABLE runtime_calls; PRAGMA user_version=9;");
    } finally { upgraded.close(); }
  }
});
