import type { RecordV1 } from "../../../packages/record/index.ts";
import { cleanUserText } from "../../../plugins/agent-sessions/filters.ts";
import { redactString } from "../redact.ts";
import { createHash } from "node:crypto";

/** 只把同一仓库、同一提交且正文一致的副本当成重复；修正或不同内容不能吞掉。 */
export function gitMaterialKey(record: Pick<RecordV1, "source" | "source_ref" | "body" | "context" | "sensitivity">, repo = record.context?.repo): string | null {
  const hash = record.context?.extra?.hash;
  if (record.source !== "mac.git" || !repo || typeof hash !== "string" || !/^[a-f0-9]{40,64}$/i.test(hash)) return null;
  return JSON.stringify([repo, hash, record.sensitivity, createHash("sha256").update(record.body).digest("hex")]);
}

export function uniqueMaterials<T extends Pick<RecordV1, "source" | "source_ref" | "body" | "context" | "sensitivity">>(records: T[], canonicalRepo: (repo: string) => string = repo => repo, seen = new Set<string>()): T[] {
  return records.filter(r => {
    const key = gitMaterialKey(r, r.context?.repo ? canonicalRepo(r.context.repo) : undefined);
    if (!key) return true;
    if (seen.has(key)) return false;
    seen.add(key); return true;
  });
}

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
