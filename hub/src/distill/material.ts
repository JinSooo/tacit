import type { RecordV1 } from "../../../packages/record/index.ts";
import { cleanUserText } from "../../../plugins/agent-sessions/filters.ts";
import { redactString } from "../redact.ts";

/** 只清理明确的采集包装，不修改原始记录；引用仍须回原文逐字验证。 */
export function materialBody(record: Pick<RecordV1, "source" | "body" | "context">): string {
  let body = record.body;
  if (record.source === "mac.screen" && record.context?.app === "com.openai.codex" && body.startsWith("Skip to content\n")) {
    const conversation = /^(?:You said:|ChatGPT said:)\s*$/m.exec(body);
    if (conversation) body = body.slice(conversation.index);
  }
  if (record.source === "codex.session" || record.source === "claude_code.session") {
    body = body.replace(/(^|\n\n)\[我\] ([\s\S]*?)(?=\n\n\[(?:我|AI)\] |$)/g, (_all, prefix: string, value: string) => {
      const cleaned = cleanUserText(value);
      return cleaned ? `${prefix}[我] ${cleaned}` : "";
    });
  }
  // 存量原文可能来自旧版过滤器，生成新模型输入时同样走当前规则。
  return redactString(body).text;
}
