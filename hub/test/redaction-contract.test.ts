import { expect, test } from "bun:test";
import fixture from "../../schema/fixtures/redaction.json";
import { redactString, redactRecord } from "../src/redact.ts";
import { fixture as record } from "./helpers.ts";
test("Mac 待发送脱敏与中枢共享已知格式和剪贴板边界", () => {
  for (const { input, text, count } of fixture.strings) expect(redactString(input)).toEqual({ text, count });
  for (const { input, text, count } of fixture.clipboard) {
    const r = redactRecord(record({ source: "mac.clipboard", title: input, body: input }));
    expect(r.body).toBe(text); expect(r.redactions).toBe(count);
  }
});
