import type { HubDB } from "../db.ts";
import { DistillStore } from "./store.ts";
import { persistFrames } from "./frames.ts";
import { DistillRules } from "./rules.ts";

/** 模型流程的接入点：规则归属后的 new frames；本轮仅执行确定性步骤。 */
export function distillOnce(db: HubDB, backfill = false, now = Date.now()) {
  const store = new DistillStore(db), rules = new DistillRules(store);
  return db.db.transaction(() => {
    let cursor = store.getState<number>("cursor_ms");
    if (cursor === null) { cursor = now; store.setState("cursor_ms",cursor); }
    const enabled = store.getState<number>("enabled_ms") ?? cursor;
    store.setState("enabled_ms",enabled);
    let created = 0, assigned = 0;
    if (backfill && !store.getState<boolean>("backfill_done")) {
      const rows = db.db.prepare("SELECT t_start_ms FROM records WHERE t_start_ms<? ORDER BY t_start_ms").all(enabled) as { t_start_ms: number }[];
      const dayStarts = [...new Set(rows.map(r => { const d = new Date(r.t_start_ms); d.setHours(0,0,0,0); return d.getTime(); }))];
      for (const start of dayStarts) {
        const end = new Date(start); end.setDate(end.getDate()+1);
        created += persistFrames(db,start-1,Number.MAX_SAFE_INTEGER,Math.min(end.getTime(),enabled)).frames.length;
        // TODO：每天的未归属片段交给模型，最后统一合并项目。
      }
      store.setState("backfill_done",true);
    }
    const result = persistFrames(db,cursor,now);
    created += result.frames.length;
    store.setState("cursor_ms",result.cursor_ms);
    for (const frame of store.frames().filter(f => f.status === "new")) {
      if (frame.key.startsWith("repo:")) rules.projectForRepo(frame.key.slice(5));
      if (rules.assign(frame).status === "assigned") assigned++;
    }
    // TODO：在此接入模型归属，以及线程、项目、当前状态和日记提炼。
    return { frames: created, assigned, unassigned: store.frames().filter(f => f.status === "new").length };
  })();
}
export async function runDistill({ db, once, backfill }: { db: HubDB; once: boolean; backfill: boolean }) {
  do {
    console.log(JSON.stringify(distillOnce(db,backfill)));
    if (once) return;
    await new Promise(resolve => setTimeout(resolve,15*60_000));
  } while (true);
}
