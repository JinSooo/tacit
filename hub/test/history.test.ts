import { afterEach, beforeEach, expect, test } from "bun:test";
import { createHandler } from "../src/server.ts";
import { DistillStore } from "../src/distill/store.ts";
import { unionSeconds } from "../src/history.ts";
import { fixture, setup } from "./helpers.ts";

let ctx: ReturnType<typeof setup>;
let handler: ReturnType<typeof createHandler>;
beforeEach(() => { ctx = setup(); handler = createHandler({ db: ctx.db, token: ctx.config.token }); });
afterEach(() => ctx.cleanup());
function call(path: string, auth = true) {
  return handler(new Request("http://127.0.0.1:47823" + path, { headers: { host: "127.0.0.1:47823", ...(auth ? { authorization: `Bearer ${ctx.config.token}` } : {}) } }));
}
const at = (hhmm: string) => `2026-11-08T${hhmm}:00+08:00`;
const day = `from=${encodeURIComponent(at("00:00"))}&to=${encodeURIComponent("2026-11-08T23:59:59.999+08:00")}`;

test("活动段：同一线程接得上的片段合成一段，未提炼的按应用临时分组", async () => {
  const store = new DistillStore(ctx.db);
  // 线程 A：编辑器 10:00–10:20，浏览器 10:25–10:30（不同片段，同一线程）；13:00 又回到线程 A，间隔太久另起一段。
  // 屏幕记录标题是"应用名 · 窗口"，应用名作为网页显示名。
  const editor = fixture({ kind: "span", title: "合成编辑器 · 文件甲", t_start: at("10:00"), t_end: at("10:20"), context: { app: "com.synthetic.editor" } });
  const browser = fixture({ source: "mac.browser", source_ref: "synthetic-visit-1", t_start: at("10:25"), t_end: at("10:30"), context: { app: "com.synthetic.browser", url: "https://example.com/a" } });
  const later = fixture({ kind: "span", t_start: at("13:00"), t_end: at("13:05"), context: { app: "com.synthetic.editor" } });
  // 未提炼：聊天 10:02–10:04、10:08–10:10 合成一段；私密记录照常列出，只计数。
  const chat1 = fixture({ kind: "span", t_start: at("10:02"), t_end: at("10:04"), context: { app: "com.synthetic.chat" } });
  const chat2 = fixture({ kind: "span", t_start: at("10:08"), t_end: at("10:10"), context: { app: "com.synthetic.chat" }, sensitivity: "private" });
  const shell = fixture({ device: "mac-abcd2345", source: "mac.shell", source_ref: "synthetic-shell-1", t_start: at("10:09") });
  const other = fixture({ device: "phone", t_start: at("10:03"), context: { app: "com.synthetic.chat" } });
  const yesterday = fixture({ t_start: "2026-11-07T23:00:00+08:00" });
  expect(ctx.db.ingest([editor, browser, later, chat1, chat2, shell, other, yesterday]).accepted).toBe(8);
  store.upsertProject({ id: "p", name: "合成项目", keys: { repos: [], hosts: [], chats: [] } });
  store.upsertThread({ id: "ta", title: "合成线程甲", brief: "在写合成功能", status: "active", project_id: "p" });
  for (const [fid, rec] of [["f1", editor], ["f2", browser], ["f3", later]] as const) {
    store.createFrame({ id: fid, key: "synthetic", record_ids: [rec.id], t_start_ms: Date.parse(rec.t_start), t_end_ms: Date.parse(rec.t_end!), chars: 1, private: 0, status: "new" });
    store.assign(fid, "ta", "rule", 1);
  }
  // 已切片但还没归属线程的片段也算未提炼。
  store.createFrame({ id: "f4", key: "synthetic", record_ids: [chat1.id], t_start_ms: Date.parse(chat1.t_start), t_end_ms: Date.parse(chat1.t_end!), chars: 1, private: 0, status: "new" });

  expect((await call(`/v1/history/segments?${day}`, false)).status).toBe(401);
  const res = await call(`/v1/history/segments?${day}&device=mac`);
  expect(res.status).toBe(200);
  const { segments } = await res.json();
  // 新的在前：13:00 线程甲、10:09 终端、10:02 聊天、10:00 线程甲。
  expect(segments.map((s: any) => [s.kind, s.record_ids])).toEqual([
    ["thread", [later.id]], ["app", [shell.id]], ["app", [chat1.id, chat2.id]], ["thread", [editor.id, browser.id]],
  ]);
  const main = segments[3];
  expect(main.thread).toEqual({ id: "ta", title: "合成线程甲", brief: "在写合成功能", status: "active", domain: null, project_id: "p", project_name: "合成项目" });
  expect(main.start_ms).toBe(Date.parse(at("10:00")));
  expect(main.end_ms).toBe(Date.parse(at("10:30")));
  expect(main.active_seconds).toBe(25 * 60);
  expect(main.apps).toEqual([
    { app: "com.synthetic.editor", name: "合成编辑器", source: "mac.screen", records: 1, seconds: 20 * 60 },
    { app: "com.synthetic.browser", name: null, source: "mac.browser", records: 1, seconds: 5 * 60 },
  ]);
  const chat = segments[2];
  expect(chat.thread).toBeNull();
  expect(chat.private).toBe(1);
  expect(chat.active_seconds).toBe(4 * 60);
  // 没有 context.app 的记录按来源归类。
  expect(segments[1].apps).toEqual([{ app: null, name: null, source: "mac.shell", records: 1, seconds: 0 }]);

  // 不带 device 时包含其他设备的记录。
  const all = await (await call(`/v1/history/segments?${day}`)).json();
  expect(all.segments.flatMap((s: any) => s.record_ids)).toContain(other.id);
  expect(all.segments.flatMap((s: any) => s.record_ids)).not.toContain(yesterday.id);

  // 删除记录后，活动段随之更新。
  ctx.db.delete(browser.id);
  const after = await (await call(`/v1/history/segments?${day}&device=mac`)).json();
  expect(after.segments.at(-1).record_ids).toEqual([editor.id]);
});

test("活动段：参数校验", async () => {
  expect((await call("/v1/history/segments")).status).toBe(400);
  expect((await call(`/v1/history/segments?from=${encodeURIComponent(at("12:00"))}&to=${encodeURIComponent(at("11:00"))}`)).status).toBe(400);
  expect((await call(`/v1/history/segments?from=2026-01-01T00:00:00Z&to=2026-03-01T00:00:00Z`)).status).toBe(400);
});

test("并集时长：重叠只算一次，瞬时事件不计", () => {
  expect(unionSeconds([[0, 60_000], [30_000, 90_000], [200_000, 200_000], [300_000, 360_000]])).toBe(150);
  expect(unionSeconds([])).toBe(0);
});

test("活动段兼容微信旧聊天名写法，不改原记录", async () => {
  const records = ["C 王家琪", "C王家琪"].map((chat, i) => fixture({ source: "mac.wechat", t_start: at(`10:0${i}`), context: { app: "com.tencent.xinWeChat", chat } }));
  ctx.db.ingest(records);
  const { segments } = await (await call(`/v1/history/segments?${day}`)).json();
  expect(segments).toHaveLength(1);
  expect(segments[0].record_ids).toEqual(records.map(r => r.id));
  expect(records.map(r => ctx.db.get(r.id)?.context?.chat)).toEqual(["C 王家琪", "C王家琪"]);
});
