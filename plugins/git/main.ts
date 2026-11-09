#!/usr/bin/env bun
import { readdir, realpath } from "node:fs/promises";
import path from "node:path";
import os from "node:os";
import { clampTitle, emitCheckpoint, emitRecord, parsePluginArgs, readState, toLocalIso, ulid, validateRecord, type RecordV1 } from "../../packages/record/index.ts";

interface RepoProgress { since: string; seen: string[]; }
export interface GitState { repos: string[]; progress: Record<string, RepoProgress>; }

function expandHome(value: string): string {
  return value === "~" ? os.homedir() : value.startsWith("~/") ? path.join(os.homedir(), value.slice(2)) : path.resolve(value);
}

export async function discoverRepos(roots: string[]): Promise<string[]> {
  const repos = new Set<string>();
  async function visit(directory: string, depth: number): Promise<void> {
    let entries;
    try { entries = await readdir(directory, { withFileTypes: true }); } catch { return; }
    if (entries.some((entry) => entry.name === ".git" && (entry.isDirectory() || entry.isFile()))) {
      try { repos.add(await realpath(directory)); } catch {}
    }
    if (depth === 4) return;
    await Promise.all(entries.filter((entry) => entry.isDirectory() && entry.name !== ".git")
      .map((entry) => visit(path.join(directory, entry.name), depth + 1)));
  }
  for (const root of roots) await visit(expandHome(root), 0);
  return [...repos].sort();
}

async function git(args: string[], deadline: number, cwd?: string, optional = false): Promise<string> {
  const remaining = deadline - Date.now();
  if (remaining <= 0) throw new Error("超过时限");
  const child = Bun.spawn(["git", "--no-pager", "-c", "color.ui=false", ...args], {
    cwd, env: { ...process.env, GIT_OPTIONAL_LOCKS: "0", GIT_PAGER: "cat", PAGER: "cat", GIT_TERMINAL_PROMPT: "0" },
    stdin: "ignore", stdout: "pipe", stderr: "pipe",
  });
  let timedOut = false;
  const timer = setTimeout(() => { timedOut = true; child.kill("SIGKILL"); }, remaining);
  try {
    const [stdout, , code] = await Promise.all([new Response(child.stdout).text(), new Response(child.stderr).text(), child.exited]);
    if (timedOut) throw new Error("超过时限");
    if (code !== 0 && !(optional && code === 1)) throw new Error(`git ${args[0]} 失败（退出码 ${code}）`);
    return stdout;
  } finally { clearTimeout(timer); }
}

interface Commit { hash: string; author: string; email: string; authored: string; committed: string; message: string; files: string[]; added: number; deleted: number; }
function parseLog(output: string): Commit[] {
  const commits: Commit[] = [];
  // Git 的 -z 保留文件名中的制表符、换行和中文；提交正文不能含 NUL。
  const marker = "\0RA_COMMIT\0";
  for (const section of output.split(marker).slice(1)) {
    const fields = section.split("\0");
    const [hash, author, email, authored, committed, message] = fields;
    if (!hash || !/^[a-f0-9]{40,64}$/.test(hash) || author === undefined || !email || !authored || !committed || message === undefined) throw new Error("无法解析 git log");
    const commit: Commit = { hash, author, email, authored, committed, message, files: [], added: 0, deleted: 0 };
    for (const field of fields.slice(6)) {
      const line = field.replace(/^\n/, "");
      if (!line) continue;
      const stat = /^(\d+|-)\t(\d+|-)\t([\s\S]+)$/.exec(line);
      if (!stat) throw new Error("无法解析 git numstat");
      commit.files.push(stat[3]!);
      commit.added += stat[1] === "-" ? 0 : Number(stat[1]);
      commit.deleted += stat[2] === "-" ? 0 : Number(stat[2]);
    }
    commits.push(commit);
  }
  return commits;
}

export async function collectGit(options: {
  device: string; roots: string[]; state?: GitState; since?: Date | null; emails?: string[];
  emit: (record: RecordV1) => void; log?: (message: string) => void;
}): Promise<GitState> {
  const log = options.log ?? ((message) => console.error(message));
  if (options.since && Number.isNaN(options.since.valueOf())) throw new Error("无效的 --since 时间");
  const repos = [...new Set([...await discoverRepos(options.roots), ...(options.state?.repos ?? []).map(expandHome)])].sort();
  const progress = { ...options.state?.progress };
  const globalEmail = options.emails ? "" : (await git(["config", "--global", "--get", "user.email"], Date.now() + 10_000, undefined, true)).trim();
  for (const repo of repos) {
    // 显式 --since（导入全部历史）要读的提交可能很多，放宽到 2 分钟；常规增量仍是 10 秒。
    const started = Date.now(), deadline = started + (options.since ? 120_000 : 10_000);
    try {
      const top = (await git(["rev-parse", "--show-toplevel"], deadline, repo)).trim();
      if (await realpath(top) !== await realpath(repo)) throw new Error("路径不是仓库根目录");
      const localEmail = options.emails ? "" : (await git(["config", "--get", "user.email"], deadline, repo, true)).trim();
      const emails = new Set((options.emails ?? [globalEmail, localEmail]).filter(Boolean).map((email) => email.toLowerCase()));
      if (!emails.size) throw new Error("未配置用户邮箱");
      const previous = options.state?.progress?.[repo];
      const since = options.since ?? new Date(previous?.since ?? started - 7 * 86400_000);
      if (Number.isNaN(since.valueOf())) throw new Error("checkpoint 时间无效");
      // 回看一秒并记住边界提交，避免同一秒内的新提交被遗漏或重复。
      const nextSince = new Date(Math.floor(started / 1000) * 1000 - 1000);
      const seen = new Set(options.since ? [] : previous?.seen ?? []);
      const output = await git(["log", "--all", `--since=${since.toISOString()}`, "--format=%x00RA_COMMIT%x00%H%x00%an%x00%ae%x00%aI%x00%cI%x00%B%x00", "--numstat", "-z", "--no-renames", "--no-ext-diff", "--no-textconv", "--no-notes", "--no-show-signature", "--no-decorate", "--encoding=UTF-8", "--diff-merges=first-parent"], deadline, repo);
      const commits = parseLog(output), records: RecordV1[] = [];
      for (const commit of commits) {
        if (!emails.has(commit.email.toLowerCase()) || seen.has(commit.hash)) continue;
        const record: RecordV1 = {
          id: ulid(), schema: 1, device: options.device, source: "mac.git", kind: "event",
          source_ref: `${repo}:${commit.hash}`, t_start: toLocalIso(new Date(commit.authored)),
          title: clampTitle(`${path.basename(repo)} · ${commit.message.split("\n")[0]}`),
          body: `${commit.message}\n作者：${commit.author} <${commit.email}>\n提交：${commit.hash}\n改动：${commit.files.length} 个文件，新增 ${commit.added} 行，删除 ${commit.deleted} 行\n${commit.files.slice(0, 50).map((file) => JSON.stringify(file)).join("\n")}${commit.files.length > 50 ? `\n（另有 ${commit.files.length - 50} 个文件）` : ""}`,
          context: { repo, extra: { author: commit.author, author_email: commit.email, hash: commit.hash, files: commit.files.length, added: commit.added, deleted: commit.deleted } },
          capture: { method: "db" }, sensitivity: "normal",
        };
        const validation = validateRecord(record);
        if (!validation.ok) throw new Error(`记录不符合契约：${validation.errors.join("；")}`);
        records.push(record);
      }
      if (Date.now() > deadline) throw new Error("超过时限");
      for (const record of records) options.emit(record);
      // --since 覆盖到未来时不把游标倒退，否则下一次会意外回溯。
      const boundary = new Date(Math.max(nextSince.valueOf(), since.valueOf()));
      progress[repo] = { since: boundary.toISOString(), seen: commits.filter((commit) => new Date(commit.committed) >= boundary).map((commit) => commit.hash) };
    } catch (error) { log(`git：跳过仓库 ${repo}：${(error as Error).message}`); }
  }
  return { repos, progress };
}

if (import.meta.main) {
  try {
    const args = parsePluginArgs();
    const state = await collectGit({ device: args.device,
      roots: (process.env.RA_GIT_ROOTS ?? path.join(os.homedir(), "Study")).split(":").filter(Boolean),
      emails: process.env.RA_GIT_EMAILS === undefined ? undefined : process.env.RA_GIT_EMAILS.split(/[:,;\s]+/).filter(Boolean),
      state: readState<GitState>(args.stateFile, { repos: [], progress: {} }), since: args.since, emit: emitRecord });
    emitCheckpoint(state);
  } catch (error) { console.error(`git：${(error as Error).message}`); process.exitCode = 1; }
}
