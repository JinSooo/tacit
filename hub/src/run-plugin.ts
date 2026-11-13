import { logFailure } from "./diagnostics.ts";
import { mkdirSync, renameSync, rmSync, writeFileSync, readFileSync, realpathSync, statSync, unlinkSync } from "node:fs";
import { isAbsolute, join, relative, sep } from "node:path";
import { randomBytes } from "node:crypto";
import { spawn } from "node:child_process";
import { HubDB, type IngestResult } from "./db.ts";
import { pluginRecordPolicy } from "./plugin-policy.ts";
import { jsonLines } from "./jsonl.ts";

/** 中枢返回 503（库忙）时每次重试前等待的毫秒数，合计约 7.75 秒。 */
const BUSY_RETRY_MS = [250, 500, 1000, 2000, 4000];

export interface PluginSummary {
  failure?: string;
  accepted: number; duplicates: number; rejected: number; exitCode: number;
  filtered: number; stateWritten: boolean; protocolErrors: number; released: number; releaseErrors: number;
}

export async function runPlugin(options: {
  db?: HubDB; hub?: string; tokenFile?: string; dataDir: string; name: string; command: string[]; device?: string;
  allowedSource?: string; env?: NodeJS.ProcessEnv; cwd?: string;
  report?: (summary: PluginSummary) => void;
}): Promise<PluginSummary> {
  if (!/^[a-z0-9][a-z0-9_-]{0,62}$/.test(options.name)) throw new Error("插件名称无效");
  if (!options.command.length) throw new Error("缺少插件命令");
  const device = options.device ?? "mac";
  if (!/^[a-z0-9][a-z0-9-]{0,62}$/.test(device)) throw new Error("设备名无效");
  if (!options.hub && !options.db) throw new Error("缺少数据库或 hub 地址");
  const token = options.hub ? readFileSync(options.tokenFile ?? join(options.dataDir, "token"), "utf8").trim() : "";
  if (options.hub && !token) throw new Error("本地 token 文件为空");
  const ingest = async (records: unknown[]): Promise<IngestResult> => {
    if (!options.hub) return options.db!.ingest(records);
    const body = JSON.stringify({ device, records });
    let response: Response;
    // 503 是中枢撞上写锁、不等锁直接返回；runner 是独立进程，在这里退避重试不会卡住中枢，免得整次运行白跑。
    for (let attempt = 0; ; attempt++) {
      response = await fetch(new URL("/v1/ingest", options.hub), {
        method: "POST", headers: { authorization: `Bearer ${token}`, "content-type": "application/json" },
        body, signal: AbortSignal.timeout(30_000), redirect: "error",
      });
      if (response.status !== 503 || attempt === BUSY_RETRY_MS.length) break;
      await response.body?.cancel();
      await Bun.sleep(BUSY_RETRY_MS[attempt]!);
    }
    if (!response.ok) throw new Error(response.status === 503 ? "Hub 数据库忙，稍后重试" : "Hub 接收失败");
    const result = await response.json() as IngestResult;
    if (!result || !Number.isSafeInteger(result.accepted) || result.accepted < 0
      || !Number.isSafeInteger(result.duplicates) || result.duplicates < 0 || !Array.isArray(result.rejected)
      || result.accepted + result.duplicates + result.rejected.length !== records.length) throw new Error("Hub 响应无效");
    return result;
  };
  const dir = join(options.dataDir, "plugins", options.name);
  mkdirSync(dir, { recursive: true, mode: 0o700 });
  const stateFile = join(dir, "state.json");
  const child = spawn(options.command[0]!, [...options.command.slice(1), "--device", device, "--state", stateFile], { stdio: ["ignore", "pipe", "pipe"], env: options.env, cwd: options.cwd, detached: process.platform !== "win32" });
  let diagnostic = "";
  child.stderr!.setEncoding("utf8");
  child.stderr!.on("data", (chunk: string) => { diagnostic = (diagnostic + chunk).slice(0, 8192); });
  let interrupted = false;
  const kill = (signal: NodeJS.Signals) => {
    try { if (process.platform !== "win32" && child.pid) process.kill(-child.pid, signal); else child.kill(signal); } catch {}
  };
  let forceStop: ReturnType<typeof setTimeout> | undefined;
  const stop = () => {
    interrupted = true; kill("SIGTERM");
    forceStop ??= setTimeout(() => kill("SIGKILL"), 2000); forceStop.unref();
  };
  process.once("SIGTERM", stop); process.once("SIGINT", stop);
  const started = new Promise<void>((resolve, reject) => {
    child.once("spawn", () => resolve());
    child.once("error", reject);
  });
  // 立刻注册 error/close，避免很快退出的进程在读完 stdout 前丢失事件。
  const exited = new Promise<number>((resolve, reject) => {
    child.once("error", reject);
    child.once("close", (code) => resolve(code ?? 1));
  });
  // 在异步读取 stdout 时，启动失败也不会产生未处理的 rejection。
  void exited.catch(() => {});
  const summary: PluginSummary = { accepted: 0, duplicates: 0, rejected: 0, exitCode: 1, filtered: 0, stateWritten: false, protocolErrors: 0, released: 0, releaseErrors: 0 };
  let batch: unknown[] = [];
  let checkpoint: unknown;
  let release: string[] = [];
  let hasCheckpoint = false;
  let storageFailed = false;
  const flush = async () => {
    if (!batch.length) return;
    if (interrupted) { batch = []; return; }
    try {
      const result: IngestResult = await ingest(batch);
      summary.accepted += result.accepted;
      summary.duplicates += result.duplicates;
      summary.rejected += result.rejected.length;
    } catch (error) { logFailure("plugin.ingest", error); storageFailed = true; summary.rejected += batch.length; }
    batch = [];
  };
  try {
    // Bun 在 ENOENT 时不会结束 stdout；必须先确认启动成功，再等待输出流。
    await started;
    for await (const line of jsonLines(child.stdout!)) {
      try {
        if (interrupted) continue;
        const message = JSON.parse(line);
        if (!message || typeof message !== "object") throw new Error();
        if (message.type === "record" && Object.hasOwn(message, "record")) {
          if (options.allowedSource) {
            const policy = pluginRecordPolicy(message.record, options.allowedSource);
            if (policy === "invalid") { summary.rejected++; continue; }
            if (policy === "blocked") { summary.filtered++; continue; }
          }
          batch.push(message.record);
          if (batch.length === 500) await flush();
        } else if (message.type === "checkpoint" && Object.hasOwn(message, "state")) {
          if (message.release !== undefined && (!Array.isArray(message.release) || !message.release.every((p: unknown) => typeof p === "string"))) throw new Error();
          release = message.release ?? [];
          checkpoint = message.state; hasCheckpoint = true;
        } else throw new Error();
      } catch { summary.protocolErrors++; }
    }
    await flush();
    summary.exitCode = await exited;
    if (interrupted) summary.exitCode = 143;
    if (summary.exitCode === 0 && !summary.rejected && !summary.protocolErrors && !storageFailed && hasCheckpoint) {
      const tempFile = join(dir, `.state-${process.pid}-${randomBytes(8).toString("hex")}.tmp`);
      try {
        writeFileSync(tempFile, JSON.stringify(checkpoint) + "\n", { mode: 0o600, flag: "wx" });
        renameSync(tempFile, stateFile);
        summary.stateWritten = true;
        for (const file of release) {
          let target: string;
          try { target = realpathSync(file); }
          catch (error) {
            if ((error as NodeJS.ErrnoException).code !== "ENOENT") summary.releaseErrors++;
            continue;
          }
          try {
            const root = realpathSync(join(options.dataDir, "buffer"));
            const inside = relative(root, target);
            if (!isAbsolute(file) || !inside || inside === ".." || inside.startsWith(`..${sep}`) || isAbsolute(inside) || !statSync(target).isFile()) {
              summary.releaseErrors++; continue;
            }
            unlinkSync(target);
            summary.released++;
          } catch { summary.releaseErrors++; }
        }
      } finally { rmSync(tempFile, { force: true }); }
    }
  } catch (e) {
    kill("SIGKILL");
    await exited.catch(() => {});
    throw e;
  } finally {
    process.removeListener("SIGTERM", stop); process.removeListener("SIGINT", stop);
    if (forceStop) clearTimeout(forceStop);
  }
  if (summary.exitCode !== 0) summary.failure = /EACCES|EPERM|permission denied/i.test(diagnostic) ? "permission"
    : /ENOENT|no such file/i.test(diagnostic) ? "missing_file"
    : /ETIMEDOUT|ECONNREFUSED|ENOTFOUND|fetch failed/i.test(diagnostic) ? "network"
    : interrupted ? "interrupted" : "process";
  else if (storageFailed) summary.failure = "storage";
  else if (summary.protocolErrors) summary.failure = "protocol";
  else if (summary.rejected) summary.failure = "rejected";
  else if (summary.releaseErrors) summary.failure = "cleanup";
  options.report?.(summary);
  return summary;
}
