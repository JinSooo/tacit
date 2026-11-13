import type { HubDB } from "./db.ts";
import { DistillStore } from "./distill/store.ts";

/** 在读取时计算，模型离线时也能看见状态；不把错误正文带到摘要中。 */
export function currentNow(hub: HubDB, clock = Date.now()) {
  const saved = new DistillStore(hub).getState<{ brief?: string; detail?: unknown; updated_at?: string | null }>("now");
  const updated = Date.parse(saved?.updated_at ?? "") || 0;
  const latest = hub.db.prepare("SELECT MAX(t_start_ms) ms FROM records WHERE sensitivity!='private'").get() as { ms: number | null };
  const call = hub.db.prepare("SELECT at,ok FROM llm_usage WHERE task IN ('assign','thread_digest','thread_brief') ORDER BY julianday(at) DESC,id DESC LIMIT 1").get() as { at: string; ok: number } | undefined;
  let feedback: string | null = null;
  if (call && !call.ok && Date.parse(call.at) >= updated) feedback = "最近一次整理失败，显示的摘要可能不是最新内容。请到设置检查 AI 模型连接。";
  else if ((latest.ms ?? 0) > updated && clock - updated > 3600_000) feedback = saved?.brief ? "有新活动尚未整理，下面是此前的摘要。" : "已有活动记录，等待整理出摘要。";
  if (!saved && !feedback) return null;
  return { ...saved, feedback };
}
