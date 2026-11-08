import { join } from "node:path";
import { loadConfig } from "./config.ts";
import { HubDB } from "./db.ts";
import { startServer } from "./server.ts";
import { runPlugin } from "./run-plugin.ts";

export async function main(argv = process.argv.slice(2)): Promise<void> {
  const [command, name] = argv;
  const separator = argv.indexOf("--");
  if (command !== "serve" && command !== "run-plugin") throw new Error("用法：bun hub/src/cli.ts serve | run-plugin <name> -- <插件命令...>");
  if (command === "run-plugin" && (!name || separator !== 2 || !argv[3])) throw new Error("用法：run-plugin <name> -- <插件命令...>");
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
      if (summary.exitCode !== 0 || summary.rejected || summary.protocolErrors) process.exitCode = 1;
    } finally { db.close(); }
  }
}

if (import.meta.main) main().catch(() => {
  console.error("Hub 执行失败，请检查命令、数据目录、密钥及插件状态。");
  process.exitCode = 1;
});
