import { expect, test } from "bun:test";
import { toLocalIso } from "../../packages/record/index.ts";
import { dayStep, distillRound, frameView, touchThread, type LLM } from "../src/distill/run.ts";
import { DistillStore } from "../src/distill/store.ts";
import { createHandler } from "../src/server.ts";
import { emptyDayOutput, fixture, setup } from "./helpers.ts";

test("每日回顾按角色取材、严格引用当日原文，浏览器和屏幕正文留在可搜索历史", async () => {
  const ctx = setup(), store = new DistillStore(ctx.db);
  const date = "2026-11-16", base = new Date(date + "T10:00:00").getTime(), now = base + 3600_000;
  const record = (offset: number, overrides: Parameters<typeof fixture>[0]) =>
    fixture({ t_start: toLocalIso(base + offset * 60_000), ...overrides });
  const session = record(0, { source: "codex.session", source_ref: "synthetic-session",
    body: "[我] 合成的本人决定。\n\n[AI] 合成的 AI 提案。" });
  const chat = record(5, { source: "mac.wechat", body: "合成的对方说明。",
    context: { chat: "合成群", extra: { from_me: 0 } } });
  const audio = record(10, { source: "mac.audio", source_ref: "synthetic-audio",
    body: "[10:10:05] 我：合成的本人发言。\n[10:10:08] 对方：合成的对方录音。" });
  const note = record(15, { source: "manual.note", body: "合成的本人笔记。" });
  const screen = record(20, { body: "合成屏幕正文应排除" });
  const browser = record(25, { source: "mac.browser", source_ref: "synthetic-browser", body: "合成浏览器正文应排除" });
  const privateNote = record(30, { source: "manual.note", sensitivity: "private", body: "合成私密笔记应排除" });
  const crossing = record(50, { source: "claude_code.session", source_ref: "synthetic-late",
    t_end: toLocalIso(now + 60_000), body: "[我] 合成的跨截止点内容应排除。" });
  try {
    const all = [session, chat, audio, note, screen, browser, privateNote, crossing];
    expect(ctx.db.ingest(all).accepted).toBe(all.length);
    store.createFrame({ id: "skeleton", key: "app:synthetic", record_ids: [screen.id,browser.id],
      t_start_ms: base + 20 * 60_000, t_end_ms: base + 25 * 60_000, chars: 10, private: 0, status: "new" });
    const view = frameView(store, store.frames()[0]!, { maxRecords: 10, excerpt: () => 600 });
    expect(view.records.map(row => row.excerpt)).toEqual(["", ""]);
    expect(view.records.map(row => row.id)).toEqual([screen.id,browser.id]);
    const llm: LLM = { async complete<T>(req: import("../src/llm/index.ts").LLMRequest) {
      if (req.task !== "day") return { ok: true, data: { brief: "合成简略版" } as T, ms: 1 };
      const { evidence, blocks } = JSON.parse(/<data>\n([\s\S]*)\n<\/data>/.exec(req.prompt)![1]!);
      expect(blocks).toHaveLength(1);
      expect(req.prompt).not.toContain("应排除");
      expect(evidence.map((entry: { source: string; role: string }) => [entry.source,entry.role])).toEqual([
        ["codex.session","user"], ["codex.session","assistant"], ["mac.wechat","other"],
        ["mac.audio","user"], ["mac.audio","other"], ["manual.note","user"],
      ]);
      const [me, ai, incoming, spoken, , notes] = evidence.map((entry: { key: string }) => entry.key);
      const out = {
        ...emptyDayOutput,
        decisions: [{ text: "本人已确认", refs: [me] }, { text: "把提案误作决定", refs: [ai] }],
        blockers: [{ text: "对方提到一处未完成", refs: [incoming] }, { text: "无依据条目", refs: ["r999"] }],
        authored: [{ text: "本人写下笔记", refs: [notes, spoken] }, { text: "把对方叙述写成本人感受", refs: [incoming] }],
        suggestions: Array.from({ length: 4 }, (_, i) => ({ text: `合成建议 ${i+1}`, refs: [me] })),
      };
      return { ok: true, data: out as T, ms: 1 };
    } };
    expect(await dayStep({ db: ctx.db, llm }, store, date, now)).toEqual({ ok: true, calls: 2 });
    const handler = createHandler({ db: ctx.db, token: ctx.config.token });
    const read = (route: string) => handler(new Request("http://127.0.0.1:47823" + route, {
      headers: { host: "127.0.0.1:47823", authorization: `Bearer ${ctx.config.token}` },
    }));
    const diary = await (await read(`/v1/days/${date}`)).json();
    const sections = diary.detail.sections;
    expect(sections.progress).toEqual([{ text: "本人已确认", evidence: [{ id: session.id, at: session.t_start }] }]);
    expect(sections.blockers.map((entry: { text: string }) => entry.text)).toEqual(["对方提到一处未完成"]);
    expect(sections.authored[0].evidence.map((e: {id:string}) => e.id)).toEqual([note.id,audio.id]);
    expect(sections.authored).toHaveLength(1);
    expect(sections.suggestions).toHaveLength(3);
    expect(diary.detail.cutoff).toBe(toLocalIso(now));
    expect((await read(`/v1/records/${sections.progress[0].evidence[0].id}`)).status).toBe(200);
    expect(ctx.db.get(screen.id)?.body).toBe(screen.body);
  } finally { ctx.cleanup(); }
});

test("定时整理关闭旧问题、按使用天归档，暂停事项跨天仍可接续", async () => {
  const ctx = setup(), store = new DistillStore(ctx.db);
  const start = new Date("2026-11-01T10:00:00").getTime(), day = 86_400_000, now = start + 12 * day;
  try {
    const days = Array.from({ length: 9 }, (_, i) => fixture({ t_start: toLocalIso(start + i * day) }));
    expect(ctx.db.ingest(days).accepted).toBe(days.length);
    store.setState("enabled_ms", start);
    store.setState("last_rowid", days.length);
    store.setState("cursor_ms", now);
    store.upsertThread({ id: "older", title: "合成事项", status: "active", last_ms: start, needs_regen: 0, domain: "work" });
    store.upsertThread({ id: "other", title: "合成事项乙", status: "active", last_ms: start + 3 * day, needs_regen: 0, domain: "work" });
    store.createPending({ id: "old-question", kind: "thread_done", payload: { thread_id: "older" }, created_at: toLocalIso(start) });
    const llm: LLM = { async complete() { throw new Error("这轮没有新片段"); } };
    const round = await distillRound({ db: ctx.db, llm, now: () => now });
    expect(round.lifecycle).toEqual({ paused: 1, asked: 0, archived: 1, expired: 1 });
    expect(store.pending()).toEqual([]);
    expect(store.thread("older")?.status).toBe("archived");
    expect(store.thread("other")?.status).toBe("paused");

    const followup = fixture({ t_start: toLocalIso(now) });
    expect(ctx.db.ingest([followup]).accepted).toBe(1);
    const frame = { id: "later", key: "app:test", record_ids: [followup.id], chars: 5, private: 0,
      status: "new" as const, t_start_ms: now, t_end_ms: now + 60_000 };
    store.createFrame(frame);
    store.assign(frame.id, "other", "rule", 1);
    touchThread(store, "other", frame);
    expect(store.thread("other")).toMatchObject({ status: "active", last_ms: frame.t_end_ms });
  } finally { ctx.cleanup(); }
});
