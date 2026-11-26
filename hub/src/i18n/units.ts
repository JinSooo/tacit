import type { Lang } from "./language.ts";

const LATIN_RUN = /[A-Za-z0-9]+(?:[._\-/+:][A-Za-z0-9]+)*/gu;
// Require a letter so shared kana marks such as ー count, but punctuation such as ・ does not.
const CJK_LETTER = /(?=\p{L})[\p{scx=Han}\p{scx=Hiragana}\p{scx=Katakana}\p{scx=Hangul}]|〇/u;
const LATIN_ALNUM = /(?:\p{sc=Latin}\p{M}*|[0-9０-９])+/u;
const SPEECH_TOKEN = new RegExp(`${CJK_LETTER.source}|${LATIN_ALNUM.source}`, "gu");
const EN_SUMMARY_TOKEN = new RegExp(
  `${CJK_LETTER.source}|${LATIN_ALNUM.source}(?:[._\\-/+:]${LATIN_ALNUM.source})*`,
  "gu",
);

export function speechUnits(text: string): number {
  let units = 0;
  for (const token of text.match(SPEECH_TOKEN) ?? []) {
    units += CJK_LETTER.test(token) ? 1 : 2;
  }
  return units;
}

export function summaryLength(text: string, lang: Lang = "zh"): number {
  if (lang === "zh") return Array.from(text.replace(LATIN_RUN, "w").replace(/\s+/gu, "")).length;
  return text.match(EN_SUMMARY_TOKEN)?.length ?? 0;
}

export function hasCjkLeakage(text: string, threshold = 0.3): boolean {
  const characters = Array.from(text.replace(/\s+/gu, ""));
  const ideographs = characters.filter(char => /\p{Unified_Ideograph}|[〇\uF900-\uFA6D\uFA70-\uFAD9]/u.test(char)).length;
  return characters.length > 0 && ideographs / characters.length > threshold;
}
