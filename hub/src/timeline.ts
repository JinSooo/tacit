import { toLocalIso } from "../../packages/record/index.ts";
import { HubDB, InputError } from "./db.ts";
import { localDayStart } from "./distill/requests.ts";
import type { ReviewItem } from "./distill/day-review.ts";
import { applyTimelineCorrections, DistillStore, isTimelineItem, timelineCorrectionKey, type StoredReviewItem, type TimelineCorrections } from "./distill/store.ts";
import { redactString } from "./redact.ts";

type DayRow = { date: string; detail: string; corrections: string | null };
type TimelineDay = { date: string; items: ReviewItem[] };

const normalized = (text: string) => text.normalize("NFKC").toLowerCase();

export function timelineDays(hub: HubDB, params: URLSearchParams) {
  const project = params.get("project_id"), q = params.get("q")?.trim();
  if (project ? params.has("q") || project.length > 128 : !q || q.length > 4096 || params.has("project_id")) {
    throw new InputError("请提供有效项目或搜索词");
  }
  const before = params.get("before");
  if (before !== null && localDayStart(before) === null) throw new InputError("日期游标无效");
  const limit = Number(params.get("limit") ?? 15);
  if (!Number.isInteger(limit) || limit < 1 || limit > 31) throw new InputError("limit 必须是 1–31 个使用日");

  const words = q ? normalized(q).split(/\s+/u) : [];
  const days: TimelineDay[] = [];
  const rows = hub.db.prepare<[string | null, string | null, string | null, string | null], DayRow>(`
    SELECT d.date,d.detail,c.v corrections FROM days d
    LEFT JOIN distill_state c ON c.k='timeline_corrections:' || d.date
    WHERE d.detail IS NOT NULL AND (? IS NULL OR d.date<?)
      AND (? IS NULL OR EXISTS (SELECT 1 FROM json_each(d.detail,'$.items') i WHERE json_extract(i.value,'$.project_id')=?))
    ORDER BY d.date DESC`).iterate(before,before,project,project);
  for (const row of rows) {
    const detail = JSON.parse(row.detail) as { items?: StoredReviewItem[] };
    if (!Array.isArray(detail.items)) continue;
    const corrections = row.corrections ? JSON.parse(row.corrections) as TimelineCorrections : null;
    const items = new DistillStore(hub).readingItems(applyTimelineCorrections(detail.items, corrections)).filter(isTimelineItem).filter(item => {
      if (project) return item.project_id === project;
      const target = normalized(`${item.title}\n${item.description}`);
      return words.every(word => target.includes(word));
    });
    if (!items.length) continue;
    if (days.length === limit) return { days, next_cursor: days.at(-1)!.date };
    days.push({ date: row.date, items: [...items].sort((a,b) => Date.parse(b.t_start) - Date.parse(a.t_start) || a.id.localeCompare(b.id)) });
  }
  return { days, next_cursor: null };
}

export function timelineRecord(hub: HubDB, id: string) {
  const record = hub.db.prepare<[string], { id: string; t_start_ms: number; t_end: string | null }>(`
    SELECT COALESCE(original.id,r.id) id,COALESCE(original.t_start_ms,r.t_start_ms) t_start_ms,
      CASE WHEN original.id IS NULL THEN r.t_end ELSE original.t_end END t_end
    FROM records r LEFT JOIN records original ON r.source='manual.correction' AND r.corrects=original.id WHERE r.id=?`).get(id);
  if (!record) return null;
  const from = toLocalIso(record.t_start_ms).slice(0,10);
  const end = Date.parse(record.t_end ?? "");
  const to = Number.isFinite(end) ? toLocalIso(Math.max(record.t_start_ms,end)).slice(0,10) : from;
  const days = hub.db.prepare<[string,string,string], { date: string }>(`
    SELECT DISTINCT d.date
    FROM days d JOIN json_each(d.detail,'$.items') i
    WHERE d.date BETWEEN ? AND ?
      AND EXISTS (SELECT 1 FROM json_each(i.value,'$.record_ids') r WHERE r.value=?)
    ORDER BY d.date`).all(from,to,record.id);
  const store = new DistillStore(hub);
  for (const { date } of days) {
    const items = store.dayView(date)?.detail?.items as ReviewItem[] | undefined;
    const item = items?.filter(isTimelineItem).sort((a, b) => Date.parse(a.t_start) - Date.parse(b.t_start) || a.id.localeCompare(b.id))
      .find(item => item.record_ids.includes(record.id));
    if (item) return { date, segment_id: item.id };
  }
  return { date: from, segment_id: null };
}

function findSegment(store: DistillStore, date: string, id: string): ReviewItem | null {
  const items = store.day(date)?.detail?.items;
  if (!Array.isArray(items)) return null;
  const item = (items as StoredReviewItem[]).find(item => item.id === id);
  return item && isTimelineItem(item) && item.record_ids.length > 0 ? item : null;
}

export function correctTimelineSegment(store: DistillStore, date: string, id: string, input: unknown) {
  if (localDayStart(date) === null) throw new InputError("日期无效");
  const value = input && typeof input === "object" && "description" in input ? input.description : null;
  const description = typeof value === "string" ? value.trim() : "";
  if (!description || /[\x00-\x1f\x7f]/u.test(description) || Array.from(description).length > 160) {
    throw new InputError("请写一句不超过 160 字的描述");
  }
  const text = redactString(description).text;
  return store.hub.db.transaction(() => {
    const item = findSegment(store,date,id);
    if (!item) return null;
    const key = timelineCorrectionKey(date), corrections = store.getState<TimelineCorrections>(key);
    store.setState(key, { ...corrections, [id]: { record_ids: item.record_ids, description: text } });
    return { item: { ...item, description: text } };
  }).immediate();
}

export function deleteTimelineSegment(store: DistillStore, date: string, id: string, input: unknown) {
  if (localDayStart(date) === null) throw new InputError("日期无效");
  const expected = input && typeof input === "object" && "record_ids" in input ? input.record_ids : null;
  if (!Array.isArray(expected) || !expected.length || expected.some(id => typeof id !== "string" || !/^[0-9A-HJKMNP-TV-Z]{26}$/.test(id))) {
    throw new InputError("缺少有效的段内记录");
  }
  const members = new Set(expected);
  if (members.size !== expected.length) throw new InputError("段内记录不能重复");
  return store.hub.db.transaction(() => {
    const item = findSegment(store,date,id);
    if (!item) return null;
    if (item.record_ids.length !== members.size || item.record_ids.some(id => !members.has(id))) return { changed: true };
    return { deleted: store.hub.deleteMany(item.record_ids) };
  }).immediate();
}
