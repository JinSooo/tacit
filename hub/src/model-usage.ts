import { toLocalIso } from "../../packages/record/index.ts";
import type { HubDB } from "./db.ts";

interface UsageRow {
  at: string; task: string | null; tier: string | null; model: string | null;
  input_tokens: number | null; output_tokens: number | null; ok: number | null; ms: number | null;
}
const TIMELINE_TASKS = new Set(["day", "day_polish", "day_brief"]);

/** 按本地日历取 0 点，跨夏令时不假定一天有 24 小时。 */
export function modelUsageDayStart(now: number, offset = 0): number {
  const date = new Date(now);
  date.setDate(date.getDate() + offset);
  return date.setHours(0, 0, 0, 0);
}

/** 记录时间可能是 UTC 或带偏移的本地 ISO；先粗筛日期，再比较真实时刻。 */
export function modelUsageRows(hub: HubDB, start: number, now: number): UsageRow[] {
  const earliestPrefix = new Date(start - 86_400_000).toISOString().slice(0, 10);
  const rows = hub.db.prepare(`
    SELECT at,task,tier,model,input_tokens,output_tokens,ok,ms FROM llm_usage
    WHERE at>=? AND task IS NOT 'connection_test'
  `).all(earliestPrefix) as UsageRow[];
  return rows.filter(row => {
    const time = Date.parse(row.at);
    return time >= start && time <= now;
  });
}

export const usageTokens = (row: Pick<UsageRow, "input_tokens" | "output_tokens">) =>
  (row.input_tokens ?? 0) + (row.output_tokens ?? 0);

export function readModelUsage(hub: HubDB, now = Date.now()) {
  const today = modelUsageDayStart(now);
  const days = new Set<string>();
  let total = 0, timeline = 0, todayTokens = 0;
  for (const row of modelUsageRows(hub, modelUsageDayStart(now, -6), now)) {
    if (row.input_tokens === null && row.output_tokens === null) continue;
    const time = Date.parse(row.at), tokens = usageTokens(row);
    days.add(toLocalIso(time).slice(0, 10));
    total += tokens;
    if (row.task && TIMELINE_TASKS.has(row.task)) timeline += tokens;
    if (time >= today) todayTokens += tokens;
  }
  return {
    days_with_usage: days.size,
    average_daily_tokens: days.size ? total / days.size : null,
    average_daily_timeline_tokens: days.size ? timeline / days.size : null,
    today_tokens: todayTokens,
  };
}
