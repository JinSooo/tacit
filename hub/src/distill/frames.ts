import { chatKey } from "../chat.ts";
import type { RecordV1 } from "../../../packages/record/index.ts";
import { ulid } from "../../../packages/record/index.ts";
import type { HubDB } from "../db.ts";
import { DistillStore, type Frame } from "./store.ts";
import { gitMaterialKey } from "./material.ts";
import { resolveRepoRoot } from "./repos.ts";

const gap = 10 * 60_000, maxDuration = 2 * 60 * 60_000;
export function frameKey(record: RecordV1): string {
  if (record.source === "mac.audio") return `audio:${record.source_ref}`;
  const c = record.context;
  const git = gitMaterialKey(record);
  if (git) return `git:${git}`;
  // 仓库只是项目线索；并行会话即使工作目录相同，也不是同一件事。
  if (record.source === "codex.session" || record.source === "claude_code.session") {
    const session = record.source_ref?.split("#")[0];
    return session ? `session:${record.source}:${session}` : `record:${record.id}`;
  }
  if (c?.chat) return `chat:${c.app ?? record.source}:${chatKey(c.chat)}`;
  if (c?.url) { try {
    const url = new URL(c.url);
    // Electron 内部 app://-/index.html 不是网页身份；同域网站的不同页面也必须分开。
    if (url.protocol === "https:" || url.protocol === "http:") return `url:${url.href}`;
  } catch { /* 无效 URL 按窗口分组。 */ } }
  if (record.source === "mac.screen") {
    const window = c?.window?.trim();
    if (window && !/^(?:wait|chatgpt|claude|codex|new chat|新对话|新建对话|无标题)$/i.test(window)) return `window:${c?.app ?? record.source}:${window}`;
    // 无法辨认会话的泛标题不强行合并；归属阶段仍能根据正文找回相关事项。
    if (c?.url || window) return `record:${record.id}`;
  }
  if (c?.repo) return `repo:${c.repo}`;
  return `app:${c?.app ?? record.source}`;
}
interface Group { key: string; records: RecordV1[]; start: number; end: number; last: number }
/** 不生成随机 ID，纯函数输出可直接用于边界测试。 */
export function sliceFrames(records: RecordV1[], cursor_ms: number, now = Date.now()): { frames: Omit<Frame,"id">[]; cursor_ms: number } {
  const sorted = records.filter(r => r.source !== "manual.correction").sort((a,b) => Date.parse(a.t_start)-Date.parse(b.t_start) || a.id.localeCompare(b.id));
  const groups: Group[] = [], current = new Map<string,Group>();
  const auxiliary = (r: RecordV1) => r.source === "mac.clipboard" || r.source === "mac.file";
  const add = (r: RecordV1, key: string) => {
    const start = Date.parse(r.t_start), end = Math.max(start,Date.parse(r.t_end ?? r.t_start));
    let g = current.get(key);
    if (!g || start < g.start || start - g.last > gap || end - g.start > maxDuration) {
      g = { key, records: [], start, end: Math.min(end,start+maxDuration), last: end };
      groups.push(g); current.set(key,g);
    }
    g.records.push(r); g.end = Math.min(Math.max(g.end,end),g.start+maxDuration); g.last = end;
  };
  for (const r of sorted) if (!auxiliary(r)) add(r,frameKey(r));
  for (const r of sorted) if (auxiliary(r)) {
    const at = Date.parse(r.t_start);
    // 多个活动重叠时，跟随开始时间最近的一个。
    const g = groups.filter(g => g.start <= at && at <= g.end).sort((a,b) => b.start-a.start || a.key.localeCompare(b.key))[0];
    if (g) g.records.push(r);
    else add(r,`app:${r.context?.app ?? r.source}`);
  }
  const open = groups.filter(g => now-g.last < gap);
  const next = Math.max(cursor_ms, open.length ? Math.min(...open.map(g => g.start))-1 : Math.max(cursor_ms,...sorted.map(r => Date.parse(r.t_start))));
  return {
    frames: groups.filter(g => !open.includes(g)).sort((a,b) => a.start-b.start || a.key.localeCompare(b.key)).map(g => ({
      t_start_ms: g.start, t_end_ms: g.end, key: g.key,
      record_ids: g.records.sort((a,b) => Date.parse(a.t_start)-Date.parse(b.t_start) || a.id.localeCompare(b.id)).map(r => r.id),
      chars: g.records.reduce((n,r) => n+r.body.length,0), private: Number(g.records.some(r => r.sensitivity === "private")), status: "new",
    })), cursor_ms: next,
  };
}
export function persistFrames(db: HubDB, cursor: number, now = Date.now(), before?: number) {
  const store = new DistillStore(db);
  return db.db.transaction(() => {
    const enabled = store.getState<number>("enabled_ms") ?? now;
    const lastRowid = store.getState<number>("last_rowid") ?? 0;
    // rowid 捕获迟到记录；时间窗口重新捞取上轮尚未结束的活动。
    const rows = (before !== undefined
      ? db.db.prepare(`SELECT id FROM records r WHERE t_start_ms>? AND t_start_ms<? AND NOT EXISTS(SELECT 1 FROM frame_records fr WHERE fr.record_id=r.id) ORDER BY t_start_ms,id`).all(cursor,before)
      : db.db.prepare(`SELECT id FROM records r WHERE (r.rowid>? OR t_start_ms>?) AND (t_start_ms>=? OR source GLOB 'manual.*') AND NOT EXISTS(SELECT 1 FROM frame_records fr WHERE fr.record_id=r.id) ORDER BY t_start_ms,id`).all(lastRowid,Math.max(enabled-1,now-48*3600000),enabled)) as { id: string }[];
    const projects = store.projects();
    const result = sliceFrames(rows.map(r => {
      const record = db.get(r.id)!;
      if (record.source !== "mac.git" || !record.context?.repo) return record;
      const repo = resolveRepoRoot(record.context.repo, projects) ?? record.context.repo;
      return { ...record, context: { ...record.context, repo } };
    }),cursor,now);
    const frames = result.frames.map(f => ({ ...f,id: ulid() }));
    for (const frame of frames) store.createFrame(frame);
    if (before === undefined) {
      const row = db.db.prepare("SELECT MAX(rowid) AS n FROM records").get() as { n: number | null };
      store.setState("last_rowid",Math.max(lastRowid,row.n ?? 0));
    }
    return { frames, cursor_ms: result.cursor_ms };
  })();
}
