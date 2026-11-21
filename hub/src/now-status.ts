import { toLocalIso } from "../../packages/record/index.ts";
import type { HubDB } from "./db.ts";
import { DistillStore, type Thread } from "./distill/store.ts";
import { wechatRecordForNotification } from "./distill/wechat-duplicates.ts";

const day = 24 * 3600_000;
const emptyBrief = "最近 24 小时没有活跃的线程。";

export function nowSummary(store: DistillStore, clock: number) {
  // 暂停的事项只要近 24 小时有活动，也仍属于此刻。
  const rows = store.hub.db.prepare(`SELECT t.id,t.title,t.brief,t.last_ms,t.updated_at,p.name project
    FROM threads t LEFT JOIN projects p ON p.id=t.project_id
    WHERE t.status IN ('active','paused') AND t.last_ms>? AND t.last_ms<=? AND trim(t.brief)!=''
    ORDER BY t.last_ms DESC LIMIT 5`).all(clock - day, clock) as (Pick<Thread, "id" | "title" | "updated_at"> & {
      brief: string; last_ms: number; project: string | null;
    })[];
  const threads = rows.map(t => ({ thread_id: t.id, title: t.title, brief: t.brief, project: t.project, last: toLocalIso(t.last_ms) }));
  const top = threads[0];
  const brief = top ? (top.project && !top.brief.includes(top.project) ? `${top.project}：${top.brief}` : top.brief) : emptyBrief;
  const updated = rows[0]?.updated_at;
  return { brief, detail: { threads }, updated_at: top ? (updated && Number.isFinite(Date.parse(updated)) ? updated : null) : toLocalIso(clock) };
}

function pendingActivity(store: DistillStore, clock: number) {
  const enabled = store.getState<number>("enabled_ms") ?? 0;
  const pending = store.hub.db.prepare<[number, number, number, number], { id: string; source: string }>(`SELECT r.id,r.source FROM records r
    LEFT JOIN frame_records fr ON fr.record_id=r.id
    LEFT JOIN frames f ON f.id=fr.frame_id
    LEFT JOIN assignments a ON a.frame_id=f.id
    LEFT JOIN threads t ON t.id=a.thread_id
    WHERE r.t_start_ms>? AND r.t_start_ms<=? AND r.sensitivity!='private' AND r.source!='manual.correction'
    AND ((fr.frame_id IS NULL AND (r.t_start_ms>=? OR r.source GLOB 'manual.*')) OR f.status='new'
      OR (t.status IN ('active','paused') AND t.last_ms>? AND t.needs_regen=1 AND COALESCE(trim(t.brief),'')=''))`)
    .iterate(clock - day, clock, enabled, clock - day);
  for (const r of pending) {
    if (r.source !== "android.notification" || !wechatRecordForNotification(store.hub, store.hub.get(r.id)!)) return true;
  }
  return false;
}

/** 在读取时计算，模型离线时也能看见状态；不把错误正文带到摘要中。 */
export function currentNow(hub: HubDB, clock = Date.now()) {
  const store = new DistillStore(hub);
  const saved = store.getState<{ brief?: string; detail?: unknown; updated_at?: string | null }>("now");
  const hasCachedSummary = !!saved?.brief?.trim() && saved.brief !== emptyBrief;
  const live = hasCachedSummary ? null : nowSummary(store, clock);
  const summary = live?.detail.threads.length ? live : saved;
  const hasSummary = hasCachedSummary || !!live?.detail.threads.length;
  const updated = Date.parse(summary?.updated_at ?? "") || 0;
  const call = hub.db.prepare("SELECT at,ok FROM llm_usage WHERE task IN ('assign','thread_digest','thread_brief') ORDER BY julianday(at) DESC,id DESC LIMIT 1").get() as { at: string; ok: number } | undefined;
  const failed = call && !call.ok && Date.parse(call.at) >= updated;
  if (!hasSummary && pendingActivity(store, clock)) {
    return { brief: "有新活动待整理。", detail: { threads: [] }, updated_at: null,
      feedback: failed ? "最近一次整理失败。请到设置检查 AI 模型连接。" : null };
  }
  let feedback: string | null = null;
  if (failed) feedback = "最近一次整理失败，显示的摘要可能不是最新内容。请到设置检查 AI 模型连接。";
  else if ((hasSummary || !summary) && clock - updated > 3600_000) {
    const latest = hub.db.prepare("SELECT MAX(t_start_ms) ms FROM records WHERE sensitivity!='private'").get() as { ms: number | null };
    if ((latest.ms ?? 0) > updated) feedback = hasSummary ? "有新活动尚未整理，下面是此前的摘要。" : "已有活动记录，等待整理出摘要。";
  }
  if (!summary && !feedback) return null;
  return { ...summary, feedback };
}
