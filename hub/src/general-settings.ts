// 通用设置：自动注入上限、多少使用天后问"做完了吗"、问后多少使用天自动归档。
// 存在 distill_state 表的 general_settings 键里（中枢和提炼进程共用的库，不需要迁移）；
// 中枢注入时、提炼进程每轮生命周期步骤都现读，改完不需要重启。
import { InputError, type HubDB } from "./db.ts";

export interface GeneralSettings { inject_tokens: number; ask_done_days: number; archive_days: number }
export const GENERAL_DEFAULTS: GeneralSettings = { inject_tokens: 800, ask_done_days: 3, archive_days: 7 };
export const GENERAL_RANGES: Record<keyof GeneralSettings, readonly [number, number]> = {
  inject_tokens: [200, 4000], ask_done_days: [1, 30], archive_days: [1, 90],
};
const KEY = "general_settings";
const FIELDS = Object.keys(GENERAL_DEFAULTS) as (keyof GeneralSettings)[];
const valid = (field: keyof GeneralSettings, value: unknown): value is number =>
  typeof value === "number" && Number.isInteger(value) && value >= GENERAL_RANGES[field][0] && value <= GENERAL_RANGES[field][1];

function stored(hub: HubDB): Record<string, unknown> {
  const row = hub.db.prepare("SELECT v FROM distill_state WHERE k=?").get(KEY) as { v: string } | undefined;
  if (!row) return {};
  try { const v = JSON.parse(row.v); return v && typeof v === "object" && !Array.isArray(v) ? v : {}; } catch { return {}; }
}

/** 没设过或存的值不合法的字段用默认值。 */
export function readGeneral(hub: HubDB): GeneralSettings {
  const s = stored(hub);
  return Object.fromEntries(FIELDS.map(f => [f, valid(f, s[f]) ? s[f] : GENERAL_DEFAULTS[f]])) as unknown as GeneralSettings;
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
    if (!valid(f, body[f])) throw new InputError(`${f} 必须是 ${GENERAL_RANGES[f][0]}–${GENERAL_RANGES[f][1]} 的整数`);
  }
  return hub.db.transaction(() => {
    const next = { ...readGeneral(hub), ...body } as GeneralSettings;
    hub.db.prepare("INSERT INTO distill_state VALUES(?,?) ON CONFLICT(k) DO UPDATE SET v=excluded.v").run(KEY, JSON.stringify({ ...stored(hub), ...next }));
    return next;
  }).immediate();
}

const POLISH_TIMINGS = ["after_segment", "hourly", "nightly"] as const;
const OVERVIEW_TIMINGS = ["hourly", "every_3h", "nightly"] as const;

/** 第 2 步只读取内部配置。通用设置 API 仍只读写已有公开字段。 */
export function readTimelineSettings(hub: HubDB) {
  const s = stored(hub);
  return {
    polish: POLISH_TIMINGS.find(value => value === s.timeline_polish) ?? "after_segment",
    overview: OVERVIEW_TIMINGS.find(value => value === s.timeline_overview) ?? "hourly",
  };
}
