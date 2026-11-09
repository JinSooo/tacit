import { afterEach, expect, test } from "bun:test";
import { chmod, mkdtemp, mkdir, readFile, realpath, rm, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { collectGit, discoverRepos, type GitState } from "./main.ts";
import { validateRecord, type RecordV1 } from "../../packages/record/index.ts";

const temporary: string[] = [];
const originalGlobal = process.env.GIT_CONFIG_GLOBAL, originalSystem = process.env.GIT_CONFIG_NOSYSTEM, originalPath = process.env.PATH;
afterEach(async () => {
  for (const [key, value] of Object.entries({ GIT_CONFIG_GLOBAL: originalGlobal, GIT_CONFIG_NOSYSTEM: originalSystem, PATH: originalPath })) {
    if (value === undefined) delete process.env[key]; else process.env[key] = value;
  }
  await Promise.all(temporary.splice(0).map((dir) => rm(dir, { recursive: true, force: true })));
});
async function temp() {
  const dir = await realpath(await mkdtemp(path.join(os.tmpdir(), "ra-git-test-"))); temporary.push(dir);
  const config = path.join(dir, "global.gitconfig");
  await writeFile(config, '[user]\n name = 合成用户\n email = global@example.test\n');
  process.env.GIT_CONFIG_GLOBAL = config; process.env.GIT_CONFIG_NOSYSTEM = "1";
  return dir;
}
async function git(cwd: string, args: string[], env: Record<string, string> = {}): Promise<string> {
  const child = Bun.spawn(["git", ...args], { cwd, env: { ...process.env, ...env }, stdout: "pipe", stderr: "pipe" });
  const [stdout, stderr, code] = await Promise.all([new Response(child.stdout).text(), new Response(child.stderr).text(), child.exited]);
  if (code) throw new Error(`测试 git 失败：${stderr}`);
  return stdout.trim();
}
async function init(dir: string, email: string) {
  await mkdir(dir, { recursive: true }); await git(dir, ["init", "-b", "main"]);
  await git(dir, ["config", "user.name", "合成用户"]); await git(dir, ["config", "user.email", email]);
  await git(dir, ["config", "commit.gpgsign", "false"]);
}
let sequence = 0;
async function commit(repo: string, email: string, message: string, file?: string, date?: string) {
  const name = file ?? `文件-${sequence++}.txt`;
  await writeFile(path.join(repo, name), "第一行\n第二行\n");
  await git(repo, ["add", "--", name]);
  await git(repo, ["commit", "--author", `合成作者 <${email}>`, "-m", message], date ? { GIT_AUTHOR_DATE: date, GIT_COMMITTER_DATE: date } : {});
  return git(repo, ["rev-parse", "HEAD"]);
}

test("两个真实仓库按全局和本地邮箱过滤、采集所有分支、同秒增量及 remembered 仓库", async () => {
  const dir = await temp(), repoA = path.join(dir, "仓库甲"), repoB = path.join(dir, "仓库乙");
  await init(repoA, "local-a@example.test"); await init(repoB, "local-b@example.test");
  const hashA = await commit(repoA, "global@example.test", "合成主题\n\n完整详细正文", "引号\"制表\t换行\n中文.txt");
  await commit(repoA, "outsider@example.test", "其他人的提交");
  await git(repoA, ["checkout", "-b", "side"]);
  const sideHash = await commit(repoA, "local-a@example.test", "分支上的提交"); await git(repoA, ["checkout", "main"]);
  const hashB = await commit(repoB, "local-b@example.test", "乙仓库提交");
  const records: RecordV1[] = [], logs: string[] = [];
  const run = (roots: string[], state?: GitState, emails?: string[]) => collectGit({ device: "test-mac", roots, state, emails, emit: (r) => records.push(r), log: (m) => logs.push(m) });
  let state = await run([dir]);
  expect(logs).toEqual([]); expect(records).toHaveLength(3);
  expect(new Set(records.map((r) => r.source_ref))).toEqual(new Set([`${repoA}:${hashA}`, `${repoA}:${sideHash}`, `${repoB}:${hashB}`]));
  const first = records.find((r) => r.source_ref?.endsWith(hashA))!;
  expect(first.title).toBe("仓库甲 · 合成主题"); expect(first.body).toContain("完整详细正文");
  expect(first.body).toContain(JSON.stringify('引号"制表\t换行\n中文.txt'));
  expect(first.context?.extra).toMatchObject({ author: "合成作者", files: 1, added: 2, deleted: 0 });
  const newHash = await commit(repoB, "local-b@example.test", "同秒的新提交");
  state = await run([repoA], state); // 乙仓库只能从 state 找到。
  expect(records).toHaveLength(4); expect(records[3]!.source_ref).toBe(`${repoB}:${newHash}`);
  await run([], state); expect(records).toHaveLength(4); expect(logs).toEqual([]);
  for (const record of records) expect(validateRecord(record)).toEqual({ ok: true });
  records.length = 0;
  await run([dir], undefined, ["outsider@example.test"]);
  expect(records).toHaveLength(1); expect(records[0]!.title).toContain("其他人的提交");
});

test("首次七天与 --since 覆盖、最多 50 个改动文件", async () => {
  const dir = await temp(), repo = path.join(dir, "repo"); await init(repo, "local@example.test");
  const oldDate = new Date(Date.now() - 9 * 86400_000).toISOString();
  await commit(repo, "local@example.test", "九天前", undefined, oldDate);
  for (let i = 0; i < 55; i++) await writeFile(path.join(repo, `many-${i.toString().padStart(2, "0")}.txt`), "新增\n");
  await git(repo, ["add", "."]); await git(repo, ["commit", "-m", "多文件提交"]);
  const records: RecordV1[] = [];
  const state = await collectGit({ device: "mac", roots: [dir], emit: (r) => records.push(r) });
  expect(records).toHaveLength(1); expect(records[0]!.context?.extra).toMatchObject({ files: 55, added: 55, deleted: 0 });
  expect(records[0]!.body.split("\n").filter((line) => line.startsWith('"many-'))).toHaveLength(50);
  expect(records[0]!.body).toContain("另有 5 个文件");
  records.length = 0;
  await collectGit({ device: "mac", roots: [dir], state, since: new Date(0), emit: (r) => records.push(r) });
  expect(records).toHaveLength(2);
  for (const record of records) expect(validateRecord(record)).toEqual({ ok: true });
});

test("发现深度不超过四层、识别 .git 文件且不跟随循环链接", async () => {
  const dir = await temp(), fourth = path.join(dir, "1", "2", "3", "4"), fifth = path.join(fourth, "5");
  await mkdir(fifth, { recursive: true }); await writeFile(path.join(fourth, ".git"), "gitdir: /合成路径"); await mkdir(path.join(fifth, ".git"));
  const { symlink } = await import("node:fs/promises"); await symlink(dir, path.join(dir, "loop"));
  expect(await discoverRepos([dir])).toEqual([fourth]);
});

test("失败仓库保持旧进度并记日志；CLI 只读 state，邮箱环境变量覆盖", async () => {
  const dir = await temp(), repo = path.join(dir, "repo"), missing = path.join(dir, "missing"); await init(repo, "local@example.test");
  await commit(repo, "special@example.test", "环境变量作者");
  const previous = { since: new Date(0).toISOString(), seen: [] };
  const initial: GitState = { repos: [repo, missing], progress: { [missing]: previous } };
  const records: RecordV1[] = [], logs: string[] = [];
  const state = await collectGit({ device: "mac", roots: [], state: initial, emails: ["special@example.test"], emit: (r) => records.push(r), log: (m) => logs.push(m) });
  expect(state.progress[missing]).toEqual(previous); expect(logs).toHaveLength(1); expect(records).toHaveLength(1);
  const stateFile = path.join(dir, "state.json"), text = JSON.stringify({ repos: [repo], progress: {} }); await writeFile(stateFile, text);
  const child = Bun.spawn([process.execPath, path.join(import.meta.dir, "main.ts"), "--device", "mac", "--state", stateFile], {
    env: { ...process.env, RA_GIT_ROOTS: path.join(dir, "absent"), RA_GIT_EMAILS: "special@example.test" }, stdout: "pipe", stderr: "pipe",
  });
  const [stdout, stderr, code] = await Promise.all([new Response(child.stdout).text(), new Response(child.stderr).text(), child.exited]);
  expect(code).toBe(0); expect(stderr).toBe("");
  const lines = stdout.trim().split("\n").map((line) => JSON.parse(line));
  expect(lines.map((line) => line.type)).toEqual(["record", "checkpoint"]);
  expect(validateRecord(lines[0].record)).toEqual({ ok: true }); expect(await readFile(stateFile, "utf8")).toBe(text);
});

test("每仓库十秒时限真实终止挂起进程，调用禁用锁和分页颜色", async () => {
  const dir = await temp(), bin = path.join(dir, "bin"); await mkdir(bin);
  const executable = path.join(bin, "git");
  await writeFile(executable, `#!/bin/sh
test "$GIT_OPTIONAL_LOCKS" = 0 || exit 90
test "$GIT_PAGER" = cat || exit 91
test "$1" = --no-pager || exit 92
test "$2" = -c || exit 93
test "$3" = color.ui=false || exit 94
shift 3
if test "$1" = rev-parse; then pwd; else exec /bin/sleep 20; fi
`); await chmod(executable, 0o700); process.env.PATH = `${bin}:${originalPath}`;
  const logs: string[] = [], started = Date.now();
  const state = await collectGit({ device: "mac", roots: [], state: { repos: [dir], progress: {} }, emails: ["test@example.test"], emit: () => { throw new Error("不应输出记录"); }, log: (m) => logs.push(m) });
  expect(Date.now() - started).toBeGreaterThanOrEqual(9900); expect(Date.now() - started).toBeLessThan(13_000);
  expect(logs).toHaveLength(1); expect(logs[0]).toContain("超过时限"); expect(state.progress[dir]).toBeUndefined();
}, 15_000);
