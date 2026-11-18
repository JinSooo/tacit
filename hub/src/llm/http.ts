import { parseJSON, tokens } from "./process.ts";
import type { BackendContext, ReadKey } from "./types.ts";
import { isLoopback } from "./local.ts";
export { isLoopback } from "./local.ts";

// 思考型模型（如经 Anthropic 兼容接口接入的 MiniMax）的思考 token 也算在输出里，8192 对当天整理偏紧（2026-11-18）。
const ANTHROPIC_MAX_TOKENS = 16384;
// 拒收 response_format 的兼容地址（MiniMax 解析不了 "type":["string","null"]，直接 400，2026-11-18）。进程内记住，之后不再带。
const noResponseFormat = new Set<string>();
const SCHEMA_NOTE = "只输出一个 JSON 对象，必须符合下面的 JSON Schema：键名照抄，必填字段都要有，不加别的字段，枚举只能从给定值里选，遵守长度和条数上限。";

/**
 * 只取服务返回的错误类别（类型、代码、状态说明），供判断额度和频率限制；不带 error.message 等可能回显请求内容的字段。
 * 只保留可见 ASCII 的短词，避免把用户内容或凭证带进错误信息。
 */
export function errorKind(text: string): string {
  let body: any;
  try { body = JSON.parse(text); } catch { return ""; }
  const parts = [body?.error?.type, body?.error?.code, body?.type !== "error" ? body?.type : undefined,
    body?.base_resp?.status_code, body?.base_resp?.status_msg];
  return parts.filter(p => p !== undefined && p !== null && p !== "").map(p => String(p))
    .filter(p => /^[\x20-\x7e]{1,60}$/.test(p) && !/[A-Za-z0-9_-]{24,}/.test(p)).slice(0, 3).join(" ");
}

export async function httpComplete(ctx: BackendContext, readKey: ReadKey): Promise<unknown> {
  const anthropic = ctx.config.provider === "anthropic";
  const controller = new AbortController();
  let timer: ReturnType<typeof setTimeout> | undefined;
  const deadline = new Promise<never>((_, reject) => {
    timer = setTimeout(() => { controller.abort(); reject(new Error(`模型 HTTP 调用超时（${ctx.timeoutMs}ms）`)); }, ctx.timeoutMs);
  });
  try {
    return await Promise.race([deadline, (async () => {
      const local = isLoopback(ctx.config.base_url);
      const key = local ? "" : await readKey(ctx.config.provider);
      if (controller.signal.aborted) throw new Error(`模型 HTTP 调用超时（${ctx.timeoutMs}ms）`);
      if (!local && !key.trim()) throw new Error("API key 为空");
      // 用户常把完整接口地址填进来（如 …/v1/chat/completions，2026-11-18 设置页 404），去掉末尾的接口路径再拼。
      const base = (ctx.config.base_url ?? (anthropic ? "https://api.anthropic.com/v1" : "https://api.openai.com/v1"))
        .replace(/\/+$/, "").replace(anthropic ? /\/messages$/ : /\/chat\/completions$/, "");
      const requestBody = anthropic ? {
          model: ctx.config.model, max_tokens: ANTHROPIC_MAX_TOKENS, system: ctx.req.system, messages: [{ role: "user", content: ctx.req.prompt }],
          tools: [{ name: "emit_result", description: "返回符合 schema 的结果", input_schema: ctx.req.schema }], tool_choice: { type: "tool", name: "emit_result" },
        } : {
          // 有的兼容服务（MiniMax 等）不读 response_format，模型看不到格式要求；schema 同时写进系统提示。
          model: ctx.config.model, messages: [{ role: "system", content: `${ctx.req.system}\n\n${SCHEMA_NOTE}\n${JSON.stringify(ctx.req.schema)}` }, { role: "user", content: ctx.req.prompt }],
          ...(ctx.config.reasoning_effort === undefined ? {} : { reasoning_effort: ctx.config.reasoning_effort }),
          ...(noResponseFormat.has(base) ? {} : { response_format: { type: "json_schema", json_schema: { name: "result", strict: true, schema: ctx.req.schema } } }),
        } as Record<string, unknown>;
      const send = (body: Record<string, unknown>) => {
        ctx.observer?.request("api",body);
        return fetch(`${base}/${anthropic ? "messages" : "chat/completions"}`, {
          method: "POST", signal: controller.signal, redirect: "error",
          headers: { "content-type": "application/json", ...(anthropic ? { "x-api-key": key, "anthropic-version": "2023-06-01" } : local ? {} : { authorization: `Bearer ${key}` }) },
          body: JSON.stringify(body),
        });
      };
      let response = await send(requestBody);
      if (!anthropic && response.status === 400 && "response_format" in requestBody) {
        // schema 已经写进系统提示，去掉 response_format 再发一次；仍失败则照常报错。
        const { response_format: _dropped, ...plain } = requestBody;
        response = await send(plain);
        if (response.ok) noResponseFormat.add(base);
      }
      if (!response.ok) throw new Error(`模型 HTTP 请求失败（${[response.status, errorKind(await response.text().catch(() => ""))].filter(Boolean).join(" ")}）`);
      const text = await response.text();
      try { ctx.observer?.response(text); } catch { throw new Error("调用结果记录失败，结果未采用"); }
      ctx.metrics.outputChars = Array.from(text).length;
      const body = parseJSON(text) as any;
      // MiniMax 等服务可能用 HTTP 200 加 base_resp 报错（如余额不足、频率限制）。
      if (body?.base_resp && body.base_resp.status_code !== 0 && body.base_resp.status_code !== undefined) throw new Error(`模型 HTTP 请求失败（200 ${errorKind(text)}）`);
      const u = body?.usage ?? {};
      // Anthropic 格式的 input_tokens 只是未命中缓存的部分，真实输入量要加上缓存读写（与 claude-cli 一致）。
      ctx.metrics.inputTokens = tokens(anthropic
        ? [u.input_tokens, u.cache_read_input_tokens, u.cache_creation_input_tokens].reduce((n: number, v: unknown) => n + (typeof v === "number" ? v : 0), 0)
        : u.prompt_tokens);
      ctx.metrics.outputTokens = tokens(anthropic ? body?.usage?.output_tokens : body?.usage?.completion_tokens);
      if (anthropic) {
        if (body.stop_reason === "max_tokens") throw new Error(`Anthropic 输出达到 ${ANTHROPIC_MAX_TOKENS} token 上限，结果未保存`);
        const tool = body?.content?.find((part: any) => part.type === "tool_use" && part.name === "emit_result");
        if (!tool || body.stop_reason !== "tool_use") throw new Error("Anthropic 未返回完整结构化结果");
        ctx.metrics.outputChars = Array.from(JSON.stringify(tool.input)).length;
        return tool.input;
      }
      const choice = body?.choices?.[0];
      if (choice?.finish_reason !== "stop" || choice.message?.refusal || typeof choice.message?.content !== "string") throw new Error("OpenAI 兼容后端未返回完整 JSON 结果");
      ctx.metrics.outputChars = Array.from(choice.message.content).length;
      // 部分思考型模型把思考过程用 <think> 包在正文开头。
      return parseJSON(choice.message.content.replace(/^\s*<think>[\s\S]*?<\/think>\s*/, ""));
    })()]);
  } catch (error) {
    if (controller.signal.aborted) throw new Error(`模型 HTTP 调用超时（${ctx.timeoutMs}ms）`);
    // 不回传 fetch/钥匙串的原始异常，避免 URL、凭证或响应内容泄漏。
    if (error instanceof Error && /^(调用记录|调用结果|记录已变化|模型 HTTP|API key|模型返回|Anthropic 未|Anthropic 输出|OpenAI 兼容)/.test(error.message)) throw error;
    throw new Error("模型 HTTP 调用失败（网络或钥匙串读取失败）");
  } finally { clearTimeout(timer); }
}
