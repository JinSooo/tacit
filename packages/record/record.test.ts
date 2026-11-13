import { expect, test } from "bun:test";
import { ulid, toLocalIso, validateRecord, clampTitle, type RecordV1 } from "./index.ts";

const base = (): RecordV1 => ({
  id: ulid(), schema: 1, device: "mac", source: "mac.shell", source_ref: "x:1", kind: "event",
  t_start: toLocalIso(Date.now()), title: "git status", body: "", capture: { method: "hook" }, sensitivity: "normal",
});

test("ulid is 26 Crockford chars and time-ordered", () => {
  const a = ulid(1_000), b = ulid(2_000);
  expect(a).toMatch(/^[0-9A-HJKMNP-TV-Z]{26}$/);
  expect(a.slice(0, 10) < b.slice(0, 10)).toBe(true);
});
test("valid event passes", () => expect(validateRecord(base())).toEqual({ ok: true }));
test("span without t_end fails", () => expect(validateRecord({ ...base(), kind: "span" }).ok).toBe(false));
test("unknown field fails", () => expect(validateRecord({ ...base(), foo: 1 }).ok).toBe(false));
test("local iso has offset", () => expect(toLocalIso(0)).toMatch(/[+-]\d\d:\d\d$/));
test("clampTitle respects limit", () => expect(Array.from(clampTitle("长".repeat(500))).length).toBe(200));

test("同一毫秒内生成的 ulid 严格递增（审计和修正按 id 取最新）", () => {
  const t = Date.UTC(2026, 10, 9, 12);
  // 和其他时间交替生成（采集端用记录开始时间生成 id 时就是这样）也要保持递增。
  const ids = Array.from({ length: 1000 }, (_, i) => { ulid(t + 1 + i); return ulid(t); });
  expect(ids.every((id, i) => i === 0 || ids[i - 1]! < id)).toBe(true);
  expect(ids.every((id) => /^[0-9A-HJKMNP-TV-Z]{26}$/.test(id))).toBe(true);
});

test("Mac 编码共享样例符合唯一 JSON Schema，未知字段仍拒绝", async () => {
  const sample = (await import("../../schema/fixtures/mac-record.json")).default;
  expect(validateRecord(sample)).toEqual({ok:true});
  expect(validateRecord({...sample,context:{...sample.context,unsupported:"x"}}).ok).toBe(false);
});
