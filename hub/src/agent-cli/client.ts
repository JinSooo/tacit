import { lstatSync } from "node:fs";
import { readFile } from "node:fs/promises";
import { join } from "node:path";
import { readHubBinding } from "../hub-binding.ts";
import { dataDirOf, resolvePort } from "../hub-json.ts";

import { DeviceTransportError, type DeviceClient } from "../devices/client.ts";
import { object } from "../devices/envelope.ts";
import { ContextCache } from "./context-cache.ts";
import { agentSecrets, linkedClient, readBoundAgentLink, type AgentClientOptions } from "./identity.ts";

export class AgentError extends Error {
  constructor(message: string, readonly unavailable = false) { super(message); }
}

function readBinding(dir: string) {
  try { return readHubBinding(dir); }
  catch { throw new AgentError("Unable to read the Tacit background service configuration"); }
}

async function connection(tool: string | null, signal: AbortSignal, options: AgentClientOptions) {
  const env = options.env ?? process.env, dir = dataDirOf(env);
  const binding = readBinding(dir);
  const { remote } = binding;
  const checkBinding = () => {
    if (remote && lstatSync(join(dir, remote.dir, "repair-transaction.json"), { throwIfNoEntry: false })) {
      throw new AgentError("Tacit is restoring the remote connection. Try again shortly.");
    }
    const current = readBinding(dir);
    if (current.generation !== binding.generation || current.remote?.hub_id !== remote?.hub_id) {
      throw new AgentError("The Tacit background service changed. Try again.");
    }
  };
  checkBinding();
  if (tool === "claude-desktop") {
    if (remote) throw new AgentError("The local Claude Desktop connection is unavailable in remote mode");
    return { linked: null, checkBinding };
  }
  const link = await readBoundAgentLink(dir, signal, remote).catch(() => {
    throw new AgentError(remote ? "Unable to read the remote AI tool connection. Check the connection in Tacit." : "Unable to read the AI tool connection");
  });
  if (!link) return { linked: null, checkBinding };
  const secrets = options.secrets ?? agentSecrets(dir);
  return {
    checkBinding, remote,
    linked: {
      cache: new ContextCache(dir, link, secrets, remote),
      async client(signal: AbortSignal) {
        try { return await linkedClient(link, env, dir, secrets, signal, remote); }
        catch { throw new AgentError(remote ? "Unable to read the remote AI tool private key. Check the connection in Tacit." : "Unable to read the AI tool private key or address"); }
      },
    },
  };
}

async function request(client: DeviceClient, kind: string, body: object, signal: AbortSignal, remote = false) {
  let reply: Awaited<ReturnType<DeviceClient["send"]>>;
  try { reply = await client.send(`agent.${kind}`, body, { signal }); }
  catch (error) {
    if (signal.aborted) throw new AgentError("The Tacit request timed out", true);
    if (error instanceof DeviceTransportError) {
      throw new AgentError(`Tacit request failed (HTTP ${error.status})`, error.status >= 500);
    }
    if (error instanceof TypeError) {
      throw new AgentError(remote ? "Unable to reach the remote Tacit background service directly" : "Unable to reach the Tacit background service", true);
    }
    throw new AgentError("Unable to verify the response from Tacit");
  }
  if (reply.status === 200) return reply.body;
  if (kind === "append" && reply.status === 400) throw new AgentError("Tacit rejected the record. Check the supplied fields (HTTP 400).");
  if (reply.status === 503) throw new AgentError("Tacit is temporarily unavailable. Try again shortly (HTTP 503).", true);
  throw new AgentError(`Tacit request failed (HTTP ${reply.status})`, reply.status >= 500);
}

export async function readHub(kind: string, params: URLSearchParams, signal: AbortSignal, body?: unknown, options: AgentClientOptions & { launchedTool?: string } = {}) {
  // MCP 的自报名只用于请求标识，不能切换 Claude Desktop 的本地连接方式。
  const { linked, checkBinding, remote } = await connection(options.launchedTool ?? params.get("tool"), signal, options);
  if (!linked) {
    checkBinding();
    return legacy(kind, params, signal, body, options.env);
  }
  const client = await linked.client(signal);
  checkBinding();
  const result = await request(client, kind, { ...object(body), ...Object.fromEntries(params) }, signal, !!remote);
  // A slow audit upload must not hold the interactive tool call open.
  await linked.cache.syncAudit(client, AbortSignal.any([signal, AbortSignal.timeout(300)])).catch(() => {});
  return result;
}

/** 传 body 时用 POST 写入（目前只有 append），否则 GET 读取。 */
async function legacy(kind: string, params: URLSearchParams, signal: AbortSignal, body?: unknown, env = process.env): Promise<unknown> {
  const dir = dataDirOf(env);
  let port: number;
  try { port = resolvePort(env, dir).port; } catch { throw new AgentError("Invalid Tacit port configuration"); }
  if (port < 1) throw new AgentError("RA_PORT must be an integer from 1 to 65535");
  let token: string;
  try { token = (await readFile(join(dir, "agent-token"), { encoding: "utf8", signal })).trim(); }
  catch { throw new AgentError("Unable to read the AI query token. Reinstall Tacit."); }
  if (!token) throw new AgentError("The AI query token is empty");
  let response: Response;
  try {
    response = await fetch(`http://127.0.0.1:${port}/v1/agent/${kind}?${params}`, {
      method: body === undefined ? "GET" : "POST",
      headers: { Authorization: `Bearer ${token}`, ...(body === undefined ? {} : { "Content-Type": "application/json" }) },
      ...(body === undefined ? {} : { body: JSON.stringify(body) }), signal, redirect: "error",
    });
  } catch {
    throw new AgentError(signal.aborted ? "The Tacit request timed out" : "Unable to reach the Tacit background service. Open Tacit to start it.");
  }
  if (!response.ok) {
    // Error bodies can contain user data or text in the service's UI language.
    await response.body?.cancel();
    if (response.status === 503) throw new AgentError("Tacit is temporarily unavailable. Try again shortly (HTTP 503).", true);
    if (body !== undefined && response.status === 400) throw new AgentError("Tacit rejected the record. Check the supplied fields (HTTP 400).");
    throw new AgentError(`Tacit request failed (HTTP ${response.status})`);
  }
  try { return await response.json(); }
  catch { throw new AgentError(signal.aborted ? "The Tacit request timed out" : "Tacit returned invalid JSON"); }
}

export function reason(error: unknown): string {
  return error instanceof AgentError ? error.message : "The Tacit request failed";
}
