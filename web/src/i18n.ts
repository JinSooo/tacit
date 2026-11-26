import type { Lang } from "../../hub/src/i18n/language.ts";
export type { Lang };

export function browserLanguage(languages = globalThis.navigator?.languages ?? []): Lang {
  return /^zh/i.test(languages[0] ?? "") ? "zh" : "en";
}

export function statusLanguage(language: unknown, fallback: Lang): Lang {
  return language === "zh" || language === "en" ? language : fallback;
}

export function englishLocale(): string {
  const language = globalThis.navigator?.languages?.[0];
  if (!language) return "en-US";
  const region = new Intl.Locale(language).region;
  return region ? `en-${region}` : "en-US";
}

export const statusPageCopy = {
  zh: { title: "Tacit 详细状态", open: "请从 Tacit 打开状态页", instructions: "在 Tacit 的“设置 → 后台与连接”里点“在浏览器中打开”。" },
  en: { title: "Tacit status", open: "Open the status page from Tacit", instructions: "In Tacit, go to Settings → Background service & connections, then choose Open in browser." },
};
