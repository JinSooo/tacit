import type { Lang } from "./language.ts";

export { parseLang, resolveLang, type Lang } from "./language.ts";
export { hasCjkLeakage, speechUnits, summaryLength } from "./units.ts";

const messages = {
  timeline: { zh: "时间线", en: "Timeline" },
  dayOverview: { zh: "当天概述", en: "Day overview" },
  conversation: { zh: "对话", en: "Conversation" },
  phoneRecording: { zh: "手机录音", en: "Phone recording" },
  me: { zh: "我", en: "Me" },
  speaker: { zh: "对方", en: "Speaker" },
  numberedSpeaker: { zh: "对方 {n}", en: "Speaker {n}" },
  others: { zh: "其他人", en: "Others" },
  lessThanMinute: { zh: "不到 1 分钟", en: "Less than a minute" },
} satisfies Record<string, Record<Lang, string>>;

export type MessageKey = keyof typeof messages;

export function t(lang: Lang, key: MessageKey, params?: Readonly<Record<string, string | number>>): string {
  return messages[key][lang].replace(/\{(\w+)\}/g, (placeholder, name: string) =>
    params && Object.hasOwn(params, name) ? String(params[name]) : placeholder);
}

export function plural(n: number, one: string, other: string): string {
  return n === 1 ? one : other;
}

export function speakerDisplayName(canonical: string, lang: Lang): string {
  if (lang === "zh") return canonical;
  if (canonical === "我") return t(lang, "me");
  if (canonical === "对方") return t(lang, "speaker");
  if (canonical === "其他人") return t(lang, "others");
  const numbered = /^对方 ([0-9]+)$/u.exec(canonical);
  return numbered ? t(lang, "numberedSpeaker", { n: numbered[1]! }) : canonical;
}

type DateValue = Date | number;

export function formatDate(lang: Lang, date: DateValue, style: "heading" | "short" = "short", timeZone?: string): string {
  if (lang === "en") {
    return new Intl.DateTimeFormat("en-US", style === "heading"
      ? { weekday: "long", month: "long", day: "numeric", timeZone }
      : { month: "short", day: "numeric", timeZone }).format(date);
  }
  const parts = new Intl.DateTimeFormat("zh-CN", {
    month: "numeric", day: "numeric", weekday: style === "heading" ? "long" : undefined, timeZone,
  }).formatToParts(date);
  const part = (type: Intl.DateTimeFormatPartTypes) => parts.find(p => p.type === type)?.value;
  return `${part("month")} 月 ${part("day")} 日${style === "heading" ? ` ${part("weekday")}` : ""}`;
}

export function formatTime(lang: Lang, date: DateValue, { locale, timeZone }: { locale?: string; timeZone?: string } = {}): string {
  return new Intl.DateTimeFormat(lang === "zh" ? "zh-CN" : locale, {
    hour: "2-digit", minute: "2-digit", hourCycle: lang === "zh" ? "h23" : undefined, timeZone,
  }).format(date);
}

const countFormat = new Intl.NumberFormat("en-US");

export function formatCount(lang: Lang, n: number, unit?: { zh: string; en: readonly [one: string, other: string] }): string {
  const count = countFormat.format(n);
  if (!unit) return count;
  return `${count} ${lang === "zh" ? unit.zh : plural(n, ...unit.en)}`;
}

export function formatDuration(lang: Lang, seconds: number): string {
  if (seconds < 60) return t(lang, "lessThanMinute");
  const minutes = Math.floor(seconds / 60);
  const hours = Math.floor(minutes / 60);
  const remainder = minutes % 60;
  if (lang === "zh") {
    if (!hours) return `${formatCount(lang, minutes)} 分钟`;
    return `${formatCount(lang, hours)} 小时${remainder ? ` ${remainder} 分` : ""}`;
  }
  if (!hours) return `${formatCount(lang, minutes)} min`;
  return `${formatCount(lang, hours)} hr${remainder ? ` ${remainder} min` : ""}`;
}
