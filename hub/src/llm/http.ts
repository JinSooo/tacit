import { observeRequest, parseJSON, tokens } from "./process.ts";
import { httpModelError, ModelError, modelErrorCategory } from "./error-category.ts";
import type { BackendContext, ReadKey } from "./types.ts";
import { isLoopback } from "./local.ts";
export { isLoopback } from "./local.ts";

// 思考型模型（如经 Anthropic 兼容接口接入的 MiniMax）的思考 token 也算在输出里，8192 对当天整理偏紧（2026-11-18）。
const ANTHROPIC_MAX_TOKENS = 16384;
// 拒收 response_format 的兼容地址（MiniMax 解析不了 "type":["string","null"]，直接 400，2026-11-18）。进程内记住，之后不再带。
const noResponseFormat = new Set<string>();
const SCHEMA_NOTE = "只输出一个 JSON 对象，必须符合下面的 JSON Schema：键名照抄，必填字段都要有，不加别的字段，枚举只能从给定值里选，遵守长度和条数上限。";

function errorHints(body: any): unknown[] {
  return [body?.error?.type, body?.error?.code, body?.type, body?.base_resp?.status_msg];
}

export async function httpComplete(ctx: BackendContext, readKey: ReadKey): Promise<unknown> {
  const anthropic = ctx.config.provider === "anthropic";
  const controller = new AbortController();
  let timer: ReturnType<typeof setTimeout> | undefined;
  const deadline = new Promise<never>((_, reject) => {
    timer = setTimeout(() => { controller.abort(); reject(new ModelError("timeout")); }, ctx.timeoutMs);
  });
  try {
    return await Promise.race([deadline, (async () => {
      const local = isLoopback(ctx.config.base_url);
      const key = local ? "" : await Promise.resolve().then(() => readKey(ctx.config.provider)).catch(() => { throw new ModelError("auth"); });
      if (controller.signal.aborted) throw new ModelError("timeout");
      if (!local && !key.trim()) throw new ModelError("auth");
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
        observeRequest(ctx, "api", body);
        return fetch(`${base}/${anthropic ? "messages" : "chat/completions"}`, {
          method: "POST", signal: controller.signal, redirect: "error",
          headers: { "content-type": "application/json", ...(anthropic ? { "x-api-key": key, "anthropic-version": "2023-06-01" } : local ? {} : { authorization: `Bearer ${key}` }) },
          body: JSON.stringify(body),
        }).catch(() => { throw new ModelError("network"); });
      };
      const receive = async (body: Record<string, unknown>) => {
        const response = await send(body);
        const text = await response.text().catch(() => { throw new ModelError("network"); });
        if (controller.signal.aborted) throw new ModelError("timeout");
        try { ctx.observer?.response(text, key); } catch { throw new ModelError("usage_record_failed"); }
        ctx.metrics.outputChars = Array.from(text).length;
        let parsed: any;
        try { parsed = JSON.parse(text); } catch { if (response.ok) throw new ModelError("invalid_json"); }
        const failed = !response.ok || parsed?.error ||
          (parsed?.base_resp?.status_code != null && parsed.base_resp.status_code !== 0);
        return { response, parsed, error: failed ? httpModelError(response.status, errorHints(parsed), response.headers.get("retry-after")) : null };
      };
      let reply = await receive(requestBody);
      if (!anthropic && reply.response.status === 400 && reply.error && modelErrorCategory(reply.error.code) === "bad_request" && "response_format" in requestBody) {
        // schema 已经写进系统提示，去掉 response_format 再发一次；仍失败则照常报错。
        const { response_format: _dropped, ...plain } = requestBody;
        reply = await receive(plain);
        if (!reply.error) noResponseFormat.add(base);
      }
      if (reply.error) throw reply.error;
      const body = reply.parsed;
      const u = body?.usage ?? {};
      // Anthropic 格式的 input_tokens 只是未命中缓存的部分，真实输入量要加上缓存读写（与 claude-cli 一致）。
      ctx.metrics.inputTokens = tokens(anthropic
        ? [u.input_tokens, u.cache_read_input_tokens, u.cache_creation_input_tokens].reduce((n: number, v: unknown) => n + (typeof v === "number" ? v : 0), 0)
        : u.prompt_tokens);
      ctx.metrics.outputTokens = tokens(anthropic ? body?.usage?.output_tokens : body?.usage?.completion_tokens);
      if (anthropic) {
        if (body.stop_reason === "max_tokens") throw new ModelError("schema_mismatch");
        const tool = body?.content?.find((part: any) => part.type === "tool_use" && part.name === "emit_result");
        if (!tool || body.stop_reason !== "tool_use") throw new ModelError("schema_mismatch");
        ctx.metrics.outputChars = Array.from(JSON.stringify(tool.input)).length;
        return tool.input;
      }
      const choice = body?.choices?.[0];
      if (choice?.finish_reason !== "stop" || choice.message?.refusal || typeof choice.message?.content !== "string") throw new ModelError("schema_mismatch");
      ctx.metrics.outputChars = Array.from(choice.message.content).length;
      // 部分思考型模型把思考过程用 <think> 包在正文开头。
      return parseJSON(choice.message.content.replace(/^\s*<think>[\s\S]*?<\/think>\s*/, ""));
    })()]);
  } catch (error) {
    if (controller.signal.aborted) throw new ModelError("timeout");
    throw error;
  } finally { clearTimeout(timer); }
}
