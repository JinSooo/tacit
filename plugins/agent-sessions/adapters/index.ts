import { AGENT_SESSIONS } from "../../../packages/record/agent-tools.ts";
import { antigravity } from "./antigravity.ts";
import { claudeCode } from "./claude-code.ts";
import { codex } from "./codex.ts";
import { geminiCli } from "./gemini-cli.ts";
import { qwenCode } from "./qwen-code.ts";
import { opencode } from "./opencode.ts";

export const adapters = [claudeCode, codex, antigravity, geminiCli, qwenCode, opencode].map(adapter => {
  const tool = AGENT_SESSIONS.find(tool => tool.id === adapter.id);
  if (!tool) throw new Error(`Missing session tool: ${adapter.id}`);
  // 保留旧 checkpoint 中的 provider 和会话键，文件游标、待发桶和去重哈希可以直接续用。
  return { ...adapter, tool, checkpointKey: adapter.checkpointKey ?? adapter.id };
});

export const adaptersByCheckpointKey = new Map(adapters.map(adapter => [adapter.checkpointKey, adapter]));
