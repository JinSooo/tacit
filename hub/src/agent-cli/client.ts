import { readFile } from "node:fs/promises";
import { join } from "node:path";
import { dataDirOf, resolvePort } from "../hub-json.ts";

import { DeviceTransportError, type DeviceClient } from "../devices/client.ts";
import { object } from "../devices/envelope.ts";
import { ContextCache, gitOrigin, readContextResult } from "./context-cache.ts";
import { agentSecrets, linkedClient, readAgentLink, type AgentClientOptions } from "./identity.ts";

export class AgentError extends Error {
  constructor(message: string, readonly unavailable = false) { super(message); }
}

async function connection(params: URLSearchParams, signal: AbortSignal, options: AgentClientOptions) {
  if (params.get("tool") === "claude-desktop") return null;
  const env = options.env ?? process.env, dir = dataDirOf(env);
  const link = await readAgentLink(dir, signal).catch(() => { throw new AgentError("无法读取 Agent 连接配置"); });
  if (!link) return null;
  const secrets = options.secrets ?? agentSecrets(dir);
  return {
    cache: new ContextCache(dir, link, secrets),
    async client(signal: AbortSignal) {
      try { return await linkedClient(link, env, dir, secrets, signal); }
      catch { throw new AgentError("无法读取 Agent 设备私钥或地址"); }
    },
  };
}

async function request(client: DeviceClient, kind: string, body: object, signal: AbortSignal) {
  let reply: Awaited<ReturnType<DeviceClient["send"]>>;
  try { reply = await client.send(`agent.${kind}`, body, { signal }); }
  catch (error) {
    if (signal.aborted) throw new AgentError("查询 hub 超时", true);
    if (error instanceof DeviceTransportError) {
      throw new AgentError(`hub 查询失败（HTTP ${error.status}）`, error.status >= 500);
    }
    if (error instanceof TypeError) throw new AgentError("当前无法连接 Tacit 中枢", true);
    throw new AgentError("无法验证 Tacit 中枢的设备响应");
  }
  if (reply.status === 200) return reply.body;
  const message = object(reply.body)?.error;
  const safe = typeof message === "string" && message.length <= 300 ? message : undefined;
  if (kind === "append" && reply.status === 400) throw new AgentError(safe ? `hub 拒绝写入：${safe}` : "hub 拒绝写入（HTTP 400）");
  if (reply.status === 503) throw new AgentError(safe ?? "hub 暂时不可用，请稍后重试（HTTP 503）", true);
  throw new AgentError(`hub 查询失败（HTTP ${reply.status}）`, reply.status >= 500);
}

export async function readHub(kind: string, params: URLSearchParams, signal: AbortSignal, body?: unknown, options: AgentClientOptions = {}) {
  const linked = await connection(params, signal, options);
  if (!linked) return legacy(kind, params, signal, body, options.env);
  const client = await linked.client(signal);
  const result = await request(client, kind, { ...object(body), ...Object.fromEntries(params) }, signal);
  // A slow audit upload must not hold the interactive tool call open.
  await linked.cache.syncAudit(client, AbortSignal.any([signal, AbortSignal.timeout(300)])).catch(() => {});
  return result;
}

export async function sessionContext(params: URLSearchParams, signal: AbortSignal, emit: (text: string) => void, options: AgentClientOptions = {}) {
  const linked = await connection(params, signal, options);
  if (!linked) {
    const result = readContextResult(await legacy("context", params, signal, undefined, options.env));
    if (!result) throw new AgentError("hub 上下文格式无效");
    if (!signal.aborted) emit(result.text);
    return;
  }
  const cwd = params.get("cwd")!;
  const querySignal = AbortSignal.any([signal, AbortSignal.timeout(800)]);
  const remoteProbe = gitOrigin(cwd, querySignal);
  let client: DeviceClient, result: ReturnType<typeof readContextResult>;
  try {
    client = await linked.client(querySignal);
    const remote = await remoteProbe;
    result = readContextResult(await request(client, "context", {
      ...Object.fromEntries(params), cache: true, ...(remote ? { remote } : {}),
    }, querySignal));
    if (!result) throw new AgentError("hub 上下文格式无效");
  } catch (error) {
    if (signal.aborted || (!querySignal.aborted && !(error instanceof AgentError && error.unavailable))) throw error;
    const cached = await linked.cache.offline(params, await remoteProbe, signal);
    if (!signal.aborted) emit(cached);
    return;
  }
  if (signal.aborted) return;
  emit(result.text);
  await Promise.allSettled([
    linked.cache.refresh(result, cwd, await remoteProbe, signal),
    linked.cache.syncAudit(client, AbortSignal.any([signal, AbortSignal.timeout(300)])),
  ]);
}

/** 传 body 时用 POST 写入（目前只有 append），否则 GET 读取。 */
async function legacy(kind: string, params: URLSearchParams, signal: AbortSignal, body?: unknown, env = process.env): Promise<unknown> {
  const dir = dataDirOf(env);
  let port: number;
  try { port = resolvePort(env, dir).port; } catch (error) { throw new AgentError(error instanceof Error ? error.message : "端口配置无效"); }
  if (port < 1) throw new AgentError("RA_PORT 必须是 1–65535 的整数");
  let token: string;
  try { token = (await readFile(join(dir, "agent-token"), { encoding: "utf8", signal })).trim(); }
  catch { throw new AgentError("无法读取 AI 查询令牌，请重新安装 Tacit"); }
  if (!token) throw new AgentError("AI 查询令牌为空");
  let response: Response;
  try {
    response = await fetch(`http://127.0.0.1:${port}/v1/agent/${kind}?${params}`, {
      method: body === undefined ? "GET" : "POST",
      headers: { Authorization: `Bearer ${token}`, ...(body === undefined ? {} : { "Content-Type": "application/json" }) },
      ...(body === undefined ? {} : { body: JSON.stringify(body) }), signal, redirect: "error",
    });
  } catch {
    throw new AgentError(signal.aborted ? "查询 hub 超时" : "当前无法连接 Tacit 中枢。后台服务没运行，请打开 Tacit");
  }
  // 不转述服务端错误正文，避免把请求或鉴权信息带进错误通道。
  // 例外：写入的 400 和 503 的 error 是 hub 给出的可读提示。
  if ((body !== undefined && response.status === 400) || response.status === 503) {
    let message: unknown;
    try { message = (await response.json() as { error?: unknown }).error; } catch {}
    if (response.status === 503) throw new AgentError(typeof message === "string" && message.length <= 300 ? message : "hub 暂时不可用，请稍后重试（HTTP 503）");
    throw new AgentError(typeof message === "string" && message.length <= 300 ? `hub 拒绝写入：${message}` : "hub 拒绝写入（HTTP 400）");
  }
  if (!response.ok) {
    await response.body?.cancel();
    throw new AgentError(`hub 查询失败（HTTP ${response.status}）`);
  }
  try { return await response.json(); }
  catch { throw new AgentError(signal.aborted ? "查询 hub 超时" : "hub 返回的 JSON 无效"); }
}

export function reason(error: unknown): string {
  return error instanceof AgentError ? error.message : "Agent 查询失败";
}
