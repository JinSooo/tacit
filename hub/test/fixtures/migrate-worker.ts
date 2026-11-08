import { createRequire } from "node:module";
import { existsSync, writeFileSync } from "node:fs";
import { HubDB } from "../../src/db.ts";
const Database = createRequire(import.meta.url)("better-sqlite3-multiple-ciphers");
const [file, key, gate, index] = process.argv.slice(2) as [string, string, string, string];
const pragma = Database.prototype.pragma;
let first = true;
Database.prototype.pragma = function (source: string, options: unknown) {
  const value = pragma.call(this, source, options);
  if (source === "user_version" && first) {
    first = false;
    writeFileSync(`${gate}-${index}`, "ready");
    const deadline = Date.now() + 10000;
    while (!existsSync(gate)) {
      if (Date.now() > deadline) throw new Error("等待合成迁移测试超时");
      Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, 5);
    }
  }
  return value;
};
try {
  const hub = new HubDB(file, key);
  console.log(hub.db.pragma("user_version", { simple: true }));
  hub.close();
} catch (error) {
  console.error(error instanceof Error ? error.message : "迁移失败");
  process.exitCode = 1;
}
