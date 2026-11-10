// 提炼请求队列（契约：docs/contracts.md 4.8）。客户端只往队列里放请求，由常驻的提炼进程领取执行，
// 避免两个进程同时调用模型、争同一个库。
import { ulid } from "../../../packages/record/index.ts";
import { InputError, type HubDB } from "../db.ts";

export const requestsSchema = `
CREATE TABLE IF NOT EXISTS distill_requests(id TEXT PRIMARY KEY,kind TEXT NOT NULL CHECK(kind IN ('round','backfill')),date_from TEXT,date_to TEXT,status TEXT NOT NULL CHECK(status IN ('queued','running','done','failed')),created_at TEXT NOT NULL,started_at TEXT,finished_at TEXT,error TEXT,progress_done INTEGER,progress_total INTEGER);
CREATE INDEX IF NOT EXISTS distill_requests_status ON distill_requests(status,created_at);
PRAGMA user_version=6;
`;

export type RequestKind = "round" | "backfill";
export type RequestStatus = "queued" | "running" | "done" | "failed";
export interface DistillRequest {
  id: string; kind: RequestKind; from?: string; to?: string; status: RequestStatus;
  created_at: string; started_at?: string; finished_at?: string; error?: string; progress?: { done: number; total: number };
}
interface Row {
  id: string; kind: RequestKind; date_from: string | null; date_to: string | null; status: RequestStatus; created_at: string;
  started_at: string | null; finished_at: string | null; error: string | null; progress_done: number | null; progress_total: number | null;
}

/** 本地日期 YYYY-MM-DD 的 0 点（毫秒）；格式或日期不合法返回 null。 */
export function localDayStart(date: string): number | null {
  const m = /^(\d{4})-(\d{2})-(\d{2})$/.exec(date);
  if (!m) return null;
  const d = new Date(Number(m[1]), Number(m[2]) - 1, Number(m[3]));
  return d.getFullYear() === Number(m[1]) && d.getMonth() === Number(m[2]) - 1 && d.getDate() === Number(m[3]) ? d.getTime() : null;
}
export function localDateString(ms: number): string {
  const d = new Date(ms), pad = (n: number) => String(n).padStart(2, "0");
  return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}`;
}
/** 默认范围：含今天在内的最近 30 天。 */
export function defaultBackfillRange(now = Date.now()): { from: string; to: string } {
  const start = new Date(now); start.setDate(start.getDate() - 29);
  return { from: localDateString(start.getTime()), to: localDateString(now) };
}

function decode(row: Row): DistillRequest {
  const r: DistillRequest = { id: row.id, kind: row.kind, status: row.status, created_at: row.created_at };
  if (row.date_from !== null) r.from = row.date_from;
  if (row.date_to !== null) r.to = row.date_to;
  if (row.started_at !== null) r.started_at = row.started_at;
  if (row.finished_at !== null) r.finished_at = row.finished_at;
  if (row.error !== null) r.error = row.error;
  if (row.progress_total !== null) r.progress = { done: row.progress_done ?? 0, total: row.progress_total };
  return r;
}

export class DistillRequests {
  constructor(readonly hub: HubDB) {}
  private get sql() { return this.hub.db; }

  /** 校验并入队。同类请求已在排队或执行时返回那一个（created=false），不重复入队。 */
  create(body: unknown, now = Date.now()): { request: DistillRequest; created: boolean } {
    if (!body || typeof body !== "object" || Array.isArray(body)) throw new InputError("请求体必须是对象");
    const b = body as Record<string, unknown>;
    if (b.kind !== "round" && b.kind !== "backfill") throw new InputError("kind 必须是 round 或 backfill");
    let from: string | null = null, to: string | null = null;
    if (b.kind === "round") {
      if (b.from !== undefined || b.to !== undefined) throw new InputError("round 不接受日期范围");
    } else {
      if ((b.from === undefined) !== (b.to === undefined)) throw new InputError("from 和 to 要同时提供或同时省略");
      if (b.from === undefined) ({ from, to } = defaultBackfillRange(now));
      else {
        if (typeof b.from !== "string" || typeof b.to !== "string" || localDayStart(b.from) === null || localDayStart(b.to) === null) throw new InputError("日期必须是 YYYY-MM-DD");
        if (b.from > b.to) throw new InputError("from 不能晚于 to");
        from = b.from; to = b.to;
      }
    }
    return this.sql.transaction(() => {
      const open = this.sql.prepare("SELECT * FROM distill_requests WHERE kind=? AND status IN ('queued','running') ORDER BY created_at LIMIT 1").get(b.kind) as Row | undefined;
      if (open) return { request: decode(open), created: false };
      const id = ulid();
      this.sql.prepare("INSERT INTO distill_requests(id,kind,date_from,date_to,status,created_at) VALUES(?,?,?,?,'queued',?)")
        .run(id, b.kind, from, to, new Date(now).toISOString());
      return { request: this.get(id)!, created: true };
    }).immediate();
  }

  get(id: string): DistillRequest | null {
    const row = this.sql.prepare("SELECT * FROM distill_requests WHERE id=?").get(id) as Row | undefined;
    return row ? decode(row) : null;
  }

  list(limit = 20): DistillRequest[] {
    return (this.sql.prepare("SELECT * FROM distill_requests ORDER BY created_at DESC,id DESC LIMIT ?").all(limit) as Row[]).map(decode);
  }

  /** 领取最早排队的请求并置为 running；没有返回 null。 */
  claim(now = Date.now()): DistillRequest | null {
    return this.sql.transaction(() => {
      const row = this.sql.prepare("SELECT id FROM distill_requests WHERE status='queued' ORDER BY created_at,id LIMIT 1").get() as { id: string } | undefined;
      if (!row) return null;
      this.sql.prepare("UPDATE distill_requests SET status='running',started_at=? WHERE id=?").run(new Date(now).toISOString(), row.id);
      return this.get(row.id);
    }).immediate();
  }

  progress(id: string, done: number, total: number) {
    this.sql.prepare("UPDATE distill_requests SET progress_done=?,progress_total=? WHERE id=?").run(done, total, id);
  }

  finish(id: string, error?: string, now = Date.now()) {
    this.sql.prepare("UPDATE distill_requests SET status=?,finished_at=?,error=? WHERE id=?")
      .run(error ? "failed" : "done", new Date(now).toISOString(), error ?? null, id);
  }

  /** 上一个提炼进程执行到一半退出时留下的 running 请求标为失败，用户可以重新提交。 */
  recoverInterrupted(now = Date.now()): number {
    return this.sql.prepare("UPDATE distill_requests SET status='failed',finished_at=?,error='整理进程中断了' WHERE status='running'").run(new Date(now).toISOString()).changes;
  }
}
