import { statSync } from "node:fs";
import { toLocalIso } from "../../packages/record/index.ts";
import type { HubDB } from "./db.ts";

/**
 * 中枢状态页的数据：只给计数、时间和状态，不读记录的标题和正文。
 * 必须只读：不调用 DistillStore.pending() 这类会顺带改库的方法。
 */
type Counts = Record<string, number>;
interface UsageRow { at: string | null; tier: string | null; model: string | null; ok: number | null; input_tokens: number | null; output_tokens: number | null; ms: number | null }
interface TierUsage { tier: string; models: string[]; calls: number; ok: number; failed: number; input_tokens: number | null; output_tokens: number | null; ms: number }

const tierOrder = ["minute", "hour", "day"];
const tierRank = (tier: string) => { const i = tierOrder.indexOf(tier); return i < 0 ? tierOrder.length : i; };
const pad = (n: number) => String(n).padStart(2, "0");
const localDate = (ms: number) => { const d = new Date(ms); return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}`; };

/**
 * 按来源、设备的记录数和最近入库时间。整表扫描十几万条要几百毫秒，而记录只追加、删除必留墓碑，
 * 所以按 (最大 rowid, 墓碑数) 缓存：只有新增时增量扫新行，出现删除才全量重算。
 * 最近入库取每组最大 rowid 那一行的 t_received（rowid 越大越晚入库），避免为 MAX(t_received) 读穿正文。
 */
interface GroupCache { maxRowid: number; tombstones: number; groups: Map<string, { source: string; device: string; count: number; last: number }> }
const groupCaches = new WeakMap<HubDB, GroupCache>();
function recordGroups(hub: HubDB) {
  const sql = hub.db;
  const maxRowid = (sql.prepare("SELECT MAX(rowid) AS n FROM records").get() as { n: number | null }).n ?? 0;
  const tombstones = (sql.prepare("SELECT COUNT(*) AS n FROM tombstones").get() as { n: number }).n;
  let cache = groupCaches.get(hub);
  if (!cache || cache.tombstones !== tombstones || cache.maxRowid > maxRowid) cache = { maxRowid: 0, tombstones, groups: new Map() };
  if (cache.maxRowid < maxRowid) {
    const rows = sql.prepare("SELECT source,device,COUNT(*) AS n,MAX(rowid) AS last FROM records WHERE rowid>? AND rowid<=? GROUP BY source,device").all(cache.maxRowid, maxRowid) as { source: string; device: string; n: number; last: number }[];
    for (const r of rows) {
      const key = JSON.stringify([r.source, r.device]);
      const g = cache.groups.get(key);
      if (g) { g.count += r.n; g.last = Math.max(g.last, r.last); }
      else cache.groups.set(key, { source: r.source, device: r.device, count: r.n, last: r.last });
    }
    cache.maxRowid = maxRowid;
  }
  groupCaches.set(hub, cache);
  const received = sql.prepare("SELECT t_received FROM records WHERE rowid=?");
  const merge = (column: "source" | "device") => {
    const merged = new Map<string, { count: number; last: number }>();
    for (const g of cache.groups.values()) {
      const m = merged.get(g[column]) ?? { count: 0, last: 0 };
      m.count += g.count; m.last = Math.max(m.last, g.last);
      merged.set(g[column], m);
    }
    return [...merged].sort((a, b) => b[1].count - a[1].count || a[0].localeCompare(b[0]))
      .map(([k, m]) => ({ [column]: k, count: m.count, last_received: (received.get(m.last) as { t_received: string } | undefined)?.t_received ?? null }));
  };
  return { bySource: merge("source") as { source: string; count: number; last_received: string | null }[], byDevice: merge("device") as { device: string; count: number; last_received: string | null }[], tombstones };
}

export function hubStatus(hub: HubDB, options: { port: number; now?: number }) {
  const sql = hub.db;
  const now = options.now ?? Date.now();
  const counts = (query: string, ...args: unknown[]): Counts =>
    Object.fromEntries((sql.prepare(query).all(...args) as { k: string; n: number }[]).map(r => [r.k, r.n]));
  const scalar = <T>(query: string, ...args: unknown[]): T => Object.values(sql.prepare(query).get(...args) as Record<string, T>)[0]!;
  const state = (key: string): unknown => {
    const row = sql.prepare("SELECT v FROM distill_state WHERE k=?").get(key) as { v: string } | undefined;
    if (!row) return null;
    try { return JSON.parse(row.v); } catch { return null; }
  };
  // distill_state 里的时间多数是毫秒数，统一转成带时区的本地时间。
  const time = (value: unknown): string | null =>
    typeof value === "number" && Number.isFinite(value) ? toLocalIso(value) : typeof value === "string" && Number.isFinite(Date.parse(value)) ? value : null;

  const file = sql.name;
  let bytes: number | null = null;
  if (file && file !== ":memory:") { try { bytes = statSync(file).size; } catch { bytes = null; } }

  const { bySource, byDevice, tombstones } = recordGroups(hub);

  // 用量的 at 有本地时间和 UTC 两种写法：先按日期前缀粗筛，再按时刻精确判断是否属于今天。
  const today = localDate(now);
  const dayStart = new Date(`${today}T00:00:00`).getTime();
  const usage = (sql.prepare("SELECT at,tier,model,ok,input_tokens,output_tokens,ms FROM llm_usage WHERE at>=?").all(localDate(dayStart - 86_400_000)) as UsageRow[])
    .filter(r => r.at !== null && Date.parse(r.at) >= dayStart && Date.parse(r.at) <= now + 60_000);
  const tiers = new Map<string, TierUsage & { modelSet: Set<string> }>();
  const add = (sum: number | null, value: number | null) => value === null ? sum : (sum ?? 0) + value;
  for (const r of usage) {
    const tier = r.tier ?? "未知";
    const t = tiers.get(tier) ?? { tier, models: [], modelSet: new Set<string>(), calls: 0, ok: 0, failed: 0, input_tokens: null, output_tokens: null, ms: 0 };
    t.calls++; if (r.ok) t.ok++; else t.failed++;
    if (r.model) t.modelSet.add(r.model);
    t.input_tokens = add(t.input_tokens, r.input_tokens); t.output_tokens = add(t.output_tokens, r.output_tokens);
    t.ms += r.ms ?? 0;
    tiers.set(tier, t);
  }
  const byTier = [...tiers.values()].map(({ modelSet, ...t }) => ({ ...t, models: [...modelSet].sort() })).sort((a, b) => tierRank(a.tier) - tierRank(b.tier) || a.tier.localeCompare(b.tier));
  const total = byTier.reduce((s, t) => ({ calls: s.calls + t.calls, ok: s.ok + t.ok, failed: s.failed + t.failed, input_tokens: add(s.input_tokens, t.input_tokens), output_tokens: add(s.output_tokens, t.output_tokens), ms: s.ms + t.ms }),
    { calls: 0, ok: 0, failed: 0, input_tokens: null as number | null, output_tokens: null as number | null, ms: 0 });

  // 模型错误在写入 llm_usage 前已由 safeError 去掉提示词内容；这里再截短。at 有两种时间写法，按 ULID 取最新。
  const lastError = sql.prepare("SELECT at,tier,error FROM llm_usage WHERE ok=0 ORDER BY id DESC LIMIT 1").get() as { at: string; tier: string; error: string | null } | undefined;
  const nowState = state("now") as { updated_at?: unknown } | null;
  const deletes = (sql.prepare("SELECT v FROM audio_settings WHERE k GLOB 'delete:*'").all() as { v: string }[])
    .reduce((n, r) => { try { const v = JSON.parse(r.v); return n + (Array.isArray(v) ? v.length : 0); } catch { return n; } }, 0);
  // 提炼请求队列（distill_requests，库版本 6 起一定存在）。
  const requests = {
    total: scalar<number>("SELECT COUNT(*) FROM distill_requests"),
    by_status: counts("SELECT status AS k,COUNT(*) AS n FROM distill_requests GROUP BY status"),
  };

  return {
    generated_at: toLocalIso(now),
    hub: {
      started_at: toLocalIso(now - Math.round(process.uptime() * 1000)),
      uptime_s: Math.round(process.uptime()),
      pid: process.pid,
      bun: typeof Bun === "undefined" ? null : Bun.version,
      schema_version: sql.pragma("user_version", { simple: true }) as number,
    },
    // 还没有局域网配对：服务固定只绑定 127.0.0.1。
    listen: { host: "127.0.0.1", port: options.port, localhost_only: true },
    database: { file, bytes },
    records: {
      total: bySource.reduce((n, r) => n + r.count, 0),
      tombstones,
      by_source: bySource,
      by_device: byDevice,
    },
    distill: {
      enabled_at: time(state("enabled_ms")),
      heartbeat_at: time(state("heartbeat_at")),
      last_round_at: time(nowState?.updated_at),
      last_slow_round_at: time(state("slow_ms")),
      cursor_at: time(state("cursor_ms")),
      backfill_done: state("backfill_done") === true,
      frames: counts("SELECT status AS k,COUNT(*) AS n FROM frames GROUP BY status"),
      threads: counts("SELECT status AS k,COUNT(*) AS n FROM threads GROUP BY status"),
      needs_regen: {
        threads: scalar<number>("SELECT COUNT(*) FROM threads WHERE needs_regen=1 AND status!='abandoned'"),
        projects: scalar<number>("SELECT COUNT(*) FROM projects WHERE needs_regen=1"),
        days: scalar<number>("SELECT COUNT(*) FROM days WHERE needs_regen=1"),
      },
      pending_open: counts("SELECT kind AS k,COUNT(*) AS n FROM pending WHERE resolved_at IS NULL GROUP BY kind"),
      requests,
      last_error: lastError ? { at: lastError.at, tier: lastError.tier, error: (lastError.error ?? "").slice(0, 300) } : null,
    },
    llm_today: { date: today, total, by_tier: byTier },
    agent_reads_today: (sql.prepare("SELECT at FROM agent_reads WHERE at>=?").all(localDate(dayStart - 86_400_000)) as { at: string }[]).filter(r => Date.parse(r.at) >= dayStart).length,
    // 转写在各设备本地进行，中枢只收文字和声纹，没有转写队列可报。
    audio: {
      speakers: counts("SELECT status AS k,COUNT(*) AS n FROM speakers GROUP BY status"),
      voice_conversations: scalar<number>("SELECT COUNT(DISTINCT conversation_ref) FROM voice_embeddings"),
      sample_requests_open: scalar<number>("SELECT COUNT(*) FROM sample_requests WHERE fulfilled_at IS NULL"),
      deletes_pending: deletes,
    },
  };
}
export type HubStatus = ReturnType<typeof hubStatus>;
