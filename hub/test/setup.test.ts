import { expect, test } from "bun:test";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, symlinkSync, unlinkSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";
import { spawnSync } from "node:child_process";
import { plist, servicePath, setup } from "../src/setup.ts";

function fixture() {
  // 稳定入口必须在临时目录之外，否则会被当成临时 shim。
  const root = mkdtempSync(join(homedir(), ".ra-setup-test-"));
  const app = join(root, "Applications/Tacit.app"), home = join(root, "home"), data = join(root, "data");
  mkdirSync(join(app, "Contents/Resources/runtime/hub/src"), { recursive: true });
  writeFileSync(join(app, "Contents/Resources/runtime/hub/src/cli.ts"), "");
  mkdirSync(join(app, "Contents/MacOS"), { recursive: true });
  writeFileSync(join(app, "Contents/MacOS/bun"), "#!/bin/sh\n", { mode: 0o755 });
  mkdirSync(home);
  const calls: string[] = [], events: string[] = [];
  let version = "v1";
  const run = (extra: Partial<Parameters<typeof setup>[0]> = {}) => setup({
    app, home, env: { RA_DATA_DIR: data, PATH: "/usr/bin:/bin" },
    launchctl: args => { calls.push(args.join(" ")); return args[0] === "print" ? 1 : 0; },
    healthy: async () => { events.push("health"); return true; },
    shellPath: () => [],
    initialize: async () => { events.push("init"); },
    relocate: () => { events.push("relocate"); return []; },
    disableFrozen: () => { events.push("frozen"); },
    version: () => version,
    log: () => {},
    ...extra,
  });
  return { root, app, home, data, calls, events, run, setVersion: (v: string) => { version = v; },
    agents: join(home, "Library/LaunchAgents"), cleanup: () => rmSync(root, { recursive: true, force: true }) };
}

// 回归：中枢的 launchd 任务没有 PATH，设置页“测试连接”调 codex 时报“无法启动 codex”，整理进程却正常。2026-11-10 在真实界面上发现。
test("中枢和整理进程带同一个 PATH，采集端由应用包启动", () => {
  const layout = { app: "/Applications/Tacit.app", runtime: "/Applications/Tacit.app/Contents/Resources/runtime",
    bun: "/Applications/Tacit.app/Contents/MacOS/bun", data: "/d", path: "/tools:/usr/bin" };
  for (const job of ["hub", "distill"] as const) {
    expect(plist(job, layout)).toContain("<key>PATH</key><string>/tools:/usr/bin</string>");
    expect(plist(job, layout)).toContain(`<string>${layout.bun}</string><string>${layout.runtime}/hub/src/cli.ts</string>`);
  }
  expect(plist("collector", layout)).toContain("<string>/Applications/Tacit.app/Contents/MacOS/Tacit</string>");
  for (const job of ["hub", "distill", "collector"] as const) {
    const lint = spawnSync("/usr/bin/plutil", ["-lint", "-"], { input: plist(job, layout) });
    expect(lint.status).toBe(0);
  }
});

test("后台服务 PATH 优先稳定入口，CLI 符号链接升级后无需重新准备", () => {
  const root = mkdtempSync(join(homedir(), ".ra-path-test-")), bin = join(root, "bin");
  mkdirSync(bin);
  try {
    for (const v of ["v1", "v2"]) { mkdirSync(join(root, v)); writeFileSync(join(root, v, "codex"), `#!/bin/sh\necho ${v}\n`, { mode: 0o755 }); }
    symlinkSync(join(root, "v1", "codex"), join(bin, "codex"));
    const path = servicePath("/x/bun", root, [bin, "/usr/bin", "/bin"]);
    expect(path.split(":")[0]).toBe(bin);
    unlinkSync(join(bin, "codex")); symlinkSync(join(root, "v2", "codex"), join(bin, "codex"));
    const next = spawnSync("/bin/sh", ["-c", "codex"], { encoding: "utf8", env: { PATH: path } });
    expect(next.stdout.trim()).toBe("v2");
  } finally { rmSync(root, { recursive: true, force: true }); }
});

test("首次打开完整准备；之后打开没有变化时不重启后台；升级后重新准备", async () => {
  const f = fixture();
  try {
    expect(await f.run()).toEqual({ full: true, restarted: true });
    expect(f.events).toEqual(["init", "relocate", "frozen", "health"]);
    for (const job of ["hub", "distill", "collector"]) expect(existsSync(join(f.agents, `dev.record-anything.${job}.plist`))).toBe(true);
    expect(f.calls.filter(c => c.startsWith("bootstrap")).map(c => c.split("/").pop())).toEqual(["dev.record-anything.hub.plist", "dev.record-anything.distill.plist"]);
    expect(JSON.parse(readFileSync(join(f.data, "collector.json"), "utf8")).bun).toBe(join(f.app, "Contents/MacOS/bun"));

    f.calls.length = 0; f.events.length = 0;
    // 后台已在运行：只核对，不初始化、不重启。
    const loaded = await f.run({ launchctl: args => { f.calls.push(args.join(" ")); return 0; } });
    expect(loaded).toEqual({ full: false, restarted: false });
    expect(f.events).toEqual([]);
    expect(f.calls.some(c => c.startsWith("bootout") || c.startsWith("bootstrap"))).toBe(false);

    f.events.length = 0; f.setVersion("v2");
    expect((await f.run()).full).toBe(true);
    expect(f.events).toContain("init");
  } finally { f.cleanup(); }
});

test("沿用关闭登录启动的选择和停用整理的选择", async () => {
  const f = fixture();
  try {
    const manual = join(f.data, "launch-agents");
    mkdirSync(manual, { recursive: true });
    writeFileSync(join(manual, "dev.record-anything.collector.plist"), "old");
    await f.run({ install: true, distill: false });
    expect(existsSync(join(f.agents, "dev.record-anything.hub.plist"))).toBe(false);
    expect(existsSync(join(manual, "dev.record-anything.hub.plist"))).toBe(true);
    expect(existsSync(join(manual, "dev.record-anything.distill.plist"))).toBe(false);
    // 源码安装同时启动采集端。
    expect(f.calls.at(-1)).toContain("dev.record-anything.collector.plist");
    // 之后从应用打开不会把整理加回来。
    await f.run();
    expect(existsSync(join(manual, "dev.record-anything.distill.plist"))).toBe(false);
  } finally { f.cleanup(); }
});

test("后台服务没起来时报错，不写完成记录，下次打开重新准备", async () => {
  const f = fixture();
  try {
    await expect(f.run({ healthy: async () => false })).rejects.toThrow("后台服务没能启动");
    expect(existsSync(join(f.data, "app-setup.json"))).toBe(false);
    expect((await f.run()).full).toBe(true);
  } finally { f.cleanup(); }
});
