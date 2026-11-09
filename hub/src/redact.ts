import type { RecordV1 } from "../../packages/record/index.ts";

/** Shannon 熵（bit/字符）。赋值型秘密至少 16 字符、熵 >= 3.5，且含两类字符；避免误伤普通单词。 */
export function entropy(value: string): number {
  const counts = new Map<string, number>();
  for (const c of value) counts.set(c, (counts.get(c) ?? 0) + 1);
  return [...counts.values()].reduce((sum, n) => sum - n / value.length * Math.log2(n / value.length), 0);
}

export function redactString(input: string): { text: string; count: number } {
  let count = 0;
  const replace = (type: string) => { count++; return `[已脱敏:${type}]`; };
  let text = input;
  const patterns: [string, RegExp][] = [
    ["私钥", /-----BEGIN ((?:[A-Z0-9]+ )*PRIVATE KEY)-----[\s\S]*?-----END \1-----/g],
    ["AWS", /\b(?:AKIA|ASIA)[A-Z0-9]{16}\b/g],
    ["GitHub", /\b(?:gh[pors]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,})\b/g],
    ["Anthropic", /\bsk-ant-[A-Za-z0-9_-]{16,}/g],
    ["OpenAI", /\bsk-(?!ant-)[A-Za-z0-9_-]{16,}/g],
    ["Slack", /\bxox[a-z]-[A-Za-z0-9-]{10,}/g],
    ["Stripe", /\b[sr]k_(?:live|test)_[A-Za-z0-9]{16,}/g],
    ["Google", /\bAIza[0-9A-Za-z_-]{35}/g],
    ["GitLab", /\bglpat-[A-Za-z0-9_-]{20,}/g],
    ["HuggingFace", /\bhf_[A-Za-z0-9]{30,}\b/g],
    ["JWT", /\beyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]{8,}\b/g],
    // curl -H "Authorization: Bearer …" 这类命令行里最常见；只要求长度，不要求熵，Bearer 后面的值几乎总是凭据。
    ["Bearer", /(?<=\b(?:Bearer|Token)\s+)[A-Za-z0-9._~+\/-]{16,}=*/gi],
  ];
  for (const [type, pattern] of patterns) text = text.replace(pattern, () => replace(type));
  text = text.replace(/(\b[a-z][a-z0-9+.-]*:\/\/[^\s/@:]+:)([^\s/@]+)(@)/gi,
    (_, prefix, _password, suffix) => prefix + replace("URL密码") + suffix);
  text = text.replace(/((?:["']?)(?:password|passwd|pwd|token|access_token|refresh_token|api[_-]?key|secret|client_secret)["']?\s*[:=]\s*)(["']?)([A-Za-z0-9_+\/.=~%!@#$^&*?:-]{16,})\2/gi,
    (whole, prefix: string, quote: string, value: string) => {
      const classes = [/[a-z]/, /[A-Z]/, /[0-9]/, /[^A-Za-z0-9]/].filter(r => r.test(value)).length;
      return classes >= 2 && entropy(value) >= 3.5 ? prefix + quote + replace("赋值密钥") + quote : whole;
    });
  return { text, count };
}

export function redactRecord(record: RecordV1): RecordV1 {
  let count = 0;
  const visit = (value: unknown): unknown => {
    if (typeof value === "string") {
      const result = redactString(value);
      count += result.count;
      return result.text;
    }
    if (Array.isArray(value)) return value.map(visit);
    if (value && typeof value === "object") return Object.fromEntries(Object.entries(value).map(([key, v]) => [key, visit(v)]));
    return value;
  };
  const title = visit(record.title) as string;
  const body = visit(record.body) as string;
  const context = record.context === undefined ? undefined : visit(record.context) as RecordV1["context"];
  return {
    ...record, title, body, ...(context === undefined ? {} : { context }),
    redactions: (record.redactions ?? 0) + count,
    sensitivity: count && record.sensitivity === "normal" ? "redacted" : record.sensitivity,
  };
}
