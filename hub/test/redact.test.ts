import { expect, test } from "bun:test";
import { redactString, redactRecord } from "../src/redact.ts";
import { bigram } from "../src/db.ts";
import { setup, fixture } from "./helpers.ts";

// 全部为人为构造的假密钥，不含任何真实凭据。
const examples: [string, string][] = [
  ["私钥", "-----BEGIN RSA PRIVATE KEY-----\nSYNTHETICCONTENT\n-----END RSA PRIVATE KEY-----"],
  ["AWS", "AKIAABCDEFGHIJKLMNOP"],
  ["GitHub", "ghp_" + "aB3".repeat(12)],
  ["GitHub", "gho_" + "aB3".repeat(12)],
  ["GitHub", "ghs_" + "aB3".repeat(12)],
  ["GitHub", "github_pat_" + "aB3_".repeat(20)],
  ["OpenAI", "sk-proj-" + "aB3_".repeat(20)],
  ["Anthropic", "sk-ant-api03-" + "aB3_".repeat(20)],
  ["Slack", "xoxb-1234567890-abcdefghijk"],
  ["Slack", "xoxp-1234567890-abcdefghijk"],
  // 回归：以下四种在 2026-11-09 假密钥实测里漏拦。
  ["Stripe", "sk_live_" + "aB3".repeat(8)],
  ["Stripe", "rk_test_" + "aB3".repeat(8)],
  ["Google", "AIzaSy" + "aB3-".repeat(8) + "a"],
  ["GitLab", "glpat-" + "aB3_".repeat(5)],
  ["HuggingFace", "hf_" + "aB3".repeat(11)],
  ["JWT", "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiJzeW50aGV0aWMifQ.c3ludGhldGljU2lnbmF0dXJl"],
  ["URL密码", "https://fake-user:synth-pass@example.invalid/path"],
  // 回归：curl 命令里的 Bearer 头曾经漏拦（2026-11-08 验收发现）。
  ["Bearer", `curl -H "Authorization: Bearer ${"aB3.".repeat(6)}" https://example.invalid`],
  ...["password", "token", "api_key", "secret", "client_secret"].map(key => ["赋值密钥", `${key}=aB3cD4eF5gH6iJ7kL8mN9pQ0`] as [string, string]),
];
for (const [i, [type, input]] of examples.entries()) test(`脱敏正例 ${i}：${type}`, () => {
  const result = redactString(input);
  expect(result.count).toBe(1);
  expect(result.text).toContain(`[已脱敏:${type}]`);
  expect(result.text).not.toContain(input);
});

test("普通 SHA、UUID、中文、单词和低熵赋值不误伤", () => {
  for (const text of [
    "12ab34cd56ef78ab90cd12ef34ab56cd78ef90ab", "b278b7dc-d7ad-4fe8-a3de-8d5a9d6f0123",
    "这是一段很长的中文文字用来说明普通的日常讨论不应该被当作密钥进行替换而丢失内容",
    "documentation internationalization base64 image ordinaryword",
    "token=aaaaaaaaaaaaaaaaaaaaaaaa", "password=internationalization",
    "from huggingface_hub import hf_hub_download", "task_live_update_handler",
  ]) expect(redactString(text)).toEqual({ text, count: 0 });
});

test("连续网址保留，最后一个地址后的合成凭据仍然拦截", () => {
  const links = ["https://example.invalid/path-1", "https://example.invalid/path-2", "https://example.invalid/login-3"];
  const list = links.join("\n");
  expect(redactString(list)).toEqual({ text: list, count: 0 });
  const account = "fixture-user", password = "Fixture9-Only-Pass";
  expect(redactString([list, account, password].join("\n"))).toEqual({ text: [list, account, "[已脱敏:密码]"].join("\n"), count: 1 });
});

test("递归处理 context 的字符串，累加数量且 private 不降级", () => {
  const key = examples[2]![1];
  const r = fixture({ title: key, body: key, context: { window: key, extra: { nested: [key, { value: key }] } }, redactions: 2 });
  expect(redactRecord(r).redactions).toBe(7);
  expect(redactRecord(r).sensitivity).toBe("redacted");
  expect(redactRecord({ ...r, sensitivity: "private" }).sensitivity).toBe("private");
  expect(r.body).toBe(key);
});

test("实际解密后的 records 与 FTS 表中没有原始密钥", () => {
  const ctx = setup();
  try {
    for (const [, secret] of examples) {
      const record = fixture({ title: secret.slice(0, 180), body: secret, context: { extra: { value: secret } } });
      expect(ctx.db.ingest([record]).accepted).toBe(1);
    }
    const stored = JSON.stringify(ctx.db.db.prepare("SELECT * FROM records").all());
    const indexed = JSON.stringify(ctx.db.db.prepare("SELECT * FROM records_fts").all());
    for (const [, secret] of examples) {
      expect(stored).not.toContain(secret);
      expect(indexed).not.toContain(secret);
    }
  } finally { ctx.cleanup(); }
});

test("赋值型密钥包含标点和 JSON 引号也能拦截", () => {
  for (const input of ['password="aB3!cD4@eF5#gH6$iJ7%kL8";', '{"api_key":"aB3!cD4@eF5#gH6$iJ7%kL8"}']) {
    expect(redactString(input).count).toBe(1);
    expect(redactString(input).text).not.toContain("aB3!");
  }
});

test("剪贴板单词型密码在写入 records 和 FTS 前拦截，其他来源不误伤", () => {
  const ctx = setup();
  try {
    const passwords = ["Qw#58kLp2z", "Aa@1234567", "Abc12345", "abc@1234", "Ab1" + "x".repeat(61)];
    for (const secret of passwords) {
      for (const source of ["mac.clipboard", "mac.screen", "mac.browser", "codex.session"]) {
        const record = fixture({ source, source_ref: crypto.randomUUID(), title: `复制 · ${secret}`, body: ` \n${secret}\t`,
          context: { app: "com.tencent.xinWeChat" }, redactions: 2 });
        expect(ctx.db.ingest([record]).accepted).toBe(1);
        const stored = ctx.db.get(record.id)!;
        if (source === "mac.clipboard") {
          expect(stored.title).toBe("复制 · [已脱敏:密码]");
          expect(stored.body).toBe(" \n[已脱敏:密码]\t");
          expect(stored.title).not.toContain(secret);
          expect(stored.body).not.toContain(secret);
          expect(stored.redactions).toBe(4);
          expect(stored.sensitivity).toBe("redacted");
        } else {
          expect(stored.title).toBe(record.title);
          expect(stored.body).toBe(record.body);
          expect(stored.redactions).toBe(2);
          expect(stored.sensitivity).toBe("normal");
        }
      }
    }
    const rows = ctx.db.db.prepare("SELECT title,body FROM records WHERE source='mac.clipboard'").all();
    // FTS 使用 bigram 编码，比较已脱敏正文，而不只检查原始密码是否存在。
    const indexed = ctx.db.db.prepare("SELECT title,body FROM records_fts WHERE rowid IN (SELECT rowid FROM records WHERE source='mac.clipboard')").all();
    expect(rows).toHaveLength(passwords.length);
    expect(indexed).toHaveLength(passwords.length);
    for (const row of indexed) expect(row).toEqual({ title: bigram("复制 · [已脱敏:密码]"), body: bigram(" \n[已脱敏:密码]\t") });
    for (const secret of passwords) expect(JSON.stringify([...rows, ...indexed])).not.toContain(secret);
  } finally { ctx.cleanup(); }
});

test("剪贴板普通文字、地址、路径和边界长度不按密码拦截", () => {
  const ctx = setup();
  try {
    for (const text of ["hello-world", "https://example.com/a?b=1", "https://Example.com/A?b=1", "user@example.com",
      "User1@example.com", "/Users/a/b.txt", "/Users/A1/b.txt", "C:\\Users\\A1\\b.txt", "./A1/b.txt", "~/A1/b.txt",
      "18000000000", "Password", "Ab1 short sentence", "Ab1\nnext", "Ab1\tword", "Ab1xxxx", "Ab1" + "x".repeat(62)]) {
      const record = fixture({ source: "mac.clipboard", title: `复制 · ${text}`, body: text });
      expect(ctx.db.ingest([record]).accepted).toBe(1);
      expect(ctx.db.get(record.id)).toMatchObject({ title: record.title, body: text, redactions: 0, sensitivity: "normal" });
    }
  } finally { ctx.cleanup(); }
});

test("剪贴板密码规则不误伤 UUID、文件名、代码标识符和带中文的名字（2026-11-12 正式库复核的误判形状）", () => {
  const clip = (body: string) => redactRecord({ ...fixture(), source: "mac.clipboard", title: `复制 · ${body}`, body });
  // 合成样例，形状照正式库里的误判：UUID、kebab 版本串、带中文的文件名和名字、snake 标识符、带扩展名的文件
  for (const body of ["3f2a9c1e-7b4d-4e8a-9c2f-1a2b3c4d5e6f", "abc-def-12-34", "a-1.2-b", "A9运营期需求清单.xlsx", "饭耳-Ab全天录音智能体",
                      "Foo_bar9baz", "FOO_BAR1.2.3", "Report-xY(2).pdf", "AbCd-Ef"]) {
    expect(clip(body).body).toBe(body);
  }
  for (const body of ["aBcD1$", "Qw#58kLp2z", "Ab@1234567", "xY9$kLmN"]) {
    if (body.length >= 8) expect(clip(body).body).toBe("[已脱敏:密码]");
  }
});

test("people 和 media 中的自由文本也在入库前脱敏", () => {
  const ctx = setup(), key = "ghp_" + "aB3".repeat(12);
  try {
    const record = fixture({ people: [key], media: [{ path: `https://user:synthetic-password@example.invalid/${key}`, kind: "audio" }] });
    expect(ctx.db.ingest([record]).accepted).toBe(1);
    const stored = ctx.db.get(record.id)!;
    expect(JSON.stringify(stored)).not.toContain(key); expect(JSON.stringify(stored)).not.toContain("synthetic-password");
    expect(stored.redactions).toBe(3); expect(stored.sensitivity).toBe("redacted");
  } finally { ctx.cleanup(); }
});

test("Basic credentials and single-component URL user information are redacted", () => {
  for (const header of ["Authorization", "Proxy-Authorization"]) {
    expect(redactString(`${header}: Basic dTpw`)).toEqual({
      text: `${header}: Basic [已脱敏:Basic]`, count: 1,
    });
  }
  expect(redactString("Connecting with Basic ZmFrZS1sb2dpbjpzYW1wbGU=")).toEqual({
    text: "Connecting with Basic [已脱敏:Basic]", count: 1,
  });
  expect(redactString("http://example-access@proxy.example.invalid:8080/path")).toEqual({
    text: "http://[已脱敏:URL凭据]@proxy.example.invalid:8080/path", count: 1,
  });
  expect(redactString("https://example.invalid/path/user@example.invalid")).toEqual({
    text: "https://example.invalid/path/user@example.invalid", count: 0,
  });
});

// 回归（第 2 轮审查）：普通英文里的 Basic 和 ssh 用户名不是凭据。
test("plain English after Basic and ssh user names stay readable", () => {
  for (const text of ["Use basic authentication for the demo", "Basic configuration steps", "basic implementation notes",
    "Basic QWxwaGFCZXRhR2FtbWE=", "ssh://git@github.com/example/plugin.git", "git@github.com:example/plugin.git"]) {
    expect(redactString(text)).toEqual({ text, count: 0 });
  }
});
