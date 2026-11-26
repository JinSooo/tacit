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

// 官网的 latest.json 决定已装用户会不会看到“可以更新了”，appcast.json 决定点了“更新”能不能在应用里装上。
// 两者在安装包上传后由 scripts/publish-mac-update.ts 一起改，所以可以落后于正在发的版本，但彼此必须一致。
test("官网 latest.json 与应用内更新的 appcast 指向同一个已发布的 Mac 版本", () => {
  const version = JSON.parse(read("package.json")).version as string;
  const mac = JSON.parse(read("site/src/latest.json")).mac as { version: string; url: string };
  const appcast = JSON.parse(read("site/src/appcast.json")) as { version: string };
  // 官网上的版本不能比正在发的还新。
  expect(Bun.semver.order(mac.version, version)).toBeLessThanOrEqual(0);
  expect(appcast.version).toBe(mac.version);
  expect(mac.url).toBe(`https://github.com/JinSooo/tacit/releases/tag/mac-v${mac.version}`);
});

// 手机也读同一份 latest.json 的 android 条目来提示“可以更新了”，跟 versionName 一起改。
test("官网 latest.json 指向当前 Android 版本的 Release", () => {
  const version = /\bversionName\s*=\s*"([^"]+)"/.exec(read("android/app/build.gradle.kts"))?.[1];
  const android = JSON.parse(read("site/src/latest.json")).android as { version: string; url: string };
  expect(android.version).toBe(version!);
  expect(android.url).toBe(`https://github.com/JinSooo/tacit/releases/tag/android-v${version}`);
});
