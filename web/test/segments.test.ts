import { expect, test } from "bun:test";
import { appName, foldSegments, isMinor, type Segment } from "../src/segments.ts";

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
