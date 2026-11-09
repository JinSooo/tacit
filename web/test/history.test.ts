import { expect, test } from "bun:test";
import { ulid as sharedUlid, toLocalIso as sharedIso, validateRecord } from "../../packages/record/index.ts";
import { ulid, toLocalIso } from "../src/record-helpers.ts";
import { buildNote, buildCorrection, chapterSpans, dateTitle, dayKey, dayRange, duration, groupRecords, laneOf, latestCorrection, safeUrl, sourceColor, timeRange } from "../src/history.ts";

const note = () => buildNote({ start: "2026-11-06T14:02:00", end: "2026-11-06T14:27:00", title: "合成工作片段", body: "第一行\n第二行" });
test("浏览器辅助函数与共享包格式一致，包括时区和 ULID 时间前缀", () => {
  for (const value of [0, Date.parse("2026-11-08T14:02:10+08:00"), Date.parse("2026-07-01T00:01:59Z")]) {
    expect(toLocalIso(value)).toBe(sharedIso(value));
    expect(toLocalIso(new Date(value))).toBe(sharedIso(new Date(value)));
    expect(ulid(value)).toMatch(/^[0-9A-HJKMNP-TV-Z]{26}$/);
    expect(ulid(value).slice(0, 10)).toBe(sharedUlid(value).slice(0, 10));
  }
  expect(new Set(Array.from({ length: 100 }, () => ulid())).size).toBe(100);
});
test("本地日期分组与排序，不修改输入", () => {
  const a = note();
  const b = buildNote({ start: "2026-11-07T00:01", title: "合成夜间活动", body: "" });
  const c = buildNote({ start: "2026-11-06T15:00", title: "合成下午活动", body: "" });
  const input = [a, b, c];
  const groups = groupRecords(input);
  expect(groups.map(group => group.day)).toEqual(["2026-11-07", "2026-11-06"]);
  expect(groups[1]!.records.map(record => record.id)).toEqual([c.id, a.id]);
  expect(input).toEqual([a, b, c]);
  expect(dayKey(new Date("2026-11-06T23:59"))).toBe("2026-11-06");
});
test("日期标题处理今天、跨月昨天、星期和跨年", () => {
  const now = new Date("2026-11-01T00:10");
  expect(dateTitle("2026-11-01", now)).toBe("今天");
  expect(dateTitle("2026-10-31", now)).toBe("昨天");
  expect(dateTitle("2026-10-29", now)).toBe("10月29日 周四");
  expect(dateTitle("2025-11-06", now)).toBe("2025年11月6日 周四");
});
test("事件、时段、跨天与秒/分钟/小时时长", () => {
  const record = note();
  expect(timeRange(record)).toBe("14:02–14:27");
  expect(duration(record)).toBe("25分钟");
  expect(timeRange({ ...record, kind: "event" })).toBe("14:02");
  expect(timeRange({ ...record, t_end: "2026-11-06T14:02:40" })).toBe("14:02");
  expect(duration({ ...record, kind: "event" })).toBe("");
  expect(duration({ ...record, t_end: "2026-11-06T14:02:28" })).toBe("28秒");
  // 同一秒内开始和结束的片段不显示时长。
  expect(duration({ ...record, t_end: record.t_start })).toBe("");
  expect(duration({ ...record, t_end: "2026-11-06T15:03" })).toBe("1小时1分钟");
  expect(timeRange({ ...record, t_end: "2026-11-07T00:03" })).toBe("14:02–11月7日 00:03");
});
test("补写事件和时段、修正均通过共享校验，不携带 hub 或来源字段", () => {
  const span = note();
  const event = buildNote({ start: "2026-11-08T12:00", title: " 合成\n标题 ", body: "" });
  expect(event.title).toBe("合成 标题");
  expect(event.kind).toBe("event");
  expect(event).not.toHaveProperty("t_end");
  const original = { ...span, sensitivity: "private" as const, source_ref: "synthetic-ref" };
  const correction = buildCorrection(original, "合成修正正文", new Date("2026-11-08T12:00"));
  for (const record of [span, event, correction]) expect(validateRecord(record)).toEqual({ ok: true });
  expect(correction).toMatchObject({ source: "manual.correction", corrects: span.id, device: "web", capture: { method: "manual" }, sensitivity: "private" });
  expect(correction).not.toHaveProperty("source_ref");
  expect(correction).not.toHaveProperty("t_received");
  expect(() => buildNote({ start: "bad", title: "标题", body: "" })).toThrow();
  expect(() => buildNote({ start: "2026-11-08T12:00", end: "2026-11-07T12:00", title: "标题", body: "" })).toThrow();
  expect(() => buildNote({ start: "2026-11-08T12:00", title: " ", body: "" })).toThrow();
});
test("最新修正按时间及 ID 选择，外部 URL 仅允许 HTTP(S)", () => {
  const original = note();
  const first = buildCorrection(original, "旧", new Date("2026-11-08T10:00"));
  const last = buildCorrection(original, "新", new Date("2026-11-08T11:00"));
  expect(latestCorrection({ ...original, corrections: [last, first] })?.body).toBe("新");
  expect(safeUrl("javascript:alert(1)")).toBeUndefined();
  expect(safeUrl("file:///etc/passwd")).toBeUndefined();
  expect(safeUrl("https://example.invalid/path")).toBe("https://example.invalid/path");
});

test("条带图：泳道归类、来源颜色、整天范围和日记章节", () => {
  expect(laneOf("codex.session")).toBe("agent");
  expect(laneOf("mac.git")).toBe("terminal");
  expect(laneOf("mac.clipboard")).toBe("other");
  expect(sourceColor("mac.screen")).toBe("var(--src-screen)");
  expect(sourceColor("plugin.unknown")).toBe("var(--src-other)");
  const day = dayRange("2026-11-09");
  expect(day.end - day.start).toBe(86400000);
  expect(Date.parse(day.from)).toBe(day.start);
  // hub 的 to 是闭区间，停在次日零点前 1 毫秒。
  expect(Date.parse(day.to)).toBe(day.end - 1);
  expect(day.to).toMatch(/T23:59:59\.999[+-]\d\d:\d\d$/);
  const spans = chapterSpans("2026-11-09", [{ start: "22:42", end: "00:00", text: "跨午夜" }, { start: "9:05", end: "10:30", text: "上午" }, { start: "坏", end: "10:00", text: "跳过" }]);
  expect(spans.map(s => s.text)).toEqual(["跨午夜", "上午"]);
  expect(spans[0]!.end).toBe(day.end);
  expect(spans[1]!.start - day.start).toBe((9 * 60 + 5) * 60000);
});
