import { expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { join } from "node:path";

const root = join(import.meta.dir, "..");
const read = (path: string) => readFileSync(join(root, path), "utf8");

// Mac 安装包里带着后台服务，三处版本号一起发。Android 从 v0.6.4 起单独发版、版本号独立，
// 由 scripts/release-apk.sh 核对 versionName 与 android-v<版本> tag（v0.4.1 时手机修复已发出、手机却仍显示旧版本号）。
test("Mac 安装包、后台服务和 MCP 的版本号一致", () => {
  const version = JSON.parse(read("package.json")).version as string;
  expect(/<key>CFBundleShortVersionString<\/key><string>([^<]+)<\/string>/.exec(read("collector/build.sh"))?.[1]).toBe(version);
  expect(/serverInfo: \{ name: "tacit", version: "([^"]+)" \}/.exec(read("hub/src/agent-cli/mcp.ts"))?.[1]).toBe(version);
});
