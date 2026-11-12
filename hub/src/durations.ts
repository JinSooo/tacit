import type { HubDB } from "./db.ts";

/** 区间并集的总秒数：重叠的时段只算一次，瞬时事件不计时长。 */
export function unionSeconds(spans: [number, number][]): number {
  const sorted = spans.filter(([s,e]) => e > s).sort((a,b) => a[0]-b[0]);
  let total = 0, cur: [number, number] | null = null;
  for (const [s,e] of sorted) {
    if (cur && s <= cur[1]) cur[1] = Math.max(cur[1],e);
    else { if (cur) total += cur[1]-cur[0]; cur = [s,e]; }
  }
  if (cur) total += cur[1]-cur[0];
  return Math.round(total/1000);
}

/** 只读时间列，不加载正文。活动片段的外包区间含空档，不能拿它当活跃时长。 */
export function recordSpans(hub: HubDB, ids: string[], from = -Infinity, to = Infinity): [number, number][] {
  const rows = hub.db.prepare("SELECT t_start_ms,t_end FROM records WHERE id IN (SELECT value FROM json_each(?))").all(JSON.stringify(ids)) as { t_start_ms: number; t_end: string | null }[];
  return rows.flatMap(r => {
    const end = Math.max(r.t_start_ms, Date.parse(r.t_end ?? "") || r.t_start_ms);
    return r.t_start_ms < to && end >= from ? [[Math.max(from,r.t_start_ms), Math.min(to,end)] as [number,number]] : [];
  });
}
