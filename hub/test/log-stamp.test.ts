import { expect, test } from "bun:test";
import { localLogTime, stampLogLine } from "../src/log-stamp.ts";

// 回归：hub.log 没有时间，反复出现的“Hub 已启动”分不清是崩溃重启还是正常重启（2026-11-23）。
test("中枢日志行带上时间：JSON 补 at、已有 at 不动、纯文字加前缀且仍能匹配启动行", () => {
  const now = Date.parse("2026-11-23T12:00:00Z"), at = localLogTime(now);
  expect(at).toMatch(/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}[+-]\d{2}:\d{2}$/);
  expect(JSON.parse(stampLogLine('{"location":"relay.space","code":"UNKNOWN"}', now))).toEqual({ at, location: "relay.space", code: "UNKNOWN" });
  expect(stampLogLine('{"at":"2026-11-23T20:00:00+09:00","code":"started"}', now)).toBe('{"at":"2026-11-23T20:00:00+09:00","code":"started"}');
  const started = stampLogLine("Hub 已启动：http://127.0.0.1:47823", now);
  expect(started).toBe(`${at} Hub 已启动：http://127.0.0.1:47823`);
  expect(/Hub 已启动：http:\/\/127\.0\.0\.1:(\d+)/.exec(started)?.[1]).toBe("47823");
  expect(stampLogLine("[1,2]", now)).toBe(`${at} [1,2]`);
});
