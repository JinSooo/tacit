import {expect,test} from "bun:test";
import {mkdtempSync,mkdirSync,writeFileSync,symlinkSync,rmSync} from "node:fs";
import {join} from "node:path";
import {homedir} from "node:os";
import {spawnSync} from "node:child_process";

test.skipIf(process.platform !== "darwin")("旧应用在用户应用目录时原地改名，保护同名第三方应用及符号链接", () => {
  const root = mkdtempSync(join(homedir(), ".ra-app-test-"));
  const system = join(root, "System Apps"), user = join(root, "User Apps");
  const installed = join(user, "Record Anything.app");
  const foreign = join(system, "Tacit.app");
  const desired = join(user, "Tacit.app");
  const helpers = new URL("../../scripts/mac-app.sh", import.meta.url).pathname;
  const writeBundle = (path: string, id: string) => {
    const contents = join(path, "Contents");
    mkdirSync(contents, { recursive: true });
    writeFileSync(join(contents, "Info.plist"), `<plist version="1.0"><dict><key>CFBundleIdentifier</key><string>${id}</string></dict></plist>`);
  };
  const run = (command: string, ...args: string[]) => spawnSync("/bin/sh",
    ["-ec", '. "$1"; shift; ' + command, "tacit-test", helpers, ...args], { encoding: "utf8" });
  try {
    writeBundle(installed, "dev.record-anything.collector");
    writeBundle(foreign, "dev.example.tacit");
    const location = run('tacit_install_dir "$1" "$2"', system, user);
    expect(location.status).toBe(0);
    expect(location.stdout.trim()).toBe(user);
    expect(run('tacit_check_destination "$1"', foreign).status).toBe(1);
    expect(run('tacit_check_destination "$1"', desired).status).toBe(0);
    symlinkSync(installed, desired);
    expect(run('tacit_check_destination "$1"', desired).status).toBe(1);
  } finally { rmSync(root, { recursive: true, force: true }); }
});
