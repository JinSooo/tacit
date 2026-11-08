import { afterEach, beforeEach, expect, test } from "bun:test";
import { mkdirSync, realpathSync } from "node:fs";
import { join } from "node:path";
import { spawnSync } from "node:child_process";
import { DistillStore } from "../src/distill/store.ts";
import * as P from "../src/distill/prompts.ts";
import { distillRound, type LLM } from "../src/distill/run.ts";
import type { LLMRequest } from "../src/llm/index.ts";
import { fixture, setup } from "./helpers.ts";
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
function fakeLLM(behave: Partial<{ assign: (frames: ReturnType<typeof framesIn>, prompt: string) => P.AssignOutput["items"]; failAssign: boolean; done: boolean }> = {}) {
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
          title: "合成线程", status_hint: behave.done ? "done_candidate" : "active", invalidate: [],
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
  expect((store.getState<{ brief: string }>("now"))!.brief).toContain("合成线程");

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
