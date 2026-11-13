/** Leave a complete token for the ingestion redactor; never keep a credential cut in half. */
export function capturePrefix(text: string, limit: number, truncated = text.length > limit): string {
  if (!truncated) return text;
  let end = Math.max(0, limit);
  if (end >= text.length || /[!-~]/.test(text[end]!)) {
    while (end > 0 && /[!-~]/.test(text[end - 1]!)) end--;
  }
  if (/[\uD800-\uDBFF]/.test(text[end - 1] ?? "")) end--;
  let prefix = text.slice(0, end);
  for (const match of prefix.matchAll(/-----BEGIN ((?:[A-Z0-9]+ )*PRIVATE KEY)-----/g)) {
    if (!prefix.slice(match.index! + match[0].length).includes(`-----END ${match[1]}-----`)) {
      prefix = prefix.slice(0, match.index); break;
    }
  }
  return prefix;
}
