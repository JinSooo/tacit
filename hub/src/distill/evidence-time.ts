import type { RecordV1 } from "../../../packages/record/index.ts";

/** 日期参数描述被查询的数据范围，不是观察到请求成功的时间；正文仍原样供逐字核对。 */
export function evidenceTime(record: Pick<RecordV1, "t_start" | "t_end" | "body" | "context">) {
  const query_dates: { parameter: string; value: string }[] = [];
  const seen = new Set<string>();
  for (const text of [record.context?.url ?? "", record.body]) {
    const params = /[?&](?:amp;)?(start_?date|end_?date|date_?from|date_?to|from|to|date)=([^\s&#"'<>]+)/gi;
    for (const match of text.matchAll(params)) {
      let value: string;
      try { value = decodeURIComponent(match[2]!); } catch { continue; }
      if (!/^\d{4}-\d{2}-\d{2}(?:T\d{2}:\d{2}(?::\d{2}(?:\.\d+)?)?(?:Z|[+-]\d{2}:?\d{2})?)?$/.test(value) || !Number.isFinite(Date.parse(value))) continue;
      const parameter = match[1]!, key = `${parameter.toLowerCase()}:${value}`;
      if (!seen.has(key)) { seen.add(key); query_dates.push({ parameter, value }); }
    }
  }
  return { recorded_at: record.t_start, ...(record.t_end ? { recorded_until: record.t_end } : {}),
    ...(query_dates.length ? { query_dates: query_dates.slice(0, 12) } : {}) };
}
