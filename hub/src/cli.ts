import { cliLanguage, cliText } from "./agent-cli/locale.ts";
import { homedir } from "node:os";
import { join } from "node:path";
import { closeSync, constants, mkdirSync, openSync, readFileSync, renameSync, rmSync, writeFileSync } from "node:fs";
import { randomUUID } from "node:crypto";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import { applyTimezone, dataDirOf, hubModeOf, timezoneStatus } from "./hub-json.ts";
import { httpOrigin } from "./devices/http-origin.ts";
import type { HubDB as Database } from "./db.ts";

/** 错误消息可能夹带路径、凭据或记录正文。 */
export function cliErrorDetail(error: unknown): string {
  const value = error as { name?: unknown; code?: unknown } | null;
  const label = (input: unknown, fallback: string) => typeof input === "string" && /^[A-Za-z][A-Za-z0-9_]{0,63}$/.test(input) ? input : fallback;
  const name = label(value?.name, "Error");
  // 密钥存放层的错误带固定的 reason 类别（secrets/errors.ts），帮运维区分根密钥缺失、权限、位置等。
  const reason = (error as { reason?: unknown } | null)?.reason;
  return `${name} (${label(value?.code, "UNKNOWN")}${typeof reason === "string" && /^[a-z_]{1,48}$/.test(reason) ? `: ${reason}` : ""})`;
}

const startupMessages = {
  db_key_missing: cliText("钥匙串里找不到数据库密钥，但已有记录库。请用之前导出的密钥备份恢复，不要重装。", "An existing database is missing its key. Restore the key from your backup."),
  db_key_unreadable: cliText("无法读取或保存钥匙串里的数据库密钥。请检查钥匙串是否解锁。", "The database key could not be read or saved. Check that the Keychain is unlocked."),
  db_open_failed: cliText("无法打开记录库，或记录库完整性检查失败。请确认数据库密钥与记录库匹配。", "The database could not be opened or failed its integrity check. Check that the key matches the database."),
  db_migration_failed: cliText("记录库升级失败。请保留现有记录库和迁移备份。", "The database upgrade failed. Keep the current database and its migration backup."),
  port_in_use: cliText("后台服务的端口已被占用。请在设置 › 后台与连接里更换端口。", "The background service port is in use. Change it in Settings → Background & connection."),
  unknown: cliText("后台服务没能启动。点「重新准备」再试。仍然失败时，可在设置里复制诊断信息。", "The background service could not start. Click Prepare again. If it still fails, copy diagnostics from Settings."),
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

function parseLocalStatusPort(args: string[]): number | undefined {
  if (args.length === 0) return undefined;
  if (args.length === 2 && args[0] === "--local-status-port") {
    const raw = args[1] ?? "";
    const port = Number(raw);
    if (!raw.trim() || !Number.isInteger(port) || port < 0 || port > 65535) {
      throw new Error(cliText("--local-status-port 必须是 0–65535 的整数", "--local-status-port must be an integer from 0 to 65535"));
    }
    return port;
  }
  throw new Error(cliText("用法：serve [--local-status-port <port>] | run [--local-status-port <port>]", "Usage: serve [--local-status-port <port>] | run [--local-status-port <port>]"));
}

async function serve(args: string[] = []): Promise<void> {
  const dataDir = dataDirOf();
  let db: Database | undefined;
  let stopLogs: (() => void) | undefined;
  let failure: StartupCode = "unknown";
  try {
    const localStatusPort = parseLocalStatusPort(args);
    applyTimezone(process.env, dataDir);
    (await import("./log-stamp.ts")).stampConsole();
    const [{ loadConfig }, { HubDB }, { startServer }, { startLogRetention }] = await Promise.all([
      import("./config.ts"), import("./db.ts"), import("./server.ts"), import("./log-retention.ts"),
    ]);
    const config = loadConfig();
    const tz = timezoneStatus({ mode: config.mode, dataDir: config.dataDir });
    if (tz.warning) process.stderr.write(`[warn] ${tz.warning}\n`);
    failure = "db_open_failed";
    const database = db = new HubDB(join(config.dataDir, "history.db"), config.dbKey);
    // 中枢单线程，同步等锁会阻塞所有请求，因此迁移完成后只短暂等锁。
    database.db.pragma("busy_timeout=300");
    failure = "unknown";
    stopLogs = startLogRetention(config.dataDir);
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
    const restart = () => { console.log(cliText("端口已改，中枢退出以便用新端口重启", "The port changed. The background service will restart on the new port.")); void stop(); };
    const server = startServer({
      db: database, token: config.token, agentToken: config.agentToken,
      port: config.port, lanPort: config.lanPort, mode: config.mode, localStatusPort,
      settings: { dataDir: config.dataDir, mode: config.mode, restart },
    });
    try { rmSync(startupFile(config.dataDir), { force: true }); }
    catch { console.error(JSON.stringify({ code: "startup_marker_remove_failed" })); }
    if (config.mode === "server") {
      console.log(cliText(
        `Hub 已启动（server 模式）：设备端口 0.0.0.0:${server.lanPort}${server.port !== null ? `，本地排障端口 http://127.0.0.1:${server.port}` : ""}`,
        `Tacit device service listening on 0.0.0.0:${server.lanPort}${server.port !== null ? `, local diagnostics at http://127.0.0.1:${server.port}` : ""}`,
      ));
    } else {
      console.log(cliText(`Hub 已启动：http://127.0.0.1:${server.port}`, `Tacit background service started at http://127.0.0.1:${server.port}`));
    }
    process.once("exit", cleanup);
    process.once("SIGINT", stop);
    process.once("SIGTERM", stop);
  } catch (error) {
    const code = errorCode(error);
    if (code === "db_key_missing" || code === "db_key_unreadable" || code === "db_migration_failed") failure = code;
    // 服务端 sealed-file：根密钥或 secrets.enc 不可用，沿用“密钥读不出来”这一类启动诊断（Mac 端诊断的类别表是固定的）。
    else if (code === "master_key_unreadable") failure = "db_key_unreadable";
    else if (code === "EADDRINUSE") failure = "port_in_use";
    reportStartupFailure(dataDir, failure);
    stopLogs?.();
    db?.close();
    process.exitCode = 1;
  }
}

const usage = () => cliText("用法：bun hub/src/cli.ts run | serve [--local-status-port <port>] | pair --role <collect|view|admin> [--relay <url>] [--address <origin>] | devices list|set-role|remove | init | open [--print] | keys export|import-db-key | audio consolidate | distill [--once] [--backfill [--from YYYY-MM-DD --to YYYY-MM-DD]] [--slice-only] | run-plugin <name> [--hub <url> | --transport stdio] [--device <id>] -- <插件命令...>", "Usage: bun hub/src/cli.ts run | serve [--local-status-port <port>] | pair --role <collect|view|admin> [--relay <url>] [--address <origin>] | devices list|set-role|remove | init | open [--print] | keys export|import-db-key | audio consolidate | distill [--once] [--backfill [--from YYYY-MM-DD --to YYYY-MM-DD]] [--slice-only] | run-plugin <name> [--hub <url> | --transport stdio] [--device <id>] -- <plugin command...>");

export async function main(argv = process.argv.slice(2)): Promise<void> {
  const [command, name] = argv;
  if (command === "--help" || command === "-h") { console.log(usage()); return; }
  if (command === "history-export") return (await import("./history-export.ts")).runHistoryExport(argv.slice(1));
  if (command === "history-reconcile") return (await import("./history-reconcile.ts")).historyReconcileCommand(argv.slice(1));
  if (command === "serve") return serve(argv.slice(1));
  if (command === "run") {
    const localStatusPort = parseLocalStatusPort(argv.slice(1));
    const dataDir = dataDirOf();
    applyTimezone(process.env, dataDir);
    const [{ loadConfig }, { HubDB }, { runSupervisor }] = await Promise.all([
      import("./config.ts"), import("./db.ts"), import("./supervisor.ts"),
    ]);
    // 启动前先做硬校验（根密钥、db-key、库完整性与迁移），避免根密钥缺失时进入崩溃重启死循环。
    const config = loadConfig();
    new HubDB(join(config.dataDir, "history.db"), config.dbKey).close();
    const entry = fileURLToPath(import.meta.url);
    const serveCmd = [process.execPath, entry, "serve", ...(localStatusPort !== undefined ? ["--local-status-port", String(localStatusPort)] : [])];
    const distillCmd = [process.execPath, entry, "distill"];
    await runSupervisor({ specs: [{ name: "serve", command: serveCmd }, { name: "distill", command: distillCmd }] });
    return;
  }
  if (command === "pair") {
    const usage = cliText("用法：bun hub/src/cli.ts pair --role <collect|view|admin> [--relay <url>] [--address <origin>]", "Usage: bun hub/src/cli.ts pair --role <collect|view|admin> [--relay <url>] [--address <origin>]");
    const flags = new Map<string, string>();
    for (let i = 1; i < argv.length; i += 2) {
      const flag = argv[i]!, value = argv[i + 1];
      if (!["--role", "--relay", "--address"].includes(flag) || flags.has(flag) || !value || value.startsWith("--")) {
        throw new Error(usage);
      }
      flags.set(flag, value);
    }
    const role = flags.get("--role"), relayUrl = flags.get("--relay"), address = flags.get("--address");
    if (!role) throw new Error(usage);
    if (address !== undefined && !httpOrigin(address)) {
      console.error(cliText("--address 必须是 http 或 https origin", "--address must be an HTTP or HTTPS origin"));
      process.exitCode = 1;
      return;
    }
    applyTimezone(process.env, dataDirOf());
    const [{ loadConfig }, { HubDB, InputError }, { DeviceService }, { WireError }] = await Promise.all([
      import("./config.ts"), import("./db.ts"), import("./devices/service.ts"), import("./devices/envelope.ts"),
    ]);
    const config = loadConfig();
    const db = new HubDB(join(config.dataDir, "history.db"), config.dbKey);
    const devices = new DeviceService(db, config.lanPort);
    try {
      const invite = await devices.createPairing({ role, relayUrl, address, openListener: false });
      console.log(invite.uri);
      process.stderr.write(cliText(
        `已创建 ${invite.role} 配对邀请，有效期至 ${invite.expires_at}（仅可使用一次）\n`,
        `Created a single-use ${invite.role} invite link. It expires at ${invite.expires_at}.\n`,
      ));
      // 容器里只看得到自己的网卡（如 172.17.0.x），设备按这个地址连不上。
      if (address === undefined && hubModeOf() === "server") {
        process.stderr.write(cliText("邀请里只有本机网卡地址；在容器里运行时，请加 --address http://<设备能访问的服务器地址>:<端口> 重新生成\n", "The invite contains only local network addresses. In a container, use --address http://<reachable-server-address>:<port> to generate a new invite.\n"));
      }
    } catch (error) {
      if (!(error instanceof WireError) && !(error instanceof InputError)) throw error;
      console.error(cliText(error.message, "Could not create the invite link. Check the role and relay settings."));
      process.exitCode = 1;
    } finally {
      await devices.stop(true);
      db.close();
    }
    return;
  }
  // Agent 侧薄进程不能加载数据库、提炼或模型模块。
  if (command === "mcp" || command === "hook") {
    const { runAgentCommand } = await import("./agent-cli/index.ts");
    await runAgentCommand(argv);
    return;
  }
  if (command === "agents") {
    const { runAgents } = await import("./agents-install.ts");
    try {
      await runAgents(argv.slice(1), { lang: cliLanguage() }, async () => {
        const { ensureAgentIdentity } = await import("./agent-cli/identity.ts");
        await ensureAgentIdentity();
      });
    }
    catch (error) { console.error(error instanceof Error ? error.message : cliText("Agent 注册失败", "AI tool registration failed")); process.exitCode = 1; }
    return;
  }
  if (command === "plugins") {
    const { pluginCLI } = await import("./plugin-manager.ts");
    await pluginCLI(); return;
  }
  if (command === "plugin-run") {
    const [{ PluginManager, pluginSource }, { runPlugin }, { dataDirOf }] = await Promise.all([import("./plugin-manager.ts"), import("./run-plugin.ts"), import("./hub-json.ts")]);
    if (!name) throw new Error(cliText("插件运行参数无效", "Invalid plugin arguments"));
    let hub: string | undefined, transport: "stdio" | undefined, device: string | undefined;
    let idx = 2;
    while (idx < argv.length) {
      const flag = argv[idx];
      if (flag === "--hub" || flag === "--transport" || flag === "--device") {
        const value = argv[idx + 1];
        if (!value) throw new Error(cliText("插件运行参数无效", "Invalid plugin arguments"));
        if (flag === "--hub") { if (hub !== undefined) throw new Error(cliText("插件运行参数无效", "Invalid plugin arguments")); hub = value; }
        else if (flag === "--transport") { if (transport !== undefined || value !== "stdio") throw new Error(cliText("插件运行参数无效", "Invalid plugin arguments")); transport = "stdio"; }
        else { if (device !== undefined) throw new Error(cliText("插件运行参数无效", "Invalid plugin arguments")); device = value; }
        idx += 2;
      } else break;
    }
    if (Boolean(hub) === Boolean(transport)) throw new Error(cliText("插件运行参数无效", "Invalid plugin arguments"));
    const dataDir = dataDirOf(), manager = new PluginManager(dataDir), plugin = manager.installed(name);
    const code = join(manager.path(name), "code");
    const summary = await runPlugin({ name, dataDir, hub, transport, device, allowedSource: pluginSource(name),
      sandbox: { code, manifest: plugin.manifest, values: plugin.values },
      command: [process.execPath, "--no-install", "--no-env-file", join(code, plugin.manifest.entry), ...argv.slice(idx)], cwd: code,
      env: { PATH: process.env.PATH, HOME: homedir(), TMPDIR: process.env.TMPDIR, RA_PLUGIN_CONFIG: JSON.stringify(plugin.values) } });
    console.log(JSON.stringify(summary));
    if (summary.exitCode !== 0 || summary.rejected || summary.protocolErrors || summary.releaseErrors) process.exitCode = 1;
    return;
  }
  if (command === "devices") {
    const [,, id, roleOrForce, forceFlag] = argv;
    const list = name === "list" && argv.length === 2;
    const setRole = name === "set-role" && (argv.length === 4 || argv.length === 5 && forceFlag === "--force");
    const remove = name === "remove" && (argv.length === 3 || argv.length === 4 && roleOrForce === "--force");
    if (!list && !setRole && !remove) {
      throw new Error(cliText("用法：devices list | devices set-role <device_id> <role> [--force] | devices remove <device_id> [--force]", "Usage: devices list | devices set-role <device_id> <role> [--force] | devices remove <device_id> [--force]"));
    }
    const [{ loadConfig }, { HubDB }, { deviceList, updateDeviceRole, removeDevice }, { WireError }] = await Promise.all([
      import("./config.ts"), import("./db.ts"), import("./devices/store.ts"), import("./devices/envelope.ts"),
    ]);
    const config = loadConfig();
    const db = new HubDB(join(config.dataDir, "history.db"), config.dbKey);
    try {
      const result = list ? deviceList(db) : setRole ? updateDeviceRole(db.db, id, roleOrForce, { force: forceFlag === "--force" })
        : removeDevice(db.db, id, { force: roleOrForce === "--force" });
      console.log(JSON.stringify(result));
    } catch (error) {
      if (!(error instanceof WireError)) throw error;
      console.error(cliText(error.message, "Could not update the device. Check the device ID and role."));
      process.exitCode = 1;
    } finally { db.close(); }
    return;
  }
  if (command === "projection" && name === "reset" && argv.length === 2) {
    const [{ loadConfig }, { HubDB }, { resetProjection, projectionHead }] = await Promise.all([
      import("./config.ts"), import("./db.ts"), import("./devices/projection-store.ts"),
    ]);
    const config = loadConfig();
    const db = new HubDB(join(config.dataDir, "history.db"), config.dbKey);
    try {
      // A restored file may be older than the epoch already cached by a device.
      resetProjection(db.db, Date.now());
      console.log(JSON.stringify({ epoch: projectionHead(db.db).epoch }));
    } finally { db.close(); }
    return;
  }
  if (command === "audio") {
    // 一次性整理旧版采集端拆碎的说话人，见 AudioStore.consolidateAll。
    if (name !== "consolidate" || argv.length !== 2) throw new Error(cliText("用法：bun hub/src/cli.ts audio consolidate", "Usage: bun hub/src/cli.ts audio consolidate"));
    const [{ loadConfig }, { HubDB }, { AudioStore }] = await Promise.all([import("./config.ts"), import("./db.ts"), import("./audio.ts")]);
    const config = loadConfig();
    const db = new HubDB(join(config.dataDir, "history.db"), config.dbKey);
    try { console.log(JSON.stringify(new AudioStore(db).consolidateAll())); } finally { db.close(); }
    return;
  }
  if (command === "setup") {
    let SetupError: typeof import("./setup.ts").SetupError | undefined;
    try {
      const runtime = await import("./setup.ts");
      SetupError = runtime.SetupError;
      const app = argv[argv.indexOf("--app") + 1];
      const flags = argv.slice(1).filter((a, i, all) => a !== "--app" && all[i - 1] !== "--app");
      if (!argv.includes("--app") || !app || flags.some(f => !["--install", "--no-distill", "--retry"].includes(f))) {
        console.error(cliText("用法：bun hub/src/cli.ts setup --app <Tacit.app> [--install] [--no-distill]", "Usage: bun hub/src/cli.ts setup --app <Tacit.app> [--install] [--no-distill]"));
        throw new Error();
      }
      await runtime.setup({ app, lang: cliLanguage(), retry: flags.includes("--retry"), install: flags.includes("--install"), distill: flags.includes("--no-distill") ? false : flags.includes("--install") ? true : undefined });
    } catch (error) {
      if (SetupError && error instanceof SetupError) {
        console.error(error.message);
        console.error(`setup_error:${error.reason}`);
      } else {
        console.error(startupMessages.unknown);
        console.error(cliErrorDetail(error));
        console.error("setup_error:unknown");
      }
      process.exitCode = 1;
    }
    return;
  }
  if (command === "audio-models") {
    if (argv.length !== 1) throw new Error(cliText("用法：bun hub/src/cli.ts audio-models", "Usage: bun hub/src/cli.ts audio-models"));
    const [{ ensureAudioModels }, { dataDirOf }] = await Promise.all([import("./audio-models.ts"), import("./hub-json.ts")]);
    await ensureAudioModels(join(dataDirOf(), "models"), { log: m => console.log(m) });
    return;
  }
  if (command === "keys") {
    if (name === "export" && argv.length === 2) {
      const { exportKeysForBackend } = await import("./keys.ts");
      const { text, missing } = exportKeysForBackend();
      console.log(text);
      if (missing.length) { console.error(cliText(`没有导出：${missing.join("、")}密钥`, "Some keys could not be exported.")); process.exitCode = 1; }
      return;
    }
    if (name === "import-db-key" && argv.length === 2) {
      const { importDbKey } = await import("./keys.ts");
      const raw = await Bun.stdin.text();
      try {
        const result = importDbKey(raw);
        const target = result.backend === "keychain" ? cliText("钥匙串", "the Keychain") : "secrets.enc";
        console.log(result.status === "unchanged"
          ? cliText(`数据库密钥已在 ${target} 中且一致，无需修改。`, `The matching database key is already in ${target}.`)
          : cliText(`已导入数据库密钥到 ${target}。`, `Imported the database key into ${target}.`));
      } catch (error) {
        const code = errorCode(error);
        if (code === "invalid_key" || code === "db_key_mismatch" || code === "db_key_exists") {
          console.error(cliText((error as Error).message, {
            invalid_key: "The database key must be 32–128 hexadecimal characters.",
            db_key_mismatch: "The supplied key could not open the existing history.db. Import stopped.",
            db_key_exists: "A different database key already exists. Import stopped to preserve your records.",
          }[code]));
          process.exitCode = 1;
          return;
        }
        throw error;
      }
      return;
    }
    throw new Error(cliText("用法：bun hub/src/cli.ts keys export | keys import-db-key", "Usage: bun hub/src/cli.ts keys export | keys import-db-key"));
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
    if (port < 1) throw new Error(cliText("RA_PORT 必须是 1–65535 的整数", "RA_PORT must be an integer from 1 to 65535"));
    const token = readFileSync(join(dataDir, "token"), "utf8").trim();
    if (!token) throw new Error(cliText("本地 token 文件为空", "The local token file is empty"));
    const url = `http://127.0.0.1:${port}/#token=${encodeURIComponent(token)}`;
    if (argv.includes("--print")) console.log(url);
    else {
      const opened = spawnSync("open", [url]);
      if (opened.status !== 0) throw new Error(cliText("无法打开浏览器", "Unable to open the browser"));
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
        if (!v || localDayStart(v) === null) throw new Error(cliText("--from/--to 必须是 YYYY-MM-DD", "--from and --to must use YYYY-MM-DD"));
        range ??= { from: "", to: "" };
        range[a === "--from" ? "from" : "to"] = v;
      } else if (["--once", "--backfill", "--slice-only"].includes(a)) flags.push(a);
      else throw new Error(cliText("提炼参数无效", "Invalid summarization arguments"));
    }
    // --from/--to 只配合 --backfill：按范围重复整理，不看 backfill_done。
    if (range && (!range.from || !range.to || range.from > range.to || !flags.includes("--backfill"))) throw new Error(cliText("--from/--to 需要同时给出、from 不晚于 to，并配合 --backfill", "Use --from and --to together with --backfill, with --from on or before --to"));
    applyTimezone(process.env, dataDirOf());
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
    // 常驻整理进程的错误行（如 {"step":"day","category":…}）也带上时间，诊断信息才能按时间挑出来。
    if (!flags.includes("--once")) (await import("./log-stamp.ts")).stampConsole();
    const store = new DistillStore(db);
    const llm = createLLM({ dataDir: config.dataDir, mode: config.mode, journal: new RuntimeLog(db), recordUsage: row => store.writeUsage({ ...row, input_tokens: row.input_tokens ?? undefined, output_tokens: row.output_tokens ?? undefined, error: row.error ?? undefined }) });
    try { await runDistill({ db, llm, once: flags.includes("--once"), backfill: flags.includes("--backfill"), range, dataDir: config.dataDir, mode: config.mode }); }
    finally { db.close(); }
    return;
  }
  if (command !== "run-plugin") throw new Error(usage());
  if (command === "run-plugin" && (!name || separator < 2 || !argv[separator + 1])) throw new Error(cliText("用法：run-plugin <name> -- <插件命令...>", "Usage: run-plugin <name> -- <plugin command...>"));
  let runPluginDevice: string | undefined;
  if (command === "run-plugin") {
    let hub: string | undefined, tokenFile: string | undefined, transport: "stdio" | undefined;
    for (let i = 2; i < separator; i += 2) {
      const flag = argv[i], value = argv[i + 1];
      if (!value || i + 1 >= separator) throw new Error(cliText("参数缺少值", "Missing argument value"));
      if (flag === "--hub") hub = value;
      else if (flag === "--token-file") tokenFile = value;
      else if (flag === "--transport") {
        if (value !== "stdio") throw new Error(cliText("--transport 仅支持 stdio", "--transport only supports stdio"));
        transport = "stdio";
      } else if (flag === "--device") runPluginDevice = value;
      else throw new Error(cliText("未知参数", "Unknown argument"));
    }
    if (transport && (hub || tokenFile)) throw new Error(cliText("--transport stdio 不能与 --hub 或 --token-file 同用", "--transport stdio cannot be combined with --hub or --token-file"));
    if (hub || transport) {
      const dataDir = process.env.RA_DATA_DIR ?? join(homedir(), "Library/Application Support/record-anything");
      const summary = await runPlugin({ hub, tokenFile, transport, device: runPluginDevice, dataDir, name: name!, command: argv.slice(separator + 1) });
      console.log(JSON.stringify(summary));
      if (summary.exitCode !== 0 || summary.rejected || summary.protocolErrors || summary.releaseErrors) process.exitCode = 1;
      return;
    }
    if (tokenFile) throw new Error(cliText("--token-file 需要 --hub", "--token-file requires --hub"));
  }
  const config = loadConfig();
  const db = new HubDB(join(config.dataDir, "history.db"), config.dbKey);
  try {
    const summary = await runPlugin({ db, device: runPluginDevice, dataDir: config.dataDir, name: name!, command: argv.slice(separator + 1), report: result => console.log(JSON.stringify(result)) });
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
    console.error(cliText("Hub 执行失败，请检查命令、数据目录、密钥及插件状态。", "The Tacit command failed. Check the command, data directory, keys, and plugin status."));
    console.error(cliErrorDetail(error));
  }
  process.exitCode = 1;
});
