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

// 官网的 latest.json 决定已装用户会不会看到“可以更新了”，跟着版本号一起改，部署官网放在 Release 上传之后。
test("官网 latest.json 指向当前 Mac 版本的 Release", () => {
  const version = JSON.parse(read("package.json")).version as string;
  const mac = JSON.parse(read("site/src/latest.json")).mac as { version: string; url: string };
  expect(mac.version).toBe(version);
  expect(mac.url).toMatch(new RegExp(`^https://github\\.com/JinSooo/tacit/releases/tag/(?:mac-)?v${version.replaceAll(".", "\\.")}$`));
});
