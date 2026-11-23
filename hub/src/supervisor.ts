// 单容器/服务端运行入口的子进程守护：同时托管 serve 与 distill，转发退出信号并在异常退出时按退避重启。
import { spawn as nodeSpawn } from "node:child_process";

export interface SupervisedSpec {
  name: string;
  command: string[];
}

export interface SupervisedExit {
  code: number | null;
  signal: NodeJS.Signals | null;
}

export interface SupervisedChild {
  readonly pid?: number;
  kill(signal?: NodeJS.Signals): boolean;
  readonly exited: Promise<SupervisedExit>;
}

export interface SignalTarget {
  on(event: "SIGTERM" | "SIGINT", listener: () => void): unknown;
  off(event: "SIGTERM" | "SIGINT", listener: () => void): unknown;
}

export interface SupervisorOptions {
  specs: SupervisedSpec[];
  spawn?: (spec: SupervisedSpec) => SupervisedChild;
  initialBackoffMs?: number;
  maxBackoffMs?: number;
  /** 子进程连续存活超过该时长后再崩溃，退避重置回初始值。 */
  stableMs?: number;
  shutdownTimeoutMs?: number;
  log?: (message: string) => void;
  signalTarget?: SignalTarget;
  now?: () => number;
}

export function defaultSupervisorSpawn(spec: SupervisedSpec): SupervisedChild {
  const [cmd, ...args] = spec.command;
  const child = nodeSpawn(cmd!, args, { stdio: "inherit", env: process.env });
  const exited = new Promise<SupervisedExit>(resolve => {
    let settled = false;
    const finish = (result: SupervisedExit) => {
      if (settled) return;
      settled = true;
      resolve(result);
    };
    child.once("exit", (code, signal) => finish({ code, signal }));
    child.once("error", () => finish({ code: 1, signal: null }));
  });
  return {
    get pid() { return child.pid; },
    kill(signal: NodeJS.Signals = "SIGTERM") {
      try { return child.kill(signal); } catch { return false; }
    },
    exited,
  };
}

export async function runSupervisor(options: SupervisorOptions): Promise<void> {
  const spawn = options.spawn ?? defaultSupervisorSpawn;
  const initialBackoffMs = options.initialBackoffMs ?? 1_000;
  const maxBackoffMs = options.maxBackoffMs ?? 60_000;
  const stableMs = options.stableMs ?? 30_000;
  const shutdownTimeoutMs = options.shutdownTimeoutMs ?? 10_000;
  const log = options.log ?? (msg => console.error(msg));
  const signalTarget = options.signalTarget ?? process;
  const now = options.now ?? Date.now;

  let stopping = false;
  let forceTimer: ReturnType<typeof setTimeout> | undefined;
  const running = new Map<string, SupervisedChild>();
  const sleepers = new Set<{ timer: ReturnType<typeof setTimeout>; wake: () => void }>();

  const sleep = (ms: number) => new Promise<void>(resolve => {
    if (stopping) { resolve(); return; }
    const entry = {
      timer: setTimeout(() => { sleepers.delete(entry); resolve(); }, ms),
      wake: () => { clearTimeout(entry.timer); sleepers.delete(entry); resolve(); },
    };
    sleepers.add(entry);
  });

  const stopAll = (signal: NodeJS.Signals) => {
    if (stopping) return;
    stopping = true;
    log(`[run] 收到 ${signal}，正在通知子进程退出`);
    for (const sleeper of [...sleepers]) sleeper.wake();
    for (const child of running.values()) child.kill(signal);
    if (shutdownTimeoutMs > 0 && running.size > 0) {
      forceTimer = setTimeout(() => {
        for (const [name, child] of running) {
          log(`[run] 子进程 ${name} 退出超时，发送 SIGKILL`);
          child.kill("SIGKILL");
        }
      }, shutdownTimeoutMs);
      forceTimer.unref();
    }
  };

  const onSigTerm = () => stopAll("SIGTERM");
  const onSigInt = () => stopAll("SIGINT");
  signalTarget.on("SIGTERM", onSigTerm);
  signalTarget.on("SIGINT", onSigInt);

  const supervise = async (spec: SupervisedSpec) => {
    let backoff = initialBackoffMs;
    while (!stopping) {
      const started = now();
      const child = spawn(spec);
      running.set(spec.name, child);
      const exit = await child.exited;
      if (running.get(spec.name) === child) running.delete(spec.name);
      if (stopping) break;
      const lived = now() - started;
      if (lived >= stableMs) backoff = initialBackoffMs;
      const delay = backoff;
      backoff = Math.min(backoff * 2, maxBackoffMs);
      const reason = exit.signal ? `信号 ${exit.signal}` : `退出码 ${exit.code ?? "null"}`;
      log(`[run] 子进程 ${spec.name} 异常退出（${reason}），${delay}ms 后重启`);
      await sleep(delay);
    }
  };

  try {
    await Promise.all(options.specs.map(spec => supervise(spec)));
  } finally {
    clearTimeout(forceTimer);
    signalTarget.off("SIGTERM", onSigTerm);
    signalTarget.off("SIGINT", onSigInt);
  }
}
