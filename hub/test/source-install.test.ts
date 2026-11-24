import { expect, test } from "bun:test";
import { createHash } from "node:crypto";
import { cpSync, existsSync, mkdirSync, mkdtempSync, readFileSync, readdirSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import { base32 } from "../src/devices/envelope.ts";

test("源码升级准备失败时恢复旧包和原先运行的任务，成功时删除旧包备份", () => {
  const root = mkdtempSync(join(tmpdir(), "tacit-install-test-"));
  const home = join(root, "isolated-home"), state = join(root, "state"), bin = join(root, "bin");
  const data = join(home, "Library/Application Support/record-anything");
  const agents = join(home, "Library/LaunchAgents"), manual = join(data, "launch-agents");
  const apps = join(home, "Applications"), app = join(apps, "Tacit.app");
  const staged = join(root, "collector/build/Tacit.app/Contents/Helpers");
  const executable = (file: string, body: string) => writeFileSync(file, "#!/bin/sh\nset -eu\n" + body + "\n", { mode: 0o755 });
  const label = (job: string) => `dev.record-anything.${job}`;
  const plist = (dir: string, job: string) => join(dir, label(job) + ".plist");
  try {
    for (const dir of [bin, state, app, agents, manual, staged, join(root, "scripts")]) mkdirSync(dir, { recursive: true });
    cpSync(new URL("../../install.sh", import.meta.url), join(root, "install.sh"));
    // 回滚判定直接用仓库里的绑定读取代码。
    symlinkSync(fileURLToPath(new URL("..", import.meta.url)), join(root, "hub"));
    writeFileSync(join(root, "scripts/mac-app.sh"), `
tacit_install_dir() { printf '%s\\n' "$2"; }
tacit_owns_bundle() { return 1; }
tacit_check_destination() { :; }
tacit_processes() { :; }
tacit_stop_processes() { :; }
`);
    for (const file of [join(root, "scripts/fetch-audio-lib.sh"), join(root, "collector/build.sh"),
      ...["xcode-select", "bun", "codesign"].map(name => join(bin, name))]) executable(file, "exit 0");
    executable(join(bin, "bun"), 'if [ "$1" = --no-env-file ]; then exec "$TEST_BUN" "$@"; fi');
    executable(join(bin, "ditto"), 'cp -R "$1" "$2"');
    executable(join(bin, "launchctl"), `
case "$1" in
  print) test -f "$TEST_STATE/$(basename "$2")" ;;
  bootout) rm -f "$TEST_STATE/$(basename "$2")" ;;
  bootstrap) cp "$3" "$TEST_STATE/$(basename "$3" .plist)" ;;
  *) exit 2 ;;
esac
`);
    executable(join(staged, "Tacit"), `
test -f "$HOME/Applications/Tacit.app/new"
for job in hub distill collector; do
  if [ -f "$TEST_DATA/hub-binding.json" ] && [ "$job" != collector ]; then continue; fi
  printf new > "$TEST_DATA/launch-agents/dev.record-anything.$job.plist"
  launchctl bootstrap ignored "$TEST_DATA/launch-agents/dev.record-anything.$job.plist"
done
printf new > "$TEST_DATA/collector.json"
printf new > "$TEST_DATA/app-setup.json"
exit "$TEST_SETUP_STATUS"
`);
    writeFileSync(join(staged, "../../new"), "");
    writeFileSync(join(app, "old"), "old");
    for (const job of ["hub", "collector"]) {
      writeFileSync(plist(manual, job), `old-${job}`);
      writeFileSync(join(state, label(job)), `old-${job}`);
    }
    writeFileSync(plist(agents, "distill"), "old-distill-disabled");
    for (const file of ["collector.json", "app-setup.json"]) writeFileSync(join(data, file), "old");

    const run = (status: string) => spawnSync("/bin/sh", [join(root, "install.sh")], {
      env: { HOME: home, PATH: bin + ":/usr/bin:/bin", TEST_STATE: state, TEST_DATA: data, TEST_SETUP_STATUS: status, TEST_BUN: process.execPath },
      encoding: "utf8", timeout: 10_000,
    });
    const failing = run("7");
    expect(failing.stderr).toContain("已回滚应用和后台启动项");
    expect(failing.status).toBe(7);
    expect(readdirSync(apps)).toEqual(["Tacit.app"]);
    expect(readdirSync(app)).toEqual(["old"]);
    expect(readdirSync(manual).sort()).toEqual([label("collector") + ".plist", label("hub") + ".plist"]);
    expect(readdirSync(state).sort()).toEqual([label("collector"), label("hub")]);
    expect(readFileSync(join(state, label("hub")), "utf8")).toBe("old-hub");
    expect(readFileSync(plist(agents, "distill"), "utf8")).toBe("old-distill-disabled");
    for (const file of ["collector.json", "app-setup.json"]) expect(readFileSync(join(data, file), "utf8")).toBe("old");

    const binding = join(data, "hub-binding.json");
    for (const phase of ["committed", "switching_back"]) {
      const hub_pk = Buffer.alloc(32, 9), hub_id = base32(createHash("sha256").update(hub_pk).digest().subarray(0, 16));
      writeFileSync(binding, JSON.stringify({ version: 1, generation: 1, target: "remote", phase, updated_at: new Date().toISOString(),
        remote: { hub_id, hub_pk: hub_pk.toString("base64url"), dir: `remote-${hub_id}` } }), { mode: 0o600 });
      // Simulate a stale loaded local task when installation starts.
      writeFileSync(join(state, label("hub")), "old-hub");
      const remoteFailure = run("7");
      expect(remoteFailure.status).toBe(7);
      expect(remoteFailure.stderr).toContain("已回滚应用和后台启动项");
      expect(readdirSync(state)).toEqual([label("collector")]);
      expect(readFileSync(join(state, label("collector")), "utf8")).toBe("old-collector");
      expect(readFileSync(plist(manual, "hub"), "utf8")).toBe("old-hub");
    }

    writeFileSync(binding, "{broken");
    writeFileSync(join(state, label("hub")), "old-hub");
    const malformed = run("7");
    expect(malformed.status).toBe(7);
    expect(malformed.stderr).toContain('{"code":"install_binding_invalid"}');
    // 损坏的绑定按远端处理：不重新拉起本机后台。
    expect(existsSync(join(state, label("hub")))).toBe(false);
    rmSync(binding);

    const success = run("0");
    expect(success.status).toBe(0);
    expect(readdirSync(apps)).toEqual(["Tacit.app"]);
    expect(readdirSync(app).sort()).toEqual(["Contents", "new"]);
    expect(readFileSync(join(state, label("hub")), "utf8")).toBe("new");
  } finally { rmSync(root, { force: true, recursive: true }); }
});
