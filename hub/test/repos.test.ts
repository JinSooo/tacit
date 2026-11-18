import { afterEach, beforeEach, expect, test } from "bun:test";
import { spawnSync } from "node:child_process";
import { mkdirSync, realpathSync } from "node:fs";
import { join } from "node:path";
import { homedir } from "node:os";
import { DistillRules } from "../src/distill/rules.ts";
import { projectForPath, resolveRepoRoot } from "../src/distill/repos.ts";
import { DistillStore, type Frame } from "../src/distill/store.ts";
import { AgentReads } from "../src/agent.ts";
import { frameKey } from "../src/distill/frames.ts";
import { nominateByName, projectStep, sliceStep, type LLM } from "../src/distill/run.ts";
import { HubDB } from "../src/db.ts";
import { createHandler, startServer } from "../src/server.ts";
import { ulid } from "../../packages/record/index.ts";
import { fixture, networkDenied, reviewEvidence, setup } from "./helpers.ts";

let ctx: ReturnType<typeof setup>, store: DistillStore, repo: string, worktree: string;
function git(...args: string[]) {
  const result = spawnSync("git", args, { encoding: "utf8", timeout: 5000 });
  if (result.status !== 0) throw new Error(`合成仓库操作失败：${result.stderr}`);
  return result.stdout.trim();
}
beforeEach(() => {
  ctx = setup(); store = new DistillStore(ctx.db);
  repo = join(realpathSync(ctx.dir), "main-repo");
  worktree = join(realpathSync(ctx.dir), "worktrees", "example");
  git("init", repo);
  git("-C", repo, "-c", "user.name=合成用户", "-c", "user.email=synthetic@example.test", "-c", "commit.gpgsign=false", "commit", "--allow-empty", "-m", "合成初始提交");
  git("-C", repo, "worktree", "add", "--detach", worktree);
  store.upsertProject({ id: "main", name: "合成主项目", confirmed: 1, brief: "合成主项目摘要", keys: { repos: [repo], hosts: [], chats: [] } });
});
afterEach(() => ctx.cleanup());
function frame(path: string): Frame {
  const record = fixture({ source: "codex.session", source_ref: ulid(), context: { cwd: path } });
  expect(ctx.db.ingest([record]).accepted).toBe(1);
  const value: Frame = { id: ulid(), key: frameKey(record), record_ids: [record.id], t_start_ms: 1000, t_end_ms: 1000, chars: 1, private: 0, status: "new" };
  store.createFrame(value); return value;
}
function active() { store.upsertThread({ id: "thread", project_id: "main", title: "合成线程", brief: "合成线程摘要", status: "active", last_ms: 1000 }); }
async function context(cwd: string) {
  const response = await new AgentReads(ctx.db).handle("context", new URLSearchParams({ tool: "codex", event: "startup", cwd }));
  expect(response.status).toBe(200); return response.json();
}

test("worktree repo key 复用主项目并保存根别名，不新增项目或待确认", () => {
  const rules = new DistillRules(store); active();
  expect(rules.projectForRepo(worktree)?.id).toBe("main");
  expect(rules.projectForRepo(worktree)?.id).toBe("main");
  expect(store.project("main")?.keys.repos).toEqual([repo, worktree]);
  expect(store.projects()).toHaveLength(1); expect(store.pending()).toHaveLength(0);
  expect(rules.projectForFrame(frame(worktree))?.id).toBe("main");
  expect(rules.assign(frame(worktree))).toEqual({ status: "unassigned" });
});

test("首次从 worktree 发现仓库只创建一个主项目及其确认项", () => {
  ctx.db.db.prepare("DELETE FROM projects").run();
  const rules = new DistillRules(store), project = rules.projectForRepo(worktree)!;
  expect(project.name).toBe("main-repo"); expect(project.keys.repos).toEqual([repo, worktree]);
  expect(rules.projectForRepo(repo)?.id).toBe(project.id);
  expect(store.projects()).toHaveLength(1); expect(store.pending()).toHaveLength(1);
});

test("worktree 删除后未缓存的子路径仍靠持久化别名归属", async () => {
  new DistillRules(store).projectForRepo(worktree); active();
  git("-C", repo, "worktree", "remove", worktree);
  const deleted = join(worktree, "never-probed");
  expect(resolveRepoRoot(deleted, store.projects())).toBe(repo);
  const rules = new DistillRules(store);
  expect(rules.projectForRepo(worktree)?.id).toBe("main");
  expect(rules.projectForFrame(frame(deleted))?.id).toBe("main");
  expect(rules.assign(frame(deleted)).status).toBe("unassigned");
  expect((await context(deleted)).project_id).toBe("main");
  expect(store.projects()).toHaveLength(1); expect(store.pending()).toHaveLength(0);
});

test("子目录 repo key 归主项目，保存的是 worktree 根", () => {
  const child = join(worktree, "src"); mkdirSync(child);
  const rules = new DistillRules(store); active();
  expect(rules.projectForFrame(frame(child))?.id).toBe("main");
  expect(rules.assign(frame(child)).status).toBe("unassigned");
  expect(rules.projectForRepo(child)?.keys.repos).toEqual([repo, worktree]);
  const mainChild = join(repo, "src"); mkdirSync(mainChild);
  expect(rules.projectForRepo(mainChild)?.id).toBe("main");
  expect(rules.projectForFrame(frame(mainChild))?.id).toBe("main");
  expect(rules.assign(frame(mainChild)).status).toBe("unassigned");
});

test("context 未见过的 worktree cwd 和子目录返回主项目，不写别名", async () => {
  active();
  store.upsertThread({ ...store.thread("thread")!, domain: "work" });
  reviewEvidence(store,"thread");
  const child = join(worktree, "src"); mkdirSync(child);
  for (const cwd of [worktree, child, join(repo, "src")]) {
    const started = performance.now(), result = await context(cwd);
    expect(result.project_id).toBe("main");
    expect(result.text).toContain("合成线程摘要");
    expect(performance.now() - started).toBeLessThan(2000);
  }
  expect(store.project("main")?.keys.repos).toEqual([repo]);
  expect(store.pending()).toHaveLength(0);
});

test("git 失败时取最长路径边界，失败缓存不遮蔽新增或合并后的别名", () => {
  const missing = join(ctx.dir, "missing");
  expect(resolveRepoRoot(missing, store.projects())).toBeNull();
  store.upsertProject({ id: "other", name: "合成嵌套项目", keys: { repos: ["/synthetic/main", missing], hosts: [], chats: [] } });
  expect(resolveRepoRoot(missing, store.projects())).toBe("/synthetic/main");
  store.upsertProject({ ...store.project("other")!, keys: { repos: ["/synthetic/merged", missing], hosts: [], chats: [] } });
  expect(resolveRepoRoot(missing, store.projects())).toBe("/synthetic/merged");
  expect(resolveRepoRoot(missing + "-suffix", store.projects())).toBeNull();
  expect(projectForPath(join(repo, "nested", "file"), [
    ...store.projects(), { id: "nested", name: "合成嵌套项目", keys: { repos: [join(repo, "nested")], hosts: [], chats: [] } },
  ])?.id).toBe("nested");
});

test("非 .git 公共目录退回工作树根，裸仓库不创建项目", () => {
  const separate = join(ctx.dir, "separate-repo"), metadata = join(ctx.dir, "metadata");
  git("init", `--separate-git-dir=${metadata}`, separate);
  expect(resolveRepoRoot(separate, [])).toBe(realpathSync(separate));
  const bare = join(ctx.dir, "bare.git"); git("init", "--bare", bare);
  expect(new DistillRules(store).projectForRepo(bare)).toBeNull();
  expect(store.projects()).toHaveLength(1); expect(store.pending()).toHaveLength(0);
});

test("家目录别名不吸收零散会话", () => {
  const home = { id: "home", name: "合成家目录项目", keys: { repos: [homedir()], hosts: [], chats: [] } };
  expect(projectForPath(join(homedir(), "synthetic-unrelated"), [home])).toBeNull();
});

async function verifyProjectRemoval(call: (token: string) => Promise<Response>, agentToken: string) {
  const rules = new DistillRules(store);
  rules.projectForRepo(worktree);
  const keys = { repos: [repo, worktree], hosts: ["exhibit.example.test"], chats: ["mac.wechat:合成展 厅"] };
  store.upsertProject({ ...store.project("main")!, keys, detail: { status: "合成项目详情" } });
  store.upsertProject({ id: "other", name: "合成独立项目", keys: { repos: [], hosts: [], chats: [] } });
  active();
  store.upsertThread({ ...store.thread("thread")!, project_hint: "main", detail: { progress: "合成事项进展" }, needs_regen: 0,
    first_ms: Date.parse("2026-11-15T12:00:00"), last_ms: Date.parse("2026-11-17T12:00:00") });
  store.upsertThread({ id: "hint-only", project_hint: "main", title: "合成候选事项", status: "active", needs_regen: 0 });
  const record = reviewEvidence(store, "thread");
  store.writeFact({ id: "fact", thread_id: "thread", project_id: "main", kind: "decision", text: "合成决定",
    evidence: [record.id], origin: "user", valid_at: record.at, created_at: record.at });
  store.upsertThread({ ...store.thread("thread")!, needs_regen: 0 });
  const queued = [
    { id: "project-pending", kind: "project", payload: { project_id: "main" } },
    { id: "merge-pending", kind: "merge", payload: { a: "other", b: "main" } },
    { id: "thread-pending", kind: "thread_done", payload: { thread_id: "thread" } },
    { id: "unrelated-pending", kind: "project", payload: { project_id: "other" } },
    { id: "earlier-resolution", kind: "project", payload: { project_id: "main" }, resolved_at: record.at, resolution: "confirm" },
  ] as const;
  for (const item of queued) store.createPending({ ...item, created_at: record.at });
  store.setState("now", { brief: "合成项目旧摘要", detail: { threads: [] } });
  store.setState("project_brief:main", true);
  store.setState("digest:thread", { frames: ["old-frame"], records: 1 });
  store.setState("candidates", [{ id: "candidate", project_id: "main", frame_ids: [] }]);
  store.upsertDay({ date: "2026-11-15", needs_regen: 0, brief: "合成概述", detail: { summary: "合成概述", items: [{ project_id: "main" }] } });
  store.upsertDay({ date: "2026-11-16", needs_regen: 0, brief: "另一日旧摘要", detail: { summary: "另一日旧摘要", items: [{ project_id: "other" }] } });
  expect((await context(repo)).text).toContain("合成线程摘要");
  const denied = await call(agentToken);
  expect(denied.status).toBe(403);
  expect(await denied.json()).toEqual({ error: "此令牌仅允许 AI 查询与追加" });
  expect(store.project("main")).not.toBeNull();

  const removed = await call(ctx.config.token);
  expect(removed.status).toBe(200);
  expect(await removed.json()).toEqual({ removed: true });
  expect(store.project("main")).toBeNull();
  expect(store.projects().map(project => project.id)).toEqual(["other"]);
  expect(store.ignoredProjectKeys()).toEqual(keys);
  expect(store.thread("thread")).toMatchObject({ project_id: null, project_hint: null, brief: null, detail: null, needs_regen: 1 });
  expect(store.thread("hint-only")).toMatchObject({ project_hint: null, needs_regen: 1 });
  expect(store.facts("thread_id", "thread")).toMatchObject([{ id: "fact", project_id: null, evidence: [record.id] }]);
  expect(ctx.db.get(record.id)).not.toBeNull();
  expect(store.pending().map(item => item.id)).toEqual(["unrelated-pending"]);
  expect(ctx.db.db.prepare("SELECT id,resolution FROM pending WHERE resolved_at IS NOT NULL ORDER BY id").all()).toEqual([
    { id: "earlier-resolution", resolution: "confirm" }, { id: "merge-pending", resolution: "project_removed" },
    { id: "project-pending", resolution: "project_removed" }, { id: "thread-pending", resolution: "project_removed" },
  ]);
  expect(store.getState("now")).toBeNull();
  expect(store.getState("project_brief:main")).toBeNull();
  expect(store.getState("digest:thread")).toBeNull();
  expect(store.getState("candidates")).toEqual([{ id: "candidate", project_id: null, frame_ids: [] }]);
  expect(store.day("2026-11-15")).toMatchObject({ needs_regen: 1, brief: null, detail: null });
  expect(store.day("2026-11-16")).toMatchObject({ needs_regen: 0, brief: "另一日旧摘要" });
  expect(await context(repo)).toMatchObject({ project_id: null, text: "", tokens_est: 0 });
  const missing = await call(ctx.config.token);
  expect(missing.status).toBe(404);
  expect(await missing.json()).toEqual({ error: "项目不存在" });
}

test("项目移除 API 鉴权并原子解绑，只撤下相关派生内容和待确认", async () => {
  const agentToken = "synthetic-agent-token";
  const options = { db: ctx.db, token: ctx.config.token, agentToken, settings: { dataDir: ctx.dir } };
  const path = "/v1/projects/main";
  if (await networkDenied()) {
    const handler = createHandler(options);
    await verifyProjectRemoval(token => handler(new Request(`http://127.0.0.1:47823${path}`, {
      method: "DELETE", headers: { host: "127.0.0.1:47823", authorization: `Bearer ${token}` },
    })), agentToken);
    return;
  }
  const server = startServer({ ...options, port: 0 });
  try {
    await verifyProjectRemoval(token => fetch(new URL(path, server.url), { method: "DELETE", headers: { authorization: `Bearer ${token}` } }), agentToken);
  } finally { server.stop(true); }
});

test("待确认忽略持久化仓库别名，后续切片、规则和名称提名都不再关联", () => {
  const rules = new DistillRules(store);
  rules.projectForRepo(worktree);
  const keys = { repos: [repo, worktree], hosts: ["Exhibit.example.test"], chats: ["mac.wechat:合成展 厅"] };
  store.upsertProject({ ...store.project("main")!, keys });
  store.createPending({ id: "pending", kind: "project", payload: { project_id: "main" }, created_at: new Date().toISOString() });
  store.resolvePending("pending", "ignore");
  expect(store.project("main")).toBeNull();
  expect(store.pending()).toEqual([]);
  expect(ctx.db.db.prepare("SELECT resolution FROM pending WHERE id='pending'").get()).toEqual({ resolution: "ignore" });
  const reopened = new HubDB(ctx.file, ctx.config.dbKey);
  try {
    const persisted = new DistillStore(reopened), next = new DistillRules(persisted);
    expect(persisted.ignoredProjectKeys()).toEqual(keys);
    expect(next.projectForRepo(repo)).toBeNull();
    expect(next.projectForRepo(worktree)).toBeNull();
    git("-C", repo, "worktree", "remove", worktree);
    expect(next.projectForRepo(join(worktree, "never-probed"))).toBeNull();
    const at = Date.now();
    const followup = fixture({ source: "codex.session", t_start: new Date(at - 20 * 60_000).toISOString(),
      source_ref: "synthetic-next-round", context: { cwd: repo } });
    expect(reopened.ingest([followup]).accepted).toBe(1);
    expect(sliceStep(reopened, false, at, at - 3600_000).frames).toBe(1);
    expect(persisted.projects()).toEqual([]);
    expect(persisted.pending()).toEqual([]);
    const kept = { id: "new-project", name: "合成独立项目", keys: { repos: [], hosts: [], chats: [] } };
    persisted.upsertProject(kept);
    const repoFrame = persisted.frames()[0]!;
    const chat = fixture({ source: "mac.wechat", context: { chat: "合成展厅" } });
    const browser = fixture({ source: "mac.browser", source_ref: "synthetic-website", context: { url: "https://exhibit.example.test/guide" } });
    expect(reopened.ingest([chat, browser]).accepted).toBe(2);
    for (const [id, source] of [["chat", chat], ["host", browser]] as const) {
      persisted.createFrame({ ...repoFrame, id, key: frameKey(source), record_ids: [source.id] });
    }
    for (const [id, frameId] of [["repo-thread", repoFrame.id], ["chat-thread", "chat"], ["host-thread", "host"]] as const) {
      persisted.upsertThread({ id, title: `整理${kept.name}`, status: "active" });
      persisted.assign(frameId, id, "rule", 1);
    }
    persisted.upsertThread({ id: "unrelated-thread", title: `整理${kept.name}`, status: "active" });
    expect(nominateByName(persisted)).toBe(1);
    expect(persisted.thread("unrelated-thread")?.project_hint).toBe(kept.id);
    for (const id of ["repo-thread", "chat-thread", "host-thread"]) expect(persisted.thread(id)?.project_hint).toBeNull();
  } finally { reopened.close(); }
});

test("项目整理期间移除项目，旧模型结果不能写回", async () => {
  active();
  const llm: LLM = { async complete<T>(request: import("../src/llm/index.ts").LLMRequest) {
    expect(request.task).toBe("project");
    expect(store.removeProject("main")).toBe(true);
    return { ok: true, ms: 1, data: { goal: "合成目标", status: "合成进度", people: [], resolutions: [] } as T };
  } };
  expect(await projectStep({ db: ctx.db, llm }, store, Date.now())).toEqual({ calls: 1, updated: 0, failed: 1 });
  expect(store.project("main")).toBeNull();
  expect(store.getState("project_brief:main")).toBeNull();
});
