import { expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { join } from "node:path";

const root = join(import.meta.dir, "..");
const read = (path: string) => readFileSync(join(root, path), "utf8");

// v0.4.1 发版时手机端修复已随版本发出，但 Android 仍显示 0.4.0，分不清装的是哪一版。
test("Mac、后台服务和 Android 的版本号一致", () => {
  const version = JSON.parse(read("package.json")).version as string;
  expect(/<key>CFBundleShortVersionString<\/key><string>([^<]+)<\/string>/.exec(read("collector/build.sh"))?.[1]).toBe(version);
  expect(/serverInfo: \{ name: "tacit", version: "([^"]+)" \}/.exec(read("hub/src/agent-cli/mcp.ts"))?.[1]).toBe(version);
  expect(/versionName = "([^"]+)"/.exec(read("android/app/build.gradle.kts"))?.[1]).toBe(version);
});
