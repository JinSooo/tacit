import { isAbsolute } from "node:path";
import { AgentError, readHub, reason } from "./client.ts";

function readInput(): Promise<string> {
  return new Promise((resolve, reject) => {
    let text = "";
    process.stdin.setEncoding("utf8");
    process.stdin.on("data", chunk => { text += chunk; });
    process.stdin.once("end", () => resolve(text));
    process.stdin.once("error", reject);
  });
}

function toolArg(args: string[], hook: boolean): string {
  if (args.length !== 2 || args[0] !== "--tool" || !args[1] || args[1].length > 32 || /[\s\x00-\x1f\x7f]/.test(args[1])) {
    throw new AgentError("请用 --tool 指定 AI 工具名称");
  }
  if (hook && !["claude-code", "codex"].includes(args[1])) throw new AgentError("SessionStart 仅支持 claude-code 或 codex");
  return args[1];
}

async function sessionStart(args: string[]): Promise<void> {
  const controller = new AbortController();
  let timer: ReturnType<typeof setTimeout> | undefined;
  try {
    const timeout = new Promise<never>((_, reject) => {
      timer = setTimeout(() => {
        controller.abort();
        process.stdin.destroy();
        reject(new AgentError("SessionStart 查询超时"));
      }, 2000);
    });
    await Promise.race([timeout, (async () => {
      const tool = toolArg(args, true);
      let input: unknown;
      try { input = JSON.parse(await readInput()); }
      catch { throw new AgentError("SessionStart 输入不是有效 JSON"); }
      if (!input || typeof input !== "object" || !("cwd" in input) || typeof input.cwd !== "string" || !isAbsolute(input.cwd)) {
        throw new AgentError("SessionStart cwd 必须是绝对路径");
      }
      const source = "source" in input ? input.source : undefined;
      const event = typeof source === "string" && ["startup", "resume", "clear", "compact"].includes(source) ? source : "startup";
      const query = new URLSearchParams({ cwd: input.cwd, event, tool });
      const session = "session_id" in input ? input.session_id : undefined;
      if (typeof session === "string" && session && session.length <= 128) query.set("session", session);
      const result = await readHub("context", query, controller.signal);
      if (!result || typeof result !== "object" || !("text" in result) || typeof result.text !== "string") throw new AgentError("hub 上下文格式无效");
      if (!controller.signal.aborted && result.text.trim()) process.stdout.write(JSON.stringify({ hookSpecificOutput: { hookEventName: "SessionStart", additionalContext: result.text } }) + "\n");
    })()]);
  } catch (error) {
    console.error(reason(error));
  } finally {
    clearTimeout(timer);
    controller.abort();
  }
}

export async function runAgentCommand(argv: string[]): Promise<void> {
  if (argv[0] === "hook") {
    if (argv[1] !== "session-start") { console.error("hook 仅支持 session-start"); return; }
    await sessionStart(argv.slice(2));
  } else {
    const tool = toolArg(argv.slice(1), false);
    const { runMcp } = await import("./mcp.ts");
    await runMcp(tool);
  }
}
