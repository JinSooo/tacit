import { expect, test } from "bun:test";
import { createHash } from "node:crypto";
import { chmodSync, mkdtempSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { base32 } from "../src/devices/envelope.ts";
import { readHubBinding } from "../src/hub-binding.ts";

const hub_pk = Buffer.alloc(32, 7).toString("base64url");
const hub_id = base32(createHash("sha256").update(Buffer.alloc(32, 7)).digest().subarray(0, 16));
const remote = { hub_id, hub_pk, dir: `remote-${hub_id}` };

// 2026-11-24 A1 审查回归：绑定文件存在但损坏、矛盾或不安全时，不能静默当成本机模式。
test("后台绑定只有文件不存在才算本机，损坏、矛盾、链接和宽权限一律拒绝", () => {
  const dir = mkdtempSync(join(tmpdir(), "hub-binding-"));
  const file = join(dir, "hub-binding.json");
  const write = (value: unknown, mode = 0o600) => {
    rmSync(file, { force: true });
    writeFileSync(file, typeof value === "string" ? value : JSON.stringify(value), { mode });
    chmodSync(file, mode);
  };
  try {
    expect(readHubBinding(dir)).toEqual({ generation: 0, remote: null });
    const base = { version: 1, updated_at: "2026-11-24T00:00:00Z" };
    write({ ...base, generation: 0, target: "local", phase: "local", remote: null });
    expect(readHubBinding(dir)).toEqual({ generation: 0, remote: null });
    write({ ...base, generation: 1, target: "remote", phase: "preparing", remote });
    expect(readHubBinding(dir)).toEqual({ generation: 1, remote: null });
    write({ ...base, generation: 2, target: "remote", phase: "committed", remote });
    expect(readHubBinding(dir)).toEqual({ generation: 2, remote });

    for (const bad of ["{}", "null", "[]", "123", "", "{\"version\":0}",
      { ...base, version: 99, generation: 1, target: "local", phase: "local" },
      { ...base, generation: 1, target: "local", phase: "committed" },
      { ...base, generation: 1, target: "remote", phase: "local", remote },
      { ...base, generation: 0, target: "remote", phase: "committed", remote },
      { ...base, generation: 1, target: "remote", phase: "committed" },
      { ...base, generation: 1, target: "remote", phase: "committed", remote: { ...remote, dir: "../x" } }]) {
      write(bad);
      expect(() => readHubBinding(dir)).toThrow();
    }
    write({ ...base, generation: 2, target: "remote", phase: "committed", remote }, 0o644);
    expect(() => readHubBinding(dir)).toThrow();
    rmSync(file);
    symlinkSync(join(dir, "missing"), file);
    expect(() => readHubBinding(dir)).toThrow();
    // 第 2 轮审查回归：数据目录本身是链接时与 Mac 端一致地拒绝。
    rmSync(file);
    write({ ...base, generation: 0, target: "local", phase: "local", remote: null });
    const linked = dir + "-link";
    symlinkSync(dir, linked);
    try { expect(() => readHubBinding(linked)).toThrow(); } finally { rmSync(linked); }
  } finally { rmSync(dir, { recursive: true, force: true }); }
});
