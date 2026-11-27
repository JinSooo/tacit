import { cliText } from "./locale.ts";
import { AGENT_TOOLS, type SessionStartFormat } from "../../../packages/record/agent-tools.ts";
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

function toolArg(args: string[]): string {
  if (args.length !== 2 || args[0] !== "--tool" || !args[1] || args[1].length > 32 || /[\s\x00-\x1f\x7f]/.test(args[1])) {
    throw new AgentError(cliText("请用 --tool 指定 AI 工具名称", "Use --tool to specify the AI tool"));
  }
  return args[1];
}

function firstPath(value: unknown): unknown {
  return Array.isArray(value) ? value[0] : undefined;
}

function sessionQuery(format: SessionStartFormat, tool: string, input: unknown): URLSearchParams {
  const fields = input && typeof input === "object" ? input as Record<string, unknown> : {};
  let cwd = fields.cwd, session = fields.session_id;
  if (format === "antigravity") {
    cwd = typeof cwd === "string" && isAbsolute(cwd) ? cwd : firstPath(fields.workspacePaths);
    session = fields.conversationId;
  } else if (format === "cursor") {
    cwd = firstPath(fields.workspace_roots);
    session = fields.session_id || fields.conversation_id;
  } else if (format === "copilot") {
    session = fields.sessionId;
  }
  if (typeof cwd !== "string" || !isAbsolute(cwd)) {
    throw new AgentError(cliText("SessionStart cwd 必须是绝对路径", "SessionStart cwd must be an absolute path"));
  }
  const source = format === "copilot" && fields.source === "resume" ? "resume"
    : format === "claude" ? fields.source : undefined;
  const event = typeof source === "string" && ["startup", "resume", "clear", "compact"].includes(source) ? source : "startup";
  const query = new URLSearchParams({ cwd, event, tool });
  if (typeof session === "string" && session && session.length <= 128 && !/[\x00-\x1f\x7f]/.test(session)) query.set("session", session);
  return query;
}

function sessionOutput(format: SessionStartFormat, text: string) {
  switch (format) {
    case "antigravity": return { injectSteps: [{ systemMessage: { systemMessage: text } }] };
    case "cursor": return { additional_context: text };
    case "copilot": return { additionalContext: text };
    case "claude": return { hookSpecificOutput: { hookEventName: "SessionStart", additionalContext: text } };
  }
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
      const tool = toolArg(args);
      const format = AGENT_TOOLS.find(entry => entry.id === tool)?.sessionStart;
      if (!format) throw new AgentError(cliText("此 AI 工具不支持 SessionStart", "This AI tool does not support SessionStart"));
      let input: unknown;
      try { input = JSON.parse(await readInput()); }
      catch { throw new AgentError(cliText("SessionStart 输入不是有效 JSON", "SessionStart input must be valid JSON")); }
      const query = sessionQuery(format, tool, input);
      await sessionContext(query, controller.signal, text => {
        if (text.trim()) process.stdout.write(JSON.stringify(sessionOutput(format, text)) + "\n");
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
    const tool = toolArg(argv.slice(1));
    const { runMcp } = await import("./mcp.ts");
    await runMcp(tool);
  }
}
