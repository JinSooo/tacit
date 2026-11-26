import type { Lang } from "../i18n/language.ts";

export function cliLanguage(env: NodeJS.ProcessEnv = process.env): Lang {
  return /^zh/i.test(env.LC_ALL || env.LC_MESSAGES || env.LANG || "") ? "zh" : "en";
}

export function cliText(zh: string, en: string, lang = cliLanguage()): string {
  return lang === "zh" ? zh : en;
}
