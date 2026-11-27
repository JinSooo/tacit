export const MODEL_ERROR_LABELS = {
  timeout: "超时", network: "网络不可用", rate_limited: "请求太频繁", quota: "额度用完",
  auth: "密钥无效", bad_request: "请求被拒绝", server_error: "服务出错", invalid_json: "返回不是 JSON",
  schema_mismatch: "返回格式不对", cli_missing: "没找到命令行工具", cli_failed: "命令行调用失败", usage_record_failed: "用量记录失败",
  cli_not_logged_in: "命令行工具未登录", cli_outdated: "命令行工具版本不兼容",
  cli_model_unavailable: "命令行模型不可用", cli_network: "命令行工具连不上模型服务", cli_runtime_missing: "找不到 Node.js",
  config_error: "模型配置无效", unknown: "未知错误",
} as const;

export type ModelErrorCategory = keyof typeof MODEL_ERROR_LABELS;
export type ModelErrorCode = ModelErrorCategory | `${ModelErrorCategory}:${number}`;
const known = (value: string): value is ModelErrorCategory => Object.hasOwn(MODEL_ERROR_LABELS, value);

export function modelErrorCategory(code: ModelErrorCode): ModelErrorCategory {
  return code.split(":")[0] as ModelErrorCategory;
}

function statusCode(category: ModelErrorCategory, status?: number): ModelErrorCode {
  return status !== undefined && Number.isInteger(status) && status >= 100 && status <= 599 ? `${category}:${status}` : category;
}

function categoryForStatus(status: number): ModelErrorCategory {
  if (status === 408) return "timeout";
  if (status === 429) return "rate_limited";
  if (status === 402) return "quota";
  if (status === 401 || status === 403) return "auth";
  if (status >= 500) return "server_error";
  if (status >= 400) return "bad_request";
  return "unknown";
}

export class ModelError extends Error {
  constructor(readonly code: ModelErrorCode, readonly retryAfterMs?: number) { super(code); }
}

function cliCategory(message: string, status: number | undefined): ModelErrorCategory | undefined {
  if (/\benv:\s*node:\s*no such file or directory|\bnode:\s*command not found/i.test(message)) return "cli_runtime_missing";
  if (/\bmodel\b[^\r\n]{0,180}(?:not found|not exist|(?:not|isn't) supported|not available|not have access)|\b(?:model_not_found|unsupported_model)\b|\b(?:do not|don't) have access to (?:the |this )?model/i.test(message)) return "cli_model_unavailable";
  if (status === 401 || /\b(?:401|unauthorized|not (?:logged|signed) in|authentication_error|invalid_api_key|oauth token (?:has )?expired)\b|\b(?:codex|claude) login\b|(?:run|use)\s+`?\/login\b|\b(?:please|must) (?:log|sign) in\b|\bsign in again\b|\baccess token could not be refreshed\b|没有登录|登录已过期/i.test(message)) return "cli_not_logged_in";
  if (/\b(?:unexpected argument|unknown (?:option|argument)|unrecognized (?:option|argument))\b|\berror:\s*unrecognized\b|^\s*usage:/im.test(message)) return "cli_outdated";
  if (/\b(?:stream disconnected|error sending request|reconnecting|failed to connect|could not connect|unable to connect|connect(?:ion)? (?:failed|refused|reset)|dns error|network|proxy|econnreset|econnrefused|enetunreach|ehostunreach|enotfound|eai_again)\b|网络/i.test(message)) return "cli_network";
}

/** 用诊断文字识别旧错误、CLI 失败和服务商错误类型，返回值永远来自固定集合。 */
export function classifyModelError(error: unknown, fallback: ModelErrorCategory = "unknown"): ModelErrorCode {
  if (error instanceof ModelError) return error.code;
  const message = typeof error === "string" ? error : error instanceof Error ? error.message : "";
  const fixed = /^([a-z_]+)(?::([1-5]\d{2}))?$/.exec(message);
  if (fixed && fixed[0] === message && known(fixed[1]!)) return statusCode(fixed[1]!, fixed[2] ? Number(fixed[2]) : undefined);

  const statusText = /\bHTTP\s+(?:请求失败[（(])?([1-5]\d{2})\b/i.exec(message)?.[1];
  const status = statusText ? Number(statusText) : undefined;
  const cli = fallback === "cli_failed" ? cliCategory(message, status) : undefined;
  const code = typeof error === "object" && error !== null && "code" in error ? error.code : undefined;
  if (code === "config_error") return "config_error";
  let category: ModelErrorCategory;
  if (/服务端中枢仅支持 API 模型|服务端中枢尚未配置 API 模型/.test(message)) category = "config_error";
  else if (/\b(?:insufficient[ _-](?:quota|balance)(?:_error)?|quota(?:_exceeded)?|usage[ _-]+limit)\b|\b(?:hit|reached|exceeded)\s+(?:your\s+|the\s+)?(?:\d+[ -](?:hour|day|week|month)\s+)?limit\b|额度|余额不足|限额/i.test(message)) category = "quota";
  else if (/\brate[ _-]?limit(?:ed|ing|s|_exceeded|_error)?\b|频率限制|请求太频繁|too many requests/i.test(message)) category = "rate_limited";
  else if (cli && (cli !== "cli_network" || status === undefined)) category = cli;
  else if (status !== undefined && categoryForStatus(status) !== "unknown") category = categoryForStatus(status);
  else if (code === "ETIMEDOUT" || (error instanceof Error && error.name === "TimeoutError") || /超时|time[ -]?out|timed?\s*out|time limit exceeded/i.test(message)) category = "timeout";
  else if ((typeof code === "string" && /^(?:ECONNRESET|ECONNREFUSED|ENETUNREACH|EHOSTUNREACH|ENOTFOUND|EAI_AGAIN)$/.test(code)) ||
    /网络|\bnetwork\b|\b(?:econnreset|econnrefused|enetunreach|ehostunreach|enotfound|eai_again)\b|fetch failed|failed to connect|connection (?:refused|reset)|dns error/i.test(message)) category = "network";
  else if (/\bauthentication_error\b|\binvalid_api_key\b|\bpermission_error\b|API key|令牌无效|密钥无效|没有登录|not logged in/i.test(message)) category = "auth";
  else if (/用量记录失败|调用(?:结果)?记录保存失败|调用结果记录失败/.test(message)) category = "usage_record_failed";
  else if (/非法 JSON|不是合法 JSON|invalid json|JSON parse|未返回完整 JSON/i.test(message)) category = "invalid_json";
  else if (/不符合 (?:JSON )?schema|schema mismatch|结构化结果|无效省略|structured_output|token 上限/.test(message)) category = "schema_mismatch";
  else if (/请求 schema 无效|日期范围无效|不支持的模型档位|\binvalid_request_error\b/.test(message)) category = "bad_request";
  else if (/\b(?:codex|claude) 退出失败|无法启动 (?:codex|claude)|Codex 未写入结果文件/.test(message)) category = "cli_failed";
  else category = fallback;
  return statusCode(category, status);
}

export function httpModelError(status: number, hints: unknown[], retryAfter: string | null): ModelError {
  const categories = hints.map(hint => modelErrorCategory(classifyModelError(hint)));
  const category = (["quota", "rate_limited", "auth", "bad_request", "server_error"] as const)
    .find(kind => categories.includes(kind)) ?? categoryForStatus(status);
  const delay = retryAfter === null ? NaN : /^\d+$/.test(retryAfter) ? Number(retryAfter) * 1000 : Date.parse(retryAfter) - Date.now();
  return new ModelError(statusCode(category, status), delay >= 0 ? Math.min(delay, 6 * 3600_000) : undefined);
}
