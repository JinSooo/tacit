import { expect, test } from "bun:test";
import { chmodSync, existsSync, mkdirSync, mkdtempSync, readFileSync, readdirSync, rmSync, statSync, symlinkSync, unlinkSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";
import { spawnSync } from "node:child_process";
import { DEFAULT_LAN_PORT, DEFAULT_PORT } from "../src/hub-json.ts";
import { identityFromRaw } from "../src/devices/envelope.ts";
import { parseShellEnv, plist, probePort, servicePath, setup } from "../src/setup.ts";

function fixture() {
  // 稳定入口必须在临时目录之外，否则会被当成临时 shim。
  const root = mkdtempSync(join(homedir(), ".ra-setup-test-"));
  const app = join(root, "Applications/Tacit.app"), home = join(root, "home"), data = join(root, "data");
  mkdirSync(join(app, "Contents/Resources/runtime/hub/src"), { recursive: true });
  writeFileSync(join(app, "Contents/Resources/runtime/hub/src/cli.ts"), "");
  mkdirSync(join(app, "Contents/Helpers"), { recursive: true });
  writeFileSync(join(app, "Contents/Helpers/Tacit"), "#!/bin/sh\n", { mode: 0o755 });
  mkdirSync(home);
  const calls: string[] = [], events: string[] = [];
  let version = "v1";
  const run = (extra: Partial<Parameters<typeof setup>[0]> = {}) => setup({
    app, home, env: { RA_DATA_DIR: data, PATH: "/usr/bin:/bin" },
    launchctl: args => { calls.push(args.join(" ")); return args[0] === "print" ? 1 : 0; },
    healthy: async () => { events.push("health"); return true; },
    shellEnv: () => ({}),
    systemPath: [],
    probePort: async port => port,
    initialize: async () => { events.push("init"); },
    relocate: () => { events.push("relocate"); return []; },
    dropRemovedSettings: () => { events.push("frozen"); },
    version: () => version,
    log: () => {},
    wait: async () => {},
    ...extra,
  });
  return { root, app, home, data, calls, events, run, setVersion: (v: string) => { version = v; },
    agents: join(home, "Library/LaunchAgents"), cleanup: () => rmSync(root, { recursive: true, force: true }) };
}

// 回归：中枢的 launchd 任务没有 PATH，设置页“测试连接”调 codex 时报“无法启动 codex”，整理进程却正常。2026-11-10 在真实界面上发现。
test("中枢和整理进程带同一个 PATH，采集端由应用包启动", () => {
  const layout = { app: "/Applications/Tacit.app", runtime: "/Applications/Tacit.app/Contents/Resources/runtime",
    bun: "/Applications/Tacit.app/Contents/Helpers/Tacit", data: "/d", path: "/tools:/usr/bin" };
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

// 回归（2026-11-27）：代理设在 .zshrc 里时，终端里 codex 正常，launchd 拉起的后台里没有代理、调用失败。
test("登录 shell 的代理和 CODEX_HOME 只写进中枢和整理任务", () => {
  const out = `motd\n\n__TACIT_ENV__\nPATH=/a:/b\nhttps_proxy=http://127.0.0.1:7890\nOPENAI_API_KEY=synthetic\nCODEX_HOME=/c\nEMPTY_PROXY=\n\n__TACIT_ENV__\n`;
  const env = parseShellEnv(out);
  expect(env).toEqual({ PATH: "/a:/b", https_proxy: "http://127.0.0.1:7890", CODEX_HOME: "/c" });
  const { PATH: _, ...cliEnv } = env;
  const layout = { app: "/Applications/Tacit.app", runtime: "/r", bun: "/b/Tacit", data: "/d", path: "/a", cliEnv };
  for (const job of ["hub", "distill"] as const) {
    expect(plist(job, layout)).toContain(`<key>TACIT_CLI_ENV</key><string>{"https_proxy":"http://127.0.0.1:7890","CODEX_HOME":"/c"}</string>`);
    expect(spawnSync("/usr/bin/plutil", ["-lint", "-"], { input: plist(job, layout) }).status).toBe(0);
  }
  expect(plist("collector", layout)).not.toContain("TACIT_CLI_ENV");
  // 没有代理时启动配置和以前一样，升级不会因此重启后台。
  expect(plist("hub", { ...layout, cliEnv: {} })).not.toContain("TACIT_CLI_ENV");
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
    expect(JSON.parse(readFileSync(join(f.data, "collector.json"), "utf8")).bun).toBe(join(f.app, "Contents/Helpers/Tacit"));

    f.calls.length = 0; f.events.length = 0;
    // 后台已在运行：只核对，不初始化、不重启。
    const loaded = await f.run({ launchctl: args => { f.calls.push(args.join(" ")); return 0; } });
    expect(loaded).toEqual({ full: false, restarted: false });
    expect(f.events).toEqual(["health"]);
    expect(f.calls.some(c => c.startsWith("bootout") || c.startsWith("bootstrap"))).toBe(false);

    f.events.length = 0; f.setVersion("v2");
    expect((await f.run()).full).toBe(true);
    expect(f.events).toContain("init");

    // 2026-11-24 回归：同版本重装但运行时换了位置（旧版在 Contents/MacOS/bun），也要重新准备并迁移 AI 工具连接。
    const collector = join(f.data, "collector.json");
    writeFileSync(collector, JSON.stringify({ ...JSON.parse(readFileSync(collector, "utf8")), bun: join(f.app, "Contents/MacOS/bun") }));
    f.events.length = 0;
    expect((await f.run()).full).toBe(true);
    expect(f.events).toContain("relocate");
    expect(JSON.parse(readFileSync(collector, "utf8")).bun).toBe(join(f.app, "Contents/Helpers/Tacit"));
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

// 回归：升级后打开时后台还在运行，bootout 后立刻 bootstrap 失败，后台服务从此没有加载（2026-11-19 安装包升级实测）。
test("后台在运行时重新准备：等旧任务退完再加载，加载失败会重试", async () => {
  const f = fixture();
  try {
    await f.run();
    f.setVersion("v2");
    const running = new Set(["hub", "distill"]), tearingDown = new Map<string, number>();
    const job = (target: string) => target.split("dev.record-anything.")[1]!.replace(".plist", "");
    const launchctl = (args: string[]) => {
      const name = job(args.at(-1)!);
      if (args[0] === "print") {
        const left = tearingDown.get(name);
        if (left) { tearingDown.set(name, left - 1); return 0; }
        return running.has(name) ? 0 : 1;
      }
      if (args[0] === "bootout") { running.delete(name); tearingDown.set(name, 2); return 0; }
      if (tearingDown.get(name)) return 5;
      running.add(name); return 0;
    };
    expect((await f.run({ launchctl })).restarted).toBe(true);
    expect([...running].sort()).toEqual(["distill", "hub"]);
    const logs: string[] = [], setupLog = join(f.data, "logs/setup.log");
    chmodSync(setupLog, 0o644);
    await expect(f.run({ install: true, log: line => logs.push(line),
      launchctl: args => args[0] === "bootstrap" ? 5 : args[0] === "print" ? 1 : 0,
    })).rejects.toThrow("dev.record-anything.hub 没能加载");
    expect(logs.filter(line => line.includes("dev.record-anything.hub") && line.includes("launchctl 退出码 5"))).toHaveLength(5);
    expect(statSync(setupLog).mode & 0o777).toBe(0o600);
  } finally { f.cleanup(); }
});

test("已提交的远端绑定在安装和升级时只准备采集，保留封存的中枢数据和任务定义", async () => {
  const f = fixture();
  try {
    const identity = await identityFromRaw("61".repeat(32));
    const bind = (phase: "committed" | "switching_back") => writeFileSync(join(f.data, "hub-binding.json"), JSON.stringify({
      version: 1, generation: 1, target: "remote", phase,
      remote: { hub_id: identity.hubID, hub_pk: identity.publicKey.toString("base64url"), dir: "remote-" + identity.hubID },
      updated_at: new Date().toISOString(),
    }), { mode: 0o600 });
    const manual = join(f.data, "launch-agents");
    mkdirSync(manual, { recursive: true });
    const hub = join(manual, "dev.record-anything.hub.plist"), db = join(f.data, "history.db");
    writeFileSync(hub, "原本机后台任务");
    writeFileSync(db, "合成封存库");
    writeFileSync(join(f.data, "app-setup.json"), JSON.stringify({ app: f.app, version: "old", distill: true }));
    bind("committed");
    expect(await f.run({ install: true, distill: false })).toEqual({ full: true, restarted: false });
    expect(f.events).toEqual(["relocate", "frozen"]);
    expect(f.calls).toHaveLength(1);
    expect(f.calls[0]).toEndWith("dev.record-anything.collector.plist");
    expect(readdirSync(f.agents)).toEqual(["dev.record-anything.collector.plist"]);
    expect(readFileSync(hub, "utf8")).toBe("原本机后台任务");
    expect(readFileSync(db, "utf8")).toBe("合成封存库");
    expect(JSON.parse(readFileSync(join(f.data, "app-setup.json"), "utf8")).distill).toBe(true);

    bind("switching_back");
    f.calls.length = 0;
    f.events.length = 0;
    f.setVersion("v2");
    expect(await f.run()).toEqual({ full: true, restarted: false });
    expect(f.calls).toEqual([]);
    expect(f.events).toEqual(["relocate", "frozen"]);
  } finally { f.cleanup(); }
});

test("setup reports a fixed reason at each failure point", async () => {
  const f = fixture();
  try {
    await expect(f.run({ app: f.home })).rejects.toMatchObject({ reason: "bundle_incomplete" });
    await expect(f.run({ initialize: async () => { throw new Error("synthetic key error"); } })).rejects.toMatchObject({ reason: "database" });
    await expect(f.run({ launchctl: () => 1 })).rejects.toMatchObject({ reason: "background_blocked" });
    await expect(f.run({ healthy: async () => false })).rejects.toMatchObject({ reason: "service_unhealthy" });
  } finally { f.cleanup(); }
});

test("startup detects a bound random port and allocates a free port with the OS", async () => {
  const server = Bun.serve({ hostname: "127.0.0.1", port: 0, fetch: () => new Response() });
  try {
    expect(await probePort(server.port!, "127.0.0.1")).toBeNull();
    const selected = await probePort(0, "127.0.0.1");
    expect(selected).toBeGreaterThan(1023);
    expect(selected).not.toBe(server.port);
  } finally { await server.stop(true); }
});

test("setup moves occupied default ports before loading hub and leaves fixed ports alone", async () => {
  const f = fixture();
  try {
    mkdirSync(f.data);
    const file = join(f.data, "hub.json");
    writeFileSync(file, JSON.stringify({ timezone: "Asia/Taipei" }));
    const probe: typeof probePort = async (port, host) => {
      if (port === 0) return host === "127.0.0.1" ? 52631 : 52632;
      return null; // 模拟默认端口和固定端口被占，不接触真实默认监听。
    };
    await f.run({ probePort: probe, healthy: async port => port === 52631, launchctl: args => {
      if (args[0] === "bootstrap") expect(JSON.parse(readFileSync(file, "utf8"))).toMatchObject({ port: 52631, lan_port: 52632 });
      return args[0] === "print" ? 1 : 0;
    } });
    const saved = readFileSync(file, "utf8");
    expect(JSON.parse(saved)).toEqual({ timezone: "Asia/Taipei", port: 52631, lan_port: 52632 });
    await expect(f.run({ retry: true, probePort: probe })).rejects.toMatchObject({ reason: "port_in_use" });
    await expect(f.run({ retry: true, probePort: probe, env: { RA_DATA_DIR: f.data, RA_PORT: String(DEFAULT_PORT) } }))
      .rejects.toMatchObject({ reason: "port_in_use" });
    expect(readFileSync(file, "utf8")).toBe(saved);

    writeFileSync(file, JSON.stringify({ port: 52631, lan_port: DEFAULT_LAN_PORT }));
    await f.run({ retry: true, probePort: async port => {
      expect(port).toBe(52631); // LAN 固定值无需探测或替换。
      return port;
    } });
    expect(JSON.parse(readFileSync(file, "utf8")).lan_port).toBe(DEFAULT_LAN_PORT);
  } finally { f.cleanup(); }
});

test("setup only initializes Codex when Claude is unavailable and preserves existing model settings", async () => {
  const f = fixture();
  try {
    const bin = join(f.home, ".npm-global/bin");
    mkdirSync(bin, { recursive: true });
    const file = join(f.data, "models.json");
    await f.run({ env: { RA_DATA_DIR: f.data } });
    expect(existsSync(file)).toBe(false);
    for (const tool of ["claude", "codex"]) writeFileSync(join(bin, tool), "#!/bin/sh\n", { mode: 0o755 });
    f.setVersion("v2");
    await f.run();
    expect(existsSync(file)).toBe(false);

    unlinkSync(join(bin, "claude"));
    f.setVersion("v3");
    await f.run();
    const tier = { provider: "codex-cli", model: "gpt-6-luna" };
    expect(JSON.parse(readFileSync(file, "utf8"))).toEqual({ tiers: { minute: tier, hour: tier, day: tier } });
    expect(statSync(file).mode & 0o777).toBe(0o600);
    const existing = JSON.stringify({ tiers: { minute: { ...tier, model: "custom" }, hour: tier, day: tier } });
    writeFileSync(file, existing);
    f.setVersion("v4");
    await f.run();
    expect(readFileSync(file, "utf8")).toBe(existing);
  } finally { f.cleanup(); }
});

test("service PATH reaches npm CLI and a separate node, with stable manager fallbacks", () => {
  const f = fixture();
  try {
    const install = (dir: string, tool: string) => {
      const bin = join(f.home, dir);
      mkdirSync(bin, { recursive: true });
      writeFileSync(join(bin, tool), "#!/bin/sh\n", { mode: 0o755 });
      return bin;
    };
    const codex = install(".npm-global/bin", "codex");
    const oldNvm = install(".nvm/versions/node/v9.10.0/bin", "node");
    const nvm = install(".nvm/versions/node/v22.2.1/bin", "node");
    const dirs = (search: string[] = []) => servicePath("/x/bun", f.home, search).split(":");
    expect(dirs()).toContain(codex);
    expect(dirs()).toContain(nvm);
    expect(dirs()).not.toContain(oldNvm);
    for (const path of [".asdf/shims", ".volta/bin", ".fnm/aliases/default/bin"]) {
      const bin = install(path, "node");
      expect(dirs()).toContain(bin);
      unlinkSync(join(bin, "node"));
    }
    const separate = install("other/bin", "node");
    expect(dirs([separate])).toContain(separate);
    expect(dirs()).toEqual(expect.arrayContaining(["/opt/homebrew/bin", "/usr/local/bin"]));
  } finally { f.cleanup(); }
});

test("升级把注册的其他 CLI 目录写进已有 hub 和 distill 启动配置", async () => {
  const f = fixture();
  try {
    await f.run();
    const bins = ["agy", "opencode", "gemini", "qwen", "droid", "copilot", "kimi", "cbc"].map(name => {
      const dir = join(f.root, name);
      mkdirSync(dir);
      writeFileSync(join(dir, name), "#!/bin/sh\n", { mode: 0o700 });
      return dir;
    });
    const readPlist = (job: string) => readFileSync(join(f.agents, `dev.record-anything.${job}.plist`), "utf8");
    expect(readPlist("hub")).not.toContain(bins[0]!);
    f.setVersion("v2");
    const warnings: string[] = [];
    expect(await f.run({ shellEnv: () => ({ PATH: bins.join(":") }), log: message => warnings.push(message) })).toEqual({ full: true, restarted: true });
    for (const job of ["hub", "distill"]) for (const bin of bins) expect(readPlist(job)).toContain(bin);
    expect(readPlist("collector")).not.toContain(bins[0]!);
    expect(warnings.join("\n")).not.toContain("没找到 cursor");
  } finally { f.cleanup(); }
});


// 回归（第 2 轮审查）：只传给 hub 时，设置页显示已接入，采集端却按默认目录找不到会话。
test("只把允许的 AI 工具配置路径从登录 shell 传给 hub 和采集端", async () => {
  const f = fixture();
  try {
    const output = "\n__TACIT_ENV__\nGEMINI_CLI_HOME=/demo/gemini&config\nOPENCODE_CONFIG_DIR=/demo/opencode\nFACTORY_HOME_OVERRIDE=/demo/factory\nGEMINI_API_KEY=synthetic\n\n__TACIT_ENV__\n";
    await f.run({ shellEnv: () => parseShellEnv(output) });
    const readPlist = (job: string) => readFileSync(join(f.agents, `dev.record-anything.${job}.plist`), "utf8");
    for (const job of ["hub", "collector"]) {
      const text = readPlist(job);
      expect(text).toContain("<key>GEMINI_CLI_HOME</key><string>/demo/gemini&amp;config</string>");
      expect(text).toContain("<key>OPENCODE_CONFIG_DIR</key><string>/demo/opencode</string>");
      expect(text).toContain("<key>FACTORY_HOME_OVERRIDE</key><string>/demo/factory</string>");
      expect(text).not.toContain("GEMINI_API_KEY");
    }
    expect(readPlist("distill")).not.toContain("GEMINI_CLI_HOME");
  } finally { f.cleanup(); }
});

test("setup probes separate durable ranges before considering an ephemeral port", async () => {
  const f = fixture();
  try {
    const checked: [number, string][] = [];
    await f.run({ probePort: async (port, host) => {
      checked.push([port, host]);
      return [47826, 47926].includes(port) ? port : null;
    }, healthy: async port => port === 47826 });
    expect(checked).toEqual([
      [DEFAULT_PORT, "127.0.0.1"], [47825, "127.0.0.1"], [47826, "127.0.0.1"],
      [DEFAULT_LAN_PORT, "0.0.0.0"], [47925, "0.0.0.0"], [47926, "0.0.0.0"],
    ]);
    expect(JSON.parse(readFileSync(join(f.data, "hub.json"), "utf8"))).toEqual({ port: 47826, lan_port: 47926 });
  } finally { f.cleanup(); }
});

test("normal startup restarts an already registered hub once after a default port conflict", async () => {
  const f = fixture();
  try {
    await f.run();
    const marker = join(f.data, "hub-startup-error.json");
    const healthPorts: number[] = [];
    let loaded = true, restarts = 0;
    const setConflict = () => writeFileSync(marker, JSON.stringify({ code: "port_in_use" }));
    const launchctl = (args: string[]) => {
      const hub = args.at(-1)?.includes("dev.record-anything.hub");
      if (args[0] === "print") return hub && loaded ? 0 : 1;
      if (hub && args[0] === "bootout") loaded = false;
      if (hub && args[0] === "bootstrap") {
        expect(existsSync(marker)).toBe(false);
        restarts++;
        loaded = true;
      }
      return 0;
    };
    const options = { launchctl, probePort: async (port: number) => port === DEFAULT_PORT ? null : port,
      healthy: async (port: number) => {
        healthPorts.push(port);
        return port === 47825;
      } };
    setConflict();
    expect(await f.run(options)).toEqual({ full: false, restarted: true });
    expect(healthPorts).toEqual([DEFAULT_PORT, 47825]);
    expect(restarts).toBe(1);

    writeFileSync(join(f.data, "hub.json"), JSON.stringify({ port: DEFAULT_PORT }));
    setConflict();
    await expect(f.run(options)).rejects.toMatchObject({ reason: "port_in_use" });
    expect(restarts).toBe(1);
  } finally { f.cleanup(); }
});

// 回归（第 2 轮审查）：自家后台正监听默认端口、只是健康检查慢时，探测也显示“被占”，不能因此卸载并改端口。
test("a slow but registered hub without a port_in_use record keeps its port", async () => {
  const f = fixture();
  try {
    await f.run();
    let bootouts = 0;
    const launchctl = (args: string[]) => {
      if (args[0] === "bootout") bootouts++;
      return args[0] === "print" ? 0 : 0;
    };
    await expect(f.run({ launchctl, probePort: async () => null, healthy: async () => false }))
      .rejects.toMatchObject({ reason: "service_unhealthy" });
    expect(bootouts).toBe(0);
    expect(existsSync(join(f.data, "hub.json")) ? JSON.parse(readFileSync(join(f.data, "hub.json"), "utf8")).port : undefined).toBeUndefined();
  } finally { f.cleanup(); }
});
