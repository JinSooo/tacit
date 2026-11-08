import { afterEach, expect, test } from "bun:test";
import { mkdtemp, mkdir, readFile, writeFile, rm, readdir, stat, realpath } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { collectShell } from "./main.ts";
import { runPlugin } from "../../hub/src/run-plugin.ts";
import { setup } from "../../hub/test/helpers.ts";
import { validateRecord, type RecordV1 } from "../../packages/record/index.ts";

const temporary: string[] = [];
async function temp() { const dir = await mkdtemp(path.join(os.tmpdir(), "ra-shell-test-")); temporary.push(dir); return dir; }
afterEach(async () => { await Promise.all(temporary.splice(0).map((dir) => rm(dir, { recursive: true, force: true }))); });
const hook = path.join(import.meta.dir, "hook.zsh");
const main = path.join(import.meta.dir, "main.ts");
const entry = (cwd: string, command = "echo 中文", start_ms = Date.now()) => ({ start_ms, duration_ms: 12, exit_code: 0, cwd, command, pid: 123 });

test("zsh -f 实际钩子保留特殊命令、退出码、权限和 shell 状态，忽略空格命令", async () => {
  const dir = await temp(), file = path.join(dir, "缓冲", "shell.jsonl");
  const commands = [
    'printf \'%s\\n\' \'引号"与反斜杠\\\'',
    "printf '%s\\n' '第一行\n第二行'",
    "printf '%s\\n' $'控制\\t\\r\\001'",
    "false",
    " printf '不记录\\n'",
    "setopt HIST_IGNORE_SPACE",
    " printf '仍不记录\\n'",
  ];
  const child = Bun.spawn(["/bin/sh", "-c", "cat | /usr/bin/script -q /dev/null zsh -f -i"], {
    cwd: dir, env: { ...process.env, RA_SHELL_LOG: file, PS1: "", PS2: "" },
    stdin: "pipe",
    stdout: "pipe", stderr: "pipe",
  });
  let sent = false, closed = false, output = "";
  for await (const chunk of child.stdout) {
    output += new TextDecoder().decode(chunk);
    if (!sent && output.includes("\x1b[?2004h")) {
      sent = true;
      child.stdin.write(`umask 022\nsource '${hook}'\n${commands.join("\n")}\nunfunction _ra_shell_preexec\nunfunction _ra_shell_precmd\nprint -r -- UMASK=$(umask)\nexit\n`);
    }
    if (!closed && output.includes("UMASK=022")) { closed = true; child.stdin.end(); }
  }
  const [stdout, stderr, code] = [output, await new Response(child.stderr).text(), await child.exited];
  expect(code).toBe(0);
  expect(stderr).not.toContain("_ra_shell_");
  expect(stdout).toContain("UMASK=022");
  const rows = (await readFile(file, "utf8")).trim().split("\n").map((line) => JSON.parse(line));
  for (const command of commands.slice(0, 4)) expect(rows.some((row) => row.command === command)).toBe(true);
  expect(rows.some((row) => row.command.includes("不记录"))).toBe(false);
  expect(rows.find((row) => row.command === "false").exit_code).toBe(1);
  for (const row of rows) {
    expect(row.cwd).toBe(await realpath(dir));
    expect(row.pid).toBe(rows[0].pid); expect(row.pid).toBeGreaterThan(0);
    expect(Number.isInteger(row.start_ms)).toBe(true);
    expect(row.duration_ms).toBeGreaterThanOrEqual(0);
  }
  expect((await stat(file)).mode & 0o777).toBe(0o600);
  expect((await stat(path.dirname(file))).mode & 0o777).toBe(0o700);
});

test("重复 source 不重复注册，写入失败静默且不改变退出码", async () => {
  const dir = await temp(), file = path.join(dir, "shell.jsonl");
  const child = Bun.spawn(["zsh", "-f", "-c", `source '${hook}'; source '${hook}';
    print -r -- $preexec_functions;
    _ra_shell_preexec $'原文\\t\\r\\001\\0中文'; false; _ra_shell_precmd;
    _ra_shell_log='${dir}/不存在/log'; _ra_shell_preexec '失败'; false; _ra_shell_precmd;
    print -r -- 完成`], { env: { ...process.env, RA_SHELL_LOG: file }, stdout: "pipe", stderr: "pipe" });
  const [stdout, stderr, code] = await Promise.all([new Response(child.stdout).text(), new Response(child.stderr).text(), child.exited]);
  expect(code).toBe(0); expect(stderr).toBe(""); expect(stdout).toContain("完成"); expect(stdout.match(/_ra_shell_preexec/g)).toHaveLength(1);
  const rows = (await readFile(file, "utf8")).trim().split("\n").map((line) => JSON.parse(line));
  expect(rows).toHaveLength(1); expect(rows[0].exit_code).toBe(1); expect(rows[0].command).toBe("原文\t\r\x01\0中文");
});

test("开启 errexit 时缓冲目录不可用也不退出用户 shell", async () => {
  const dir = await temp(), blocker = path.join(dir, "不是目录"); await writeFile(blocker, "合成数据");
  const child = Bun.spawn(["zsh", "-f", "-e", "-c", `source '${hook}'; _ra_shell_preexec 'echo 测试'; _ra_shell_precmd; print -r -- 继续工作`], {
    env: { ...process.env, RA_SHELL_LOG: path.join(blocker, "shell.jsonl") }, stdout: "pipe", stderr: "pipe",
  });
  const [stdout, stderr, code] = await Promise.all([new Response(child.stdout).text(), new Response(child.stderr).text(), child.exited]);
  expect(code).toBe(0); expect(stderr).toBe(""); expect(stdout.trim()).toBe("继续工作");
});

test("轮转读取遗留 pending、坏行及无末尾换行，重读自然键稳定", async () => {
  const dir = await temp(), file = path.join(dir, "shell.jsonl"), cwd = path.join(dir, "repo", "子目录");
  await mkdir(cwd, { recursive: true }); await writeFile(path.join(dir, "repo", ".git"), "gitdir: /合成路径");
  const first = entry(cwd, 'echo "中文"\n第二行', Date.now() - 9 * 86400_000);
  const second = entry(cwd, "第二条", first.start_ms + 1);
  const leftover = path.join(dir, "shell.000.pending.jsonl");
  await writeFile(leftover, JSON.stringify(first) + "\n坏行\n{}\n残缺");
  await writeFile(file, JSON.stringify(second));
  const records: RecordV1[] = [], logs: string[] = [];
  const run = () => collectShell({ file, device: "test-mac", emit: (r) => records.push(r), log: (m) => logs.push(m) });
  const result = await run();
  expect(result.state).toEqual({ version: 2 }); expect(result.release).toHaveLength(2);
  expect(result.release[0]).toBe(leftover); expect(logs).toEqual(["shell：跳过 3 条坏行"]);
  expect(records).toHaveLength(2); expect(records[0]!.context).toEqual({ cwd, repo: path.dirname(cwd) });
  expect(records[0]!.source_ref).toBe(`123:${first.start_ms}`);
  await run(); expect(records).toHaveLength(4);
  expect(records[2]!.source_ref).toBe(records[0]!.source_ref);
  for (const record of records) expect(validateRecord(record)).toEqual({ ok: true });
});

test("--since 过滤、长标题、缺失目录以及 CLI 忽略旧 state 且只读", async () => {
  const dir = await temp(), file = path.join(dir, "shell.jsonl"), stateFile = path.join(dir, "state.json");
  const old = entry(dir, "旧命令", 1000), recent = entry(dir, "中".repeat(180));
  await writeFile(file, [old, recent].map((value) => JSON.stringify(value)).join("\n") + "\n");
  const records: RecordV1[] = [];
  await collectShell({ file, device: "mac", since: new Date(2000), emit: (r) => records.push(r) });
  expect(records).toHaveLength(1); expect(Array.from(records[0]!.title)).toHaveLength(120);
  expect(await collectShell({ file: path.join(dir, "absent", "shell.jsonl"), device: "mac", emit: () => {} })).toEqual({ state: { version: 2 }, release: [] });
  const stateText = JSON.stringify({ offset: 999999, inode: "old" }); await writeFile(stateFile, stateText);
  const child = Bun.spawn([process.execPath, main, "--device", "mac", "--state", stateFile], {
    env: { ...process.env, RA_SHELL_LOG: file }, stdout: "pipe", stderr: "pipe",
  });
  const output = await new Response(child.stdout).text(); expect(await child.exited).toBe(0);
  const lines = output.trim().split("\n").map((line) => JSON.parse(line));
  expect(lines.map((line) => line.type)).toEqual(["record", "record", "checkpoint"]);
  expect(lines[2].state).toEqual({ version: 2 }); expect(lines[2].release).toHaveLength(1);
  expect(await readFile(stateFile, "utf8")).toBe(stateText);
});

async function hookCommand(file: string, command: string) {
  const child = Bun.spawn(["zsh", "-f", "-c", `source '${hook}'; _ra_shell_preexec '${command}'; ${command}; _ra_shell_precmd`], {
    env: { ...process.env, RA_SHELL_LOG: file }, stdout: "pipe", stderr: "pipe",
  });
  expect(await child.exited).toBe(0);
}

test("真实钩子轮转期间的新命令写入新文件，runner 入库后只留下新 shell.jsonl", async () => {
  const ctx = setup();
  try {
    const dir = path.join(ctx.dir, "buffer"), file = path.join(dir, "shell.jsonl");
    await hookCommand(file, "echo first");
    const records: RecordV1[] = [];
    const collecting = collectShell({ file, device: "mac", emit: (r) => records.push(r) });
    // 等观察到 rename，再模拟钩子按原路径追加。
    for (let i = 0; i < 100; i++) {
      if ((await readdir(dir)).some((name) => name.endsWith(".pending.jsonl"))) break;
      await Bun.sleep(5);
    }
    await hookCommand(file, "echo second");
    await collecting;
    expect(records.map((r) => r.title)).toEqual(["echo first"]);
    expect(await readFile(file, "utf8")).toContain("echo second");
    // 用 zsh 设置子进程环境，真正以 CLI 运行插件。
    const running = runPlugin({ db: ctx.db, dataDir: ctx.dir, name: "shell", command: ["env", `RA_SHELL_LOG=${file}`, process.execPath, main] });
    for (let i = 0; i < 100; i++) {
      if ((await readdir(dir)).filter((name) => name.endsWith(".pending.jsonl")).length === 2) break;
      await Bun.sleep(5);
    }
    await hookCommand(file, "echo third");
    const result = await running;
    expect(result.stateWritten).toBe(true); expect(result.accepted).toBe(2); expect(result.released).toBe(2);
    expect(await readdir(dir)).toEqual(["shell.jsonl"]);
    expect(await readFile(file, "utf8")).toContain("echo third");
    expect(JSON.parse(await readFile(path.join(ctx.dir, "plugins/shell/state.json"), "utf8"))).toEqual({ version: 2 });
  } finally { ctx.cleanup(); }
});
