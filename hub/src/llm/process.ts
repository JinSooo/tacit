import { classifyModelError, ModelError } from "./error-category.ts";
import type { BackendContext, Spawn } from "./types.ts";
import { capturedCLIEnv, cliProxyEnv, systemProxyEnv } from "../net/system-proxy.ts";

export function input(ctx: BackendContext): string {
  return JSON.stringify({ system: ctx.req.system, prompt: ctx.req.prompt });
}
/** CLI 后端只继承这些变量。调用方环境里的中转站地址、模型映射（ANTHROPIC_*）和宿主 Agent 会话变量（CLAUDE_CODE_*、CMUX_* 等）
 * 一律不传：提炼必须走 models.json 选定的通道，而且不能因为是谁启动的 distill 而改变（2026-11-08 实测：继承后会走中转站）。
 * 代理和 CODEX_HOME 只决定 CLI 怎么连网、去哪读登录，照常传。 */
export const SHELL_ENV = /^(CODEX_HOME|(?:http|https|all|no)_proxy|(?:HTTP|HTTPS|ALL|NO)_PROXY)$/;
const KEEP_ENV = /^(HOME|USER|LOGNAME|PATH|SHELL|TMPDIR|LANG|LC_[A-Z_]+|TERM|__CF_USER_TEXT_ENCODING)$/;
/** 显式设置优先于安装时保存的登录 shell 环境，再回落到 macOS 系统代理。 */
export function cliEnv(source: NodeJS.ProcessEnv = process.env, defaults = systemProxyEnv()): NodeJS.ProcessEnv {
  const captured = capturedCLIEnv(source);
  const kept = Object.fromEntries(Object.entries(source).filter(([key]) => KEEP_ENV.test(key)));
  const codexHome = source.CODEX_HOME ?? captured.CODEX_HOME;
  return { ...kept, ...cliProxyEnv(source, captured, defaults),
    ...(codexHome === undefined ? {} : { CODEX_HOME: codexHome }), CI: "1" };
}
export function run(ctx: BackendContext, command: string, args: string[]): Promise<string> {
  return new Promise((resolve, reject) => {
    let stdout = "", stderr = "", settled = false, failure: ModelError | undefined;
    let timer: ReturnType<typeof setTimeout> | undefined;
    const stderrLimit = 64 * 1024;
    let stderrTruncated = false;
    observeRequest(ctx, "cli", { input: JSON.parse(input(ctx)), schema: ctx.req.schema });
    // 不继承额外的终端输入通道；认证仍由 CLI 自己处理。
    let child: ReturnType<Spawn>;
    try { child = ctx.spawn(command, args, { cwd: ctx.cwd, stdio: "pipe", detached: process.platform !== "win32", env: cliEnv() }); }
    catch (error) { cannotStart(error); return; }
    function stop() {
      try { if (process.platform !== "win32" && child.pid) process.kill(-child.pid, "SIGKILL"); else child.kill("SIGKILL"); }
      catch { child.kill("SIGKILL"); }
    }
    function fail(error: ModelError, detail?: string) {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      try { if (detail) ctx.observer?.failure?.(detail); }
      catch { reject(new ModelError("usage_record_failed")); return; }
      reject(error);
    }
    function cannotStart(error: unknown) {
      const code = spawnFailure(error);
      fail(new ModelError(code), code === "cli_missing" ? "The selected command was not found." : "The selected command could not be started.");
    }
    timer = setTimeout(() => { failure = new ModelError("timeout"); stop(); }, ctx.timeoutMs);
    child.stdout.setEncoding("utf8"); child.stderr.setEncoding("utf8");
    child.stdout.on("data", (chunk: string) => {
      if (failure) return;
      stdout += chunk;
      ctx.metrics.outputChars += Array.from(chunk).length;
      if (stdout.length > 8 * 1024 * 1024) { failure = new ModelError("schema_mismatch"); stop(); }
    });
    child.stderr.on("data", (chunk: string) => {
      const remaining = stderrLimit - stderr.length;
      stderr += chunk.slice(0, remaining);
      stderrTruncated ||= chunk.length > remaining;
    });
    child.on("error", cannotStart);
    child.stdin.on("error", () => { /* 提前退出时由 close 统一报告。 */ });
    child.on("close", code => {
      if (settled) return;
      try { ctx.observer?.response(stdout); }
      catch { fail(new ModelError("usage_record_failed")); return; }
      if (failure) {
        fail(failure, failure.code === "timeout" ? "The command was stopped after it exceeded the time limit." : undefined);
        return;
      }
      if (code !== 0) {
        // claude -p 出错时常把原因写在 stdout 的 JSON（result 字段）里，stderr 是空的，例如"额度用完"。
        // 丢弃可能截在凭据中间的不完整末行，保留的内容由快照脱敏后再截短。
        let reason = (stderrTruncated ? stderr.slice(0, Math.max(0, stderr.lastIndexOf("\n"))) : stderr).trim();
        try { const o = JSON.parse(stdout); if (o?.is_error && typeof o.result === "string") reason = o.result; } catch { /* 不是 JSON 就用 stderr */ }
        if (command === "codex") {
          // --json 的错误在 stdout 的 JSONL 事件里，stderr 经常为空。
          // 只提取错误事件；不能把其他事件（含模型正文）当作诊断。
          for (const line of stdout.split("\n")) {
            try {
              const event = JSON.parse(line);
              const message = event.type === "turn.failed" ? event.error?.message : event.type === "error" ? event.message : null;
              if (typeof message === "string" && message.trim()) reason = message;
            } catch { /* 非事件行忽略。 */ }
          }
        }
        fail(new ModelError(classifyModelError(reason, "cli_failed")), reason.trim() || "The command exited without an error message.");
        return;
      }
      settled = true; clearTimeout(timer); resolve(stdout);
    });
    child.stdin.end(input(ctx));
  });
}

/** 命令不在 PATH 里（没装 Claude Code / Codex）单独归类，界面才能直接说“没找到”，而不是笼统的“调用失败”。 */
export function spawnFailure(error: unknown): "cli_missing" | "cli_failed" {
  return (error as NodeJS.ErrnoException | null)?.code === "ENOENT" ? "cli_missing" : "cli_failed";
}

export function observeRequest(ctx: BackendContext, transport: "api" | "cli", payload: unknown) {
  try { ctx.observer?.request(transport, payload); }
  catch (error) { throw error instanceof ModelError ? error : new ModelError("usage_record_failed"); }
}

export function parseJSON(text: string): unknown {
  try { return JSON.parse(text); } catch { throw new ModelError("invalid_json"); }
}
export function tokens(value: unknown): number | null {
  return typeof value === "number" && Number.isFinite(value) && value >= 0 ? value : null;
}
