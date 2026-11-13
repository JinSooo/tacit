import { constants, openSync, closeSync, fstatSync, fchmodSync, readSync, writeFileSync, renameSync, ftruncateSync, fsyncSync, unlinkSync, lstatSync } from "node:fs";
import { join } from "node:path";
import { randomUUID } from "node:crypto";

/** launchd 持有活动日志 fd，因此采用 copy-truncate；不改名活动文件。 */
export function rotateLog(path: string, limit = 5 * 1024 * 1024): boolean {
  let fd: number;
  try { fd = openSync(path, constants.O_RDWR | constants.O_NOFOLLOW); }
  catch (e) { if ((e as NodeJS.ErrnoException).code === "ENOENT") return false; throw e; }
  const temp = `${path}.${randomUUID()}.rotate-tmp`;
  try {
    const stat = fstatSync(fd);
    if (!stat.isFile()) throw new Error("日志路径不是普通文件");
    fchmodSync(fd,0o600);
    if (stat.size < limit) return false;
    // 即便旧日志很大，也只分配和保留最近 limit 字节。
    const tail = Buffer.alloc(Math.min(stat.size,limit));
    let read = 0;
    while (read < tail.length) {
      const n = readSync(fd,tail,read,tail.length-read,stat.size-tail.length+read);
      if (!n) throw new Error("日志读取未完成");
      read += n;
    }
    const out = openSync(temp,constants.O_WRONLY|constants.O_CREAT|constants.O_EXCL|constants.O_NOFOLLOW,0o600);
    try { writeFileSync(out,tail);fsyncSync(out); } finally { closeSync(out); }
    for (const target of [`${path}.1`,`${path}.2`]) {
      try { if (!lstatSync(target).isFile() || lstatSync(target).isSymbolicLink()) throw new Error("日志副本路径无效"); }
      catch (e) { if ((e as NodeJS.ErrnoException).code !== "ENOENT") throw e; }
    }
    try { renameSync(`${path}.1`,`${path}.2`); } catch (e) { if ((e as NodeJS.ErrnoException).code !== "ENOENT") throw e; }
    renameSync(temp,`${path}.1`); ftruncateSync(fd,0);fsyncSync(fd);
    return true;
  } finally { closeSync(fd); try { unlinkSync(temp); } catch {} }
}

export function startLogRetention(dataDir: string): () => void {
  const run = () => {
    for (const name of ["hub","distill","collector"]) {
      try { rotateLog(join(dataDir,"logs",`${name}.log`)); }
      catch { console.error(JSON.stringify({location:"logs.rotate",category:"storage",log:name})); }
    }
  };
  run(); const timer = setInterval(run,30_000);timer.unref();return () => clearInterval(timer);
}
