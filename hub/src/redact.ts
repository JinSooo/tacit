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
    ["Basic", /(?<=\b(?:Proxy-)?Authorization:[ \t]*Basic[ \t]+)[A-Za-z0-9+/]+=*/gi],
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
  // 没有 Authorization 前缀的 "Basic <值>"：只有值确实是 base64 且解出“用户:密码”时才算凭据，
  // 否则 "basic authentication" 这类普通英文会被误遮（2026-11-27 第 2 轮审查）。
  text = text.replace(/(?<=\bBasic[ \t]+)[A-Za-z0-9+/]{12,}={0,2}(?![A-Za-z0-9+/=])/g, value => {
    if (value.length % 4 !== 0) return value;
    let decoded = "";
    try { decoded = Buffer.from(value, "base64").toString("utf8"); } catch { return value; }
    return decoded.includes(":") && !/[\u0000-\u001f\u007f\ufffd]/.test(decoded) ? replace("Basic") : value;
  });
  // 地图瓦片请求常只采到 DataServer?...&tk=…；限定查询参数和 32 位十六进制格式，普通哈希不动。
  text = text.replace(/([?&](?:amp;)?tk=)[a-f0-9]{32}(?![a-f0-9])/gi,
    (_, prefix: string) => prefix + replace("地图密钥"));
  text = text.replace(/(\b[a-z][a-z0-9+.-]*:\/\/[^\s/@:]+:)([^\s/@]+)(@)/gi,
    (_, prefix, _password, suffix) => prefix + replace("URL密码") + suffix);
  // 单段用户信息只在网页、代理和 WebSocket 地址里当凭据；ssh://git@host 的 git 是用户名，不遮。
  text = text.replace(/(\b(?:https?|wss?|socks(?:4a?|5h?)?):\/\/)[^\s\/@:?#]+(@)(?=[^\s\/@?#])/gi,
    (_, prefix, suffix) => prefix + replace("URL凭据") + suffix);
  text = text.replace(/((?:["']?)(?:password|passwd|pwd|token|access_token|refresh_token|api[_-]?key|secret|client_secret)["']?\s*[:=]\s*)(["']?)([A-Za-z0-9_+\/.=~%!@#$^&*?:-]{16,})\2/gi,
    (whole, prefix: string, quote: string, value: string) => {
      const classes = [/[a-z]/, /[A-Z]/, /[0-9]/, /[^A-Za-z0-9]/].filter(r => r.test(value)).length;
      return classes >= 2 && entropy(value) >= 3.5 ? prefix + quote + replace("赋值密钥") + quote : whole;
    });
  // 明确的账号/密码标签不靠长密钥熵值判断；屏幕和聊天中常出现短密码或纯数字密码。
  text = text.replace(/((?:账号|帐号|账户|用户名|\busername|\baccount)[ \t]*(?:[/／][ \t]*)?(?:密码|口令|password|passwd|pwd)[ \t]*(?:是|为)?[ \t]*[:：=][ \t\r\n]*)([^\s/／:：=]{1,128}(?:[ \t]*[/／][ \t]*|[ \t]+|\r?\n[ \t]*))([A-Za-z0-9_+/.=~%!@#$^&*?:-]{1,128})/gi,
    (_whole, label: string) => label + replace("账号密码"));
  text = text.replace(/((?:\b(?:password|passwd|pwd)\b|密码|口令)["']?[ \t]*(?:[:：=]|为[:：]?|是[:：]?|\r?\n)[ \t]*)(["']?)([A-Za-z0-9_+/.=~%!@#$^&*?:-]{4,128})\2/gi,
    (whole, label: string, quote: string, value: string) => {
      const classes = [/[a-z]/, /[A-Z]/, /[0-9]/, /[^A-Za-z0-9]/].filter(r => r.test(value)).length;
      return classes >= 2 || /^\d+$/.test(value) ? label + quote + replace("密码") + quote : whole;
    });
  // 登录地址后直接粘贴“用户名 密码”，包括 OCR 把 https: 拆成多行的情况；连续网址是访问列表。
  text = text.replace(/(https?\\?[ \t\r\n]*:[ \t\r\n]*\/\/[^\s]+[ \t\r\n]+)((?!https?:\/\/)[^\s]{1,64})([ \t\r\n]+)((?!https?:\/\/)[A-Za-z0-9_+/.=~%!@#$^&*?:-]{8,128})/gi,
    (whole, url: string, user: string, space: string, value: string) => {
      const classes = [/[a-z]/, /[A-Z]/, /[0-9]/, /[^A-Za-z0-9]/].filter(r => r.test(value)).length;
      return classes >= 3 ? url + user + space + replace("密码") : whole;
    });
  // 登录表单或账号对话把值单独放一行；沿用剪贴板密码判别，并要求附近有明确凭据语境。
  const context = text;
  text = text.replace(/(^|\n)([ \t]*)([^\s\n]+)([ \t]*)(?=\r?\n|$)/g,
    (whole, line: string, indent: string, value: string, suffix: string, offset: number) => {
      const nearby = context.slice(Math.max(0, offset - 300), offset + whole.length + 100);
      return isClipboardPassword(value) && /账号|帐号|用户名|密码|口令|\b(?:password|login|sign in)\b/i.test(nearby)
        ? line + indent + replace("密码") + suffix : whole;
    });
  return { text, count };
}

/** 只用于剪贴板正文整体；普通文本里的标识符不能用这个启发式。 */
function isClipboardPassword(value: string): boolean {
  // 密码只由可打印 ASCII 组成；带中文的是名字或句子（2026-11-12 正式库复核：26 条命中里一半是文件名、UUID、代码标识符）。
  if (value.length < 8 || value.length > 64 || !/^[\x21-\x7e]+$/.test(value)) return false;
  if (/^(?:[a-z][a-z0-9+.-]*:\/\/|www\.)/i.test(value)
    || /^[^@]+@[^@]+\.[^@]+$/.test(value)
    || /^(?:[a-z]:[\\/]|[\\/]|~[\\/]|\.{1,2}[\\/])/i.test(value)
    || /^[^\\/:*?"<>|]+(?:[\\/][^\\/:*?"<>|]+)+$/.test(value)
    || /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(value)
    // 文件名（结尾是扩展名）、只用 - _ . 连接的标识符（kebab、snake、版本号）不算密码。
    || /\.[A-Za-z][A-Za-z0-9]{0,5}$/.test(value)
    || /^[A-Za-z0-9]+(?:[-_.][A-Za-z0-9]+)+$/.test(value)
    || /^(?:[A-Za-z]+|[0-9]+)$/.test(value)) return false;
  return [/[A-Z]/, /[a-z]/, /[0-9]/, /[^A-Za-z0-9]/].filter(pattern => pattern.test(value)).length >= 3;
}

export function redactRecord(record: RecordV1): RecordV1 {
  let count = 0;
  const candidate = record.source === "mac.clipboard" ? record.body.trim() : "";
  const password = isClipboardPassword(candidate) ? candidate : null;
  const redactClipboard = (text: string): string => {
    if (!password) return text;
    const parts = text.split(password);
    count += parts.length - 1;
    return parts.join("[已脱敏:密码]");
  };
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
  const title = redactClipboard(visit(record.title) as string);
  const body = redactClipboard(visit(record.body) as string);
  const context = record.context === undefined ? undefined : visit(record.context) as RecordV1["context"];
  const people = record.people === undefined ? undefined : visit(record.people) as RecordV1["people"];
  const media = record.media === undefined ? undefined : visit(record.media) as RecordV1["media"];
  return {
    ...record, title, body, ...(record.source_ref == null ? {} : { source_ref: visit(record.source_ref) as string }), ...(people === undefined ? {} : { people }), ...(media === undefined ? {} : { media }), ...(context === undefined ? {} : { context }),
    redactions: (record.redactions ?? 0) + count,
    sensitivity: count && record.sensitivity === "normal" ? "redacted" : record.sensitivity,
  };
}
