import { expect, test } from "bun:test";
import fixture from "../../schema/fixtures/redaction.json";
import { redactString, redactRecord } from "../src/redact.ts";
import { fixture as record } from "./helpers.ts";
test("共享脱敏样例覆盖已知格式、代理凭据和剪贴板边界", () => {
  for (const { input, text, count } of [...fixture.strings, ...fixture.proxyCredentials]) {
    expect(redactString(input)).toEqual({ text, count });
  }
  for (const { input, text, count } of fixture.clipboard) {
    const r = redactRecord(record({ source: "mac.clipboard", title: input, body: input }));
    expect(r.body).toBe(text); expect(r.redactions).toBe(count);
  }
});
