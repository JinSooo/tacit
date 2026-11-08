import { createServer } from "node:net";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { ulid, type RecordV1 } from "../../packages/record/index.ts";
import { loadConfig } from "../src/config.ts";
import { HubDB } from "../src/db.ts";

export function fixture(overrides: Partial<RecordV1> = {}): RecordV1 {
  return { id: ulid(), schema: 1, device: "mac", source: "mac.screen", kind: "event", t_start: "2026-11-08T10:00:00+08:00", title: "合成活动", body: "这是合成的测试内容", capture: { method: "ax" }, sensitivity: "normal", ...overrides };
}
export function setup() {
  const dir = mkdtempSync(join(tmpdir(), "ra-hub-test-"));
  // 每个测试只传入合成环境，绝不会读取或创建真实钥匙串。
  const config = loadConfig({ RA_DATA_DIR: dir, RA_DB_KEY: "synthetic-db-key-0123456789", RA_PORT: "0" });
  const file = join(dir, "history.db");
  const db = new HubDB(file, config.dbKey);
  return { dir, config, file, db, cleanup() { db.close(); rmSync(dir, { recursive: true, force: true }); } };
}

// 只跳过操作系统明确禁止监听的环境，其他网络错误仍使测试失败。
export function networkDenied(): Promise<boolean> {
  return new Promise((resolve, reject) => {
    const probe = createServer();
    probe.once("error", (error: NodeJS.ErrnoException) => {
      if (error.code === "EPERM" || error.code === "EACCES") resolve(true);
      else reject(error);
    });
    probe.listen(0, "127.0.0.1", () => probe.close(() => resolve(false)));
  });
}
