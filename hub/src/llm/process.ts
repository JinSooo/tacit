import type { BackendContext } from "./types.ts";

export function input(ctx: BackendContext): string {
  return JSON.stringify({ system: ctx.req.system, prompt: ctx.req.prompt });
}
export function safeError(message: string, secrets: string[]): string {
  // 子进程可能回显输入；出现任一输入行时舍弃整段诊断，避免残留片段。
  const parts = secrets.flatMap(s => [s, JSON.stringify(s).slice(1, -1), ...s.split(/\r?\n/)]).filter(Boolean);
  const fragments = new Set(Array.from({ length: Math.max(0, message.length - 7) }, (_, i) => message.slice(i, i + 8)));
  const echoed = parts.some(s => message.includes(s) || (s.length >= 8 && Array.from({ length: s.length - 7 }, (_, i) => s.slice(i, i + 8)).some(p => fragments.has(p))));
  return echoed ? "后端调用失败（诊断含输入内容，已隐藏）" : message.slice(0, 500);
}
/** CLI 后端只继承这些变量。调用方环境里的中转站地址、模型映射（ANTHROPIC_*）和宿主 Agent 会话变量（CLAUDE_CODE_*、CMUX_* 等）
 * 一律不传：提炼必须走 models.json 选定的通道，而且不能因为是谁启动的 distill 而改变（2026-11-08 实测：继承后会走中转站）。 */
const KEEP_ENV = /^(HOME|USER|LOGNAME|PATH|SHELL|TMPDIR|LANG|LC_[A-Z_]+|TERM|__CF_USER_TEXT_ENCODING)$/;
export function cliEnv(source: NodeJS.ProcessEnv = process.env): NodeJS.ProcessEnv {
  return { ...Object.fromEntries(Object.entries(source).filter(([k]) => KEEP_ENV.test(k))), CI: "1" };
}
export function run(ctx: BackendContext, command: string, args: string[]): Promise<string> {
  return new Promise((resolve, reject) => {
    let stdout = "", stderr = "", settled = false, failure: string | undefined;
    ctx.observer?.request("cli", { input: JSON.parse(input(ctx)), schema: ctx.req.schema });
    // 不继承额外的终端输入通道；认证仍由 CLI 自己处理。
    const child = ctx.spawn(command, args, { cwd: ctx.cwd, stdio: "pipe", detached: process.platform !== "win32", env: cliEnv() });
    function stop() {
      try { if (process.platform !== "win32" && child.pid) process.kill(-child.pid, "SIGKILL"); else child.kill("SIGKILL"); }
      catch { child.kill("SIGKILL"); }
    }
    function fail(message: string) {
      if (settled) return;
      settled = true; clearTimeout(timer); reject(new Error(message));
    }
    const timer = setTimeout(() => { failure = `模型调用超时（${ctx.timeoutMs}ms），已终止进程`; stop(); }, ctx.timeoutMs);
    child.stdout.setEncoding("utf8"); child.stderr.setEncoding("utf8");
    child.stdout.on("data", (chunk: string) => {
      if (failure) return;
      stdout += chunk;
      ctx.metrics.outputChars += Array.from(chunk).length;
      if (stdout.length > 8 * 1024 * 1024) { failure = "模型输出超过 8 MiB"; stop(); }
    });
    child.stderr.on("data", (chunk: string) => { stderr = (stderr + chunk).slice(0, 500); });
    child.on("error", () => fail(`无法启动 ${command}`));
    child.stdin.on("error", () => { /* 提前退出时由 close 统一报告。 */ });
    child.on("close", code => {
      if (settled) return;
      try { ctx.observer?.response(stdout); }
      catch { fail("调用结果记录失败，结果未采用"); return; }
      if (failure) { fail(failure); return; }
      if (code !== 0) {
        // claude -p 出错时常把原因写在 stdout 的 JSON（result 字段）里，stderr 是空的，例如"额度用完"。
        let reason = stderr;
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
        fail(`${command} 退出失败（${code}）：${safeError(reason, [ctx.req.system, ctx.req.prompt, input(ctx)])}`); return;
      }
      settled = true; clearTimeout(timer); resolve(stdout);
    });
    child.stdin.end(input(ctx));
  });
}

export function parseJSON(text: string): unknown {
  try { return JSON.parse(text); } catch { throw new Error("模型返回非法 JSON"); }
}
export function tokens(value: unknown): number | null {
  return typeof value === "number" && Number.isFinite(value) && value >= 0 ? value : null;
}
