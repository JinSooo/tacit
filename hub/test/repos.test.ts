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
import { ulid } from "../../packages/record/index.ts";
import { fixture, setup } from "./helpers.ts";

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
  expect(rules.assign(frame(worktree))).toEqual({ status: "assigned", thread_id: "thread", project_id: "main" });
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
  expect(rules.assign(frame(deleted)).status).toBe("assigned");
  expect((await context(deleted)).project_id).toBe("main");
  expect(store.projects()).toHaveLength(1); expect(store.pending()).toHaveLength(0);
});

test("子目录 repo key 归主项目，保存的是 worktree 根", () => {
  const child = join(worktree, "src"); mkdirSync(child);
  const rules = new DistillRules(store); active();
  expect(rules.assign(frame(child)).status).toBe("assigned");
  expect(rules.projectForRepo(child)?.keys.repos).toEqual([repo, worktree]);
  const mainChild = join(repo, "src"); mkdirSync(mainChild);
  expect(rules.projectForRepo(mainChild)?.id).toBe("main");
  expect(rules.assign(frame(mainChild)).status).toBe("assigned");
});

test("context 未见过的 worktree cwd 和子目录返回主项目，不写别名", async () => {
  active();
  const child = join(worktree, "src"); mkdirSync(child);
  for (const cwd of [worktree, child, join(repo, "src")]) {
    const started = performance.now(), result = await context(cwd);
    expect(result.project_id).toBe("main");
    expect(result.text).toContain("合成主项目摘要"); expect(result.text).toContain("合成线程摘要");
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
