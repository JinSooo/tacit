import { ulid } from '../../../packages/record/index.ts';
import type { DistillStore, Frame } from './store.ts';
import { sliceFrames } from './frames.ts';

/** 对已审核的旧片段重建边界；只改派生关系，原记录、修正和用户事实不动。
 * 后续先重建返回的源事项，再让新片段归属，最后更新项目/日记。
 */
export function repairFrameBoundaries(store: DistillStore, frameIds: string[]) {
  const sql = store.hub.db;
  return sql.transaction(() => {
    const result = { replaced: 0, created: 0, protected: [] as string[], threads: [] as string[], frame_ids: [] as string[] };
    const changed = new Set<string>(), sourceThreads = new Set<string>(), affected = new Set<string>(), projects = new Set<string>(), records = new Set<string>(), times: string[] = [];
    const at = new Date().toISOString();
    for (const id of new Set(frameIds)) {
      const row = sql.prepare('SELECT * FROM frames WHERE id=?').get(id) as (Omit<Frame,'record_ids'> & { record_ids: string }) | undefined;
      if (!row) continue;
      const ids: string[] = JSON.parse(row.record_ids);
      const assignment = sql.prepare('SELECT thread_id,method FROM assignments WHERE frame_id=?').get(id) as { thread_id: string; method: string } | undefined;
      const userFact = sql.prepare("SELECT 1 FROM facts WHERE origin='user' AND invalid_at IS NULL AND EXISTS(SELECT 1 FROM json_each(evidence) WHERE value IN (SELECT value FROM json_each(?))) LIMIT 1").get(row.record_ids);
      if (assignment?.method === 'user' || userFact) { result.protected.push(id); continue; }
      const originals = ids.map(rid => store.hub.get(rid));
      if (originals.some(r => !r)) throw new Error('重分组引用的记录不存在');
      const next = sliceFrames(originals.map(r => r!), 0, Number.MAX_SAFE_INTEGER).frames;
      if (next.length <= 1) continue;
      const coverage = next.flatMap(f => f.record_ids).sort();
      if (JSON.stringify(coverage) !== JSON.stringify([...ids].sort())) throw new Error('重分组不能增删原始记录');
      const rejections = sql.prepare('SELECT thread_id,at FROM frame_rejections WHERE frame_id=?').all(id) as { thread_id: string; at: string }[];
      sql.prepare('DELETE FROM assignments WHERE frame_id=?').run(id);
      sql.prepare('DELETE FROM frame_rejections WHERE frame_id=?').run(id);
      sql.prepare('DELETE FROM frame_records WHERE frame_id=?').run(id);
      sql.prepare('DELETE FROM frames WHERE id=?').run(id);
      for (const frame of next) {
        const fid = ulid(); store.createFrame({ ...frame, id: fid }); result.frame_ids.push(fid);
        for (const r of rejections) sql.prepare('INSERT INTO frame_rejections VALUES(?,?,?)').run(fid,r.thread_id,r.at);
      }
      result.replaced++; result.created += next.length; changed.add(id);
      if (assignment) { sourceThreads.add(assignment.thread_id); affected.add(assignment.thread_id); }
      for (const r of originals) { records.add(r!.id); times.push(r!.t_start); }
    }
    if (!result.replaced) return result;
    const recordIDs = JSON.stringify([...records]);
    // 源事项可能还有受污染但未完整列出证据的自动事实，连同引用变化记录的其他事实一起撤下。
    const facts = sql.prepare("SELECT id,thread_id,project_id FROM facts WHERE origin='llm' AND invalid_at IS NULL AND (thread_id IN (SELECT value FROM json_each(?)) OR EXISTS(SELECT 1 FROM json_each(evidence) WHERE value IN (SELECT value FROM json_each(?))))").all(JSON.stringify([...sourceThreads]),recordIDs) as { id: string; thread_id: string | null; project_id: string | null }[];
    for (const f of facts) {
      sql.prepare('UPDATE facts SET invalid_at=? WHERE id=?').run(at,f.id);
      if (f.thread_id) affected.add(f.thread_id); if (f.project_id) projects.add(f.project_id);
    }
    // 候选标题也来自旧混合材料；其未变化片段重新归属，不继承污染标题。
    const candidates = store.getState<{ frame_ids: string[] }[]>('candidates') ?? [];
    store.setState('candidates', candidates.filter(c => {
      if (!c.frame_ids.some(fid => changed.has(fid))) return true;
      for (const fid of c.frame_ids) sql.prepare("UPDATE frames SET status='new' WHERE id=? AND status='candidate'").run(fid);
      return false;
    }));
    store.clearDerived(affected, projects, times, true);
    for (const id of sourceThreads) {
      const remaining = sql.prepare('SELECT f.t_start_ms,f.t_end_ms FROM frames f JOIN assignments a ON a.frame_id=f.id WHERE a.thread_id=? ORDER BY f.t_start_ms,f.id').all(id) as { t_start_ms: number; t_end_ms: number }[];
      let last = 0, sessions = 0;
      for (const f of remaining) { if (!last || f.t_start_ms-last>30*60000) sessions++; last=Math.max(last,f.t_end_ms); }
      sql.prepare('UPDATE threads SET first_ms=?,last_ms=?,active_minutes=?,sessions=? WHERE id=?').run(remaining[0]?.t_start_ms ?? null,last || null,store.activeMinutes(id),sessions,id);
    }
    result.threads = [...affected]; return result;
  })();
}
