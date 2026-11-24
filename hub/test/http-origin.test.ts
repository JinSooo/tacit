import { expect, test } from "bun:test";
import { httpOrigin } from "../src/devices/http-origin.ts";

// 2026-11-24 A1 审查回归：端口 0 和控制字符不能被 URL 解析静默吞掉后当成合法地址。
test("配对地址只接受 http(s) origin，拒绝端口 0、控制字符、凭据、路径和查询", () => {
  expect(httpOrigin("https://hub.example.test")).toBe("https://hub.example.test");
  expect(httpOrigin("http://192.0.2.1:8443/")).toBe("http://192.0.2.1:8443");
  for (const bad of ["http://hub.example.test:0", "http://hub\x01.example.test", "http://hub.example.test\x7f",
    "https://user:pw@hub.example.test", "https://hub.example.test/path", "https://hub.example.test/?q", "ftp://hub.example.test", "", 1]) {
    expect(httpOrigin(bad)).toBeNull();
  }
});
