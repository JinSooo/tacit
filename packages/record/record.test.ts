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
