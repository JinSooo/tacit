import { expect, test } from "bun:test";
import type { HistoryRow } from "../src/history.ts";
import { appName, collapseConversations, conversationTitle, foldSegments, isMinor, withoutRecords, type Conversation, type Segment } from "../src/segments.ts";

function seg(id: string, opts: { thread?: boolean; records?: number; seconds?: number } = {}): Segment {
  return {
    id, kind: opts.thread ? "thread" : "app", start_ms: 0, end_ms: 0,
    thread: opts.thread ? { id: "t", title: "合成线程", brief: null, status: "active", domain: null, project_id: null, project_name: null } : null,
    apps: [], active_seconds: opts.seconds ?? 10, record_ids: Array.from({ length: opts.records ?? 1 }, (_, i) => `${id}${i}`), private: 0,
  };
}

test("零碎段连续 3 段以上才折成一行，线程段、记录多或时长长的不算零碎", () => {
  expect(isMinor(seg("t", { thread: true }))).toBe(false);
  expect(isMinor(seg("m", { records: 3 }))).toBe(false);
  expect(isMinor(seg("l", { seconds: 300 }))).toBe(false);
  const items = foldSegments([seg("a"), seg("b"), seg("c"), seg("T", { thread: true }), seg("d"), seg("e"), seg("U", { thread: true })]);
  expect(items.map(i => i.id)).toEqual(["minor:a", "T", "d", "e", "U"]);
});

test("应用显示名优先用中枢给的 name，没有时退回 bundle id 末段或来源名", () => {
  expect(appName({ app: "com.synthetic.editor", name: "合成编辑器", source: "mac.screen", records: 1, seconds: 0 })).toBe("合成编辑器");
  expect(appName({ app: "com.synthetic.editor", name: null, source: "mac.screen", records: 1, seconds: 0 })).toBe("editor");
  expect(appName({ app: null, name: null, source: "mac.shell", records: 1, seconds: 0 })).toBe("终端");
});

function rec(id: string, source: string, start: string, end?: string): HistoryRow {
  return { id, schema: 1, device: "mac", source, kind: end ? "span" : "event", t_start: start, t_end: end ?? null, title: id, capture: { method: "asr" }, sensitivity: "normal" };
}
const talk = (id: string, record_ids: string[], title: string | null = null, minutes = 42): Conversation =>
  ({ id, record_ids, start_ms: 0, end_ms: minutes * 60_000, app: null, title });

test("同一场对话被静音切开的几条记录合成一行，放在第一次出现的位置，其他记录不动", () => {
  // 列表是新的在前；屏幕记录夹在两段录音之间。
  const rows = [rec("a3", "mac.audio", "2026-11-11T10:20:00Z"), rec("s1", "mac.screen", "2026-11-11T10:15:00Z"),
    rec("a2", "mac.audio", "2026-11-11T10:10:00Z"), rec("a1", "mac.audio", "2026-11-11T10:00:00Z"), rec("b1", "mac.audio", "2026-11-11T09:00:00Z")];
  const items = collapseConversations(rows, [talk("a1", ["a1", "a2", "a3"]), talk("b1", ["b1"])]);
  expect(items.map(i => i.id)).toEqual(["a1", "s1", "b1"]);
  const first = items[0]!;
  expect(first.kind === "conversation" && first.records.map(r => r.id)).toEqual(["a3", "a2", "a1"]);
  // 不在任何一场里的记录（例如还没拿到分组）照常列出。
  expect(collapseConversations(rows, []).map(i => i.kind)).toEqual(["record", "record", "record", "record", "record"]);
});

test("对话一行的标题：有总结用总结的标题，没有时写时长，不再列说话人编号", () => {
  expect(conversationTitle(talk("a", ["a"], "周会排期"))).toBe("对话：周会排期");
  expect(conversationTitle(talk("a", ["a"]))).toBe("对话 42 分钟");
  expect(conversationTitle(talk("a", ["a"], null, 75))).toBe("对话 1 小时 15 分");
  expect(conversationTitle(talk("a", ["a"], "  ", 0))).toBe("对话");
  expect(conversationTitle(talk("a", ["a"], null, 0.5))).toBe("对话");
});

test("删掉对话的第一条记录后，这一行改用剩下的记录打开，旧总结的标题不再显示", () => {
  const rows = new Map([["a2", rec("a2", "mac.audio", "2026-11-11T10:10:00Z", "2026-11-11T10:12:00Z")]]);
  const [left, ...rest] = withoutRecords([talk("a1", ["a1", "a2"], "周会排期"), talk("b1", ["b1"])], ["a1"], rows);
  expect(left).toMatchObject({ id: "a2", record_ids: ["a2"], title: null, start_ms: Date.parse("2026-11-11T10:10:00Z"), end_ms: Date.parse("2026-11-11T10:12:00Z") });
  expect(rest.map(c => c.id)).toEqual(["b1"]);
  expect(withoutRecords([talk("a1", ["a1"])], ["a1"], new Map())).toEqual([]);
});
