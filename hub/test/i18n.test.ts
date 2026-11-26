import { expect, test } from "bun:test";
import speechFixtures from "../../scripts/fixtures/i18n/speech-units.json";
import {
  formatCount, formatDate, formatDuration, formatTime, hasCjkLeakage, parseLang, plural, resolveLang,
  speakerDisplayName, speechUnits, summaryLength, t,
} from "../src/i18n/index.ts";
import { summaryLength as legacySummaryLength } from "../src/distill/prompts.ts";

test("stored languages are explicit, while locale preferences resolve by tag and weight", () => {
  expect(parseLang("zh")).toBe("zh");
  expect(parseLang("en")).toBe("en");
  for (const input of [undefined, null, "auto", "ZH", "zh-Hans", "en ", ""]) expect(parseLang(input)).toBeNull();
  expect(resolveLang("ZH-Hant-TW")).toBe("zh");
  expect(resolveLang("zh-Hans-CN,en;q=0.9")).toBe("zh");
  expect(resolveLang("en-GB;q=0.5, zh-CN;q=0.9")).toBe("zh");
  expect(resolveLang("en-GB, zh;q=1")).toBe("en");
  expect(resolveLang("zh;q=0, fr")).toBe("en");
  expect(resolveLang("fr", "zh")).toBe("en");
  expect(resolveLang("*", "zh")).toBe("zh");
  expect(resolveLang(null, "zh")).toBe("zh");
  expect(resolveLang()).toBe("en");
});

test("messages interpolate parameters and speaker display only translates canonical labels", () => {
  expect(t("zh", "timeline")).toBe("时间线");
  expect(t("en", "timeline")).toBe("Timeline");
  expect(t("en", "numberedSpeaker", { n: 2 })).toBe("Speaker 2");
  expect(t("zh", "numberedSpeaker", { n: 2 })).toBe("对方 2");
  expect(plural(1, "activity", "activities")).toBe("activity");
  expect(plural(0, "activity", "activities")).toBe("activities");

  for (const [original, translated] of Object.entries({
    我: "Me", 对方: "Speaker", "对方 12": "Speaker 12", 其他人: "Others",
    "对方 许同学": "对方 许同学", "周同学": "周同学", Alex: "Alex", "[我]": "[我]",
  })) {
    expect(speakerDisplayName(original, "en")).toBe(translated);
    expect(speakerDisplayName(original, "zh")).toBe(original);
  }
});

test("formats date, clock, duration and count with the UI conventions", () => {
  const date = new Date("2025-11-26T12:45:00Z");
  expect(formatDate("en", date, "heading", "UTC")).toBe("Wednesday, November 26");
  expect(formatDate("en", date, "short", "UTC")).toBe("Nov 26");
  expect(formatDate("zh", date, "heading", "UTC")).toBe("11 月 26 日 星期三");
  expect(formatDate("zh", date, "short", "UTC")).toBe("11 月 26 日");
  expect(formatTime("en", date, { locale: "en-US", timeZone: "UTC" })).toBe("12:45 PM");
  expect(formatTime("en", date, { locale: "en-GB", timeZone: "Asia/Taipei" })).toBe("20:45");
  expect(formatTime("zh", date, { locale: "en-US", timeZone: "Asia/Taipei" })).toBe("20:45");
  expect(formatTime("zh", Date.UTC(2025, 10, 26), { timeZone: "UTC" })).toBe("00:00");

  for (const [seconds, zh, en] of [
    [0, "不到 1 分钟", "Less than a minute"],
    [59, "不到 1 分钟", "Less than a minute"],
    [60, "1 分钟", "1 min"],
    [3600, "1 小时", "1 hr"],
    [5680, "1 小时 34 分", "1 hr 34 min"],
  ] as const) {
    expect(formatDuration("zh", seconds)).toBe(zh);
    expect(formatDuration("en", seconds)).toBe(en);
  }
  const record = { zh: "条", en: ["record", "records"] } as const;
  expect(formatCount("en", 1, record)).toBe("1 record");
  expect(formatCount("en", 1234, record)).toBe("1,234 records");
  expect(formatCount("zh", 1234, record)).toBe("1,234 条");
});

for (const { text, units } of speechFixtures) {
  test(`speech units for ${JSON.stringify(text)}`, () => expect(speechUnits(text)).toBe(units));
}

test("Chinese summary length keeps the legacy formula and English ignores punctuation", () => {
  for (const text of [...speechFixtures.map(row => row.text), "Tacit v1.2: 今天🙂！", "a:b+c / agent/foo", "café。"]) {
    expect(summaryLength(text)).toBe(legacySummaryLength(text));
    expect(summaryLength(text, "zh")).toBe(legacySummaryLength(text));
  }
  expect(summaryLength("Tacit v1.2: 今天🙂！", "zh")).toBe(7);
  expect(summaryLength("Tacit v1.2: 今天🙂！", "en")).toBe(4);
  expect(summaryLength("?! 。 …", "en")).toBe(0);
  expect(summaryLength("Café、かな、한글", "en")).toBe(5);
});

test("leakage uses ideographs as a proportion of non-whitespace code points", () => {
  expect(hasCjkLeakage("abc def g 中 文 字")).toBe(false);
  expect(hasCjkLeakage("abcdef 𠮷中文")).toBe(true);
  expect(hasCjkLeakage("中文 a!", 0.5)).toBe(false);
  expect(hasCjkLeakage("中文 a!", 0.49)).toBe(true);
  expect(hasCjkLeakage("かな・한글")).toBe(false);
  expect(hasCjkLeakage(" \n")).toBe(false);
});
