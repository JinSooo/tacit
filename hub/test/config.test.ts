import { expect, test } from "bun:test";
import { statSync, writeFileSync, readFileSync, renameSync, rmSync } from "node:fs";
import { join } from "node:path";
import { loadConfig } from "../src/config.ts";
import { setup } from "./helpers.ts";

test("RA_DB_KEY 优先，token 生成权限 0600 且重启稳定", () => {
  const ctx = setup();
  try {
    const env = { RA_DATA_DIR: ctx.dir, RA_DB_KEY: "synthetic-explicit-key" };
    const config = loadConfig(env);
    expect(config.dbKey).toBe(env.RA_DB_KEY);
    expect(config.port).toBe(47823);
    expect(config.token).toBe(ctx.config.token);
    const file = join(ctx.dir, "token");
    expect(statSync(file).mode & 0o777).toBe(0o600);
    expect(readFileSync(file, "utf8").trim()).toBe(config.token);
    expect(() => loadConfig({ ...env, RA_DB_KEY: "" })).toThrow();
    expect(() => loadConfig({ ...env, RA_PORT: "65536" })).toThrow();
    writeFileSync(file, "");
    expect(() => loadConfig(env)).toThrow();
  } finally { ctx.cleanup(); }
});

test("钥匙串返回 44 时，主库或迁移备份存在就不新建密钥", () => {
  const ctx = setup();
  try {
    ctx.db.close();
    const env = { RA_DATA_DIR: ctx.dir };
    const calls: string[] = [];
    const security = ([command]: string[]) => {
      calls.push(command!);
      return { status: command === "find-generic-password" ? 44 : 0, stdout: "" };
    };
    expect(() => loadConfig(env, security)).toThrow(expect.objectContaining({ code: "db_key_missing" }));
    const backup = `${ctx.file}.migration-v11.bak`;
    renameSync(ctx.file, backup);
    expect(() => loadConfig(env, security)).toThrow(expect.objectContaining({ code: "db_key_missing" }));
    expect(calls).toEqual(["find-generic-password", "find-generic-password"]);
    rmSync(backup);
    expect(loadConfig(env, security).dbKey).toMatch(/^[0-9a-f]{64}$/);
    expect(calls.slice(2)).toEqual(["find-generic-password", "add-generic-password"]);
  } finally { ctx.cleanup(); }
});

test("钥匙串读取超时或失败时返回不可读，禁止写入新密钥", () => {
  const ctx = setup();
  try {
    for (const result of [{ status: null, stdout: "", error: new Error("ETIMEDOUT") }, { status: 36, stdout: "" }]) {
      const calls: string[] = [];
      expect(() => loadConfig({ RA_DATA_DIR: ctx.dir }, ([command]) => {
        calls.push(command!);
        return result;
      })).toThrow(expect.objectContaining({ code: "db_key_unreadable" }));
      expect(calls).toEqual(["find-generic-password"]);
    }
  } finally { ctx.cleanup(); }
});
