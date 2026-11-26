/** 与 Agent 指标的默认排除集合共用；只识别机器协议，不能凭项目目录排除正常开发。 */
export const DEFAULT_EXCLUDED_TOOLS = new Set(["accuracy-eval", "release-check", "qa-readonly", "test"]);
export function excludedSession(body: string, context?: { extra?: Record<string, unknown> }) {
  const tool = context?.extra?.tool;
  if (typeof tool === "string" && DEFAULT_EXCLUDED_TOOLS.has(tool)) return true;
  if (/\[tacit-tool-session:(accuracy-eval|release-check|qa-readonly|test)\]/.test(body)) return true;
  // 旧评测记录没有显式来源；专用 MCP 名与脚本生成的答题协议必须同时出现。
  return /mcp__tacit_eval__/.test(body) && /答案字段为[\s\S]*evidence_ids/.test(body) ||
    /\[我\] <pasted_content\b[\s\S]*# MCP Server Instructions[\s\S]*^## tacit_eval\s*$/m.test(body);
}
export function requestOnly(text: string) {
  return /^(?:同意(?:现在)?(?:更新正式库)?|继续(?:吧)?|安装(?:吧)?|可以|好的?|OK|确认|执行吧|怎么又不跑了|咋又不跑了|又卡住了)[。！!？?\s]*$/i.test(text.trim())
    || /^(?:ok|okay|yes|sure|continue|go ahead|go on|proceed|sounds good|do it|lgtm|approved|install it)[\p{P}\s]*$/iu.test(text.trim());
}
