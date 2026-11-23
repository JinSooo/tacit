import { sandboxLaunch, type PluginSandbox } from "./plugin-sandbox.ts";
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
/** 设备协议单批上限：与 CollectorUpload 及中枢 device ingest 一致。 */
const STDIO_BATCH_LIMIT = 200;
const STDIO_BYTE_LIMIT = 4 * 1024 * 1024;

export interface PluginStdioTransport {
  input: AsyncIterable<Uint8Array | string>;
  write: (line: string) => void | Promise<void>;
}

export interface PluginSummary {
  failure?: string;
  warnings?: string[];
  accepted: number; duplicates: number; rejected: number; exitCode: number;
  filtered: number; stateWritten: boolean; protocolErrors: number; released: number; releaseErrors: number;
}

function validateIngestResult(value: unknown, count: number): IngestResult {
  const result = value as IngestResult | null;
  if (!result || typeof result !== "object"
    || !Number.isSafeInteger(result.accepted) || result.accepted < 0
    || !Number.isSafeInteger(result.duplicates) || result.duplicates < 0
    || !Array.isArray(result.rejected)
    || result.accepted + result.duplicates + result.rejected.length !== count) {
    throw new Error("Hub 响应无效");
  }
  return result;
}

export async function runPlugin(options: {
  db?: HubDB; hub?: string; tokenFile?: string; transport?: "stdio"; stdio?: PluginStdioTransport;
  dataDir: string; name: string; command: string[]; device?: string;
  allowedSource?: string; sandbox?: PluginSandbox; env?: NodeJS.ProcessEnv; cwd?: string;
  report?: (summary: PluginSummary) => void;
}): Promise<PluginSummary> {
  if (!/^[a-z0-9][a-z0-9_-]{0,62}$/.test(options.name)) throw new Error("插件名称无效");
  if (!options.command.length) throw new Error("缺少插件命令");
  const device = options.device ?? "mac";
  if (!/^[a-z0-9][a-z0-9-]{0,62}$/.test(device)) throw new Error("设备名无效");
  const isStdio = options.transport === "stdio";
  if (options.transport !== undefined && !isStdio) throw new Error("不支持的传输方式");
  const modeCount = Number(Boolean(options.hub)) + Number(Boolean(options.db)) + Number(isStdio);
  if (modeCount === 0) throw new Error("缺少数据库或 hub 地址");
  if (modeCount > 1) throw new Error("不能同时指定多种传输方式");
  const token = options.hub ? readFileSync(options.tokenFile ?? join(options.dataDir, "token"), "utf8").trim() : "";
  if (options.hub && !token) throw new Error("本地 token 文件为空");
  const stdioLines = isStdio ? jsonLines(options.stdio?.input ?? process.stdin) : undefined;
  const writeStdio = options.stdio?.write ?? ((line: string) => new Promise<void>((resolve, reject) => {
    process.stdout.write(line, err => err ? reject(err) : resolve());
  }));
  let stdioSeq = 0;
  const ingest = async (records: unknown[]): Promise<IngestResult> => {
    if (isStdio) {
      for (let attempt = 0; ; attempt++) {
        const id = ++stdioSeq;
        await writeStdio(JSON.stringify({ type: "ingest", id, records }) + "\n");
        const next = await stdioLines!.next();
        if (next.done) throw new Error("宿主连接已断开");
        let reply: Record<string, unknown>;
        try { reply = JSON.parse(next.value) as Record<string, unknown>; }
        catch { throw new Error("宿主响应无效"); }
        if (!reply || typeof reply !== "object" || reply.type !== "ingest_result" || reply.id !== id) {
          throw new Error("宿主响应无效");
        }
        if (reply.ok === true) return validateIngestResult(reply.result, records.length);
        if (reply.status === 503 && attempt < BUSY_RETRY_MS.length) {
          await Bun.sleep(BUSY_RETRY_MS[attempt]!);
          continue;
        }
        throw new Error(reply.status === 503 ? "Hub 数据库忙，稍后重试" : "Hub 接收失败");
      }
    }
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
    return validateIngestResult(await response.json(), records.length);
  };
  const dir = join(options.dataDir, "plugins", options.name);
  mkdirSync(dir, { recursive: true, mode: 0o700 });
  const stateFile = join(dir, "state.json");
  const launch = options.sandbox ? sandboxLaunch({ sandbox: options.sandbox, dataDir: options.dataDir, stateFile, command: options.command }) : options;
  const child = spawn(launch.command[0]!, [...launch.command.slice(1), "--device", device, "--state", stateFile], { stdio: ["ignore", "pipe", "pipe"], env: launch.env, cwd: launch.cwd, detached: process.platform !== "win32" });
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
  const batchLimit = isStdio ? STDIO_BATCH_LIMIT : 500;
  let batch: unknown[] = [];
  let batchBytes = 0;
  let checkpoint: unknown;
  let release: string[] = [];
  let hasCheckpoint = false;
  let storageFailed = false;
  const flush = async () => {
    if (!batch.length) return;
    if (interrupted) { batch = []; batchBytes = 0; return; }
    try {
      const result: IngestResult = await ingest(batch);
      summary.accepted += result.accepted;
      summary.duplicates += result.duplicates;
      summary.rejected += result.rejected.length;
    } catch (error) { logFailure("plugin.ingest", error); storageFailed = true; summary.rejected += batch.length; }
    batch = [];
    batchBytes = 0;
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
          if (isStdio) {
            const size = Buffer.byteLength(JSON.stringify(message.record)) + (batch.length ? 1 : 0);
            // 留出外层 JSON 键和记录数组开销，确保加密前的 body 不超过 4 MiB。
            if (batch.length > 0 && batchBytes + size + 128 > STDIO_BYTE_LIMIT) await flush();
            batch.push(message.record);
            batchBytes += Buffer.byteLength(JSON.stringify(message.record)) + (batch.length > 1 ? 1 : 0);
          } else {
            batch.push(message.record);
          }
          if (batch.length === batchLimit) await flush();
        } else if (message.type === "checkpoint" && Object.hasOwn(message, "state")) {
          if (message.release !== undefined && (!Array.isArray(message.release) || !message.release.every((p: unknown) => typeof p === "string"))) throw new Error();
          // Sandboxed plugins cannot write buffers, so they must not use the trusted runner as a deletion proxy.
          if (options.sandbox && message.release?.length) throw new Error();
          release = message.release ?? [];
          checkpoint = message.state; hasCheckpoint = true;
          // 内置会话插件只报告计数，第三方插件或日志内容不能借摘要进入采集端。
          if (options.name === "agent-sessions" && !options.sandbox) {
            const { unrecognized, damaged } = message.sessionWarnings ?? {};
            const warnings: string[] = [];
            if (Number.isSafeInteger(unrecognized) && unrecognized >= 20) warnings.push(`Claude Code / Codex 会话格式可能已变化，有 ${unrecognized} 行没有识别`);
            if (Number.isSafeInteger(damaged) && damaged > 0) warnings.push(`跳过 ${damaged} 行损坏数据`);
            summary.warnings = warnings.length ? warnings : undefined;
          }
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
    if (isStdio && !options.stdio) {
      process.stdin.pause();
      (process.stdin as { unref?: () => void }).unref?.();
    }
  }
  if (summary.exitCode !== 0) summary.failure = options.sandbox && /sandbox-exec:|sandbox_init/i.test(diagnostic) ? "sandbox" : /EACCES|EPERM|permission denied/i.test(diagnostic) ? "permission"
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
