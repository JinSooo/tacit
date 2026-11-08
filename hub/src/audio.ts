import { ulid } from "../../packages/record/index.ts";
import { HubDB, InputError } from "./db.ts";

export const MATCH_THRESHOLD = 0.5;
export const DEFAULT_ME_THRESHOLD = 0.49;
const VECTOR_SIZE = 512, ASK_CONVERSATIONS = 3, ASK_SECONDS = 120;
const MAX_CLIPS = 3, MAX_CLIP_BYTES = 2 * 1024 * 1024;

export const audioSchema = `
CREATE TABLE speakers(id TEXT PRIMARY KEY,label TEXT NOT NULL,name TEXT,is_me INTEGER NOT NULL DEFAULT 0,status TEXT NOT NULL,merged_into TEXT,centroid BLOB NOT NULL,conversations INTEGER NOT NULL DEFAULT 0,seconds REAL NOT NULL DEFAULT 0,created_at TEXT NOT NULL,updated_at TEXT);
CREATE TABLE voice_embeddings(conversation_ref TEXT NOT NULL,local TEXT NOT NULL,device TEXT NOT NULL,speaker_id TEXT NOT NULL,track TEXT NOT NULL,seconds REAL NOT NULL,centroid BLOB NOT NULL,t_start TEXT NOT NULL,t_end TEXT NOT NULL,PRIMARY KEY(conversation_ref,local));
CREATE INDEX voice_embeddings_speaker ON voice_embeddings(speaker_id);
CREATE TABLE voice_samples(id TEXT PRIMARY KEY,speaker_id TEXT NOT NULL,request_id TEXT NOT NULL,mime TEXT NOT NULL,data BLOB NOT NULL,created_at TEXT NOT NULL);
CREATE TABLE sample_requests(id TEXT PRIMARY KEY,speaker_id TEXT NOT NULL,device TEXT NOT NULL,conversation_ref TEXT NOT NULL,local TEXT NOT NULL,created_at TEXT NOT NULL,fulfilled_at TEXT);
CREATE INDEX sample_requests_speaker ON sample_requests(speaker_id);
CREATE TABLE audio_settings(k TEXT PRIMARY KEY,v TEXT);
PRAGMA user_version=5;
`;
interface Speaker {
  id: string; label: string; name: string | null; is_me: number; status: string;
  centroid: Buffer; conversations: number; seconds: number;
}
interface Embedding { conversation_ref: string; local: string; device: string; speaker_id: string; track: string; seconds: number; centroid: Buffer }
interface SampleRequest { id: string; speaker_id: string; device: string; conversation_ref: string; local: string; fulfilled_at: string | null }
function object(value: unknown): Record<string, unknown> {
  if (!value || typeof value !== "object" || Array.isArray(value)) throw new InputError("音频参数必须是对象");
  return value as Record<string, unknown>;
}
function text(value: unknown, field: string): string {
  if (typeof value !== "string" || !value.trim() || value.length > 512) throw new InputError(`${field} 无效`);
  return value;
}
function deviceName(value: unknown): string {
  const device = text(value, "device");
  if (!/^[a-z0-9][a-z0-9-]{0,62}$/.test(device)) throw new InputError("device 无效");
  return device;
}
function date(value: unknown): string {
  const result = text(value, "时间");
  if (!/^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d(?:\.\d+)?(?:Z|[+-]\d\d:\d\d)$/.test(result) || !Number.isFinite(Date.parse(result))) throw new InputError("时间必须是带时区的 RFC 3339");
  return result;
}
function normalize(vector: number[]): number[] {
  const norm = Math.hypot(...vector);
  return norm ? vector.map(n => n / norm) : vector;
}
function vector(value: unknown): number[] {
  if (!Array.isArray(value) || value.length !== VECTOR_SIZE || !value.every(n => typeof n === "number" && Number.isFinite(n) && Number.isFinite(Math.fround(n)))) throw new InputError("声纹必须是 512 维有限 float32 数值");
  const result = normalize(value);
  if (!result.some(n => n !== 0)) throw new InputError("声纹不能是零向量");
  return result;
}
function pack(v: number[]): Buffer { return Buffer.from(new Float32Array(v).buffer); }
function unpack(blob: Buffer): number[] { return Array.from(new Float32Array(Uint8Array.from(blob).buffer)); }
function similarity(a: number[], b: number[]): number { return a.reduce((n, v, i) => n + v * b[i]!, 0); }
function weighted(parts: { centroid: Buffer; seconds: number }[]): number[] {
  const result = Array<number>(VECTOR_SIZE).fill(0);
  const scale = Math.max(...parts.map(p => Math.abs(p.seconds)));
  if (scale) for (const p of parts) unpack(p.centroid).forEach((v, i) => { result[i]! += v * (p.seconds / scale); });
  // 零秒样本仍可建说话人；没有有效权重时保留已有方向，避免下发零向量。
  return result.some(n => n !== 0) ? normalize(result) : parts.length ? normalize(unpack(parts[0]!.centroid)) : result;
}
function label(index: number): string {
  let suffix = "";
  do { suffix = String.fromCharCode(65 + index % 26) + suffix; index = Math.floor(index / 26) - 1; } while (index >= 0);
  return `说话人 ${suffix}`;
}

export class AudioStore {
  constructor(readonly hub: HubDB) {}
  private get sql() { return this.hub.db; }
  private setting<T>(key: string, fallback: T): T {
    const row = this.sql.prepare("SELECT v FROM audio_settings WHERE k=?").get(key) as { v: string } | undefined;
    return row ? JSON.parse(row.v) as T : fallback;
  }
  private set(key: string, value: unknown) {
    this.sql.prepare("INSERT INTO audio_settings VALUES(?,?) ON CONFLICT(k) DO UPDATE SET v=excluded.v").run(key, JSON.stringify(value));
  }
  speaker(id: string): Speaker | undefined { return this.sql.prepare("SELECT * FROM speakers WHERE id=?").get(id) as Speaker | undefined; }
  private activeSpeakers(): Speaker[] { return this.sql.prepare("SELECT * FROM speakers WHERE status!='merged' ORDER BY created_at,id").all() as Speaker[]; }
  private contributions(speaker: Speaker): Embedding[] | null {
    const rows = this.sql.prepare("SELECT * FROM voice_embeddings WHERE speaker_id=?").all(speaker.id) as Embedding[];
    const seconds = rows.reduce((n,r) => n+r.seconds,0);
    // skipped 和删除会保留聚合中心；逐条贡献齐全时直接重算，避免归一化后的中心相减造成漂移。
    return Math.abs(seconds-speaker.seconds) <= Math.max(1,speaker.seconds)*1e-12 && new Set(rows.map(r => r.conversation_ref)).size === speaker.conversations ? rows : null;
  }

  settings() { return { retention_days: this.setting("retention_days", 7) }; }
  updateSettings(value: unknown) {
    const b = object(value);
    if (!Number.isInteger(b.retention_days) || Number(b.retention_days) < 1 || Number(b.retention_days) > 365) throw new InputError("retention_days 必须是 1–365 的整数");
    this.set("retention_days", b.retention_days);
    return this.settings();
  }
  purge() { const purge_before = new Date().toISOString(); this.set("purge_before", purge_before); return { purge_before }; }
  sync(value: unknown) {
    const device = deviceName(value);
    return this.sql.transaction(() => {
      const me = this.activeSpeakers().filter(s => s.is_me);
      const purge = this.setting<string | null>("purge_before", null);
      const ack = this.setting<string | null>(`purged:${device}`, null);
      return {
        ...this.settings(), purge_before: purge && (!ack || Date.parse(ack) < Date.parse(purge)) ? purge : null,
        voiceprint: me.length ? { vector: weighted(me), threshold: this.setting("me_threshold", DEFAULT_ME_THRESHOLD) } : null,
        sample_requests: this.sql.prepare("SELECT id,speaker_id,conversation_ref,local FROM sample_requests WHERE device=? AND fulfilled_at IS NULL ORDER BY created_at,id").all(device),
        delete_conversations: this.setting<string[]>(`delete:${device}`, []),
      };
    })();
  }
  ack(value: unknown) {
    const b = object(value), device = deviceName(b.device);
    const purged = b.purged_at === undefined ? undefined : date(b.purged_at);
    if (b.deleted !== undefined && (!Array.isArray(b.deleted) || !b.deleted.every(v => typeof v === "string" && v.length > 0 && v.length <= 512))) throw new InputError("deleted 必须是对话键数组");
    return this.sql.transaction(() => {
      if (purged) {
        const purge = this.setting<string | null>("purge_before", null);
        // 只确认 hub 已发出的清理时刻，未来时间不能吞掉下一次清理。
        const previous = this.setting<string | null>(`purged:${device}`, null);
        if (purge && Date.parse(purged) >= Date.parse(purge) && (!previous || Date.parse(previous) < Date.parse(purge))) this.set(`purged:${device}`, purge);
      }
      if (b.deleted) this.set(`delete:${device}`, this.setting<string[]>(`delete:${device}`, []).filter(ref => !(b.deleted as string[]).includes(ref)));
      return { acknowledged: true };
    }).immediate();
  }
  embeddings(value: unknown) {
    const b = object(value), device = deviceName(b.device), ref = text(b.conversation_ref, "conversation_ref");
    const start = date(b.t_start), end = date(b.t_end);
    if (Date.parse(end) < Date.parse(start) || !Array.isArray(b.speakers) || !b.speakers.length) throw new InputError("对话时间或说话人无效");
    const input = b.speakers.map(raw => {
      const s = object(raw), local = text(s.local, "local");
      if (!["mic", "sys"].includes(String(s.track)) || typeof s.seconds !== "number" || !Number.isFinite(s.seconds) || s.seconds < 0) throw new InputError("track 或 seconds 无效");
      return { local, track: s.track as string, seconds: s.seconds, centroid: pack(vector(s.centroid)) };
    });
    if (new Set(input.map(s => s.local)).size !== input.length) throw new InputError("local 不能重复");
    return this.sql.transaction(() => {
      if (this.sql.prepare("SELECT 1 FROM tombstones WHERE source='mac.audio' AND source_ref=?").get(ref)) throw new InputError("对话已删除");
      const old = this.sql.prepare("SELECT * FROM voice_embeddings WHERE conversation_ref=?").all(ref) as Embedding[];
      if (old.some(s => s.device !== device)) throw new InputError("对话属于其他设备");
      // 原样重传不更改中心和累计次数。
      const same = old.length === input.length && input.every(s => old.some(o => o.local === s.local && o.track === s.track && o.seconds === s.seconds && o.centroid.equals(s.centroid))) &&
        (this.sql.prepare("SELECT 1 FROM voice_embeddings WHERE conversation_ref=? AND (t_start!=? OR t_end!=?)").get(ref,start,end) === undefined);
      if (same) return { speakers: input.map(s => this.mapping(s.local, old.find(o => o.local === s.local)!.speaker_id)) };
      // 覆盖时先撤回旧贡献，不把重复上传计作新对话。
      for (const id of new Set(old.map(s => s.speaker_id))) {
        const speaker = this.speaker(id)!;
        const removed = old.filter(s => s.speaker_id === id);
        const seconds = Math.max(0, speaker.seconds - removed.reduce((n,s) => n+s.seconds,0));
        const known = this.contributions(speaker);
        const remainder = known ? weighted(known.filter(r => r.conversation_ref !== ref)) :
          weighted([{ centroid: speaker.centroid, seconds: speaker.seconds }, ...removed.map(s => ({ ...s, seconds: -s.seconds }))]);
        this.sql.prepare("UPDATE speakers SET centroid=?,seconds=?,conversations=MAX(0,conversations-1),updated_at=? WHERE id=?").run(pack(seconds ? remainder : unpack(speaker.centroid)), seconds, new Date().toISOString(), id);
      }
      this.sql.prepare("DELETE FROM voice_embeddings WHERE conversation_ref=?").run(ref);
      const result = [];
      const touched = new Set<string>();
      for (const s of input) {
        const v = unpack(s.centroid);
        const best = this.activeSpeakers().map(speaker => ({ speaker, score: similarity(v, unpack(speaker.centroid)) })).sort((a,b) => b.score-a.score)[0];
        let speaker = best && best.score >= MATCH_THRESHOLD ? best.speaker : undefined;
        const now = new Date().toISOString();
        if (!speaker) {
          const count = (this.sql.prepare("SELECT COUNT(*) AS n FROM speakers").get() as { n: number }).n;
          const id = ulid();
          this.sql.prepare("INSERT INTO speakers(id,label,status,centroid,created_at) VALUES(?,?,'new',?,?)").run(id,label(count),s.centroid,now);
          speaker = this.speaker(id)!;
        }
        if (!Number.isFinite(speaker.seconds + s.seconds)) throw new InputError("累计 seconds 超出范围");
        const center = weighted([...(this.contributions(speaker) ?? [speaker]), s]);
        this.sql.prepare("UPDATE speakers SET centroid=?,seconds=seconds+?,conversations=conversations+?,updated_at=? WHERE id=?").run(pack(center.some(n => n !== 0) ? center : v), s.seconds, Number(!touched.has(speaker.id)), now, speaker.id);
        this.sql.prepare("INSERT INTO voice_embeddings VALUES(?,?,?,?,?,?,?,?,?)").run(ref,s.local,device,speaker.id,s.track,s.seconds,s.centroid,start,end);
        touched.add(speaker.id);
        result.push(this.mapping(s.local, speaker.id));
      }
      for (const id of touched) this.ask(id);
      return { speakers: result };
    }).immediate();
  }
  private mapping(local: string, id: string) {
    const s = this.speaker(id)!;
    return { local, speaker_id: id, label: s.name ?? s.label, is_me: Boolean(s.is_me) };
  }
  private ask(id: string) {
    const s = this.speaker(id)!;
    if (s.status !== "new" || s.conversations < ASK_CONVERSATIONS && s.seconds < ASK_SECONDS) return;
    const now = new Date().toISOString();
    this.sql.prepare("INSERT INTO pending(id,kind,payload,created_at) VALUES(?,'voice',?,?)").run(ulid(),JSON.stringify({ speaker_id: id }),now);
    this.sql.prepare("UPDATE speakers SET status='asked',updated_at=? WHERE id=?").run(now,id);
    // 一段对话可能有多个本地标签归到同一个人，只选其中最长的样本。
    const rows = this.sql.prepare(`SELECT * FROM (SELECT *,SUM(seconds) OVER(PARTITION BY conversation_ref) AS conversation_seconds,ROW_NUMBER() OVER(PARTITION BY conversation_ref ORDER BY seconds DESC,local) AS rank FROM voice_embeddings WHERE speaker_id=?) WHERE rank=1 ORDER BY conversation_seconds DESC,conversation_ref LIMIT 3`).all(id) as Embedding[];
    for (const r of rows) this.sql.prepare("INSERT INTO sample_requests(id,speaker_id,device,conversation_ref,local,created_at) VALUES(?,?,?,?,?,?)").run(ulid(),id,r.device,r.conversation_ref,r.local,now);
  }
  pendingPayload(id: string): Record<string, unknown> | null {
    const s = this.speaker(id);
    if (!s || s.status !== "asked") return null;
    return { speaker_id: id, label: s.label, conversations: s.conversations, seconds: s.seconds,
      samples: this.sql.prepare("SELECT id,mime FROM voice_samples WHERE speaker_id=? ORDER BY created_at,id").all(id),
      samples_pending: Boolean(this.sql.prepare("SELECT 1 FROM sample_requests WHERE speaker_id=? AND fulfilled_at IS NULL LIMIT 1").get(id)) };
  }
  resolve(id: string, action: string, name?: string, target?: string) {
    const s = this.speaker(id);
    if (!s || s.status !== "asked") throw new InputError("说话人不存在或已处理");
    const now = new Date().toISOString();
    if (action === "me") this.sql.prepare("UPDATE speakers SET is_me=1,name='我',status='confirmed',updated_at=? WHERE id=?").run(now,id);
    else if (action === "rename") {
      if (!name?.trim()) throw new InputError("需要说话人名字");
      this.sql.prepare("UPDATE speakers SET name=?,status='confirmed',updated_at=? WHERE id=?").run(name.trim(),now,id);
    } else if (action === "ignore") this.sql.prepare("UPDATE speakers SET status='ignored',updated_at=? WHERE id=?").run(now,id);
    else if (action === "merge_into") {
      const dest = target ? this.speaker(target) : undefined;
      if (!dest || dest.id === id || dest.status === "merged") throw new InputError("说话人合并目标无效");
      const overlap = (this.sql.prepare("SELECT COUNT(DISTINCT conversation_ref) AS n FROM voice_embeddings WHERE speaker_id=? AND conversation_ref IN (SELECT conversation_ref FROM voice_embeddings WHERE speaker_id=?)").get(id,dest.id) as { n: number }).n;
      const center = weighted([dest,s]);
      if (!Number.isFinite(dest.seconds+s.seconds)) throw new InputError("累计 seconds 超出范围");
      this.sql.prepare("UPDATE speakers SET centroid=?,seconds=?,conversations=?,is_me=?,name=?,updated_at=? WHERE id=?").run(pack(center.some(n => n !== 0) ? center : unpack(dest.centroid)), dest.seconds+s.seconds, dest.conversations+s.conversations-overlap, Number(Boolean(dest.is_me || s.is_me)), dest.is_me || s.is_me ? "我" : dest.name, now,dest.id);
      this.sql.prepare("UPDATE voice_embeddings SET speaker_id=? WHERE speaker_id=?").run(dest.id,id);
      this.sql.prepare("UPDATE speakers SET status='merged',merged_into=?,updated_at=? WHERE id=?").run(dest.id,now,id);
      this.ask(dest.id);
    } else throw new InputError("说话人操作无效");
    this.sql.prepare("DELETE FROM voice_samples WHERE speaker_id=?").run(id);
    this.sql.prepare("DELETE FROM sample_requests WHERE speaker_id=?").run(id);
  }
  skipped(ref: string) {
    text(ref,"conversation_ref");
    this.sql.prepare("DELETE FROM voice_embeddings WHERE conversation_ref=?").run(ref);
    return { skipped: true };
  }
  uploadSamples(value: unknown) {
    const b = object(value), requestId = text(b.request_id,"request_id");
    if (!Array.isArray(b.clips) || !b.clips.length || b.clips.length > MAX_CLIPS) throw new InputError("试听样本必须是 1–3 段");
    const clips = b.clips.map(raw => {
      const c = object(raw);
      if (c.mime !== "audio/mp4" && c.mime !== "audio/wav") throw new InputError("样本 MIME 无效");
      if (typeof c.data !== "string" || c.data.length > Math.ceil(MAX_CLIP_BYTES/3)*4 || !/^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$/.test(c.data)) throw new InputError("样本 base64 无效或超过 2MB");
      const data = Buffer.from(c.data,"base64");
      if (!data.length || data.length > MAX_CLIP_BYTES || data.toString("base64") !== c.data) throw new InputError("样本 base64 无效或超过 2MB");
      return { mime: c.mime, data };
    });
    return this.sql.transaction(() => {
      const request = this.sql.prepare("SELECT * FROM sample_requests WHERE id=?").get(requestId) as SampleRequest | undefined;
      if (!request || this.speaker(request.speaker_id)?.status !== "asked") throw new InputError("样本请求不存在或已处理");
      const existing = (this.sql.prepare("SELECT COUNT(*) AS n FROM voice_samples WHERE speaker_id=? AND request_id!=?").get(request.speaker_id,requestId) as { n: number }).n;
      if (existing+clips.length > MAX_CLIPS) throw new InputError("每个说话人最多 3 段样本");
      this.sql.prepare("DELETE FROM voice_samples WHERE request_id=?").run(requestId);
      const now = new Date().toISOString();
      for (const c of clips) this.sql.prepare("INSERT INTO voice_samples VALUES(?,?,?,?,?,?)").run(ulid(),request.speaker_id,requestId,c.mime,c.data,now);
      this.sql.prepare("UPDATE sample_requests SET fulfilled_at=? WHERE id=?").run(now,requestId);
      return { uploaded: clips.length };
    }).immediate();
  }
  sample(id: string) { return this.sql.prepare("SELECT mime,data FROM voice_samples WHERE id=?").get(id) as { mime: string; data: Buffer } | undefined; }
  speakers() { return { speakers: this.activeSpeakers().map(s => ({ id: s.id, label: s.label, name: s.name, is_me: Boolean(s.is_me), confirmed: s.status === "confirmed", conversations: s.conversations, seconds: s.seconds })) }; }
  /** 由 removeRecord 的删除事务调用，删除队列和逐条声纹一起提交。 */
  removeConversation(ref: string, device: string) {
    const devices = new Set([device, ...(this.sql.prepare("SELECT DISTINCT device FROM voice_embeddings WHERE conversation_ref=?").all(ref) as { device: string }[]).map(r => r.device)]);
    for (const d of devices) this.set(`delete:${d}`, [...new Set([...this.setting<string[]>(`delete:${d}`,[]),ref])]);
    this.sql.prepare("DELETE FROM voice_embeddings WHERE conversation_ref=?").run(ref);
    const requests = this.sql.prepare("SELECT id FROM sample_requests WHERE conversation_ref=?").all(ref) as { id: string }[];
    for (const r of requests) this.sql.prepare("DELETE FROM voice_samples WHERE request_id=?").run(r.id);
    this.sql.prepare("DELETE FROM sample_requests WHERE conversation_ref=?").run(ref);
  }
}
