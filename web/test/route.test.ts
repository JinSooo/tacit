import { expect, test } from "bun:test";
import { initialPage, pageHash, parseHash } from "../src/route.ts";
import { createUndoQueue, type UndoEntry } from "../src/undo.ts";

test("页面片段解析：新写法、旧的 token 与 status 写法、未知片段", () => {
  expect(parseHash("#/now")).toEqual({ page: "now", token: null });
  expect(parseHash("#/pending")).toEqual({ page: "pending", token: null });
  expect(parseHash("#/unknown")).toEqual({ page: null, token: null });
  expect(parseHash("#/")).toEqual({ page: null, token: null });
  expect(parseHash("#token=a%2Bb")).toEqual({ page: null, token: "a+b" });
  expect(parseHash("#token=abc&status")).toEqual({ page: "status", token: "abc" });
  expect(parseHash("#status")).toEqual({ page: "status", token: null });
  expect(parseHash("#content")).toEqual({ page: null, token: null });
  expect(parseHash("")).toEqual({ page: null, token: null });
  expect(pageHash("status")).toBe("#/status");
  expect(parseHash(pageHash("settings")).page).toBe("settings");
  expect(initialPage("", "")).toBe("history");
  expect(initialPage("", "?thread=t1")).toBe("audit");
  expect(initialPage("#/now", "?thread=t1")).toBe("now");
  expect(initialPage("#token=x&status", "")).toBe("status");
});

function harness() {
  const timers = new Map<number, () => void>();
  let next = 0;
  const commits: [string, string, boolean][] = [];
  let entries: UndoEntry<string>[] = [];
  const queue = createUndoQueue<string>({
    delay: 5000,
    commit: (id, value, flushing) => commits.push([id, value, flushing]),
    onChange: value => { entries = value; },
    schedule: run => { timers.set(++next, run); return next; },
    cancel: timer => { timers.delete(timer as number); },
  });
  const tick = () => { for (const [id, run] of [...timers]) { timers.delete(id); run(); } };
  return { queue, timers, commits, entries: () => entries, tick };
}

test("撤销队列：到时提交，期间可撤销，撤销后不再提交", () => {
  const h = harness();
  h.queue.add("a", "done");
  h.queue.add("b", "ignore");
  expect(h.entries().map(e => e.id)).toEqual(["a", "b"]);
  expect(h.queue.undo("a")).toBe(true);
  expect(h.queue.undo("a")).toBe(false);
  expect(h.entries().map(e => e.id)).toEqual(["b"]);
  h.tick();
  expect(h.commits).toEqual([["b", "ignore", false]]);
  expect(h.entries()).toEqual([]);
  expect(h.timers.size).toBe(0);
});

test("撤销队列：同一项再次处理替换旧动作；离开页面立即提交全部并标记", () => {
  const h = harness();
  h.queue.add("a", "done");
  h.queue.add("a", "continue");
  expect(h.timers.size).toBe(1);
  h.queue.add("b", "keep");
  h.queue.flush();
  expect(h.commits).toEqual([["a", "continue", true], ["b", "keep", true]]);
  expect(h.timers.size).toBe(0);
  h.tick();
  expect(h.commits).toHaveLength(2);
});
