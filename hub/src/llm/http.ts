import { parseJSON, tokens } from "./process.ts";
import type { BackendContext, ReadKey } from "./types.ts";
import { isLoopback } from "./local.ts";
export { isLoopback } from "./local.ts";

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
      const base = ctx.config.base_url ?? (anthropic ? "https://api.anthropic.com/v1" : "https://api.openai.com/v1");
      const response = await fetch(`${base.replace(/\/$/, "")}/${anthropic ? "messages" : "chat/completions"}`, {
        method: "POST", signal: controller.signal, redirect: "error",
        headers: { "content-type": "application/json", ...(anthropic ? { "x-api-key": key, "anthropic-version": "2023-06-01" } : local ? {} : { authorization: `Bearer ${key}` }) },
        body: JSON.stringify(anthropic ? {
          model: ctx.config.model, max_tokens: 8192, system: ctx.req.system, messages: [{ role: "user", content: ctx.req.prompt }],
          tools: [{ name: "emit_result", description: "返回符合 schema 的结果", input_schema: ctx.req.schema }], tool_choice: { type: "tool", name: "emit_result" },
        } : {
          model: ctx.config.model, messages: [{ role: "system", content: ctx.req.system }, { role: "user", content: ctx.req.prompt }],
          ...(ctx.config.reasoning_effort === undefined ? {} : { reasoning_effort: ctx.config.reasoning_effort }),
          response_format: { type: "json_schema", json_schema: { name: "result", strict: true, schema: ctx.req.schema } },
        }),
      });
      if (!response.ok) throw new Error(`模型 HTTP 请求失败（${response.status}）`);
      const text = await response.text();
      ctx.metrics.outputChars = Array.from(text).length;
      const body = parseJSON(text) as any;
      ctx.metrics.inputTokens = tokens(anthropic ? body?.usage?.input_tokens : body?.usage?.prompt_tokens);
      ctx.metrics.outputTokens = tokens(anthropic ? body?.usage?.output_tokens : body?.usage?.completion_tokens);
      if (anthropic) {
        if (body.stop_reason === "max_tokens") throw new Error("Anthropic 输出达到 8192 token 上限，结果未保存");
        const tool = body?.content?.find((part: any) => part.type === "tool_use" && part.name === "emit_result");
        if (!tool || body.stop_reason !== "tool_use") throw new Error("Anthropic 未返回完整结构化结果");
        ctx.metrics.outputChars = Array.from(JSON.stringify(tool.input)).length;
        return tool.input;
      }
      const choice = body?.choices?.[0];
      if (choice?.finish_reason !== "stop" || choice.message?.refusal || typeof choice.message?.content !== "string") throw new Error("OpenAI 兼容后端未返回完整 JSON 结果");
      ctx.metrics.outputChars = Array.from(choice.message.content).length;
      return parseJSON(choice.message.content);
    })()]);
  } catch (error) {
    if (controller.signal.aborted) throw new Error(`模型 HTTP 调用超时（${ctx.timeoutMs}ms）`);
    // 不回传 fetch/钥匙串的原始异常，避免 URL、凭证或响应内容泄漏。
    if (error instanceof Error && /^(模型 HTTP|API key|模型返回|Anthropic 未|Anthropic 输出|OpenAI 兼容)/.test(error.message)) throw error;
    throw new Error("模型 HTTP 调用失败（网络或钥匙串读取失败）");
  } finally { clearTimeout(timer); }
}
