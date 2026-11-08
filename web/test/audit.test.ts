import { expect, test } from "bun:test";
import { auditPath, auditSummary, auditTargets } from "../src/audit.ts";
import type { Api } from "../src/distillation.ts";
test("审计筛选和不透明游标正确编码；摘要只显示已有参数", () => {
  const url = new URL(auditPath("claude-code", "opaque+/="), "http://localhost");
  expect(url.searchParams.get("tool")).toBe("claude-code");
  expect(url.searchParams.get("cursor")).toBe("opaque+/=");
  expect(auditSummary({ cwd: "/synthetic/repo" })).toBe("/synthetic/repo");
  expect(auditSummary({ id: "synthetic", level: "detail" })).toBe("synthetic / detail");
  expect(auditSummary({ q_length: 0 })).toBe("q_length=0");
  expect(auditSummary({ from: "2026-01-01" })).toBe("2026-01-01 至 不限");
  expect(auditSummary({})).toBe("无");
});
test("只有仍存在的线程和项目有链接，记录和删除的 ID 只显示；服务故障不伪装成不存在", async () => {
  const calls: string[] = [];
  const api: Api = async <T>(path: string) => {
    calls.push(path);
    if (path.includes("threads/thread-one") || path.includes("projects/project-one")) return { id: "合成实体" } as T;
    throw new Error("内容不存在");
  };
  const result = await auditTargets(api, ["thread-one", "project-one", "record-one", "removed-one"]);
  expect([...result.entries()].sort()).toEqual([["project-one", "project"], ["thread-one", "thread"]]);
  expect(calls).toHaveLength(7);
  await expect(auditTargets(async () => { throw new Error("存储操作失败"); }, ["id"])).rejects.toThrow("存储操作失败");
});
