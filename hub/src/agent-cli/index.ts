import { cliText } from "./locale.ts";
import { isAbsolute } from "node:path";
import { AgentError, reason, sessionContext } from "./client.ts";

import type { AgentClientOptions } from "./identity.ts";

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
    throw new AgentError(cliText("请用 --tool 指定 AI 工具名称", "Use --tool to specify the AI tool"));
  }
  if (hook && !["claude-code", "codex"].includes(args[1])) throw new AgentError(cliText("SessionStart 仅支持 claude-code 或 codex", "SessionStart supports only claude-code and codex"));
  return args[1];
}

async function sessionStart(args: string[], options?: AgentClientOptions): Promise<void> {
  const controller = new AbortController();
  let timer: ReturnType<typeof setTimeout> | undefined;
  try {
    const timeout = new Promise<never>((_, reject) => {
      timer = setTimeout(() => {
        controller.abort();
        process.stdin.destroy();
        reject(new AgentError(cliText("SessionStart 查询超时", "SessionStart timed out")));
      }, 2000);
    });
    await Promise.race([timeout, (async () => {
      const tool = toolArg(args, true);
      let input: unknown;
      try { input = JSON.parse(await readInput()); }
      catch { throw new AgentError(cliText("SessionStart 输入不是有效 JSON", "SessionStart input must be valid JSON")); }
      if (!input || typeof input !== "object" || !("cwd" in input) || typeof input.cwd !== "string" || !isAbsolute(input.cwd)) {
        throw new AgentError(cliText("SessionStart cwd 必须是绝对路径", "SessionStart cwd must be an absolute path"));
      }
      const source = "source" in input ? input.source : undefined;
      const event = typeof source === "string" && ["startup", "resume", "clear", "compact"].includes(source) ? source : "startup";
      const query = new URLSearchParams({ cwd: input.cwd, event, tool });
      const session = "session_id" in input ? input.session_id : undefined;
      if (typeof session === "string" && session && session.length <= 128 && !/[\x00-\x1f\x7f]/.test(session)) query.set("session", session);
      await sessionContext(query, controller.signal, text => {
        if (text.trim()) process.stdout.write(JSON.stringify({ hookSpecificOutput: { hookEventName: "SessionStart", additionalContext: text } }) + "\n");
      }, options);
    })()]);
  } catch (error) {
    console.error(reason(error));
  } finally {
    clearTimeout(timer);
    controller.abort();
  }
}

export async function runAgentCommand(argv: string[], options?: AgentClientOptions): Promise<void> {
  if (argv[0] === "hook") {
    if (argv[1] !== "session-start") { console.error(cliText("hook 仅支持 session-start", "hook supports only session-start")); return; }
    await sessionStart(argv.slice(2), options);
  } else {
    const tool = toolArg(argv.slice(1), false);
    const { runMcp } = await import("./mcp.ts");
    await runMcp(tool);
  }
}
