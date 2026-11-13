import {expect,test} from "bun:test";
import {mkdtempSync,rmSync,openSync,closeSync,writeSync,readFileSync,statSync,symlinkSync,writeFileSync} from "node:fs";
import {tmpdir} from "node:os";
import {join} from "node:path";
import {rotateLog} from "../src/log-retention.ts";

test("轮转限制活动日志和两份副本，已有 append fd 继续写入，拒绝链接",()=>{
  const dir=mkdtempSync(join(tmpdir(),"ra-log-")),file=join(dir,"test.log");
  const fd=openSync(file,"a",0o600);
  try {
    for (const text of ["11111111","22222222","33333333"]) {writeSync(fd,text);expect(rotateLog(file,8)).toBe(true);}
    writeSync(fd,"new"); expect(readFileSync(file,"utf8")).toBe("new");
    expect(readFileSync(file+".1","utf8")).toBe("33333333");expect(readFileSync(file+".2","utf8")).toBe("22222222");
    expect(statSync(file+".1").mode&0o777).toBe(0o600);expect(rotateLog(file,8)).toBe(false);
    const other=join(dir,"other");writeFileSync(other,"keep");symlinkSync(other,join(dir,"link"));
    expect(()=>rotateLog(join(dir,"link"),1)).toThrow();expect(readFileSync(other,"utf8")).toBe("keep");
  } finally {closeSync(fd);rmSync(dir,{recursive:true,force:true});}
});
