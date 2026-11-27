import { AGENT_SESSION_NAMES } from "../../packages/record/agent-tools.ts";
import type { Api } from "./distillation.ts";
import { englishLocale, type Lang } from "./i18n.ts";
import { durationText } from "./history.ts";
import { formatDate, formatDuration } from "../../hub/src/i18n/index.ts";

type Counts = Record<string, number>;
export interface TierUsage {
  tier: string; models: string[]; calls: number; ok: number; failed: number; ms: number;
  input_tokens: number | null; output_tokens: number | null;
  input_tokens_incomplete: boolean; output_tokens_incomplete: boolean;
}
interface CollectorUpdate { updated_at: string; stale: boolean }
interface ManualRequest {
  id: string; status: "queued" | "running" | "done" | "failed";
  done: number | null; total: number | null; error: string | null; created_at: string; updated_at: string;
}
/** 与 hub/src/status.ts 的返回保持一致。 */
export interface HubStatus {
  generated_at: string;
  language?: Lang;
  hub: { started_at: string; uptime_s: number; pid: number; bun: string | null; schema_version: number; busy: { since: string; total: number; by_route: { ingest: number; agent: number; web: number }; last_at: string | null } };
  listen: { host: string; port: number; localhost_only: boolean; lan_port: number | null };
  database: { file: string; bytes: number | null };
  records: { total: number; tombstones: number; by_source: { source: string; count: number; last_received: string | null }[]; by_device: { device: string; count: number; last_received: string | null }[] };
  /** 已配对设备，用来把记录里的设备编号换成名字；旧后台没有。 */
  devices?: { id: string; name: string; platform: string }[];
  distill: {
    enabled_at: string | null; heartbeat_at: string | null; last_round_at: string | null; last_slow_round_at: string | null; cursor_at: string | null; backfill_done: boolean;
    frames: Counts; threads: Counts; needs_regen: { threads: number; projects: number; days: number }; pending_open: Counts;
    requests: { total: number; by_status: Counts; recent: ManualRequest[] };
    /** recovered：同一档位、同一用途在这次失败后调用成功。 */
    last_error: { at: string; tier: string | null; error: string; recovered: boolean; tier_last_ok_at?: string | null } | null;
    last_ok_at: string | null;
    config_error?: string | null;
    cooldown: { until: string; kind: "rate_limited" | "quota" | "network" | "budget" } | null;
  };
  collector: (CollectorUpdate & { outbox_bytes: number; outbox_dropped: number; outbox_degraded: boolean; hub_busy?: number; queue_peak?: number }) | null;
  llm_today: { date: string; total: Omit<TierUsage, "tier" | "models">; by_tier: TierUsage[]; used_tokens: number; token_limit: number | null };
  agent_reads_today: number;
  audio: {
    transcription: (CollectorUpdate & { pending: number; failed: number }) | null; transcription_disabled: boolean;
    speakers: Counts; voice_conversations: number; sample_requests_open: number; deletes_pending: number;
  };
}
export const STATUS_REFRESH_MS = 15_000;
export const fetchStatus = (api: Api, signal?: AbortSignal) => api<HubStatus>("/v1/status", { signal });

/** 模型档位的界面名，设置页和状态页共用（docs/ui.md 用词表）。 */
export const tierNames: Record<string, string> = { minute: "实时整理", hour: "每小时汇总", day: "每日时间线" };
export const frameNames: Record<string, string> = { new: "等待整理", assigned: "已归入事项", ignored: "已忽略", candidate: "待积累", candidate_expired: "未形成事项" };
export const threadNames: Record<string, string> = { active: "进行中", paused: "已暂停", done: "已完成", archived: "已归档", abandoned: "已放弃" };
export const pendingNames: Record<string, string> = { project: "新项目", merge: "可能重复的项目", thread_done: "做完了吗", voice: "新声音" };
export const requestNames: Record<string, string> = { queued: "排队中", running: "进行中", done: "已完成", failed: "失败" };
export const speakerNames: Record<string, string> = { new: "新出现", asked: "待确认", confirmed: "已确认", ignored: "已忽略", merged: "已合并" };

export const englishStatusNames = {
  tier: { minute: "Live", hour: "Hourly roundup", day: "Daily timeline" },
  frame: { new: "Waiting", assigned: "Assigned to a task", ignored: "Ignored", candidate: "Collecting activity", candidate_expired: "No task formed" },
  thread: { active: "In progress", paused: "Paused", done: "Completed", archived: "Archived", abandoned: "Abandoned" },
  pending: { project: "New project", merge: "Possible duplicate project", thread_done: "Task completion", voice: "New voice" },
  request: { queued: "Queued", running: "In progress", done: "Completed", failed: "Failed" },
  speaker: { new: "New", asked: "To confirm", confirmed: "Confirmed", ignored: "Ignored", merged: "Merged" },
  cooldown: { rate_limited: "too many requests", quota: "model quota reached", network: "model service is unreachable" },
  source: {
    "mac.audio": "Conversation", "mac.screen": "Screen", "mac.app": "App", "mac.clipboard": "Clipboard", "mac.file": "File", "mac.calendar": "Calendar", "mac.wechat": "WeChat",
    "mac.shell": "Terminal", "mac.git": "Git", "mac.browser": "Browser", ...AGENT_SESSION_NAMES,
    "manual.note": "Note", "manual.correction": "Correction", "manual.agent": "AI note",
    "android.audio": "Phone recording", "android.notification": "Phone chat", "android.usage": "Phone app", "claude_desktop.session": "Claude Desktop",
  },
} satisfies Record<string, Record<string, string>>;

/**
 * 模型错误码给人看的一句话，和 Mac 的 ModelErrorText 一字不差（collector/Sources/CollectorCore/RuntimeModels.swift）。
 * 页面不显示错误码。
 */
const errorNames: Record<string, string> = {
  auth: "API key 没设置或无效；用账号登录的，请确认已登录。",
  quota: "模型服务的额度用完了，充值或额度恢复后会自动继续。",
  bad_request: "模型服务拒绝了请求，请检查模型名、地址和思考强度。",
  config_error: "模型设置有问题，请检查后重新保存。",
  cli_missing: "这台 Mac 上没找到 Claude Code 或 Codex。装好并登录，或改填 API。",
  cli_failed: "命令行工具调用失败，请确认已安装并登录。",
  network: "连不上模型服务，请检查网络和地址。",
  rate_limited: "请求太频繁，模型服务暂时限流，稍后会自动重试。",
  timeout: "模型服务一直没有回应，请检查网络或稍后再试。",
  server_error: "模型服务暂时出错，稍后会自动重试。",
  schema_mismatch: "模型返回的内容不合格式，可以换个模型试试。",
  invalid_json: "模型返回的内容不合格式，可以换个模型试试。",
  usage_record_failed: "整理记录没能保存，请检查磁盘空间。",
  unknown: "原因不明，请检查模型设置。",
};
const englishErrors = {
  auth: "Check your API key or sign in to the model’s command-line tool.",
  quota: "Summarizing will resume when the model service quota is available again.",
  bad_request: "The model service rejected the request, so check the model name, address, and reasoning effort.",
  config_error: "Check the model settings and save them again.",
  cli_missing: "Install and sign in to Claude Code or Codex, or use an API provider.",
  cli_failed: "The command-line tool failed, so check that it is installed and signed in.",
  network: "Check the network and the model service address.",
  rate_limited: "The model service is receiving too many requests and Tacit will retry shortly.",
  timeout: "The model service did not respond in time, so check the network or try again later.",
  server_error: "The model service is temporarily unavailable and Tacit will retry shortly.",
  schema_mismatch: "The response had an unexpected format, so try another model.",
  invalid_json: "The response had an unexpected format, so try another model.",
  usage_record_failed: "Tacit could not save its run log, so check the available disk space.",
  unknown: "The model call failed for an unknown reason, so check the model settings.",
} satisfies Record<string, string>;
const errorCategory = (error: string | null) => error?.replace(/:[1-5][0-9]{2}$/, "") ?? "unknown";
export function errorName(error: string | null, lang: Lang = "zh"): string {
  const names: Record<string, string> = lang === "zh" ? errorNames : englishErrors;
  const code = errorCategory(error);
  return Object.hasOwn(names, code) ? names[code]! : names.unknown!;
}
/** 冷却原因的短说法，接在“因……”后面。 */
export const cooldownNames: Record<string, string> = { rate_limited: "请求太频繁", quota: "额度用完", network: "连不上模型服务" };
/**
 * 和 Mac 同一条规则判断要不要标红：要用户处理的立即标红；会自动重试的，出错那一档连续 1 小时没成功才标红。
 * 其余照样列出（状态页兼作排障），用灰字。
 */
export function errorNeedsAttention(error: NonNullable<HubStatus["distill"]["last_error"]>, lastOk: string | null, now: number): boolean {
  if (error.recovered) return false;
  if (["auth", "quota", "bad_request", "config_error", "cli_missing", "cli_failed"].includes(errorCategory(error.error))) return true;
  const ok = Date.parse(error.tier_last_ok_at ?? lastOk ?? "");
  return !Number.isFinite(ok) || now - ok >= 3_600_000;
}

/** 本地时间：同一年写“11 月 25 日 09:00”，跨年带年份。 */
export function formatDateTime(iso: string, now = Date.now(), lang: Lang = "zh"): string {
  const d = new Date(iso);
  if (!Number.isFinite(d.getTime())) return lang === "zh" ? "时间未知" : "Unknown time";
  if (lang === "en") {
    const date = formatDate(lang, d);
    const year = d.getFullYear() === new Date(now).getFullYear() ? "" : `, ${d.getFullYear()}`;
    return `${date}${year}, ${formatClock(iso, lang, false)}`;
  }
  const pad = (n: number) => String(n).padStart(2, "0");
  const date = `${d.getMonth() + 1} 月 ${d.getDate()} 日 ${pad(d.getHours())}:${pad(d.getMinutes())}`;
  return d.getFullYear() === new Date(now).getFullYear() ? date : `${d.getFullYear()} 年 ${date}`;
}
export function formatClock(iso: string, lang: Lang = "zh", seconds = true): string {
  const d = new Date(iso);
  if (!Number.isFinite(d.getTime())) return "—";
  if (lang === "en") return new Intl.DateTimeFormat(englishLocale(), {
    hour: "numeric", minute: "2-digit", ...(seconds ? { second: "2-digit" } : {}),
  }).format(d);
  return [d.getHours(), d.getMinutes(), ...(seconds ? [d.getSeconds()] : [])].map(n => String(n).padStart(2, "0")).join(":");
}

const number = new Intl.NumberFormat("zh-CN");
export const formatNumber = (value: number | null) => value === null ? "—" : number.format(value);
export function formatBytes(bytes: number | null): string {
  if (bytes === null) return "—";
  const units = ["B", "KB", "MB", "GB", "TB"];
  let value = bytes, unit = 0;
  while (value >= 1024 && unit < units.length - 1) { value /= 1024; unit++; }
  return `${unit === 0 ? value : value.toFixed(value < 10 ? 1 : 0)} ${units[unit]}`;
}
export function formatUptime(seconds: number, lang: Lang = "zh"): string {
  if (lang === "en") return formatDuration(lang, seconds);
  const days = Math.floor(seconds / 86400), hours = Math.floor(seconds % 86400 / 3600), minutes = Math.floor(seconds % 3600 / 60);
  if (days) return `${days} 天${hours ? ` ${hours} 小时` : ""}`;
  if (hours) return `${hours} 小时${minutes ? ` ${minutes} 分` : ""}`;
  return minutes ? `${minutes} 分钟` : `${seconds} 秒`;
}
/** 模型调用的累计耗时，写法同其他时长。 */
export function formatMs(ms: number, lang: Lang = "zh"): string {
  if (lang === "en") return formatDuration(lang, Math.floor(ms / 1000));
  if (ms < 1000) return ms > 0 ? "不到 1 秒" : "0 秒";
  const seconds = Math.round(ms / 1000);
  return seconds < 60 ? `${seconds} 秒` : durationText(seconds);
}
/** 计数按给定顺序列出，已知名称在前，未知状态原样附在后面。 */
export function countList(counts: Counts, names: Record<string, string>): { key: string; label: string; count: number }[] {
  const known = Object.keys(names).filter(key => key in counts);
  const rest = Object.keys(counts).filter(key => !(key in names)).sort();
  return [...known, ...rest].map(key => ({ key, label: names[key] ?? key, count: counts[key]! }));
}
