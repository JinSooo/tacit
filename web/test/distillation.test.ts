import { expect, test } from "bun:test";
import { createDistillationApi, groupFacts, pendingSummary, pendingTitle, recentPaused, relativeTime, type Api, type Fact } from "../src/distillation.ts";

test("最近暂停只留 3 天内有活动的暂停线程，最近的在前；翻页到更早的就停", async () => {
  const now = Date.parse("2026-11-10T12:00:00+08:00");
  const day = 86_400_000;
  const thread = (id: string, last_ms: number | null, status: "paused" | "active" = "paused") => ({ id, project_id: null, title: id, brief: null, last_ms, status });
  expect(recentPaused([thread("old", now - 4 * day), thread("a", now - day), thread("b", now - 60_000), thread("none", null), thread("act", now, "active")], now).map(t => t.id)).toEqual(["b", "a"]);
  const paths: string[] = [];
  const client = createDistillationApi(async <T,>(path: string) => {
    paths.push(path);
    const page = new URL(path, "http://x").searchParams.get("cursor");
    return (page ? { threads: [thread("b", now - 2 * day), thread("c", now - 5 * day)], next_cursor: "never" } : { threads: [thread("a", now - day)], next_cursor: "p2" }) as T;
  });
  expect((await client.pausedSince(now - 3 * day)).map(t => t.id)).toEqual(["a", "b"]);
  expect(paths).toEqual(["/v1/threads?status=paused&limit=100", "/v1/threads?status=paused&limit=100&cursor=p2"]);
});
test("待确认标题；离开网页时的提交带 keepalive", async () => {
  expect(pendingTitle({ id: "1", kind: "merge", payload: { a_name: "甲", b_name: "乙" } })).toBe("甲 和 乙");
  expect(pendingTitle({ id: "2", kind: "thread_done", payload: { title: "合成线程" } })).toBe("合成线程");
  expect(pendingTitle({ id: "3", kind: "voice", payload: {} })).toBe("新声音");
  const inits: (RequestInit | undefined)[] = [];
  const client = createDistillationApi(async <T,>(_path: string, init?: RequestInit) => { inits.push(init); return {} as T; });
  await client.resolve("p", { action: "done" });
  await client.resolve("p", { action: "done" }, true);
  expect(inits[0]!.keepalive).toBeUndefined();
  expect(inits[1]!.keepalive).toBe(true);
});

const fact: Fact = { id: "fact-synthetic", thread_id: "thread-synthetic", project_id: "project-synthetic", kind: "decision", text: "使用本地缓存", evidence: ["record-synthetic"] };
test("facts 按语义分组，推测独立，排除失效与已替代条目且不修改输入", () => {
  const facts: Fact[] = [
    { ...fact, id: "inference", kind: "inference", confidence: .72 },
    { ...fact, id: "next", kind: "next" },
    { ...fact, id: "invalid", invalid_at: "2026-11-08T00:00:00Z" },
    { ...fact, id: "superseded", superseded_by: "replacement" },
    { ...fact, id: "open", kind: "open" }, { ...fact, id: "rejected", kind: "rejected" }, fact,
  ];
  const before = structuredClone(facts);
  const groups = groupFacts(facts);
  expect(groups.map(group => group.kind)).toEqual(["decision", "rejected", "open", "next", "inference"]);
  expect(groups.flatMap(group => group.facts).map(fact => fact.id)).not.toContain("invalid");
  expect(groups[0]!.facts).toEqual([fact]);
  expect(groups.at(-1)!.facts[0]!.confidence).toBe(.72);
  expect(facts).toEqual(before);
  expect(groupFacts([])).toEqual([]);
});
test("相对时间处理零值、边界、未来和缺失时间", () => {
  const now = Date.parse("2026-11-08T12:00:00Z");
  for (const [delta, label] of [[0, "刚刚"], [59999, "刚刚"], [60000, "1分钟前"], [3599999, "59分钟前"], [3600000, "1小时前"], [86400000, "1天前"], [-60000, "刚刚"]] as const) expect(relativeTime(now - delta, now)).toBe(label);
  expect(relativeTime("2026-11-08T19:00:00+08:00", now)).toBe("1小时前");
  expect(relativeTime(null, now)).toBe("暂无活动");
  expect(relativeTime("bad", now)).toBe("时间未知");
  expect(relativeTime(0, 60000)).toBe("1分钟前");
});
test("待确认依据包含分类 keys 和样例线程标题，不泄露未要求的正文", () => {
  expect(pendingSummary({ keys: { repos: ["/synthetic/project"], hosts: ["example.invalid"], chats: ["合成讨论"] }, threads: [{ id: "t", title: "缓存写入", brief: "此正文不作为依据" }] })).toEqual(["仓库：/synthetic/project", "网站：example.invalid", "会话：合成讨论", "事项：缓存写入"]);
  expect(pendingSummary({})).toEqual([]);
});
test("mock 接口覆盖当前摘要、列表分页、项目线程及 detail/evidence 请求", async () => {
  const paths: string[] = [];
  const controller = new AbortController();
  const api: Api = async <T,>(path: string, init?: RequestInit) => {
    expect(init?.signal).toBe(controller.signal);
    paths.push(path);
    const data: Record<string, unknown> = {
      "/v1/now": { now: null }, "/v1/projects": { projects: [] }, "/v1/pending": { pending: [] },
      "/v1/threads?status=active": { threads: [{ id: "t1" }], next_cursor: "page2" },
      "/v1/threads?status=active&cursor=page2": { threads: [{ id: "t1" }, { id: "t2" }], next_cursor: null },
      "/v1/threads?project=p": { threads: [], next_cursor: null },
      "/v1/threads/t%2F1?level=detail": { id: "t/1", detail: { goal: "合成目标" }, facts: [fact] },
      "/v1/threads/t%2F1?level=evidence": { records: [{ id: "record-synthetic", title: "合成记录", t_start: "2026-11-08T00:00:00Z" }] },
      "/v1/projects/p?level=detail": { id: "p", facts: [] },
      "/v1/projects/p?level=evidence": { id: "p", records: [] },
    };
    if (!(path in data)) throw new Error(`未预期的请求：${path}`);
    return data[path] as T;
  };
  const client = createDistillationApi(api);
  expect(await client.now(controller.signal)).toEqual({ now: null });
  expect(await client.projects(controller.signal)).toEqual({ projects: [] });
  expect(await client.pending(controller.signal)).toEqual({ pending: [] });
  expect((await client.threads(undefined, controller.signal)).map(thread => thread.id)).toEqual(["t1", "t2"]);
  expect(await client.threads("p", controller.signal)).toEqual([]);
  expect((await client.thread("t/1", "detail", controller.signal)).facts).toEqual([fact]);
  expect((await client.thread("t/1", "evidence", controller.signal)).records?.[0]?.title).toBe("合成记录");
  await client.project("p", "detail", controller.signal);
  await client.project("p", "evidence", controller.signal);
  expect(paths.length).toBe(10);
});
test("mock 写入覆盖所有待确认动作与 supersedes 修正，失败向调用方传播", async () => {
  const writes: { path: string; body: Record<string, unknown> }[] = [];
  const client = createDistillationApi(async <T,>(path: string, init?: RequestInit) => {
    expect(init?.method).toBe("POST");
    writes.push({ path, body: JSON.parse(init!.body as string) });
    return { ok: true } as T;
  });
  for (const action of ["confirm", "rename", "merge_into", "ignore", "done", "continue", "abandon"] as const) await client.resolve("pending/1", { action, ...(action === "rename" ? { name: "合成新项目" } : {}), ...(action === "merge_into" ? { target: "existing" } : {}) });
  expect(writes[1]).toEqual({ path: "/v1/pending/pending%2F1", body: { action: "rename", name: "合成新项目" } });
  expect(writes[2]!.body).toEqual({ action: "merge_into", target: "existing" });
  await client.correct(fact, "  改用流式写入  ");
  expect(writes.at(-1)).toEqual({ path: "/v1/facts", body: { kind: "decision", text: "改用流式写入", supersedes: fact.id, evidence: fact.evidence, thread_id: fact.thread_id, project_id: fact.project_id } });
  expect(() => client.correct(fact, "  ")).toThrow("请填写修正内容");
  const failing = createDistillationApi(async () => { throw new Error("合成服务故障"); });
  await expect(failing.resolve("p", { action: "confirm" })).rejects.toThrow("合成服务故障");
});
