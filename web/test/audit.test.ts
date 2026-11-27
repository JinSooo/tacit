import { expect, test } from "bun:test";
import { auditAction, auditPath, auditResults, auditSummary, auditTargets, auditVisible, toolNames, type AuditTarget, type AuditTargetCache } from "../src/audit.ts";
import type { Api } from "../src/distillation.ts";
test("审计筛选和不透明游标正确编码；摘要写成人话，只显示已有参数", () => {
  const url = new URL(auditPath("claude-code", "opaque+/="), "http://localhost");
  expect(url.searchParams.get("tool")).toBe("claude-code");
  expect(url.searchParams.get("cursor")).toBe("opaque+/=");
  expect(auditSummary({ cwd: "/synthetic/repo" })).toBe("/synthetic/repo");
  expect(auditSummary({ cwd: "/Users/someone/repo" })).toBe("~/repo");
  expect(auditSummary({ id: "synthetic", level: "detail" })).toBe("");
  const targets = new Map<string, AuditTarget | null>([["synthetic", { kind: "record", title: "合成标题", search: "合成标题" }]]);
  expect(auditSummary({ id: "synthetic", level: "detail" }, targets)).toBe("合成标题");
  expect(auditSummary({ q_length: 12 })).toBe("搜索词 12 个字");
  expect(auditSummary({ from: "2026-01-01T08:30:00+08:00" })).toBe("2026-01-01 08:30 以后");
  expect(auditSummary({ from: "2026-01-01T08:30:00+08:00", to: "2026-01-02T09:00:00+08:00" })).toBe("2026-01-01 08:30 至 2026-01-02 09:00");
  expect(auditSummary({ result: "unchanged", redactions: 2 })).toBe("已经有了，没有重复添加，隐去了 2 处密钥");
  expect(auditSummary({})).toBe("");
  expect(auditAction("get", { level: "evidence" })).toBe("读取依据");
  expect(auditAction("context", { event: "compact" })).toBe("对话压缩后重新带入");
  expect(auditAction("context", {})).toBe("新会话开始时带入");
  expect(auditAction("search", {})).toBe("搜索历史记录");
  expect(auditAction("custom", {})).toBe("custom");
});
test("结果默认只列前 3 个，其余和认不出的折成另 N 项；展开后全部列出", () => {
  const items = ["a", "b", "c", "d", "e"];
  expect(auditVisible(items, 2, false)).toEqual({ shown: ["a", "b", "c"], hidden: 4, unresolved: 0 });
  expect(auditVisible(items, 2, true)).toEqual({ shown: items, hidden: 0, unresolved: 2 });
  expect(auditVisible(["a"], 0, false)).toEqual({ shown: ["a"], hidden: 0, unresolved: 0 });
});
const missing = () => Object.assign(new Error("合成内容不存在"), { status: 404 });
test("解析线程、未确认项目和记录标题，记录只保留标题，未知项合并计数", async () => {
  const calls: string[] = [];
  const api: Api = async <T>(path: string) => {
    calls.push(path);
    if (path === "/v1/threads/thread-one?level=brief") return { id: "thread-one", title: "修复合成线程" } as T;
    if (path === "/v1/projects/project-one?level=brief") return { id: "project-one", name: "合成项目", confirmed: 0 } as T;
    if (path === "/v1/records/record-one") return { id: "record-one", source: "mac.screen", title: "Zen · 合成活动标题", body: "合成正文不应保留" } as T;
    throw missing();
  };
  const ids = ["thread-one", "project-one", "record-one", "fact-one", "removed-one", "invalid/id"];
  const result = await auditTargets(api, ids);
  expect(result.get("thread-one")).toMatchObject({ kind: "thread", title: "修复合成线程" });
  expect(result.get("project-one")).toMatchObject({ kind: "project", title: "合成项目", item: { confirmed: 0 } });
  // 显示用冒号写法，点了按原标题搜索。
  expect(result.get("record-one")).toEqual({ kind: "record", title: "Zen：合成活动标题", search: "Zen · 合成活动标题" });
  expect(result.get("removed-one")).toBeNull();
  expect(auditResults(ids, result)).toEqual({ items: ids.slice(0, 3).map(id => ({ id, target: result.get(id)! })), unresolved: 3 });
  expect(calls).toHaveLength(12);
  expect(auditResults(["loading"], result)).toEqual({ items: [], unresolved: 0 });
});
test("只将 HTTP 404 视为不存在，其他错误不继续探测且允许重试", async () => {
  for (const error of [Object.assign(new Error("内容不存在"), { status: 500 }), Object.assign(new Error("无权限"), { status: 403 }), new Error("网络断开 404"), new Error("存储操作失败")]) {
    const calls: string[] = [];
    const cache: AuditTargetCache = new Map();
    const api: Api = async path => { calls.push(path); throw error; };
    await expect(auditTargets(api, ["id"], undefined, cache)).rejects.toThrow(error.message);
    expect(calls).toHaveLength(1);
    expect(cache.size).toBe(0);
    await expect(auditTargets(api, ["id"], undefined, cache)).rejects.toThrow(error.message);
    expect(calls).toHaveLength(2);
  }
});
test("同页重复和跨页重复只解析一次，包括未解析 ID", async () => {
  const calls: string[] = [];
  const cache: AuditTargetCache = new Map();
  const api: Api = async <T>(path: string) => {
    calls.push(path);
    if (path.includes("threads/thread-one")) return { id: "thread-one", title: "合成标题" } as T;
    throw missing();
  };
  const first = await auditTargets(api, ["thread-one", "thread-one", "gone", "gone"], undefined, cache);
  const second = await auditTargets(api, ["gone", "thread-one"], undefined, cache);
  expect(first.get("thread-one")).toEqual(second.get("thread-one"));
  expect(second.get("gone")).toBeNull();
  expect(calls).toHaveLength(4);
});
test("每批探测最多并发四个请求", async () => {
  let active = 0;
  let peak = 0;
  const api: Api = async () => {
    peak = Math.max(peak, ++active);
    await new Promise(resolve => setTimeout(resolve, 1));
    active--;
    throw missing();
  };
  const result = await auditTargets(api, Array.from({ length: 9 }, (_, index) => `synthetic-${index}`));
  expect(peak).toBe(4);
  expect([...result.values()]).toEqual(Array(9).fill(null));
});
test("取消请求不缓存不存在，后续可以重新解析", async () => {
  const controller = new AbortController();
  const cache: AuditTargetCache = new Map();
  const calls: string[] = [];
  const api: Api = async <T>(path: string, init?: RequestInit) => {
    calls.push(path);
    if (init?.signal === controller.signal) {
      controller.abort();
      throw new DOMException("合成取消", "AbortError");
    }
    return { id: "thread-one", title: "合成重试标题" } as T;
  };
  await expect(auditTargets(api, ["thread-one"], controller.signal, cache)).rejects.toThrow();
  expect(cache.size).toBe(0);
  const result = await auditTargets(api, ["thread-one"], undefined, cache);
  expect(result.get("thread-one")).toMatchObject({ title: "合成重试标题" });
  expect(calls).toHaveLength(2);
});
test("共享缓存复用进行中的同 ID 请求", async () => {
  const cache: AuditTargetCache = new Map();
  let calls = 0;
  const api: Api = async <T>() => {
    calls++;
    await new Promise(resolve => setTimeout(resolve, 1));
    return { id: "thread-one", title: "合成并发标题" } as T;
  };
  const results = await Promise.all([auditTargets(api, ["thread-one"], undefined, cache), auditTargets(api, ["thread-one"], undefined, cache)]);
  expect(calls).toBe(1);
  expect(results[0].get("thread-one")).toEqual(results[1].get("thread-one"));
});


test("审计筛选和结果显示新增 AI 工具的名称", () => {
  expect(toolNames).toMatchObject({ antigravity: "Antigravity", "copilot-cli": "Copilot CLI", "kimi-cli": "Kimi CLI" });
});
