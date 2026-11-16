import { afterEach, beforeEach, expect, test } from "bun:test";
import { mkdirSync, realpathSync } from "node:fs";
import { join } from "node:path";
import { spawnSync } from "node:child_process";
import { DistillStore } from "../src/distill/store.ts";
import * as P from "../src/distill/prompts.ts";
import { assignStep, classifyStep, digestStep, touchThread, projectStep, dayStep, LIMITS, distillRound, type LLM } from "../src/distill/run.ts";
import { createLLM, type LLMRequest } from "../src/llm/index.ts";
import { emptyDayOutput, fixture, setup } from "./helpers.ts";
import { AgentReads } from "../src/agent.ts";
import { HubDB } from "../src/db.ts";
import type { RecordV1 } from "../../packages/record/index.ts";

// 全部用合成数据和假模型，不调用任何真实模型。
let ctx: ReturnType<typeof setup>, store: DistillStore, repo: string;
beforeEach(() => {
  ctx = setup(); store = new DistillStore(ctx.db);
  repo = realpathSync(ctx.dir) + "/synthetic-repo"; mkdirSync(repo);
  expect(spawnSync("git", ["init", repo]).status).toBe(0);
});
afterEach(() => ctx.cleanup());

const base = Date.parse("2026-11-08T10:00:00+08:00");
const iso = (ms: number) => new Date(ms).toISOString();
const MIN = 60_000;

function session(startMin: number, minutes: number, body: string, extra: Partial<RecordV1> = {}): RecordV1 {
  return fixture({ source: "claude_code.session", source_ref: `s#${startMin}`, kind: "span", t_start: iso(base + startMin * MIN), t_end: iso(base + (startMin + minutes) * MIN),
    context: { app: "claude-code", repo, cwd: repo }, title: `Claude Code · synthetic-repo · ${body.slice(0, 10)}`, body: /^\[(我|AI)\] /.test(body) ? body : `[我] ${body}`, capture: { method: "file" }, ...extra });
}

/** 从提示词里取出 <data> 中的片段列表。 */
function framesIn(prompt: string): { id: string; key: string; records?: { id: string; excerpt: string }[] }[] {
  const m = /<data>\n([\s\S]*)\n<\/data>/.exec(prompt);
  return m ? JSON.parse(m[1]!) : [];
}

function choicesIn(prompt: string): P.ThreadView[] {
  return JSON.parse(prompt.split("\n")[1]!);
}

interface Call { kind: string; req: LLMRequest }
function fakeLLM(behave: Partial<{ assign: (frames: ReturnType<typeof framesIn>, prompt: string) => P.AssignOutput["items"]; failAssign: boolean; done: boolean; strictReferences: boolean; classification: P.Classification; dedup: (ids: string[]) => P.DedupOutput["groups"] }> = {}) {
  const calls: Call[] = [];
  const llm: LLM = {
    async complete<T>(req: LLMRequest) {
      const kind = req.system === P.ASSIGN_SYSTEM ? "assign" : req.system === P.THREAD_SYSTEM ? "thread"
        : req.system === P.BRIEF_SYSTEM || req.system === P.DAY_BRIEF_SYSTEM ? "brief"
        : req.system === P.CLASSIFY_SYSTEM ? "classify" : req.system === P.CONVERSATION_SYSTEM ? "conversation" : req.system === P.PROJECT_SYSTEM ? "project" : req.system === P.DAY_SYSTEM ? "day" : req.system === P.DEDUP_SYSTEM ? "dedup" : "unknown";
      calls.push({ kind, req });
      const ok = (data: unknown) => ({ ok: true as const, data: data as T, ms: 1 });
      if (kind === "assign") {
        if (behave.failAssign) return { ok: false as const, error: "合成失败", ms: 1 };
        const frames = framesIn(req.prompt);
        return ok({ items: behave.assign ? behave.assign(frames, req.prompt) : frames.map(f => (f.key.startsWith("repo:") || f.key.startsWith("session:"))
          ? { frame_id: f.id, thread_id: null, new_thread_title: "合成线程", ignore: false, confidence: 0.9 }
          : { frame_id: f.id, thread_id: null, new_thread_title: null, ignore: true, confidence: 0.9 }) });
      }
      if (kind === "thread") {
        const records = framesIn(req.prompt).flatMap(f => f.records ?? []).filter(r => r.id);
        const ids = records.map(r => r.id);
        const supports = [{ record_id: ids[0], text: records[0]?.excerpt.replace(/^\[我\] /, "") ?? "" }];
        return ok({
          domain: behave.classification?.domain ?? "work", in_project: behave.classification?.in_project ?? true, title: "合成线程", status_hint: behave.done ? "done_candidate" : "active", invalidate: [],
          detail: { goal: "合成目标", progress: "合成进展", artifacts: { files: [], urls: [], commands: [], people: [] },
            quotes: [{ text: "合成原话", record_id: ids[0] }, ...(behave.strictReferences ? [] : [{ text: "编造的原话", record_id: "FAKE" }])] },
          new_facts: [
            { kind: "decision", text: `合成决定 ${ids.length}`, reason: "合成理由", evidence: [ids[0]], supports, confidence: 0.9 },
            { kind: "inference", text: "合成推测内容", reason: null, evidence: [ids[0]], supports, confidence: 0.5 },
            ...(behave.strictReferences ? [] : [{ kind: "decision", text: "没有依据的决定", reason: null, evidence: ["FAKE"], supports: [{ record_id: "FAKE", text: "伪造依据" }], confidence: 0.9 }]),
          ],
        });
      }
      if (kind === "dedup") return ok({ groups: behave.dedup ? behave.dedup((JSON.parse(req.prompt.slice(req.prompt.indexOf("\n") + 1)) as { id: string }[]).map(t => t.id)) : [] });
      if (kind === "classify") return ok({ domain: "work", in_project: false });
      if (kind === "conversation") return ok({ title: "合成对话", summary: "合成总结", points: [] });
      if (kind === "brief") return ok({ brief: "合成简略" });
      if (kind === "project") return ok({ goal: "合成项目目标", status: "合成项目进展", people: [], resolutions: [] });
      if (kind === "day") return ok({ ...emptyDayOutput, timeline: [{ start: "10:00", end: "11:00", text: "合成" }] });
      throw new Error("未知调用");
    },
  };
  return { llm, calls };
}

const round = (llm: LLM, nowMs: number, slow = true) => distillRound({ db: ctx.db, llm, now: () => nowMs }, { slow, days: "all", enabledDefault: base - 60 * MIN });

test("归档仍提炼并参与项目历史，模型提示完成也不再提问，归线程候选排除归档", async () => {
  const record = session(0, 20, "合成归档历史");
  ctx.db.ingest([record]);
  store.upsertProject({ id: "p", name: "合成项目", keys: { repos: [repo], hosts: [], chats: [] }, needs_regen: 1 });
  store.upsertThread({ id: "archived", title: "独有的合成归档标题", status: "archived", project_id: "p", project_hint: "p", last_ms: base, needs_regen: 1 });
  store.createFrame({ id: "history-frame", key: `repo:${repo}`, record_ids: [record.id], t_start_ms: base, t_end_ms: base + 20 * MIN, chars: 10, private: 0, status: "new" });
  store.assign("history-frame", "archived", "user", 1);
  const fake = fakeLLM({ done: true });
  const deps = { db: ctx.db, llm: fake.llm };
  expect((await digestStep(deps, store, base + 60 * MIN)).updated).toBe(1);
  expect(store.thread("archived")?.status).toBe("archived");
  expect(store.thread("archived")?.brief).toBe("合成简略");
  expect(store.pending()).toEqual([]);
  expect((await projectStep(deps, store, base + 60 * MIN)).updated).toBe(1);
  expect(fake.calls.find(c => c.kind === "project")?.req.prompt).toMatch(/"status"\s*:\s*"archived"/);

  const fresh = session(80, 20, "合成新活动");
  ctx.db.ingest([fresh]);
  store.createFrame({ id: "fresh-frame", key: `repo:${repo}`, record_ids: [fresh.id], t_start_ms: base + 80 * MIN, t_end_ms: base + 100 * MIN, chars: 10, private: 0, status: "new" });
  const assign = fakeLLM();
  await assignStep({ db: ctx.db, llm: assign.llm }, store, base + 120 * MIN);
  const prompt = assign.calls.find(c => c.kind === "assign")!.req.prompt;
  expect(prompt).not.toMatch(/"id"\s*:\s*"archived"/);
  expect(store.thread("archived")?.status).toBe("archived");
});

test("完整一轮：建线程与项目、事实有依据、private 不外发、简略版不含推测、日记与当前状态", async () => {
  const secret = fixture({ source: "mac.screen", kind: "span", t_start: iso(base + 5 * MIN), t_end: iso(base + 6 * MIN), context: { app: "x", repo }, body: "绝不能外发的私密正文", sensitivity: "private" });
  const browse = fixture({ source: "mac.browser", source_ref: "zen:p:1", t_start: iso(base + 150 * MIN), context: { app: "zen", url: "https://video.example/1" }, title: "合成视频", body: "合成视频" });
  // 两段会话间隔 60 分钟（超过 30 分钟算两次会话）。
  expect(ctx.db.ingest([session(0, 20, "第一段合成会话"), secret, session(80, 20, "第二段合成会话"), browse]).accepted).toBe(4);
  const { llm, calls } = fakeLLM({ done: true });
  const out = await round(llm, base + 4 * 60 * MIN) as Record<string, any>;

  const threads = ctx.db.db.prepare("SELECT * FROM threads").all() as any[];
  expect(threads).toHaveLength(1);
  const t = store.thread(threads[0].id)!;
  expect(t.brief).toBe("合成简略"); expect(t.needs_regen).toBe(0); expect(t.status).toBe("paused");
  expect(t.active_minutes).toBeGreaterThanOrEqual(40); expect(t.sessions).toBe(2);
  expect((t.detail as any).quotes.map((q: any) => q.record_id)).not.toContain("FAKE");
  const facts = store.facts("thread_id", t.id);
  expect(facts.map(f => f.text).sort()).toEqual(["合成推测内容", "合成决定 2"].sort());
  expect(out.digest.dropped_ungrounded).toBe(1);

  const project = store.projects()[0]!;
  expect(t.project_id).toBe(project.id); expect(project.brief).toBe("合成简略");
  expect(store.pending().map(p => p.kind).sort()).toEqual(["project"]);
  expect(ctx.db.db.prepare("SELECT status FROM frames WHERE key LIKE 'url:%'").get()).toEqual({ status: "ignored" });
  expect(store.day("2026-11-08")?.brief).toBe("合成简略");
  // 当前状态用线程的简略版，简略版没提到项目名时补上项目名，不重复拼标题。
  expect((store.getState<{ brief: string }>("now"))!.brief).toBe("synthetic-repo：合成简略");

  for (const c of calls) expect(c.req.prompt).not.toContain("绝不能外发的私密正文");
  for (const c of calls.filter(c => c.kind === "brief")) { expect(c.req.prompt).not.toContain("合成推测内容"); expect(c.req.prompt).not.toContain("第一段合成会话"); }
  const usage = ctx.db.db.prepare("SELECT count(*) n FROM llm_usage").get() as { n: number };
  expect(usage.n).toBe(0); // 用量由 CLI 注入的 recordUsage 写，假模型不写
});

test("增量只发新片段；删除记录后整条重建且删掉的内容不再出现", async () => {
  const a = session(0, 20, "早先的合成会话"), b = session(40, 20, "之后的合成会话");
  ctx.db.ingest([a, b]);
  const first = fakeLLM();
  await round(first.llm, base + 3 * 60 * MIN);
  const c = session(200, 20, "新增的合成会话");
  ctx.db.ingest([c]);
  const second = fakeLLM({ assign: frames => frames.map(f => ({ frame_id: f.id, thread_id: null, new_thread_title: "合成线程", ignore: false, confidence: 0.9 })) });
  await round(second.llm, base + 6 * 60 * MIN);
  const threadCalls = second.calls.filter(x => x.kind === "thread");
  expect(threadCalls).toHaveLength(1);
  // 只发新片段：<data> 里只有 c，旧记录只会以详细版里的原话引用出现在 <data> 之外。
  const sent = framesIn(threadCalls[0]!.req.prompt).flatMap(f => f.records ?? []);
  expect(sent.map(r => r.id)).toEqual(["r1"]);
  expect(sent.map(r => r.excerpt)).toEqual([c.body]);

  expect(ctx.db.delete(a.id)).toBe(true);
  const third = fakeLLM();
  await round(third.llm, base + 7 * 60 * MIN);
  const rebuild = third.calls.filter(x => x.kind === "thread");
  expect(rebuild).toHaveLength(1);
  expect(rebuild[0]!.req.prompt).not.toContain("早先的合成会话");
  expect(rebuild[0]!.req.prompt).toContain(b.body); expect(rebuild[0]!.req.prompt).toContain(c.body);
  const t = store.thread((ctx.db.db.prepare("SELECT id FROM threads").get() as { id: string }).id)!;
  expect(JSON.stringify(t.detail)).not.toContain(a.id);
});

test("归线程失败时片段保持 new，下一轮恢复", async () => {
  ctx.db.ingest([session(0, 20, "合成会话")]);
  await round(fakeLLM({ failAssign: true }).llm, base + 3 * 60 * MIN);
  expect(ctx.db.db.prepare("SELECT status FROM frames").all()).toEqual([{ status: "new" }]);
  expect(ctx.db.db.prepare("SELECT count(*) n FROM threads").get()).toEqual({ n: 0 });
  await round(fakeLLM().llm, base + 3 * 60 * MIN + 1);
  expect(ctx.db.db.prepare("SELECT count(*) n FROM threads").get()).toEqual({ n: 1 });
});

test("不够门槛的新线程先当候选，下一段同一件事出现才建线程；同批同名不重复建", async () => {
  ctx.db.ingest([session(0, 5, "短的合成会话")]);
  await round(fakeLLM().llm, base + 60 * MIN, false);
  expect(ctx.db.db.prepare("SELECT count(*) n FROM threads").get()).toEqual({ n: 0 });
  const cands = store.getState<{ id: string }[]>("candidates")!;
  expect(cands).toHaveLength(1);
  ctx.db.ingest([session(70, 5, "又一段短的合成会话")]);
  const second = fakeLLM({ assign: (frames, prompt) => {
    const candidate = choicesIn(prompt).find(t => t.status === "candidate")!;
    expect(candidate).toBeDefined();
    return frames.map(f => ({ frame_id: f.id, thread_id: candidate.id, new_thread_title: null, ignore: false, confidence: 0.8 }));
  } });
  await round(second.llm, base + 2 * 60 * MIN, false);
  expect(ctx.db.db.prepare("SELECT count(*) n FROM threads").get()).toEqual({ n: 1 });
  expect(ctx.db.db.prepare("SELECT count(*) n FROM frames WHERE status='assigned'").get()).toEqual({ n: 2 });
  expect(store.getState<unknown[]>("candidates")).toHaveLength(0);

  ctx.db.ingest([session(300, 20, "合成甲"), session(340, 20, "合成乙")]);
  await round(fakeLLM({ assign: frames => frames.map(f => ({ frame_id: f.id, thread_id: null, new_thread_title: "另一件合成的事", ignore: false, confidence: 0.9 })) }).llm, base + 8 * 60 * MIN, false);
  expect(ctx.db.db.prepare("SELECT count(*) n FROM threads WHERE title='另一件合成的事'").get()).toEqual({ n: 1 });
});

// 回归：官方账号额度用完时 claude -p 把原因写在 stdout，曾经只显示"退出失败（1）"，而且本轮其余调用继续发（2026-11-08 首次真实运行发现）。
test("遇到额度限制后本轮其余调用直接跳过，原因写进输出", async () => {
  ctx.db.ingest([session(0, 20, "合成会话")]);
  let calls = 0;
  const llm: LLM = { async complete() { calls++; return { ok: false as const, error: "claude 退出失败（1）：You've hit your 5-hour limit", ms: 1 }; } };
  const out = await round(llm, base + 3 * 60 * MIN) as Record<string, unknown>;
  expect(calls).toBe(1);
  expect(String(out.stopped)).toContain("5-hour limit");
  expect(ctx.db.db.prepare("SELECT status FROM frames").all()).toEqual([{ status: "new" }]);
});

async function contextText() {
  return (await (await new AgentReads(ctx.db).handle("context", new URLSearchParams({ cwd: repo, event: "startup", tool: "codex" }))).json()).text as string;
}

test("回归：cwd 的生活线程只提名项目，digest 后不挂项目也不注入", async () => {
  ctx.db.ingest([session(0, 20, "合成周复盘")]);
  await round(fakeLLM().llm, base + 30 * MIN, false);
  const t = (ctx.db.db.prepare("SELECT id FROM threads").get() as { id: string });
  expect(store.thread(t.id)!.project_id).toBeNull();
  expect(store.thread(t.id)!.project_hint).toBe(store.projects()[0]!.id);
  const model = fakeLLM({ classification: { domain: "life", in_project: true } });
  await digestStep({ db: ctx.db, llm: model.llm }, store, base + 30 * MIN);
  expect(store.thread(t.id)!.domain).toBe("life");
  expect(store.thread(t.id)!.project_id).toBeNull();
  expect(await contextText()).not.toContain("合成线程");
  expect(model.calls.find(c => c.kind === "thread")!.req.prompt).toContain("synthetic-repo");
});

test("digest 工作归属由 in_project 和候选共同决定", async () => {
  ctx.db.ingest([session(0, 20, "合成开发")]);
  await round(fakeLLM().llm, base + 30 * MIN, false);
  const id = (ctx.db.db.prepare("SELECT id FROM threads").get() as { id: string }).id;
  const project = store.projects()[0]!;
  const model = fakeLLM();
  await digestStep({ db: ctx.db, llm: model.llm }, store, base + 30 * MIN);
  expect(store.thread(id)!.project_id).toBe(project.id);
  expect(store.facts("thread_id", id).every(f => f.project_id === project.id)).toBe(true);
  expect(await contextText()).toContain("合成线程");
  // 强制重建同一合成片段，验证工作线程也可以判定不属于候选项目。
  store.setState(`digest:${id}`, null); store.upsertThread({ ...store.thread(id)!, needs_regen: 1 });
  await digestStep({ db: ctx.db, llm: fakeLLM({ classification: { domain: "work", in_project: false } }).llm }, store, base);
  expect(store.thread(id)!.project_id).toBeNull();
  store.setState(`digest:${id}`, null); store.upsertThread({ ...store.thread(id)!, project_hint: null, needs_regen: 1 });
  const noHint = fakeLLM();
  await digestStep({ db: ctx.db, llm: noHint.llm }, store, base);
  expect(store.thread(id)!.project_id).toBeNull();
  expect(noHint.calls.find(c => c.kind === "thread")!.req.prompt).toContain('候选项目："无"');
});

test("存量 classify 同步 facts 和新旧项目；失败隔离并在下轮重试，每轮上限 12", async () => {
  for (const id of ["old", "new"]) store.upsertProject({ id, name: `合成项目${id}`, brief: `合成摘要${id}`, keys: { repos: [], hosts: [], chats: [] }, needs_regen: 0 });
  const r = fixture(); ctx.db.ingest([r]);
  for (let i = 0; i < LIMITS.threadsPerRound + 2; i++) store.upsertThread({ id: `t${String(i).padStart(2, "0")}`, title: "合成旧线程", brief: "合成简略", detail: { goal: "合成目标", progress: "合成进度" }, status: "paused", project_id: "old", project_hint: "new", needs_regen: 0 });
  store.writeFact({ id: "fact", thread_id: "t01", project_id: "old", kind: "decision", text: "合成决定", evidence: [r.id], origin: "user", valid_at: iso(base), created_at: iso(base) });
  let calls = 0;
  const llm: LLM = { async complete<T>(req: LLMRequest) {
    expect(req.system).toBe(P.CLASSIFY_SYSTEM); expect(req.tier).toBe("minute");
    for (const text of ["合成目标", "合成进度", "合成简略", "合成项目new", "合成摘要new"]) expect(req.prompt).toContain(text);
    calls++;
    if (calls === 1) throw new Error("合成失败");
    return { ok: true, data: { domain: "work", in_project: true } as T, ms: 1 };
  } };
  expect(await classifyStep({ db: ctx.db, llm }, store)).toEqual({ calls: 12, updated: 11, failed: 1 });
  expect(store.thread("t00")!.domain).toBeNull(); expect(store.thread("t01")!.project_id).toBe("new");
  expect(store.facts("thread_id", "t01")[0]!.project_id).toBe("new");
  expect(store.project("old")!.needs_regen).toBe(1); expect(store.project("new")!.needs_regen).toBe(1);
  expect((await classifyStep({ db: ctx.db, llm }, store)).updated).toBe(3);
  expect(store.thread("t00")!.domain).toBe("work");
});

test("存量已 digest 且没有新片段时走 classify；有新片段留给 digest", async () => {
  ctx.db.ingest([session(0, 20, "合成开发")]);
  await round(fakeLLM().llm, base + 30 * MIN);
  const t = store.thread((ctx.db.db.prepare("SELECT id FROM threads").get() as { id: string }).id)!;
  store.upsertThread({ ...t, domain: null });
  const llm: LLM = { async complete<T>() { return { ok: true, data: { domain: "life", in_project: false } as T, ms: 1 }; } };
  expect((await classifyStep({ db: ctx.db, llm }, store)).updated).toBe(1);
  expect(store.thread(t.id)!.project_id).toBeNull();
  expect(store.facts("thread_id", t.id).every(f => f.project_id === null)).toBe(true);
  store.upsertThread({ ...store.thread(t.id)!, domain: null }); store.setState(`digest:${t.id}`, null);
  expect((await classifyStep({ db: ctx.db, llm }, store)).calls).toBe(0);
});

test("v3 加密库真实升级 v5：旧归属保留并复制成 hint，domain 留空，重开幂等", () => {
  store.upsertThread({ id: "legacy", title: "合成旧线程", status: "active", project_id: "p" });
  ctx.db.db.exec("DROP TABLE speakers; DROP TABLE voice_embeddings; DROP TABLE voice_samples; DROP TABLE sample_requests; DROP TABLE audio_settings; ALTER TABLE threads DROP COLUMN domain; ALTER TABLE threads DROP COLUMN project_hint; DROP TABLE runtime_calls; PRAGMA user_version=3;");
  const db = new HubDB(ctx.file, ctx.config.dbKey);
  try {
    expect(db.db.pragma("user_version", { simple: true })).toBe(11);
    const t = new DistillStore(db).thread("legacy")!;
    expect(t.project_id).toBe("p"); expect(t.project_hint).toBe("p"); expect(t.domain).toBeNull();
  } finally { db.close(); }
  const again = new HubDB(ctx.file, ctx.config.dbKey); again.close();
});


test("touchThread 只填首次 hint，不覆盖已有 hint 或直接修改归属", () => {
  store.upsertThread({ id: "hint", title: "合成线程", status: "active", project_id: "old", project_hint: "first" });
  const frame = { id: "synthetic", t_start_ms: base, t_end_ms: base + MIN, key: `repo:${repo}`, record_ids: [], chars: 0, private: 0, status: "new" as const };
  touchThread(store, "hint", frame);
  expect(store.thread("hint")!.project_hint).toBe("first");
  expect(store.thread("hint")!.project_id).toBe("old");
  store.upsertThread({ id: "empty", title: "合成线程", status: "active" });
  touchThread(store, "empty", frame);
  expect(store.thread("empty")!.project_hint).toBe(store.projects()[0]!.id);
  expect(store.thread("empty")!.project_id).toBeNull();
});

test("移走最后一条生活线程后清空旧项目摘要，防止旧生活内容继续注入", async () => {
  store.upsertProject({ id: "p", name: "合成项目", keys: { repos: [repo], hosts: [], chats: [] }, brief: "合成生活旧摘要", detail: { goal: "合成生活旧目标" }, needs_regen: 0 });
  store.upsertThread({ id: "t", title: "合成复盘", status: "active", project_id: "p", project_hint: "p", needs_regen: 0 });
  const llm: LLM = { async complete<T>() { return { ok: true, data: { domain: "life", in_project: false } as T, ms: 1 }; } };
  await classifyStep({ db: ctx.db, llm }, store);
  await projectStep({ db: ctx.db, llm }, store, base);
  expect(store.project("p")!.brief).toBeNull(); expect(store.project("p")!.detail).toBeNull();
  expect(await contextText()).not.toContain("合成生活旧");
});

// 回归：用户把事实标为"不属于这条线程"后，片段要由模型重新归属，不能再被分回原线程（2026-11-10 用户报告；
// 真机上只在提示里写"不能选"时，模型仍被片段里的字样带回原线程）。
test("拒绝过的线程：单独成批且不出现在候选里，片段带被拒标题；模型硬填它的 id 时不归回去", async () => {
  store.upsertThread({ id: "wrong", status: "active", title: "合成原线程", last_ms: base, needs_regen: 0 });
  store.upsertThread({ id: "other", status: "active", title: "合成另一线程", last_ms: base, needs_regen: 0 });
  const a = session(0, 20, "合成片段一"), b = session(40, 20, "合成片段二"), c = session(80, 20, "合成片段三");
  ctx.db.ingest([a, b, c]);
  for (const [id, r, start] of [["fa", a, 0], ["fb", b, 40], ["fc", c, 80]] as const) {
    store.createFrame({ id, key: `repo:${repo}`, record_ids: [r.id], t_start_ms: base + start * MIN, t_end_ms: base + (start + 20) * MIN, chars: 10, private: 0, status: "new" });
  }
  ctx.db.db.prepare("INSERT INTO frame_rejections(frame_id,thread_id,at) VALUES('fa','wrong',?),('fb','wrong',?)").run(iso(base), iso(base));
  const fake = fakeLLM({ assign: (frames, prompt) => frames.map(f => {
    const rejected = f.records?.[0]?.excerpt === "[我] 合成片段一";
    const title = f.records?.[0]?.excerpt === "[我] 合成片段二" ? "合成另一线程" : "合成原线程";
    return { frame_id: f.id, thread_id: rejected ? null : choicesIn(prompt).find(t => t.title === title)!.id, new_thread_title: rejected ? title : null, ignore: false, confidence: 0.9 };
  }) });
  await assignStep({ db: ctx.db, llm: fake.llm }, store, base + 120 * MIN);
  const prompts = fake.calls.filter(c => c.kind === "assign").map(c => c.req.prompt);
  expect(prompts).toHaveLength(2);
  const rejectedBatch = prompts.find(p => framesIn(p).some(f => f.records?.[0]?.excerpt === "[我] 合成片段一"))!;
  expect(framesIn(rejectedBatch).map(f => [f.id, (f as { not_threads?: string[] }).not_threads])).toEqual([["s1", ["合成原线程"]], ["s2", ["合成原线程"]]]);
  expect(choicesIn(rejectedBatch).map(t => t.title)).not.toContain("合成原线程");
  expect(choicesIn(prompts.find(p => framesIn(p).some(f => f.records?.[0]?.excerpt === "[我] 合成片段三"))!).map(t => t.title)).toContain("合成原线程");
  expect(ctx.db.db.prepare("SELECT frame_id,thread_id FROM assignments ORDER BY frame_id").all()).toEqual([{ frame_id: "fb", thread_id: "other" }, { frame_id: "fc", thread_id: "wrong" }]);
  expect(ctx.db.db.prepare("SELECT status FROM frames WHERE id='fa'").get()).toEqual({ status: "ignored" });
});

// 回归：九院线程已完成，结束后的跟进对话不在候选里，只能进日记（2026-11-10 实测）。
test("最近结束的线程进候选，归进去不改变状态；太久以前结束的不进", async () => {
  const now = base + 120 * MIN;
  store.upsertThread({ id: "recent-done", status: "done", title: "合成已完成线程", last_ms: now - 3 * 24 * 60 * MIN, needs_regen: 0 });
  store.upsertThread({ id: "old-done", status: "done", title: "合成很早完成的线程", last_ms: now - 30 * 24 * 60 * MIN, needs_regen: 0 });
  const a = session(0, 20, "合成跟进");
  ctx.db.ingest([a]);
  store.createFrame({ id: "follow", key: `repo:${repo}`, record_ids: [a.id], t_start_ms: base, t_end_ms: base + 20 * MIN, chars: 10, private: 0, status: "new" });
  const fake = fakeLLM({ assign: (frames, prompt) => frames.map(f => ({ frame_id: f.id, thread_id: choicesIn(prompt).find(t => t.title === "合成已完成线程")!.id, new_thread_title: null, ignore: false, confidence: 0.9 })) });
  await assignStep({ db: ctx.db, llm: fake.llm }, store, now);
  const choices = fake.calls.find(c => c.kind === "assign")!.req.prompt.split("<data>")[0]!;
  expect(choices).toContain("合成已完成线程");
  expect(choices).not.toContain("合成很早完成的线程");
  expect(ctx.db.db.prepare("SELECT thread_id FROM assignments WHERE frame_id='follow'").get()).toEqual({ thread_id: "recent-done" });
  expect(store.thread("recent-done")?.status).toBe("done");
  expect(store.thread("recent-done")?.needs_regen).toBe(1);
});

// 回归（2026-11-12）：同一件事被拆成两条线程（Familiar 发版、首期 Weekly 各两条），之后各自长大。
test("每天合并一次重复线程：片段、事实、拒绝记录转到片段多的那条，旧 id 能跳转；不同项目的不并", async () => {
  ctx.db.ingest([session(0, 30, "合成工作 A"), session(120, 30, "合成工作 B"), session(240, 30, "合成工作 C")]);
  let n = 0;
  const first = fakeLLM({ assign: frames => frames.map(f => ({ frame_id: f.id, thread_id: null, new_thread_title: (f.key.startsWith("repo:") || f.key.startsWith("session:")) ? `合成线程 ${n++ % 2}` : null, ignore: !(f.key.startsWith("repo:") || f.key.startsWith("session:")), confidence: 0.9 })) });
  // 先不合并，建出两条线程。
  await round(first.llm, base + 300 * MIN);
  const threads = (ctx.db.db.prepare("SELECT id,(SELECT count(*) FROM assignments a WHERE a.thread_id=t.id) n FROM threads t ORDER BY n DESC").all() as { id: string; n: number }[]);
  expect(threads.length).toBe(2);
  const [keep, drop] = threads as [{ id: string; n: number }, { id: string; n: number }];
  const dropFrames = (ctx.db.db.prepare("SELECT frame_id FROM assignments WHERE thread_id=?").all(drop.id) as { frame_id: string }[]).map(r => r.frame_id);
  ctx.db.db.prepare("INSERT INTO frame_rejections(frame_id,thread_id,at) VALUES('f-x',?,'2026-11-08T00:00:00Z')").run(drop.id);
  store.createPending({ id: "p-done", kind: "thread_done", payload: { thread_id: drop.id }, created_at: "2026-11-08T00:00:00Z" });
  // 同一天不再看第二次；第二天按模型分组合并。
  const second = fakeLLM({ dedup: ids => [{ thread_ids: ids, confidence: 0.9 }] });
  await round(second.llm, base + 310 * MIN);
  expect(second.calls.filter(c => c.kind === "dedup")).toHaveLength(0);
  await round(second.llm, base + 300 * MIN + 25 * 60 * MIN);
  expect(second.calls.filter(c => c.kind === "dedup")).toHaveLength(1);
  expect(store.thread(drop.id)).toBeNull();
  for (const f of dropFrames) expect((ctx.db.db.prepare("SELECT thread_id FROM assignments WHERE frame_id=?").get(f) as { thread_id: string }).thread_id).toBe(keep.id);
  expect(ctx.db.db.prepare("SELECT count(*) n FROM facts WHERE thread_id=?").get(drop.id)).toEqual({ n: 0 });
  expect(store.rejectedThreads("f-x")).toEqual([keep.id]);
  expect(store.pending().some(p => p.id === "p-done")).toBe(false);
  expect(store.threadId(drop.id)).toBe(keep.id);
  // 合并后整条重写。
  expect(store.thread(keep.id)!.needs_regen === 0 || second.calls.some(c => c.kind === "thread")).toBe(true);
  const reads = new AgentReads(ctx.db);
  const got = await (await reads.handle("get", new URLSearchParams({ id: drop.id, tool: "codex" }))).json() as { kind: string; item: { id: string } };
  expect(got.item.id).toBe(keep.id);
});

test("不同项目、或模型把握不够的分组不合并", async () => {
  const mk = (id: string, project: string | null) => store.upsertThread({ id, status: "paused", title: id, brief: "合成", project_id: project, domain: "work", last_ms: base, first_ms: base, needs_regen: 0 } as never);
  store.upsertProject({ id: "p1", name: "一", keys: { repos: [], hosts: [], chats: [] } });
  store.upsertProject({ id: "p2", name: "二", keys: { repos: [], hosts: [], chats: [] } });
  mk("t1", "p1"); mk("t2", "p2"); mk("t3", null); mk("t4", null);
  const f = fakeLLM({ dedup: () => [{ thread_ids: ["t1", "t2"], confidence: 0.95 }, { thread_ids: ["t3", "t4"], confidence: 0.5 }] });
  const { dedupStep } = await import("../src/distill/run.ts");
  expect(await dedupStep({ db: ctx.db, llm: f.llm }, store, base)).toEqual({ calls: 1, merged: 0, failed: 0 });
  for (const id of ["t1", "t2", "t3", "t4"]) expect(store.thread(id)).not.toBeNull();
});

// 回归（2026-11-12）："修复 record-anything 页面配色与状态文案"不在仓库目录里做，一直没挂项目。
test("没有仓库线索的线程，标题写着已有项目名时提名为候选，交给模型判断；名字太短或写了两个项目名不猜", async () => {
  store.upsertProject({ id: "p-ra", name: "record-anything", keys: { repos: [], hosts: [], chats: [] } });
  store.upsertProject({ id: "p-pet", name: "all-in-pet", keys: { repos: [], hosts: [], chats: [] } });
  store.upsertProject({ id: "p-x", name: "abc", keys: { repos: [], hosts: [], chats: [] } });
  const mk = (id: string, title: string) => store.upsertThread({ id, status: "paused", title, brief: "合成", domain: "work", last_ms: base, first_ms: base, needs_regen: 0 } as never);
  mk("t-ra", "修复 Record-Anything 页面配色"); mk("t-both", "对比 record-anything 和 all-in-pet"); mk("t-short", "abc 的事");
  const f = fakeLLM();
  const llm: LLM = { complete: async <T>(req: LLMRequest) => req.system === P.CLASSIFY_SYSTEM ? { ok: true as const, data: { domain: "work", in_project: true } as T, ms: 1 } : f.llm.complete<T>(req) };
  await classifyStep({ db: ctx.db, llm }, store);
  expect(store.thread("t-ra")).toMatchObject({ project_hint: "p-ra", project_id: "p-ra", domain: "work" });
  expect(store.thread("t-both")!.project_hint ?? null).toBeNull();
  expect(store.thread("t-short")!.project_hint ?? null).toBeNull();
});

// 回归（2026-11-12）：在课程仓库里学习的线程都被判成生活，ai-engineering-from-scratch 项目下一条线程都没有。
test("判断规则改过后，之前判成生活、有候选项目的线程只重判一次", async () => {
  const { reclassifyAfterRuleChange } = await import("../src/distill/run.ts");
  store.upsertProject({ id: "p-course", name: "synthetic-course", keys: { repos: [], hosts: [], chats: [] } });
  const mk = (id: string, domain: string, hint: string | null) => store.upsertThread({ id, status: "paused", title: id, brief: "合成", domain, project_hint: hint, last_ms: base, first_ms: base, needs_regen: 0 } as never);
  mk("t-study", "life", "p-course"); mk("t-life", "life", null); mk("t-work", "work", "p-course");
  expect(reclassifyAfterRuleChange(store)).toBe(1);
  expect(store.thread("t-study")!.domain ?? null).toBeNull();
  expect(store.thread("t-life")!.domain).toBe("life");
  expect(store.thread("t-work")!.domain).toBe("work");
  store.upsertThread({ ...store.thread("t-study")!, domain: "life" });
  expect(reclassifyAfterRuleChange(store)).toBe(0);
});

test("日记合并带空白的旧微信片段，显示最新记录原名", async () => {
  const app = "com.tencent.xinWeChat";
  const names = ["C童文科", "C 童文科"];
  const records = names.map((chat, i) => fixture({ source: "mac.wechat", t_start: iso(base + i * MIN), context: { app, chat } }));
  ctx.db.ingest(records);
  for (const [i, record] of records.entries()) {
    store.createFrame({ id: `wechat-${i}`, key: `chat:${app}:${names[i]}`, record_ids: [record.id], t_start_ms: base + i * MIN, t_end_ms: base + i * MIN, chars: 1, private: 0, status: "new" });
  }
  const fake = fakeLLM();
  await dayStep({ db: ctx.db, llm: fake.llm }, store, "2026-11-08", base + 3600000);
  const prompt = fake.calls.find(c => c.kind === "day")!.req.prompt;
  const { blocks } = framesIn(prompt) as unknown as { blocks: { label: string }[] };
  expect(blocks).toHaveLength(1);
  expect(blocks[0]!.label).toBe(`${app}:C 童文科`);
});


test("假模型完整一轮经真实适配器写用量，十类任务均正确且不存正文", async () => {
  ctx.db.ingest([session(0, 20, "合成开发会话"), fixture({ source: "mac.audio", source_ref: "usage-audio", kind: "span",
    t_start: iso(base + 30 * MIN), t_end: iso(base + 35 * MIN), body: `[10:30:00] 我：${"这是本轮的合成对话内容。".repeat(30)}`, capture: { method: "asr" } })]);
  for (const id of ["old-a", "old-b"]) store.upsertThread({ id, title: "旧线程", status: "active", brief: "旧简略", detail: {}, last_ms: base, needs_regen: 0 });
  const fake = fakeLLM({ strictReferences: true }), originalFetch = globalThis.fetch;
  let request: LLMRequest;
  const config = { provider: "openai-compatible" as const, model: "fake", base_url: "http://localhost:1/v1" };
  const adapter = createLLM({ dataDir: ctx.dir, configs: async () => ({ minute: config, hour: config, day: config }),
    recordUsage: row => store.writeUsage({ ...row, input_tokens: row.input_tokens ?? undefined, output_tokens: row.output_tokens ?? undefined, error: row.error ?? undefined }) });
  globalThis.fetch = (async () => {
    const out = await fake.llm.complete(request);
    if (!out.ok) throw new Error("unexpected fake failure");
    return Response.json({ choices: [{ finish_reason: "stop", message: { content: JSON.stringify(out.data) } }], usage: { prompt_tokens: 12, completion_tokens: 3 } });
  }) as unknown as typeof fetch;
  try {
    const llm: LLM = { complete<T>(req: LLMRequest) { request = req; return adapter.complete<T>(req); } };
    await round(llm, base + 4 * 60 * MIN);
  } finally { globalThis.fetch = originalFetch; }
  const rows = ctx.db.db.prepare("SELECT * FROM llm_usage ORDER BY rowid").all() as { task: string; tier: string; ok: number }[];
  expect(rows.every(r => r.ok === 1)).toBe(true);
  expect([...new Set(rows.map(r => r.task))].sort()).toEqual(["assign", "thread_digest", "thread_brief", "project", "project_brief", "classify", "conversation_summary", "day", "day_brief", "dedupe"].sort());
  expect(rows.map(r => [r.task, r.tier])).toEqual([
    ["conversation_summary", "minute"], ["assign", "minute"], ["classify", "minute"], ["classify", "minute"],
    ["dedupe", "hour"], ["thread_digest", "hour"], ["thread_brief", "minute"],
    ["project", "hour"], ["project_brief", "minute"], ["day", "day"], ["day_brief", "minute"],
  ]);
  expect(JSON.stringify(rows)).not.toContain("合成");
});

test("本地模型实测回归：错误推测、事实ID证据和作废用户事实都不能入库", async () => {
  const record = session(0, 20, "[我] 本地测试通过，尚未部署，等待业务验收。");
  ctx.db.ingest([record]);
  store.upsertThread({ id: "local-eval", title: "合成修复", status: "active", needs_regen: 1 });
  store.createFrame({ id: "local-frame", key: `repo:${repo}`, record_ids: [record.id], t_start_ms: base, t_end_ms: base + 20 * MIN, chars: 30, private: 0, status: "new" });
  store.assign("local-frame", "local-eval", "user", 1);
  store.writeFact({ id: "user-correction", thread_id: "local-eval", kind: "decision", text: "尚未部署", origin: "user", evidence: [record.id], valid_at: iso(base), created_at: iso(base) });
  store.writeFact({ id: "existing-open", thread_id: "local-eval", kind: "open", text: "等待业务验收", origin: "llm", evidence: [record.id], valid_at: iso(base), created_at: iso(base) });
  const original = fakeLLM().llm;
  const llm: LLM = { async complete<T>(req: LLMRequest) {
    const result = await original.complete<any>(req);
    if (req.task === "thread_digest" && result.ok) {
      const recordRef = framesIn(req.prompt)[0]!.records![0]!.id;
      const factRefs = JSON.parse(/已有有效 facts：\n([^\n]+)/.exec(req.prompt)![1]!) as P.FactView[];
      const userRef = factRefs.find(f => f.origin === "user")!.id;
      const supports = [{ record_id: recordRef, text: "本地测试通过，尚未部署，等待业务验收。" }];
      const oldRef = factRefs.find(f => f.text === "等待业务验收")!.id;
      result.data.new_facts = [
        { kind: "inference", text: "超出上限的推测", confidence: 0.95, evidence: [recordRef], supports, reason: null },
        { kind: "inference", text: "恰好等于上限也不行", confidence: 0.8, evidence: [recordRef], supports, reason: null },
        { kind: "inference", text: "保留有依据且低置信度的推测", confidence: 0.79, evidence: [recordRef], supports, reason: null },
        { kind: "decision", text: "把事实ID错当记录ID", confidence: 1, evidence: [userRef], supports: [{ record_id: userRef, text: "伪造依据" }], reason: null },
        { kind: "decision", text: "保留有原始依据的决定", confidence: 1, evidence: [recordRef], supports, reason: null },
      ];
      result.data.invalidate = [{ fact_id: userRef, replaced_by: 3 }, { fact_id: oldRef, replaced_by: 0 }];
    }
    return result;
  } };
  const result = await digestStep({ db: ctx.db, llm }, store, base + 30 * MIN);
  expect(result.updated).toBe(1);
  expect(result.dropped_invalid_inference).toBe(2);
  expect(result.dropped_ungrounded).toBe(1);
  const facts = store.facts("thread_id", "local-eval");
  expect(facts.map(f => f.text).sort()).toEqual(["尚未部署", "等待业务验收", "保留有依据且低置信度的推测", "保留有原始依据的决定"].sort());
  expect(facts.find(f => f.id === "user-correction")?.origin).toBe("user");
});

test('详细整理跨活动片段去重相同提交，内容不同的提交材料仍进入模型', async()=>{
  const records=['同一提交材料','同一提交材料','用户修正后的不同材料'].map((body,i)=>fixture({source:'mac.git',source_ref:'git-'+i,body,t_start:iso(base+i*MIN),context:{repo,extra:{hash:'a'.repeat(40)}}}));
  ctx.db.ingest(records);store.upsertThread({id:'git-thread',title:'提交工作',status:'active',needs_regen:1});
  for(const [i,r] of records.entries()){const f={id:'git-f'+i,key:'repo:'+repo,record_ids:[r.id],t_start_ms:base+i*MIN,t_end_ms:base+i*MIN,chars:r.body.length,private:0,status:'new' as const};store.createFrame(f);store.assign(f.id,'git-thread','llm',1);}
  const {llm,calls}=fakeLLM();await digestStep({db:ctx.db,llm},store,base+3600000);
  const later=fixture({source:'mac.git',source_ref:'git-later',body:'同一提交材料',t_start:iso(base+4*MIN),context:{repo,extra:{hash:'a'.repeat(40)}}});ctx.db.ingest([later]);
  store.createFrame({id:'git-later',key:'repo:'+repo,record_ids:[later.id],t_start_ms:base+4*MIN,t_end_ms:base+4*MIN,chars:later.body.length,private:0,status:'new'});store.assign('git-later','git-thread','llm',1);store.upsertThread({...store.thread('git-thread')!,needs_regen:1});
  await digestStep({db:ctx.db,llm},store,base+2*3600000);
  const inputs=calls.filter(c=>c.kind==='thread').flatMap(c=>framesIn(c.req.prompt).flatMap(f=>f.records??[]));
  expect(inputs.filter(r=>r.excerpt==='同一提交材料')).toHaveLength(1);expect(inputs.filter(r=>r.excerpt==='用户修正后的不同材料')).toHaveLength(1);
  expect(records.every(r=>!!ctx.db.get(r.id))).toBe(true);expect(store.getState<{frames:string[]}>('digest:git-thread')?.frames).toHaveLength(4);
});
