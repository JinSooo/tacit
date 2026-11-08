import { readFile } from "node:fs/promises";
import { homedir } from "node:os";
import { join } from "node:path";

export class AgentError extends Error {}

export async function readHub(kind: string, params: URLSearchParams, signal: AbortSignal): Promise<unknown> {
  const port = Number(process.env.RA_PORT ?? 47823);
  if (!Number.isInteger(port) || port < 1 || port > 65535) throw new AgentError("RA_PORT 必须是 1–65535 的整数");
  const dir = process.env.RA_DATA_DIR ?? join(homedir(), "Library/Application Support/record-anything");
  let token: string;
  try { token = (await readFile(join(dir, "token"), { encoding: "utf8", signal })).trim(); }
  catch { throw new AgentError("无法读取本地 token 文件"); }
  if (!token) throw new AgentError("本地 token 文件为空");
  let response: Response;
  try {
    response = await fetch(`http://127.0.0.1:${port}/v1/agent/${kind}?${params}`, {
      headers: { Authorization: `Bearer ${token}` }, signal, redirect: "error",
    });
  } catch {
    throw new AgentError(signal.aborted ? "查询 hub 超时" : "hub 没运行，请运行 ./install.sh");
  }
  // 不转述服务端错误正文，避免把请求或鉴权信息带进错误通道。
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
