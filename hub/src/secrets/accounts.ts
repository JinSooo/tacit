import { SecretError } from "./errors.ts";

/** 模型 API key 沿用设置页的可见 ASCII 规则；security -i 按双引号解析一行，不能含引号和反斜杠（2026-11-10 实测）。 */
export const PROVIDER_KEY_PATTERN = /^[\x21\x23-\x5b\x5d-\x7e]{8,1024}$/;

interface Rule { account: RegExp; value: RegExp; macOnly?: boolean }

// 账号名白名单（docs/contracts.md 6.11.3）。value 只在写入时校验，读取原样返回。
const RULES: Rule[] = [
  { account: /^db-key$/, value: /^[0-9a-f]{32,128}$/ },
  { account: /^agent-(?:device|context-cache)-key$/, value: /^[0-9a-f]{64}$/, macOnly: true },
  { account: /^device-key$/, value: /^[0-9a-f]{64}$/ },
  { account: /^provider:[a-z][a-z0-9-]{0,39}$/, value: PROVIDER_KEY_PATTERN },
  { account: /^relay-space-[A-Za-z0-9_-]{22}$/, value: /^[A-Za-z0-9_-]{43}$/ },
  // 音频密钥只属于 Mac 采集端和本机钥匙串，服务端的 sealed-file 不持有。
  { account: /^audio-key-hex$/, value: /^[0-9a-f]{32,128}$/, macOnly: true },
];

export function ruleOf(account: string): Rule {
  const rule = typeof account === "string" ? RULES.find(r => r.account.test(account)) : undefined;
  if (!rule) throw new SecretError("invalid_account");
  return rule;
}

/** 校验账号名；backend 为 sealed-file 时拒绝只属于 Mac 的账号。 */
export function checkAccount(account: string, backend: "keychain" | "sealed-file"): void {
  if (ruleOf(account).macOnly && backend !== "keychain") throw new SecretError("backend_unsupported");
}

export function checkValue(account: string, value: string): void {
  if (typeof value !== "string" || !ruleOf(account).value.test(value)) throw new SecretError("invalid_value");
}

export const providerAccount = (provider: string) => { const a = `provider:${provider}`; ruleOf(a); return a; };
export const relayAccount = (space: string) => { const a = `relay-space-${space}`; ruleOf(a); return a; };
