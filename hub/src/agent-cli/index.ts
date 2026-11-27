import { cliText } from "./locale.ts";
import { AgentError } from "./client.ts";

import type { AgentClientOptions } from "./identity.ts";

function toolArg(args: string[]): string {
  if (args.length !== 2 || args[0] !== "--tool" || !args[1] || args[1].length > 32 || /[\s\x00-\x1f\x7f]/.test(args[1])) {
    throw new AgentError(cliText("请用 --tool 指定 AI 工具名称", "Use --tool to specify the AI tool"));
  }
  return args[1];
}

export async function runAgentCommand(argv: string[], _options?: AgentClientOptions): Promise<void> {
  // 2026-11-27 起不再在会话开始时带入，改由 AI 调用 MCP 的 project 自己查。升级会删掉旧钩子；
  // 删不掉的（配置损坏等）仍会调用这里，什么都不输出、正常退出，不打扰会话。
  if (argv[0] === "hook") return;
  const tool = toolArg(argv.slice(1));
  const { runMcp } = await import("./mcp.ts");
  await runMcp(tool);
}
