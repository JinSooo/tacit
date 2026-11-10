import { homedir } from "node:os";
import { join } from "node:path";
import { readFileSync } from "node:fs";
import { spawnSync } from "node:child_process";
import { redactString } from "./redact.ts";

const databaseFailures = new WeakMap<object, string>();
/** 只有打开数据库时的消息可展示；运行期错误可能夹带记录正文。 */
export function cliErrorDetail(error: unknown): string {
  const value = error as { name?: unknown; code?: unknown } | null;
  const label = (input: unknown, fallback: string) => typeof input === "string" && /^[A-Za-z][A-Za-z0-9_]{0,63}$/.test(input) ? input : fallback;
  const name = label(value?.name, "Error");
  if (error && typeof error === "object" && databaseFailures.has(error)) return `${name}: ${databaseFailures.get(error)}`;
  return `${name} (${label(value?.code, "UNKNOWN")})`;
}

export async function main(argv = process.argv.slice(2)): Promise<void> {
  const [command, name] = argv;
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
  const { startServer } = await import("./server.ts");
  const { runPlugin } = await import("./run-plugin.ts");
  const { runDistill, sliceStep, backfillRange, startOfDay } = await import("./distill/run.ts");
  const { localDayStart } = await import("./distill/requests.ts");
  const { DistillStore } = await import("./distill/store.ts");
  const { createLLM } = await import("./llm/index.ts");
  const openDatabase = (file: string, key: string, token: string) => {
    try { return new HubDB(file, key); }
    catch (error) {
      if (error instanceof Error) {
        let message = error.message;
        for (const secret of [key, token, process.env.RA_DB_KEY, process.env.RA_TOKEN]) if (secret) message = message.replaceAll(secret, "[已脱敏]");
        databaseFailures.set(error, redactString(message).text.replace(/[\r\n]/g, " "));
      }
      throw error;
    }
  };
  const separator = argv.indexOf("--");
  if (command === "init") {
    // 安装时在前台创建（或读取）钥匙串里的数据库密钥并试开一次数据库，失败当场可见。
    const config = loadConfig();
    openDatabase(join(config.dataDir, "history.db"), config.dbKey, config.token).close();
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
    const db = openDatabase(join(config.dataDir, "history.db"), config.dbKey, config.token);
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
    const llm = createLLM({ dataDir: config.dataDir, recordUsage: row => store.writeUsage({ ...row, input_tokens: row.input_tokens ?? undefined, output_tokens: row.output_tokens ?? undefined, error: row.error ?? undefined }) });
    try { await runDistill({ db, llm, once: flags.includes("--once"), backfill: flags.includes("--backfill"), range }); }
    finally { db.close(); }
    return;
  }
  if (command !== "serve" && command !== "run-plugin") throw new Error("用法：bun hub/src/cli.ts serve | init | open [--print] | keys export | distill [--once] [--backfill [--from YYYY-MM-DD --to YYYY-MM-DD]] [--slice-only] | run-plugin <name> [--hub <url>] -- <插件命令...>");
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
  const db = openDatabase(join(config.dataDir, "history.db"), config.dbKey, config.token);
  if (command === "serve") {
    try {
      let stopping = false;
      const stop = async () => { if (stopping) return; stopping = true; await server.stop(true); db.close(); process.exit(0); };
      // 改端口后退出，launchd 的 KeepAlive 用 hub.json 里的新端口重新拉起。
      const restart = () => { console.log("端口已改，中枢退出以便用新端口重启"); void stop(); };
      const server = startServer({ db, token: config.token, port: config.port, settings: { dataDir: config.dataDir, restart } });
      console.log(`Hub 已启动：http://127.0.0.1:${server.port}`);
      process.once("SIGINT", stop);
      process.once("SIGTERM", stop);
    } catch (e) { db.close(); throw e; }
  } else {
    try {
      const summary = await runPlugin({ db, dataDir: config.dataDir, name: name!, command: argv.slice(separator + 1), report: result => console.log(JSON.stringify(result)) });
      if (summary.exitCode !== 0 || summary.rejected || summary.protocolErrors || summary.releaseErrors) process.exitCode = 1;
    } finally { db.close(); }
  }
}

if (import.meta.main) main().catch(error => {
  console.error("Hub 执行失败，请检查命令、数据目录、密钥及插件状态。");
  console.error(cliErrorDetail(error));
  process.exitCode = 1;
});
