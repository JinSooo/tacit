import {expect,test} from "bun:test";
import {mkdtempSync,mkdirSync,writeFileSync,readFileSync,symlinkSync,unlinkSync,rmSync} from "node:fs";
import {join} from "node:path";
import {homedir} from "node:os";
import {spawnSync} from "node:child_process";

test("安装 PATH 优先稳定入口，CLI 符号链接升级后无需重装",()=>{
  // Stable CLI entries must live outside temporary roots even when the checkout is under /tmp.
  const root=mkdtempSync(join(homedir(),".ra-path-test-")),bin=join(root,"bin");mkdirSync(bin);
  try {
    for(const v of ["v1","v2"]){mkdirSync(join(root,v));writeFileSync(join(root,v,"codex"),`#!/bin/sh\necho ${v}\n`,{mode:0o755});}
    symlinkSync(join(root,"v1","codex"),join(bin,"codex"));
    const source=readFileSync(new URL("../../install.sh",import.meta.url),"utf8");
    const fn=source.slice(source.indexOf("distill_path() {"),source.indexOf("write_distill_plist() {"));
    const script=join(root,"probe.sh");writeFileSync(script,fn+"\ndistill_path\n");
    const result=spawnSync("/bin/sh",[script],{encoding:"utf8",env:{...process.env,HOME:root,PATH:bin+":/usr/bin:/bin",BUN:process.execPath}});
    expect(result.status).toBe(0);const path=result.stdout.trim();
    expect(path.split(":")[0]).toBe(bin);
    unlinkSync(join(bin,"codex"));symlinkSync(join(root,"v2","codex"),join(bin,"codex"));
    const next=spawnSync("/bin/sh",["-c","codex"],{encoding:"utf8",env:{...process.env,PATH:path}});
    expect(next.status).toBe(0);expect(next.stdout.trim()).toBe("v2");
  } finally {rmSync(root,{recursive:true,force:true});}
});

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
