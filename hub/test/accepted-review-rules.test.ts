import { expect, test } from "bun:test";
import { setup, fixture } from "./helpers.ts";
import { startServer } from "../src/server.ts";
import { AgentReads } from "../src/agent.ts";
import { currentNow } from "../src/now-status.ts";
import { DistillStore } from "../src/distill/store.ts";

test("真实 HTTP：受限令牌可查询/追加，拒绝删除、设置和普通记录读取", async () => {
  const ctx = setup(), record = fixture(); ctx.db.ingest([record]);
  const server = startServer({ db: ctx.db, token: ctx.config.token, agentToken: ctx.config.agentToken, port: 0 });
  const request = (path: string, method = "GET", body?: object) => fetch(`http://127.0.0.1:${server.port}${path}`, { method, headers: { authorization: `Bearer ${ctx.config.agentToken}`, "content-type": "application/json" }, ...(body ? { body: JSON.stringify(body) } : {}) });
  try {
    expect(ctx.config.agentToken).not.toBe(ctx.config.token);
    expect((await request("/v1/agent/timeline?tool=codex")).status).toBe(200);
    expect((await request("/v1/agent/append?tool=codex", "POST", { title: "合成手动记录", body: "合成手动内容" })).status).toBe(200);
    for (const [path, method] of [[`/v1/records/${record.id}`, "DELETE"], ["/v1/settings/general", "PUT"], ["/v1/records", "GET"], ["/v1/audit", "GET"]]) {
      expect((await request(path!, method)).status).toBe(403);
    }
    expect(ctx.db.get(record.id)?.id).toBe(record.id);
  } finally { server.stop(true); ctx.cleanup(); }
});

test("多词搜索在原始记录和事项/项目中均要求全部命中，顺序与间距不影响", async () => {
  const ctx = setup();
  try {
    const record = fixture({ title: "登录流程", body: "已经完成异常修复" }); ctx.db.ingest([record, fixture({ title: "登录", body: "无关内容" })]);
    expect(ctx.db.list(new URLSearchParams({ q: "修复 登录" })).records.map(r => r.id)).toEqual([record.id]);
    const store = new DistillStore(ctx.db);
    store.upsertThread({ id: "search-thread", title: "登录", brief: "完成异常修复", status: "active", last_ms: Date.now() });
    const response = await new AgentReads(ctx.db).handle("search", new URLSearchParams({ tool: "codex", q: "修复 登录" }));
    const data = await response.json(); expect(data.threads.map((t: any) => t.id)).toEqual(["search-thread"]);
    expect(data.records.map((r: any) => r.id)).toEqual([record.id]);
    expect(ctx.db.list(new URLSearchParams({ q: '登录 " OR *' })).records).toEqual([]);
  } finally { ctx.cleanup(); }
});

test("此刻在模型失败和新活动未整理时提示，成功恢复后撤下提示", () => {
  const ctx = setup(), now = Date.now(), store = new DistillStore(ctx.db);
  try {
    ctx.db.ingest([fixture({ t_start: new Date(now).toISOString() })]);
    store.setState("now", { brief: "旧摘要", updated_at: new Date(now - 7200_000).toISOString() });
    expect(currentNow(ctx.db, now)?.feedback).toContain("新活动");
    ctx.db.db.prepare("INSERT INTO llm_usage(id,at,task,ok) VALUES(?,?,?,?)").run("a", new Date(now).toISOString(), "thread_digest", 0);
    expect(currentNow(ctx.db, now)?.feedback).toContain("失败");
    store.setState("now", { brief: "新摘要", updated_at: new Date(now + 1).toISOString() });
    expect(currentNow(ctx.db, now + 1)?.feedback).toBeNull();
  } finally { ctx.cleanup(); }
});
