import type { Api } from "./distillation.ts";
import { durationText } from "./history.ts";

type Counts = Record<string, number>;
export interface TierUsage { tier: string; models: string[]; calls: number; ok: number; failed: number; input_tokens: number | null; output_tokens: number | null; ms: number }
/** 与 hub/src/status.ts 的返回保持一致。 */
export interface HubStatus {
  generated_at: string;
  hub: { started_at: string; uptime_s: number; pid: number; bun: string | null; schema_version: number; busy: { since: string; total: number; by_route: { ingest: number; agent: number; web: number }; last_at: string | null } };
  listen: { host: string; port: number; localhost_only: boolean };
  database: { file: string; bytes: number | null };
  records: { total: number; tombstones: number; by_source: { source: string; count: number; last_received: string | null }[]; by_device: { device: string; count: number; last_received: string | null }[] };
  distill: {
    enabled_at: string | null; heartbeat_at: string | null; last_round_at: string | null; last_slow_round_at: string | null; cursor_at: string | null; backfill_done: boolean;
    frames: Counts; threads: Counts; needs_regen: { threads: number; projects: number; days: number }; pending_open: Counts;
    /** 提炼请求队列表还不存在时为 null。 */
    requests: { total: number; by_status: Counts | null } | null;
    /** recovered：这次失败之后又成功调用过。 */
    last_error: { at: string; tier: string; error: string; recovered?: boolean } | null;
    last_ok_at?: string | null;
  };
  llm_today: { date: string; total: Omit<TierUsage, "tier" | "models">; by_tier: TierUsage[] };
  agent_reads_today: number;
  audio: { speakers: Counts; voice_conversations: number; sample_requests_open: number; deletes_pending: number };
}
export const STATUS_REFRESH_MS = 15_000;
export const fetchStatus = (api: Api, signal?: AbortSignal) => api<HubStatus>("/v1/status", { signal });

/** 模型档位的界面名，设置页和状态页共用（docs/ui.md 用词表）。 */
export const tierNames: Record<string, string> = { minute: "实时整理", hour: "每小时汇总", day: "每日日记" };
export const frameNames: Record<string, string> = { new: "等待整理", assigned: "已归入事项", ignored: "已忽略" };
export const threadNames: Record<string, string> = { active: "进行中", paused: "暂停", done: "完成", archived: "已归档", abandoned: "不做了" };
export const pendingNames: Record<string, string> = { project: "新项目", merge: "可能是同一件事", thread_done: "做完了吗", voice: "新声音" };
export const requestNames: Record<string, string> = { queued: "排队中", running: "进行中", done: "完成", failed: "失败" };
export const speakerNames: Record<string, string> = { new: "新出现", asked: "待确认", confirmed: "已确认", ignored: "已忽略", merged: "已合并" };

const number = new Intl.NumberFormat("zh-CN");
export const formatNumber = (value: number | null) => value === null ? "—" : number.format(value);
export function formatBytes(bytes: number | null): string {
  if (bytes === null) return "—";
  const units = ["B", "KB", "MB", "GB", "TB"];
  let value = bytes, unit = 0;
  while (value >= 1024 && unit < units.length - 1) { value /= 1024; unit++; }
  return `${unit === 0 ? value : value.toFixed(value < 10 ? 1 : 0)} ${units[unit]}`;
}
export function formatUptime(seconds: number): string {
  const days = Math.floor(seconds / 86400), hours = Math.floor(seconds % 86400 / 3600), minutes = Math.floor(seconds % 3600 / 60);
  if (days) return `${days} 天 ${hours} 小时`;
  if (hours) return `${hours} 小时 ${minutes} 分`;
  return minutes ? `${minutes} 分钟` : `${seconds} 秒`;
}
/** 模型调用的累计耗时，写法同其他时长。 */
export function formatMs(ms: number): string {
  if (ms < 1000) return ms > 0 ? "不到 1 秒" : "0 秒";
  return ms < 60_000 ? `${Math.round(ms / 1000)} 秒` : durationText(ms / 1000);
}
/** 计数按给定顺序列出，已知名称在前，未知状态原样附在后面。 */
export function countList(counts: Counts, names: Record<string, string>): { key: string; label: string; count: number }[] {
  const known = Object.keys(names).filter(key => key in counts);
  const rest = Object.keys(counts).filter(key => !(key in names)).sort();
  return [...known, ...rest].map(key => ({ key, label: names[key] ?? key, count: counts[key]! }));
}
