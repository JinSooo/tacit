import { expect, test } from "bun:test";
import { readFileSync } from "node:fs";

// 回归：中枢的 launchd 任务没有 PATH，设置页"测试连接"调 codex 时报"无法启动 codex"，
// 提炼进程却正常（只有它的 plist 配了 PATH）。2026-11-10 在真实界面上发现。
test("中枢的 launchd 任务和提炼进程一样带 PATH", () => {
  const script = readFileSync(new URL("../../install.sh", import.meta.url), "utf8");
  const hub = /dev\.record-anything\.hub\.plist" <<PLIST\n([\s\S]*?)\nPLIST/.exec(script)?.[1];
  expect(hub).toBeDefined();
  expect(hub).toMatch(/<key>EnvironmentVariables<\/key><dict>[\s\S]*<key>PATH<\/key><string>\$\(xml "\$\{DISTILL_PATH:-/);
});
