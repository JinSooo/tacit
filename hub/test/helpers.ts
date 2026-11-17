import { createServer } from "node:net";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { toLocalIso, ulid, type RecordV1 } from "../../packages/record/index.ts";
import { loadConfig } from "../src/config.ts";
import { HubDB } from "../src/db.ts";
import type { DayOutput } from "../src/distill/prompts.ts";
import type { DistillStore } from "../src/distill/store.ts";

export const emptyDayOutput: DayOutput = { highlight: null, items: [] };

export function fixture(overrides: Partial<RecordV1> = {}): RecordV1 {
  return { id: ulid(), schema: 1, device: "mac", source: "mac.screen", kind: "event", t_start: "2026-11-08T10:00:00+08:00", title: "合成活动", body: "这是合成的测试内容", capture: { method: "ax" }, sensitivity: "normal", ...overrides };
}
export function reviewEvidence(store: DistillStore, threadID: string, at = Date.now()) {
  const time = toLocalIso(at);
  const record = fixture({ source: "manual.note", t_start: time });
  if (store.hub.ingest([record]).accepted !== 1) throw new Error("合成回顾依据写入失败");
  const id = ulid();
  store.createFrame({ id, key: "manual:fixture", record_ids: [record.id], t_start_ms: at, t_end_ms: at,
    chars: record.body.length, private: 0, status: "new" });
  store.assign(id,threadID,"user",1);
  return { id: record.id, at: time };
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
