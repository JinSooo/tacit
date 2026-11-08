import { expect, test } from "bun:test";
import { statSync, writeFileSync, readFileSync } from "node:fs";
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
