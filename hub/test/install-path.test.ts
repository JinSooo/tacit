import {expect,test} from "bun:test";
import {mkdtempSync,mkdirSync,writeFileSync,readFileSync,symlinkSync,unlinkSync,rmSync} from "node:fs";
import {join} from "node:path";
import {spawnSync} from "node:child_process";

test("安装 PATH 优先稳定入口，CLI 符号链接升级后无需重装",()=>{
  const root=mkdtempSync(join(process.cwd(),".ra-path-test-")),bin=join(root,"bin");mkdirSync(bin);
  try {
    for(const v of ["v1","v2"]){mkdirSync(join(root,v));writeFileSync(join(root,v,"codex"),`#!/bin/sh\necho ${v}\n`,{mode:0o755});}
    symlinkSync(join(root,"v1","codex"),join(bin,"codex"));
    const source=readFileSync(new URL("../../install.sh",import.meta.url),"utf8");
    const fn=source.slice(source.indexOf("distill_path() {"),source.indexOf("write_distill_plist() {"));
    const script=join(root,"probe.sh");writeFileSync(script,fn+"\ndistill_path\n");
    const result=spawnSync("/bin/sh",[script],{encoding:"utf8",env:{...process.env,PATH:bin+":/usr/bin:/bin",BUN:process.execPath}});
    expect(result.status).toBe(0);const path=result.stdout.trim();
    unlinkSync(join(bin,"codex"));symlinkSync(join(root,"v2","codex"),join(bin,"codex"));
    const next=spawnSync("/bin/sh",["-c","codex"],{encoding:"utf8",env:{...process.env,PATH:path}});
    expect(next.stdout.trim()).toBe("v2");
  } finally {rmSync(root,{recursive:true,force:true});}
});
