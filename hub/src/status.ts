import type { RelayService } from "./devices/relay.ts";
import { deviceList } from "./devices/store.ts";
import { BusyResponses } from "./db-busy.ts";
import { readFileSync, statSync } from "node:fs";
import { dirname, join } from "node:path";
import { toLocalIso } from "../../packages/record/index.ts";
import type { HubDB } from "./db.ts";
import { readGeneral } from "./general-settings.ts";
import { budgetCooldown, providerCooldown } from "./distill/cooldown.ts";
import type { RequestStatus } from "./distill/requests.ts";
import { hubModeOf, timezoneStatus, type HubMode } from "./hub-json.ts";
import { inspectModelConfig } from "./llm/config.ts";
import { modelUsageDayStart, modelUsageRows, usageTokens } from "./model-usage.ts";

/**
 * 中枢状态页的数据：只给计数、时间和状态，不读记录的标题和正文。
 * 必须只读：不调用 DistillStore.pending() 这类会顺带改库的方法。
 */
type Counts = Record<string, number>;
interface UsageTotals {
  calls: number; ok: number; failed: number; ms: number;
  input_tokens: number | null; output_tokens: number | null;
  input_tokens_incomplete: boolean; output_tokens_incomplete: boolean;
}
interface RequestRow {
  id: string; status: RequestStatus; done: number | null; total: number | null; error: string | null;
  created_at: string; updated_at: string;
}

const emptyUsage = (): UsageTotals => ({
  calls: 0, ok: 0, failed: 0, ms: 0, input_tokens: null, output_tokens: null,
  input_tokens_incomplete: false, output_tokens_incomplete: false,
});
function addUsage(sum: UsageTotals, row: UsageTotals) {
  sum.calls += row.calls;
  sum.ok += row.ok;
  sum.failed += row.failed;
  sum.ms += row.ms;
  if (row.input_tokens !== null) sum.input_tokens = (sum.input_tokens ?? 0) + row.input_tokens;
  if (row.output_tokens !== null) sum.output_tokens = (sum.output_tokens ?? 0) + row.output_tokens;
  sum.input_tokens_incomplete ||= row.input_tokens_incomplete;
  sum.output_tokens_incomplete ||= row.output_tokens_incomplete;
}

const errorCode = /^(timeout|network|rate_limited|quota|auth|bad_request|server_error|invalid_json|schema_mismatch|cli_failed|usage_record_failed|config_error|unknown)(?::[1-5][0-9]{2})?$/;
function statusError(value: string | null): string | null {
  if (value === null) return null;
  const code = errorCode.exec(value)?.[0];
  return code === value ? code : "unknown";
}

function isoTimestamp(value: unknown): string | null {
  return typeof value === "string" && /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:\d{2})$/.test(value)
    && Number.isFinite(Date.parse(value)) ? value : null;
}

const nonnegativeCount = (value: unknown): value is number =>
  typeof value === "number" && Number.isSafeInteger(value) && value >= 0;

function collectorSnapshot(databaseFile: string, now: number) {
  const unavailable = { transcription: null, transcription_disabled: false, collector: null };
  if (!databaseFile || databaseFile === ":memory:") return unavailable;
  // history.db 与采集端快照放在同一个已解析的数据目录中。
  try {
    const snapshot = JSON.parse(readFileSync(join(dirname(databaseFile), "collector-status.json"), "utf8"));
    const updated_at = isoTimestamp(snapshot?.time);
    if (!updated_at) return unavailable;
    const stale = now - Date.parse(updated_at) > 120_000;
    const { transcription, outboxBytes, outboxDropped, outboxDegraded } = snapshot;
    const pending: unknown = transcription?.pending;
    const failed: unknown = transcription?.failed;
    return {
      transcription: nonnegativeCount(pending) && nonnegativeCount(failed) ? { pending, failed, updated_at, stale } : null,
      transcription_disabled: transcription === null && !stale,
      collector: nonnegativeCount(outboxBytes) && nonnegativeCount(outboxDropped) && typeof outboxDegraded === "boolean"
        ? { outbox_bytes: outboxBytes, outbox_dropped: outboxDropped, outbox_degraded: outboxDegraded, updated_at, stale }
        : null,
    };
  } catch {
    return unavailable;
  }
}

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

export function hubStatus(hub: HubDB, options: {
  port: number | null; lanPort?: number | null; now?: number;
  busy?: ReturnType<BusyResponses["snapshot"]>; relay?: ReturnType<RelayService["status"]>;
  mode?: HubMode; env?: NodeJS.ProcessEnv; dataDir?: string; processTimezone?: string;
}) {
  const sql = hub.db;
  const now = options.now ?? Date.now();
  const mode = options.mode ?? hubModeOf(options.env);
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
  const dataDir = options.dataDir ?? (file && file !== ":memory:" ? dirname(file) : undefined);
  const modelCheck = dataDir ? inspectModelConfig(dataDir, { mode, env: options.env }) : { ok: true as const };
  const modelConfigError = modelCheck.ok ? null : modelCheck.error;
  const timezone = timezoneStatus({ env: options.env, dataDir, mode, processTimezone: options.processTimezone });
  const { transcription, transcription_disabled, collector } = collectorSnapshot(file, now);

  const { bySource, byDevice, tombstones } = recordGroups(hub);

  const today = localDate(now);
  const dayStart = modelUsageDayStart(now);
  const usage = modelUsageRows(hub, dayStart, now);
  const tiers = new Map<string, UsageTotals & { tier: string; modelSet: Set<string> }>();
  const tasks = new Map<string | null, UsageTotals & { task: string | null }>();
  const total = emptyUsage();
  for (const r of usage) {
    const tier = r.tier ?? "未知";
    const t = tiers.get(tier) ?? { tier, modelSet: new Set<string>(), ...emptyUsage() };
    const task = tasks.get(r.task) ?? { task: r.task, ...emptyUsage() };
    if (r.model) t.modelSet.add(r.model);
    const metrics = {
      calls: 1, ok: r.ok ? 1 : 0, failed: r.ok ? 0 : 1, ms: r.ms ?? 0,
      input_tokens: r.input_tokens, output_tokens: r.output_tokens,
      input_tokens_incomplete: r.input_tokens === null, output_tokens_incomplete: r.output_tokens === null,
    };
    addUsage(t, metrics);
    addUsage(task, metrics);
    addUsage(total, metrics);
    tiers.set(tier, t);
    tasks.set(r.task, task);
  }
  const byTier = [...tiers.values()].map(({ modelSet, ...t }) => ({ ...t, models: [...modelSet].sort() })).sort((a, b) => tierRank(a.tier) - tierRank(b.tier) || a.tier.localeCompare(b.tier));
  const byTask = [...tasks.values()].sort((a, b) => (a.task ?? "").localeCompare(b.task ?? ""));
  const dailyLimit = readGeneral(hub).daily_token_limit;
  const todayTokens = usageTokens(total);

  // at 有本地时间和 UTC 两种写法，按 ULID 判断调用写入顺序。旧行缺少用途，无法证明同类恢复。
  const lastError = sql.prepare("SELECT id,at,tier,task,error FROM llm_usage WHERE ok=0 ORDER BY id DESC LIMIT 1").get() as
    { id: string; at: string; tier: string | null; task: string | null; error: string | null } | undefined;
  const recovered = !!(lastError?.tier && lastError.task && sql.prepare(
    "SELECT 1 FROM llm_usage WHERE id>? AND ok=1 AND tier=? AND task=? LIMIT 1",
  ).get(lastError.id, lastError.tier, lastError.task));
  const lastOk = sql.prepare("SELECT at FROM llm_usage WHERE ok=1 ORDER BY id DESC LIMIT 1").get() as { at: string } | undefined;
  const deletes = (sql.prepare("SELECT v FROM audio_settings WHERE k GLOB 'delete:*'").all() as { v: string }[])
    .reduce((n, r) => { try { const v = JSON.parse(r.v); return n + (Array.isArray(v) ? v.length : 0); } catch { return n; } }, 0);
  // 进度写入没有单独的时间戳，updated_at 是最近一次可观测的状态转换时间。
  const recentRequests = sql.prepare(`
    SELECT id,status,progress_done AS done,progress_total AS total,error,created_at,
      COALESCE(finished_at,started_at,created_at) AS updated_at
    FROM distill_requests ORDER BY created_at DESC,id DESC LIMIT 5
  `).all() as RequestRow[];
  const requests = {
    total: scalar<number>("SELECT COUNT(*) FROM distill_requests"),
    by_status: counts("SELECT status AS k,COUNT(*) AS n FROM distill_requests GROUP BY status"),
    recent: recentRequests.map(row => ({ ...row, error: statusError(row.error) })),
  };

  return {
    devices: deviceList(hub),
    relay: options.relay ?? null,
    generated_at: toLocalIso(now),
    hub: {
      started_at: toLocalIso(now - Math.round(process.uptime() * 1000)),
      uptime_s: Math.round(process.uptime()),
      pid: process.pid,
      bun: typeof Bun === "undefined" ? null : Bun.version,
      busy: options.busy ?? new BusyResponses().snapshot(),
      schema_version: sql.pragma("user_version", { simple: true }) as number,
      mode,
    },
    timezone,
    // 本机接口只绑定 127.0.0.1；有配对邀请或已配对设备时（server 模式下常开），另开只收加密设备请求的端口。
    listen: { host: options.port === null ? "0.0.0.0" : "127.0.0.1", port: options.port, localhost_only: !options.lanPort, lan_port: options.lanPort ?? null },
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
      last_round_at: time(state("last_round_at")),
      last_slow_round_at: time(state("slow_ms")),
      cursor_at: time(state("cursor_ms")),
      backfill_done: state("backfill_done") === true,
      frames: counts("SELECT status AS k,COUNT(*) AS n FROM frames GROUP BY status"),
      threads: counts("SELECT status AS k,COUNT(*) AS n FROM threads GROUP BY status"),
      needs_regen: {
        threads: scalar<number>("SELECT COUNT(*) FROM threads WHERE needs_regen=1 AND status!='abandoned'"),
        projects: scalar<number>("SELECT COUNT(*) FROM projects WHERE needs_regen=1 OR EXISTS(SELECT 1 FROM distill_state WHERE k='project_brief:'||projects.id AND v='true')"),
        days: scalar<number>("SELECT COUNT(*) FROM days WHERE needs_regen=1"),
      },
      pending_open: counts("SELECT kind AS k,COUNT(*) AS n FROM pending WHERE resolved_at IS NULL GROUP BY kind"),
      requests,
      last_error: lastError ? { at: lastError.at, tier: lastError.tier, error: statusError(lastError.error) ?? "unknown", recovered } : null,
      last_ok_at: lastOk?.at ?? null,
      cooldown: budgetCooldown(now, dailyLimit, todayTokens) ?? providerCooldown(state("llm_cooldown"), now),
      config_error: modelConfigError,
      paused_reason: modelConfigError,
    },
    collector,
    llm_today: { date: today, total, by_tier: byTier, by_task: byTask, used_tokens: todayTokens, token_limit: dailyLimit },
    agent_reads_today: (sql.prepare("SELECT at FROM agent_reads WHERE at>=?").all(localDate(dayStart - 86_400_000)) as { at: string }[]).filter(r => Date.parse(r.at) >= dayStart).length,
    audio: {
      transcription,
      transcription_disabled,
      // 提问被关闭（例如 F9 收尾）后说话人仍是 asked；只有还挂着未答提问的才算“已问”。
      speakers: counts(`SELECT CASE WHEN s.status='asked' AND NOT EXISTS (SELECT 1 FROM pending p WHERE p.kind='voice'
        AND p.resolved_at IS NULL AND json_extract(p.payload,'$.speaker_id')=s.id) THEN 'new' ELSE s.status END AS k,
        COUNT(*) AS n FROM speakers s GROUP BY k`),
      voice_conversations: scalar<number>("SELECT COUNT(DISTINCT conversation_ref) FROM voice_embeddings"),
      sample_requests_open: scalar<number>("SELECT COUNT(*) FROM sample_requests WHERE fulfilled_at IS NULL"),
      deletes_pending: deletes,
    },
  };
}
export type HubStatus = ReturnType<typeof hubStatus>;
