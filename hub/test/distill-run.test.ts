import { afterEach, beforeEach, expect, test } from "bun:test";
import { mkdirSync, realpathSync } from "node:fs";
import { join } from "node:path";
import { spawnSync } from "node:child_process";
import { DistillStore } from "../src/distill/store.ts";
import * as P from "../src/distill/prompts.ts";
import { assignStep, classifyStep, digestStep, touchThread, projectStep, LIMITS, distillRound, type LLM } from "../src/distill/run.ts";
import type { LLMRequest } from "../src/llm/index.ts";
import { fixture, setup } from "./helpers.ts";
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
    context: { app: "claude-code", repo, cwd: repo }, title: `Claude Code · synthetic-repo · ${body.slice(0, 10)}`, body, capture: { method: "file" }, ...extra });
}

/** 从提示词里取出 <data> 中的片段列表。 */
function framesIn(prompt: string): { id: string; key: string; records?: { id: string }[] }[] {
  const m = /<data>\n([\s\S]*)\n<\/data>/.exec(prompt);
  return m ? JSON.parse(m[1]!) : [];
}

interface Call { kind: string; req: LLMRequest }
function fakeLLM(behave: Partial<{ assign: (frames: ReturnType<typeof framesIn>, prompt: string) => P.AssignOutput["items"]; failAssign: boolean; done: boolean; classification: P.Classification }> = {}) {
  const calls: Call[] = [];
  const llm: LLM = {
    async complete<T>(req: LLMRequest) {
      const kind = req.system === P.ASSIGN_SYSTEM ? "assign" : req.system === P.THREAD_SYSTEM ? "thread" : req.system === P.BRIEF_SYSTEM ? "brief"
        : req.system === P.PROJECT_SYSTEM ? "project" : req.system === P.DAY_SYSTEM ? "day" : "unknown";
      calls.push({ kind, req });
      const ok = (data: unknown) => ({ ok: true as const, data: data as T, ms: 1 });
      if (kind === "assign") {
        if (behave.failAssign) return { ok: false as const, error: "合成失败", ms: 1 };
        const frames = framesIn(req.prompt);
        return ok({ items: behave.assign ? behave.assign(frames, req.prompt) : frames.map(f => f.key.startsWith("repo:")
          ? { frame_id: f.id, thread_id: null, new_thread_title: "合成线程", ignore: false, confidence: 0.9 }
          : { frame_id: f.id, thread_id: null, new_thread_title: null, ignore: true, confidence: 0.9 }) });
      }
      if (kind === "thread") {
        const ids = framesIn(req.prompt).flatMap(f => (f.records ?? []).map(r => r.id)).filter(Boolean);
        return ok({
          domain: behave.classification?.domain ?? "work", in_project: behave.classification?.in_project ?? true, title: "合成线程", status_hint: behave.done ? "done_candidate" : "active", invalidate: [],
          detail: { goal: "合成目标", progress: "合成进展", artifacts: { files: [], urls: [], commands: [], people: [] },
            quotes: [{ text: "合成原话", record_id: ids[0] }, { text: "编造的原话", record_id: "FAKE" }] },
          new_facts: [
            { kind: "decision", text: `合成决定 ${ids.length}`, reason: "合成理由", evidence: [ids[0]], confidence: 0.9 },
            { kind: "inference", text: "合成推测内容", reason: null, evidence: [ids[0]], confidence: 0.5 },
            { kind: "decision", text: "没有依据的决定", reason: null, evidence: ["FAKE"], confidence: 0.9 },
          ],
        });
      }
      if (kind === "brief") return ok({ brief: "合成简略" });
      if (kind === "project") return ok({ goal: "合成项目目标", status: "合成项目进展", people: [] });
      if (kind === "day") return ok({ summary: "合成日记", timeline: [{ start: "10:00", end: "11:00", text: "合成" }] });
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
  expect(store.pending().map(p => p.kind).sort()).toEqual(["project", "thread_done"]);
  expect(ctx.db.db.prepare("SELECT status FROM frames WHERE key LIKE 'host:%'").get()).toEqual({ status: "ignored" });
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
  const sent = framesIn(threadCalls[0]!.req.prompt).flatMap(f => (f.records ?? []).map(r => r.id));
  expect(sent).toEqual([c.id]);

  expect(ctx.db.delete(a.id)).toBe(true);
  const third = fakeLLM();
  await round(third.llm, base + 7 * 60 * MIN);
  const rebuild = third.calls.filter(x => x.kind === "thread");
  expect(rebuild).toHaveLength(1);
  expect(rebuild[0]!.req.prompt).not.toContain("早先的合成会话");
  expect(rebuild[0]!.req.prompt).toContain(b.id); expect(rebuild[0]!.req.prompt).toContain(c.id);
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
    expect(prompt).toContain(`cand:${cands[0]!.id}`);
    return frames.map(f => ({ frame_id: f.id, thread_id: `cand:${cands[0]!.id}`, new_thread_title: null, ignore: false, confidence: 0.8 }));
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
  ctx.db.db.exec("DROP TABLE speakers; DROP TABLE voice_embeddings; DROP TABLE voice_samples; DROP TABLE sample_requests; DROP TABLE audio_settings; ALTER TABLE threads DROP COLUMN domain; ALTER TABLE threads DROP COLUMN project_hint; PRAGMA user_version=3;");
  const db = new HubDB(ctx.file, ctx.config.dbKey);
  try {
    expect(db.db.pragma("user_version", { simple: true })).toBe(6);
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
  const fake = fakeLLM({ assign: frames => frames.map(f => ({ frame_id: f.id, thread_id: f.id === "fa" ? "wrong" : f.id === "fb" ? "other" : "wrong", new_thread_title: null, ignore: false, confidence: 0.9 })) });
  await assignStep({ db: ctx.db, llm: fake.llm }, store, base + 120 * MIN);
  const prompts = fake.calls.filter(c => c.kind === "assign").map(c => c.req.prompt);
  expect(prompts).toHaveLength(2);
  const rejectedBatch = prompts.find(p => framesIn(p).some(f => f.id === "fa"))!;
  expect(framesIn(rejectedBatch).map(f => [f.id, (f as { not_threads?: string[] }).not_threads])).toEqual([["fa", ["合成原线程"]], ["fb", ["合成原线程"]]]);
  expect(rejectedBatch.split("<data>")[0]).not.toContain('"wrong"');
  expect(prompts.find(p => framesIn(p).some(f => f.id === "fc"))!.split("<data>")[0]).toContain('"wrong"');
  expect(ctx.db.db.prepare("SELECT frame_id,thread_id FROM assignments ORDER BY frame_id").all()).toEqual([{ frame_id: "fb", thread_id: "other" }, { frame_id: "fc", thread_id: "wrong" }]);
  expect(ctx.db.db.prepare("SELECT status FROM frames WHERE id='fa'").get()).toEqual({ status: "ignored" });
});
