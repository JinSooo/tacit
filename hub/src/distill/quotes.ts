/** agent-sessions 的文本格式；这里只读取已有发言标记，不从正文猜测说话人。 */
export function sessionUserTexts(source: string, body: string): string[] | null {
  if (source !== "codex.session" && source !== "claude_code.session") return null;
  const turns = [...body.matchAll(/(?:^|\n\n)\[(我|AI)\] /g)];
  return turns.flatMap((turn, index) => turn[1] === "我"
    ? [body.slice(turn.index! + turn[0].length, turns[index + 1]?.index ?? body.length).trim()].filter(Boolean)
    : []);
}

export function withUserStatements<T extends { source: string; excerpt: string }>(record: T) {
  const user = sessionUserTexts(record.source, record.excerpt);
  return { ...record, ...(user === null ? {} : { user_statements: user }) };
}

/** 必须逐字出现在所指记录中；已标明角色的 AI 会话还必须局限于一段用户发言。 */
export function groundedQuote(record: { source: string; body: string } | null | undefined, text: string): boolean {
  if (!record || !text.trim()) return false;
  const user = sessionUserTexts(record.source, record.body);
  return (user ?? [record.body]).some(turn => turn.includes(text));
}
