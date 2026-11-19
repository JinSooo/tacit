import { homedir } from "node:os";
import { join } from "node:path";
import { closeSync, constants, mkdirSync, openSync, readFileSync, renameSync, rmSync, writeFileSync } from "node:fs";
import { randomUUID } from "node:crypto";
import { spawnSync } from "node:child_process";
import { dataDirOf } from "./hub-json.ts";
import type { HubDB as Database } from "./db.ts";

/** 错误消息可能夹带路径、凭据或记录正文。 */
export function cliErrorDetail(error: unknown): string {
  const value = error as { name?: unknown; code?: unknown } | null;
  const label = (input: unknown, fallback: string) => typeof input === "string" && /^[A-Za-z][A-Za-z0-9_]{0,63}$/.test(input) ? input : fallback;
  const name = label(value?.name, "Error");
  return `${name} (${label(value?.code, "UNKNOWN")})`;
}

const startupMessages = {
  db_key_missing: "钥匙串里找不到数据库密钥，但已有记录库。请用之前导出的密钥备份恢复，不要重装。",
  db_key_unreadable: "无法读取或保存钥匙串里的数据库密钥。请检查钥匙串是否解锁。",
  db_open_failed: "无法打开记录库，或记录库完整性检查失败。请确认数据库密钥与记录库匹配。",
  db_migration_failed: "记录库升级失败。请保留现有记录库和迁移备份。",
  port_in_use: "后台服务的端口已被占用。请在设置里更换端口。",
  unknown: "后台服务没能启动。请查看运行记录。",
};
type StartupCode = keyof typeof startupMessages;
const errorCode = (error: unknown) => (error as { code?: unknown } | null)?.code;
const startupFile = (dataDir: string) => join(dataDir, "hub-startup-error.json");

function localStartupTime(): string {
  // 其他模块加载失败时也能写启动诊断。
  const now = new Date(), offset = -now.getTimezoneOffset();
  const hours = String(Math.floor(Math.abs(offset) / 60)).padStart(2, "0");
  const minutes = String(Math.abs(offset) % 60).padStart(2, "0");
  const time = new Date(now.getTime() + offset * 60_000).toISOString().slice(0, 19);
  return time + (offset >= 0 ? "+" : "-") + hours + ":" + minutes;
}

function reportStartupFailure(dataDir: string, code: StartupCode): void {
  const target = startupFile(dataDir), temp = target + "." + randomUUID() + ".tmp";
  const diagnostic = JSON.stringify({ code }) + "\n";
  try {
    mkdirSync(dataDir, { recursive: true, mode: 0o700 });
    try {
      writeFileSync(temp, JSON.stringify({ at: localStartupTime(), code, message: startupMessages[code] }) + "\n", { mode: 0o600, flag: "wx" });
      renameSync(temp, target);
    } finally { rmSync(temp, { force: true }); }
  } catch { /* 数据目录不可写时仍尝试写日志。 */ }
  try {
    const logs = join(dataDir, "logs");
    mkdirSync(logs, { recursive: true, mode: 0o700 });
    const fd = openSync(join(logs, "hub.log"), constants.O_WRONLY | constants.O_APPEND | constants.O_CREAT | constants.O_NOFOLLOW, 0o600);
    try { writeFileSync(fd, diagnostic); } finally { closeSync(fd); }
  } catch { process.stderr.write(diagnostic); }
}

async function serve(): Promise<void> {
  const dataDir = dataDirOf();
  let db: Database | undefined;
  let stopLogs: (() => void) | undefined;
  let failure: StartupCode = "unknown";
  try {
    const [{ loadConfig }, { HubDB }, { startServer }, { startLogRetention }] = await Promise.all([
      import("./config.ts"), import("./db.ts"), import("./server.ts"), import("./log-retention.ts"),
    ]);
    const config = loadConfig();
    failure = "db_open_failed";
    const database = db = new HubDB(join(config.dataDir, "history.db"), config.dbKey);
    // 中枢单线程，同步等锁会阻塞所有请求，因此迁移完成后只短暂等锁。
    database.db.pragma("busy_timeout=300");
    failure = "unknown";
    stopLogs = startLogRetention(dataDir);
    const cleanup = () => { stopLogs?.(); database.close(); };
    let stopping = false;
    const stop = async () => {
      if (stopping) return;
      stopping = true;
      await server.stop(true);
      cleanup();
      process.removeListener("exit", cleanup);
      process.exit(0);
    };
    // 改端口后退出，launchd 的 KeepAlive 用 hub.json 里的新端口重新拉起。
    const restart = () => { console.log("端口已改，中枢退出以便用新端口重启"); void stop(); };
    const server = startServer({ db: database, token: config.token, agentToken: config.agentToken, port: config.port, settings: { dataDir, restart } });
    try { rmSync(startupFile(dataDir), { force: true }); }
    catch { console.error(JSON.stringify({ code: "startup_marker_remove_failed" })); }
    console.log(`Hub 已启动：http://127.0.0.1:${server.port}`);
    process.once("exit", cleanup);
    process.once("SIGINT", stop);
    process.once("SIGTERM", stop);
  } catch (error) {
    const code = errorCode(error);
    if (code === "db_key_missing" || code === "db_key_unreadable" || code === "db_migration_failed") failure = code;
    else if (code === "EADDRINUSE") failure = "port_in_use";
    reportStartupFailure(dataDir, failure);
    stopLogs?.();
    db?.close();
    process.exitCode = 1;
  }
}

export async function main(argv = process.argv.slice(2)): Promise<void> {
  const [command, name] = argv;
  if (command === "serve") return serve();
  // Agent 侧薄进程不能加载数据库、提炼或模型模块。
  if (command === "mcp" || command === "hook") {
    const { runAgentCommand } = await import("./agent-cli/index.ts");
    await runAgentCommand(argv);
    return;
  }
  if (command === "agents") {
    const { runAgents } = await import("./agents-install.ts");
    try { runAgents(argv.slice(1)); }
    catch (error) { console.error(error instanceof Error ? error.message : "Agent 注册失败"); process.exitCode = 1; }
    return;
  }
  if (command === "plugins") {
    const { pluginCLI } = await import("./plugin-manager.ts");
    await pluginCLI(); return;
  }
  if (command === "plugin-run") {
    const [{ PluginManager, pluginSource }, { runPlugin }, { dataDirOf }] = await Promise.all([import("./plugin-manager.ts"), import("./run-plugin.ts"), import("./hub-json.ts")]);
    if (!name || argv[2] !== "--hub" || !argv[3]) throw new Error("插件运行参数无效");
    const dataDir = dataDirOf(), manager = new PluginManager(dataDir), plugin = manager.installed(name);
    const code = join(manager.path(name), "code");
    const summary = await runPlugin({ name, dataDir, hub: argv[3], allowedSource: pluginSource(name),
      sandbox: { code, manifest: plugin.manifest, values: plugin.values },
      command: [process.execPath, "--no-install", "--no-env-file", join(code, plugin.manifest.entry), ...argv.slice(4)], cwd: code,
      env: { PATH: process.env.PATH, HOME: homedir(), TMPDIR: process.env.TMPDIR, RA_PLUGIN_CONFIG: JSON.stringify(plugin.values) } });
    console.log(JSON.stringify(summary));
    if (summary.exitCode !== 0 || summary.rejected || summary.protocolErrors || summary.releaseErrors) process.exitCode = 1;
    return;
  }
  if (command === "audio") {
    // 一次性整理旧版采集端拆碎的说话人，见 AudioStore.consolidateAll。
    if (name !== "consolidate" || argv.length !== 2) throw new Error("用法：bun hub/src/cli.ts audio consolidate");
    const [{ loadConfig }, { HubDB }, { AudioStore }] = await Promise.all([import("./config.ts"), import("./db.ts"), import("./audio.ts")]);
    const config = loadConfig();
    const db = new HubDB(join(config.dataDir, "history.db"), config.dbKey);
    try { console.log(JSON.stringify(new AudioStore(db).consolidateAll())); } finally { db.close(); }
    return;
  }
  if (command === "setup") {
    const app = argv[argv.indexOf("--app") + 1];
    const flags = argv.slice(1).filter((a, i, all) => a !== "--app" && all[i - 1] !== "--app");
    if (!argv.includes("--app") || !app || flags.some(f => !["--install", "--no-distill"].includes(f))) throw new Error("用法：bun hub/src/cli.ts setup --app <Tacit.app> [--install] [--no-distill]");
    const { setup, SetupError } = await import("./setup.ts");
    try {
      await setup({ app, install: flags.includes("--install"), distill: flags.includes("--no-distill") ? false : flags.includes("--install") ? true : undefined });
    } catch (error) {
      if (!(error instanceof SetupError)) throw error;
      console.error(error.message);
      process.exitCode = 1;
    }
    return;
  }
  if (command === "audio-models") {
    if (argv.length !== 1) throw new Error("用法：bun hub/src/cli.ts audio-models");
    const [{ ensureAudioModels }, { dataDirOf }] = await Promise.all([import("./audio-models.ts"), import("./hub-json.ts")]);
    await ensureAudioModels(join(dataDirOf(), "models"), { log: m => console.log(m) });
    return;
  }
  if (command === "keys") {
    if (name !== "export" || argv.length !== 2) throw new Error("用法：bun hub/src/cli.ts keys export");
    const { exportKeys } = await import("./keys.ts");
    const { text, missing } = exportKeys();
    console.log(text);
    if (missing.length) { console.error(`没有导出：${missing.join("、")}密钥`); process.exitCode = 1; }
    return;
  }
  const { loadConfig } = await import("./config.ts");
  const { HubDB } = await import("./db.ts");
  const { runPlugin } = await import("./run-plugin.ts");
  const { runDistill, sliceStep, backfillRange, startOfDay } = await import("./distill/run.ts");
  const { localDayStart } = await import("./distill/requests.ts");
  const { DistillStore } = await import("./distill/store.ts");
  const { createLLM } = await import("./llm/index.ts");
  const { RuntimeLog } = await import("./runtime-log.ts");
  const separator = argv.indexOf("--");
  if (command === "init") {
    // 安装时在前台创建（或读取）钥匙串里的数据库密钥并试开一次数据库，失败当场可见。
    const config = loadConfig();
    new HubDB(join(config.dataDir, "history.db"), config.dbKey).close();
    console.log(config.dataDir);
    return;
  }
  if (command === "open") {
    const { dataDirOf, resolvePort } = await import("./hub-json.ts");
    const dataDir = dataDirOf();
    const { port } = resolvePort(process.env, dataDir);
    if (port < 1) throw new Error("RA_PORT 必须是 1–65535 的整数");
    const token = readFileSync(join(dataDir, "token"), "utf8").trim();
    if (!token) throw new Error("本地 token 文件为空");
    const url = `http://127.0.0.1:${port}/#token=${encodeURIComponent(token)}`;
    if (argv.includes("--print")) console.log(url);
    else {
      const opened = spawnSync("open", [url]);
      if (opened.status !== 0) throw new Error("无法打开浏览器");
    }
    return;
  }
  if (command === "distill") {
    const flags: string[] = [];
    let range: { from: string; to: string } | undefined;
    for (let i = 1; i < argv.length; i++) {
      const a = argv[i]!;
      if (a === "--from" || a === "--to") {
        const v = argv[++i];
        if (!v || localDayStart(v) === null) throw new Error("--from/--to 必须是 YYYY-MM-DD");
        range ??= { from: "", to: "" };
        range[a === "--from" ? "from" : "to"] = v;
      } else if (["--once", "--backfill", "--slice-only"].includes(a)) flags.push(a);
      else throw new Error("提炼参数无效");
    }
    // --from/--to 只配合 --backfill：按范围重复整理，不看 backfill_done。
    if (range && (!range.from || !range.to || range.from > range.to || !flags.includes("--backfill"))) throw new Error("--from/--to 需要同时给出、from 不晚于 to，并配合 --backfill");
    const config = loadConfig();
    const db = new HubDB(join(config.dataDir, "history.db"), config.dbKey);
    // 回滚日志模式下 hub 连续写入时，等锁 5 秒常常轮不上；提炼是后台进程，等久一点无妨。
    db.db.pragma("busy_timeout=30000");
    // --slice-only：只做切片和规则归属，不调用模型（排查和测试用）。
    if (flags.includes("--slice-only")) {
      try {
        const out: Record<string, unknown> = {};
        if (range) out.backfill = backfillRange(db, range.from, range.to, { enabledDefault: startOfDay(Date.now()) });
        Object.assign(out, sliceStep(db, !range && flags.includes("--backfill")));
        console.log(JSON.stringify(out));
      } finally { db.close(); }
      return;
    }
    const store = new DistillStore(db);
    const llm = createLLM({ dataDir: config.dataDir, journal: new RuntimeLog(db), recordUsage: row => store.writeUsage({ ...row, input_tokens: row.input_tokens ?? undefined, output_tokens: row.output_tokens ?? undefined, error: row.error ?? undefined }) });
    try { await runDistill({ db, llm, once: flags.includes("--once"), backfill: flags.includes("--backfill"), range }); }
    finally { db.close(); }
    return;
  }
  if (command !== "run-plugin") throw new Error("用法：bun hub/src/cli.ts serve | init | open [--print] | keys export | audio consolidate | distill [--once] [--backfill [--from YYYY-MM-DD --to YYYY-MM-DD]] [--slice-only] | run-plugin <name> [--hub <url>] -- <插件命令...>");
  if (command === "run-plugin" && (!name || separator < 2 || !argv[separator + 1])) throw new Error("用法：run-plugin <name> -- <插件命令...>");
  if (command === "run-plugin") {
    let hub: string | undefined, tokenFile: string | undefined;
    for (let i = 2; i < separator; i += 2) {
      const flag = argv[i], value = argv[i + 1];
      if (!value || i + 1 >= separator) throw new Error("参数缺少值");
      if (flag === "--hub") hub = value;
      else if (flag === "--token-file") tokenFile = value;
      else throw new Error("未知参数");
    }
    if (hub) {
      const dataDir = process.env.RA_DATA_DIR ?? join(homedir(), "Library/Application Support/record-anything");
      const summary = await runPlugin({ hub, tokenFile, dataDir, name: name!, command: argv.slice(separator + 1) });
      console.log(JSON.stringify(summary));
      if (summary.exitCode !== 0 || summary.rejected || summary.protocolErrors || summary.releaseErrors) process.exitCode = 1;
      return;
    }
    if (tokenFile) throw new Error("--token-file 需要 --hub");
  }
  const config = loadConfig();
  const db = new HubDB(join(config.dataDir, "history.db"), config.dbKey);
  try {
    const summary = await runPlugin({ db, dataDir: config.dataDir, name: name!, command: argv.slice(separator + 1), report: result => console.log(JSON.stringify(result)) });
    if (summary.exitCode !== 0 || summary.rejected || summary.protocolErrors || summary.releaseErrors) process.exitCode = 1;
  } finally { db.close(); }
}

if (import.meta.main) main().catch(error => {
  if (["run-plugin", "plugin-run"].includes(process.argv[2] ?? "")) {
    const code = (error as { code?: string })?.code;
    console.log(JSON.stringify({ failure: error?.name === "SandboxUnavailableError" ? "sandbox" : code === "ENOENT" ? "missing_file" : code === "EACCES" || code === "EPERM" ? "permission" : "process" }));
  }
  // 模型下载保留原有命令行输出。
  if (process.argv[2] === "audio-models") console.error(error instanceof Error ? error.message : String(error));
  else {
    console.error("Hub 执行失败，请检查命令、数据目录、密钥及插件状态。");
    console.error(cliErrorDetail(error));
  }
  process.exitCode = 1;
});
