import { afterEach, beforeEach, expect, test } from "bun:test";
import { mkdirSync, symlinkSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { createHandler } from "../src/server.ts";
import { setup } from "./helpers.ts";
let ctx: ReturnType<typeof setup>;
let handler: ReturnType<typeof createHandler>;
const host = "127.0.0.1:47823";
beforeEach(() => {
  ctx = setup();
  const webDir = join(ctx.dir, "dist");
  mkdirSync(join(webDir, "assets"), { recursive: true });
  writeFileSync(join(webDir, "index.html"), "<!doctype html><title>合成网页</title>");
  writeFileSync(join(webDir, "assets/app.js"), "console.log('合成脚本')");
  writeFileSync(join(webDir, "assets/app.css"), "body { margin: 0; }");
  writeFileSync(join(ctx.dir, "outside.txt"), "合成的外部文件");
  symlinkSync(join(ctx.dir, "outside.txt"), join(webDir, "escape.txt"));
  handler = createHandler({ db: ctx.db, token: ctx.config.token, webDir });
});
afterEach(() => ctx.cleanup());
function request(path: string, headers: Record<string, string> = { host }) { return handler(new Request(`http://${host}${path}`, { headers })); }
test("网页无需 token、静态类型正确，SPA 回退和 HTML CSP", async () => {
  for (const path of ["/", "/timeline/old", "/assets/missing.js"]) {
    const result = await request(path);
    expect(result.status).toBe(200);
    expect(result.headers.get("content-type")).toBe("text/html; charset=utf-8");
    expect(result.headers.get("content-security-policy")).toBe("default-src 'self'; img-src 'self' data:; style-src 'self' 'unsafe-inline'; connect-src 'self'; media-src 'self' blob:; frame-ancestors 'none'");
    expect(await result.text()).toContain("合成网页");
  }
  const script = await request("/assets/app.js");
  expect(script.headers.get("content-type")).toBe("text/javascript; charset=utf-8");
  expect(await script.text()).toContain("合成脚本");
  expect((await request("/assets/app.css")).headers.get("content-type")).toBe("text/css; charset=utf-8");
  expect((await request("/v1/records")).status).toBe(401);
  expect((await request("/v1/health")).status).toBe(200);
});
test("所有路由严格校验 Host，拒绝缺失、异域、错误端口和伪装域名", async () => {
  for (const path of ["/", "/assets/app.js", "/v1/health", "/v1/records"]) {
    for (const wrong of ["attacker.invalid:47823", "127.0.0.1:1234", "localhost", "127.0.0.1.attacker.invalid:47823", "localhost:47823@attacker.invalid"]) {
      expect((await request(path, { host: wrong, authorization: `Bearer ${ctx.config.token}` })).status).toBe(421);
    }
    expect((await request(path, {})).status).toBe(421);
  }
  expect((await request("/", { host: "localhost:47823" })).status).toBe(200);
});
test("拒绝编码目录穿越、反斜线、空字节和逃出目录的软链接", async () => {
  for (const path of ["/..%2foutside.txt", "/%2e%2e%2foutside.txt", "/assets/%2e%2e%2f%2e%2e%2foutside.txt", "/%5c..%5coutside.txt", "/%00", "/escape.txt"]) {
    expect((await request(path)).status).toBe(403);
  }
  expect((await request("/%zz")).status).toBe(400);
});
test("未构建时给出单行说明，API 不受影响", async () => {
  handler = createHandler({ db: ctx.db, token: ctx.config.token, webDir: join(ctx.dir, "absent") });
  expect(await (await request("/")).text()).toContain("网页尚未构建");
  expect((await request("/v1/records")).status).toBe(401);
});
