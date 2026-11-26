// 通用设置存在 distill_state 表的 general_settings 键里，中枢和提炼进程共用。
// 中枢注入时、提炼进程每轮生命周期步骤都现读，改完不需要重启。
import { InputError, type HubDB } from "./db.ts";
import { parseLang, type Lang } from "./i18n/language.ts";

const TIMINGS = {
  timeline_polish: ["after_segment", "hourly", "nightly"],
  timeline_overview: ["hourly", "every_3h", "nightly"],
} as const;
export const GENERAL_RANGES = {
  inject_tokens: [200, 4000], ask_done_days: [1, 30], archive_days: [1, 90], daily_token_limit: [1, 1_000_000_000],
} as const;
export interface GeneralSettings {
  inject_tokens: number; ask_done_days: number; archive_days: number;
  timeline_polish: typeof TIMINGS.timeline_polish[number];
  timeline_overview: typeof TIMINGS.timeline_overview[number];
  daily_token_limit: number | null;
  language: Lang;
}
export const GENERAL_DEFAULTS: GeneralSettings = {
  inject_tokens: 800, ask_done_days: 3, archive_days: 7,
  timeline_polish: "after_segment", timeline_overview: "hourly", daily_token_limit: null,
  language: parseLang(process.env.TACIT_LANGUAGE) ?? "en",
};
const KEY = "general_settings";
const FIELDS = Object.keys(GENERAL_DEFAULTS) as (keyof GeneralSettings)[];
function invalid(field: keyof GeneralSettings, value: unknown): string | undefined {
  if (field === "language") return value === "zh" || value === "en" ? undefined : 'language 必须是 "zh" 或 "en"';
  if (field === "timeline_polish" || field === "timeline_overview") {
    const options = TIMINGS[field];
    return options.some(option => option === value) ? undefined : `${field} 必须是 ${options.join("、")} 之一`;
  }
  if (field === "daily_token_limit" && value === null) return;
  const [min, max] = GENERAL_RANGES[field];
  if (typeof value === "number" && Number.isInteger(value) && value >= min && value <= max) return;
  return `${field} 必须是 ${min}–${max} 的整数${field === "daily_token_limit" ? "或 null" : ""}`;
}

function stored(hub: HubDB): Record<string, unknown> {
  const row = hub.db.prepare("SELECT v FROM distill_state WHERE k=?").get(KEY) as { v: string } | undefined;
  if (!row) return {};
  try { const v = JSON.parse(row.v); return v && typeof v === "object" && !Array.isArray(v) ? v : {}; } catch { return {}; }
}

function saveGeneral(hub: HubDB, settings: Record<string, unknown>): void {
  hub.db.prepare("INSERT INTO distill_state VALUES(?,?) ON CONFLICT(k) DO UPDATE SET v=excluded.v").run(KEY, JSON.stringify(settings));
}

/** Only called from the database initialization transaction. */
export function initializeGeneralLanguage(hub: HubDB, existing: boolean): void {
  const { changes } = hub.db.prepare("INSERT OR IGNORE INTO distill_state(k,v) VALUES('general_language_initialized','true')").run();
  if (!changes || !existing) return;
  const settings = stored(hub);
  if (!Object.hasOwn(settings, "language")) saveGeneral(hub, { ...settings, language: "zh" });
}

/** 没设过或存的值不合法的字段用默认值。 */
export function readGeneral(hub: HubDB): GeneralSettings {
  const s = stored(hub);
  return Object.fromEntries(FIELDS.map(f => [f, invalid(f, s[f]) ? GENERAL_DEFAULTS[f] : s[f]])) as unknown as GeneralSettings;
}

/** 只改传入的字段；未知字段、空对象、越界或非整数都拒绝，整份不写。 */
export function updateGeneral(hub: HubDB, value: unknown): GeneralSettings {
  if (!value || typeof value !== "object" || Array.isArray(value)) throw new InputError("请求体必须是对象");
  const body = value as Record<string, unknown>;
  const keys = Object.keys(body);
  const unknown = keys.filter(k => !FIELDS.includes(k as keyof GeneralSettings));
  if (unknown.length) throw new InputError(`不认识的设置项：${unknown.slice(0, 5).map(k => k.slice(0, 40)).join("、")}`);
  if (!keys.length) throw new InputError("至少提供一个设置项");
  for (const f of keys as (keyof GeneralSettings)[]) {
    const error = invalid(f, body[f]);
    if (error) throw new InputError(error);
  }
  return hub.db.transaction(() => {
    const next = { ...readGeneral(hub), ...body } as GeneralSettings;
    const { language, ...otherSettings } = next;
    // Keep a fresh Hub on its default until a client explicitly sets the language.
    saveGeneral(hub, { ...stored(hub), ...otherSettings, ...(keys.includes("language") ? { language } : {}) });
    return next;
  }).immediate();
}

export function readTimelineSettings(hub: HubDB) {
  const settings = readGeneral(hub);
  return { polish: settings.timeline_polish, overview: settings.timeline_overview };
}
