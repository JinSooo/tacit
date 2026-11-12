import { mkdirSync, renameSync, rmSync, writeFileSync, readFileSync, realpathSync, statSync, unlinkSync } from "node:fs";
import { isAbsolute, join, relative, sep } from "node:path";
import { randomBytes } from "node:crypto";
import { spawn } from "node:child_process";
import { HubDB, type IngestResult } from "./db.ts";
import { jsonLines } from "./jsonl.ts";

export interface PluginSummary {
  accepted: number; duplicates: number; rejected: number; exitCode: number;
  stateWritten: boolean; protocolErrors: number; released: number; releaseErrors: number;
}

export async function runPlugin(options: {
  db?: HubDB; hub?: string; tokenFile?: string; dataDir: string; name: string; command: string[]; device?: string;
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
    const response = await fetch(new URL("/v1/ingest", options.hub), {
      method: "POST", headers: { authorization: `Bearer ${token}`, "content-type": "application/json" },
      body: JSON.stringify({ device, records }), signal: AbortSignal.timeout(30_000), redirect: "error",
    });
    if (!response.ok) throw new Error("Hub 接收失败");
    const result = await response.json() as IngestResult;
    if (!result || !Number.isSafeInteger(result.accepted) || result.accepted < 0
      || !Number.isSafeInteger(result.duplicates) || result.duplicates < 0 || !Array.isArray(result.rejected)
      || result.accepted + result.duplicates + result.rejected.length !== records.length) throw new Error("Hub 响应无效");
    return result;
  };
  const dir = join(options.dataDir, "plugins", options.name);
  mkdirSync(dir, { recursive: true, mode: 0o700 });
  const stateFile = join(dir, "state.json");
  const child = spawn(options.command[0]!, [...options.command.slice(1), "--device", device, "--state", stateFile], { stdio: ["ignore", "pipe", "inherit"] });
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
  const summary: PluginSummary = { accepted: 0, duplicates: 0, rejected: 0, exitCode: 1, stateWritten: false, protocolErrors: 0, released: 0, releaseErrors: 0 };
  let batch: unknown[] = [];
  let checkpoint: unknown;
  let release: string[] = [];
  let hasCheckpoint = false;
  let storageFailed = false;
  const flush = async () => {
    if (!batch.length) return;
    try {
      const result: IngestResult = await ingest(batch);
      summary.accepted += result.accepted;
      summary.duplicates += result.duplicates;
      summary.rejected += result.rejected.length;
    } catch { storageFailed = true; summary.rejected += batch.length; }
    batch = [];
  };
  try {
    // Bun 在 ENOENT 时不会结束 stdout；必须先确认启动成功，再等待输出流。
    await started;
    for await (const line of jsonLines(child.stdout!)) {
      try {
        const message = JSON.parse(line);
        if (!message || typeof message !== "object") throw new Error();
        if (message.type === "record" && Object.hasOwn(message, "record")) {
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
    child.kill();
    await exited.catch(() => {});
    throw e;
  }
  options.report?.(summary);
  return summary;
}
