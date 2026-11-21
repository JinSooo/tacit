import { parseAndroidTranscript } from "../conversations.ts";

/** 只读取已有发言标记，null 表示没有可用的角色约定。 */
export function knownUserTexts(source: string, body: string): string[] | null {
  if (source === "android.notification") return [];
  if (source === "android.audio") return parseAndroidTranscript(body).filter(turn => turn.label === "我").map(turn => turn.text);
  if (source !== "codex.session" && source !== "claude_code.session") return null;
  const turns = [...body.matchAll(/(?:^|\n\n)\[(我|AI)\] /g)];
  return turns.flatMap((turn, index) => turn[1] === "我"
    ? [body.slice(turn.index! + turn[0].length, turns[index + 1]?.index ?? body.length).trim()].filter(Boolean)
    : []);
}

export function withUserStatements<T extends { source: string; excerpt: string }>(record: T) {
  const user = knownUserTexts(record.source, record.excerpt);
  return { ...record, ...(user === null ? {} : { user_statements: user }) };
}

/** 必须逐字出现在所指记录中；有角色约定时还必须局限于一段用户发言。 */
export function groundedQuote(record: { source: string; body: string } | null | undefined, text: string): boolean {
  if (!record || !text.trim()) return false;
  const user = knownUserTexts(record.source, record.body);
  return (user ?? [record.body]).some(turn => turn.includes(text));
}
