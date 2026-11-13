import { expect, test } from "bun:test";
import { capturePrefix } from "./capture-prefix.ts";
import { clampTitle } from "./index.ts";
import { EventParser } from "../../plugins/agent-sessions/json-lines.ts";

test("capture truncation never retains a partial credential or private key block", () => {
  const secret = "AKIA" + "A1B2C3D4E5F6G7H8";
  expect(capturePrefix("文字 " + secret, 12)).toBe("文字 ");
  expect(clampTitle("文".repeat(190) + " " + secret)).not.toContain("AKIA");
  expect(capturePrefix("说明\n-----BEGIN PRIVATE KEY-----\n" + "abCD0123\n".repeat(20), 70)).toBe("说明\n");
  expect(capturePrefix("正常文字测试", 4)).toBe("正常文字");
});
test("streaming JSON projection discards a token cut at its memory limit across chunks", () => {
  const parser = new EventParser();
  const secret = "AKIA" + "A1B2C3D4E5F6G7H8";
  const json = JSON.stringify({ type: "user", message: { role: "user", content: "文".repeat(150050) + " " + secret } });
  for (let i = 0; i < json.length; i += 97) parser.push(json.slice(i, i + 97));
  const result = parser.finish();
  expect(result.damaged).toBe(false);
  expect(result.event!.message.content).not.toContain("AKIA");
  expect(result.event!.message.content).toContain("已截断");
});
