import { constants, openSync, closeSync, fstatSync, readSync } from "node:fs";
import { join } from "node:path";
import { InputError, type HubDB } from "./db.ts";
import { redactString } from "./redact.ts";
import type { LLMRequest, ModelConfig, UsageRow, CallObserver } from "./llm/types.ts";

export const SNAPSHOT_DAYS = 7;
const RETENTION = SNAPSHOT_DAYS * 86400_000;
const OUTPUT_LIMIT = 128_000;
export const runtimeSchema = `
CREATE TABLE runtime_calls (
  id TEXT PRIMARY KEY, at TEXT NOT NULL, at_ms INTEGER NOT NULL, kind TEXT NOT NULL,
  task TEXT, tier TEXT, provider TEXT, model TEXT, transport TEXT, revision INTEGER NOT NULL,
  provider_state TEXT NOT NULL DEFAULT 'not_sent', validation_state TEXT NOT NULL DEFAULT 'not_checked',
  application_state TEXT NOT NULL DEFAULT 'pending', content_state TEXT NOT NULL DEFAULT 'available',
  request_json TEXT, response_text TEXT, response_truncated INTEGER NOT NULL DEFAULT 0,
  redactions INTEGER NOT NULL DEFAULT 0, ms INTEGER, input_tokens INTEGER, output_tokens INTEGER, error TEXT
);
CREATE INDEX runtime_calls_time ON runtime_calls(kind,at_ms DESC,id DESC);
PRAGMA user_version=11;`;

type Row = Record<string, any>;
export function contentRevision(hub: HubDB): number {
  const row = hub.db.prepare("SELECT v FROM distill_state WHERE k='content_revision'").get() as { v: string } | undefined;
  return row ? Number(JSON.parse(row.v)) || 0 : 0;
}
export function expireSnapshots(hub: HubDB, now = Date.now()) {
  hub.db.prepare(`UPDATE runtime_calls SET request_json=NULL,response_text=NULL,content_state='expired'
    WHERE at_ms<=? AND content_state='available'`).run(now - RETENTION);
}
/** 与记录删除共用事务。暂不假设摘要具备完整来源链，保守清除所有正文。 */
export function eraseSnapshots(hub: HubDB) {
  hub.db.prepare(`UPDATE runtime_calls SET request_json=NULL,response_text=NULL,content_state='deleted'
    WHERE content_state='available'`).run();
}

export class RuntimeLog {
  constructor(readonly hub: HubDB) {}

  begin(id: string, req: LLMRequest, config: ModelConfig): CallObserver {
    const revision = req.contentRevision ?? contentRevision(this.hub), now = Date.now();
    const safe = redactString(JSON.stringify({ system: req.system, prompt: req.prompt, schema: req.schema, refs: req.refs ?? {} }));
    this.hub.db.transaction(() => {
      expireSnapshots(this.hub, now);
      if (revision !== contentRevision(this.hub)) throw new Error("记录已变化，等待重新整理");
      this.hub.db.prepare(`INSERT INTO runtime_calls(id,at,at_ms,kind,task,tier,provider,model,revision,request_json,redactions)
        VALUES(?,?,?,'model',?,?,?,?,?,?,?)`).run(id,new Date(now).toISOString(),now,req.task ?? null,req.tier,config.provider,config.model,revision,safe.text,safe.count);
    }).immediate();
    const request = (transport: "api" | "cli", payload: unknown) => {
      const encoded = redactString(JSON.stringify({ transport, request: payload, refs: req.refs ?? {} }));
      this.hub.db.transaction(() => {
        const row = this.hub.db.prepare("SELECT content_state FROM runtime_calls WHERE id=?").get(id) as Row | undefined;
        if (!row || row.content_state !== "available" || revision !== contentRevision(this.hub)) throw new Error("记录已变化，等待重新整理");
        // 出队后、真正发送前再检查一次；API 的钥匙串读取、CLI 的初始化也可能耗时。
        this.hub.db.prepare("UPDATE runtime_calls SET transport=?,request_json=?,redactions=?,provider_state='sending' WHERE id=?")
          .run(transport,encoded.text,encoded.count,id);
      }).immediate();
    };
    const response = (text: string) => {
      const safe = redactString(text); // 先完整脱敏再截断，避免在密钥中间截断而漏检。
      this.hub.db.transaction(() => {
        expireSnapshots(this.hub);
        this.hub.db.prepare(`UPDATE runtime_calls SET provider_state='returned',
          response_text=CASE WHEN content_state='available' AND revision=? THEN ? ELSE NULL END,
          response_truncated=?,redactions=redactions+? WHERE id=?`)
          .run(contentRevision(this.hub),safe.text.slice(0,OUTPUT_LIMIT),Number(safe.text.length > OUTPUT_LIMIT),safe.count,id);
      }).immediate();
    };
    return { request, response };
  }

  finish(row: UsageRow, validated: boolean) {
    this.hub.db.transaction(() => {
      const current = this.hub.db.prepare("SELECT revision,content_state FROM runtime_calls WHERE id=?").get(row.id) as Row | undefined;
      if (!current) return;
      const stale = current.revision !== contentRevision(this.hub);
      this.hub.db.prepare(`UPDATE runtime_calls SET
        provider_state=CASE WHEN provider_state='returned' THEN provider_state ELSE 'failed' END,
        validation_state=?,application_state=?,ms=?,input_tokens=?,output_tokens=?,error=? WHERE id=?`)
        .run(validated ? "passed" : "failed",stale ? "discarded" : row.ok ? "pending" : "not_applied",row.ms,row.input_tokens,row.output_tokens,
          stale ? "记录已变化，结果未采用" : row.error ? redactString(row.error).text : null,row.id);
    }).immediate();
  }

  context(id: string, text: string, ids: string[], revision: number) {
    const safe = redactString(JSON.stringify({ text, result_ids: ids })), now = Date.now();
    this.hub.db.transaction(() => {
      expireSnapshots(this.hub, now);
      if (revision !== contentRevision(this.hub)) throw new Error("记录已变化");
      this.hub.db.prepare(`INSERT INTO runtime_calls(id,at,at_ms,kind,revision,request_json,redactions,provider_state,validation_state,application_state)
        VALUES(?,?,?,'context',?,?,?,'not_applicable','not_applicable','returned')`).run(id,new Date(now).toISOString(),now,revision,safe.text,safe.count);
    }).immediate();
  }

  models(params: URLSearchParams) {
    expireSnapshots(this.hub);
    const limit = Number(params.get("limit") ?? 30);
    if (!Number.isInteger(limit) || limit < 1 || limit > 100) throw new InputError("limit 必须是 1–100");
    let cursor: [number,string] | null = null;
    if (params.has("cursor")) {
      try { cursor = JSON.parse(Buffer.from(params.get("cursor")!,"base64url").toString()); } catch { throw new InputError("cursor 无效"); }
      if (!Array.isArray(cursor) || cursor.length !== 2 || !Number.isFinite(cursor[0]) || typeof cursor[1] !== "string" || cursor[1].length > 128) throw new InputError("cursor 无效");
    }
    // 老调用只有用量与错误，不根据今天的记录拼造历史输入。
    const sql = `WITH calls AS (
      SELECT id,at,at_ms,task,tier,provider,model,transport,provider_state,validation_state,application_state,content_state,ms,input_tokens,output_tokens,error FROM runtime_calls WHERE kind='model'
      UNION ALL
      SELECT u.id,u.at,CAST((julianday(u.at)-2440587.5)*86400000 AS INTEGER),u.task,u.tier,u.provider,u.model,NULL,
        CASE WHEN u.ok=1 THEN 'returned' ELSE 'failed' END,CASE WHEN u.ok=1 THEN 'passed' ELSE 'unknown' END,'unknown','not_recorded',u.ms,u.input_tokens,u.output_tokens,u.error
        FROM llm_usage u WHERE NOT EXISTS(SELECT 1 FROM runtime_calls r WHERE r.id=u.id)
    ) SELECT * FROM calls ${cursor ? "WHERE at_ms<? OR (at_ms=? AND id<?)" : ""} ORDER BY at_ms DESC,id DESC LIMIT ?`;
    const rows = this.hub.db.prepare(sql).all(...(cursor ? [cursor[0],cursor[0],cursor[1]] : []),limit+1) as Row[];
    const page = rows.slice(0,limit), last = page.at(-1);
    return { calls: page, next_cursor: rows.length > limit && last ? Buffer.from(JSON.stringify([last.at_ms,last.id])).toString("base64url") : null };
  }

  detail(id: string): (Row & { request: any; response: string | null }) | null {
    expireSnapshots(this.hub);
    const row = this.hub.db.prepare("SELECT * FROM runtime_calls WHERE id=?").get(id) as Row | undefined;
    if (!row) return null;
    const { request_json, response_text, ...meta } = row;
    return { ...meta, request: request_json ? JSON.parse(request_json) : null, response: response_text };
  }
}

/** 调用结果在写入业务数据的同一个事务中记为已采用；失败事务也会回滚此状态。 */
export function appliedCall(hub: HubDB, id?: string) {
  if (!id) return;
  const row = hub.db.prepare("SELECT revision FROM runtime_calls WHERE id=?").get(id) as Row | undefined;
  if (row && row.revision !== contentRevision(hub)) throw new Error("记录已变化，结果未采用");
  hub.db.prepare("UPDATE runtime_calls SET application_state='applied' WHERE id=? AND application_state='pending' AND revision=?")
    .run(id,contentRevision(hub));
}
export function discardedCall(hub: HubDB, id?: string) {
  if (id) hub.db.prepare("UPDATE runtime_calls SET application_state='discarded' WHERE id=? AND application_state='pending'").run(id);
}

/** 只展示结构化状态字段；不返回 stderr 原文、路径、标题或任意文件。 */
export function backgroundLog(dataDir: string, source: string) {
  if (!["hub","distill","collector"].includes(source)) throw new InputError("日志来源无效");
  let fd: number;
  try { fd = openSync(join(dataDir,"logs",`${source}.log`),constants.O_RDONLY | constants.O_NOFOLLOW); }
  catch (error) { if ((error as NodeJS.ErrnoException).code === "ENOENT") return { source, events: [], skipped: 0 }; throw error; }
  try {
    const stat = fstatSync(fd);
    if (!stat.isFile()) throw new InputError("日志路径无效");
    const size = Math.min(stat.size,128 * 1024), bytes = Buffer.alloc(size);
    const read = readSync(fd,bytes,0,size,stat.size-size);
    const lines = bytes.subarray(0,read).toString("utf8").split("\n");
    if (stat.size > size) lines.shift();
    const fields = new Set(["at","step","location","category","name","code","ok","calls","failed","frames","records","updated","assigned","created_threads","ignored","candidates","pending","processed","accepted","rejected","merged","facts","threads","projects","days","round","slice","assign","digest","brief","day","backfill","conversations","lifecycle","quota","dropped_ungrounded","dropped_invalid_inference"]);
    const clean = (value: unknown, depth = 0): unknown => {
      if (typeof value === "number" || typeof value === "boolean") return value;
      if (typeof value === "string" && /^[\w.:-]{1,80}$/.test(value) && redactString(value).count === 0) return value;
      if (!value || typeof value !== "object" || Array.isArray(value) || depth > 3) return undefined;
      return Object.fromEntries(Object.entries(value).filter(([key]) => fields.has(key)).flatMap(([key,v]) => {
        const safe = clean(v,depth+1); return safe === undefined ? [] : [[key,safe]];
      }));
    };
    let skipped = 0;
    const events = lines.filter(Boolean).flatMap(line => {
      try { const safe = clean(JSON.parse(line)) as Row; if (safe && typeof safe === "object" && Object.keys(safe).length) return [safe]; } catch {}
      skipped++; return [];
    }).slice(-200).reverse();
    return { source, events, skipped, modified_at: stat.mtime.toISOString() };
  } finally { closeSync(fd); }
}
