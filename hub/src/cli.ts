import { runDistill, sliceStep } from "./distill/run.ts";
import { DistillStore } from "./distill/store.ts";
import { createLLM } from "./llm/index.ts";
import { homedir } from "node:os";
import { join } from "node:path";
import { readFileSync } from "node:fs";
import { spawnSync } from "node:child_process";
import { loadConfig } from "./config.ts";
import { HubDB } from "./db.ts";
import { startServer } from "./server.ts";
import { runPlugin } from "./run-plugin.ts";

export async function main(argv = process.argv.slice(2)): Promise<void> {
  const [command, name] = argv;
  const separator = argv.indexOf("--");
  if (command === "init") {
    // 安装时在前台创建（或读取）钥匙串里的数据库密钥并试开一次数据库，失败当场可见。
    const config = loadConfig();
    new HubDB(join(config.dataDir, "history.db"), config.dbKey).close();
    console.log(config.dataDir);
    return;
  }
  if (command === "open") {
    const port = Number(process.env.RA_PORT ?? 47823);
    if (!Number.isInteger(port) || port < 1 || port > 65535) throw new Error("RA_PORT 必须是 1–65535 的整数");
    const dataDir = process.env.RA_DATA_DIR ?? join(homedir(), "Library/Application Support/record-anything");
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
    if (argv.slice(1).some(a => !["--once", "--backfill", "--slice-only"].includes(a))) throw new Error("提炼参数无效");
    const config = loadConfig();
    const db = new HubDB(join(config.dataDir, "history.db"), config.dbKey);
    // --slice-only：只做切片和规则归属，不调用模型（排查和测试用）。
    if (argv.includes("--slice-only")) { try { console.log(JSON.stringify(sliceStep(db, argv.includes("--backfill")))); } finally { db.close(); } return; }
    const store = new DistillStore(db);
    const llm = createLLM({ dataDir: config.dataDir, recordUsage: row => store.writeUsage({ ...row, input_tokens: row.input_tokens ?? undefined, output_tokens: row.output_tokens ?? undefined, error: row.error ?? undefined }) });
    try { await runDistill({ db, llm, once: argv.includes("--once"), backfill: argv.includes("--backfill") }); }
    finally { db.close(); }
    return;
  }
  if (command !== "serve" && command !== "run-plugin") throw new Error("用法：bun hub/src/cli.ts serve | init | open [--print] | distill [--once] [--backfill] [--slice-only] | run-plugin <name> [--hub <url>] -- <插件命令...>");
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
  if (command === "serve") {
    try {
      const server = startServer({ db, token: config.token, port: config.port });
      console.log(`Hub 已启动：http://127.0.0.1:${server.port}`);
      const stop = async () => { await server.stop(true); db.close(); process.exit(0); };
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

if (import.meta.main) main().catch(() => {
  console.error("Hub 执行失败，请检查命令、数据目录、密钥及插件状态。");
  process.exitCode = 1;
});
