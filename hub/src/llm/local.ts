/** 只表示连接地址在本机，不表示模型没有转发到云端。 */
export function isLoopback(baseURL: string | undefined): boolean {
  if (!baseURL) return false;
  try {
    const url = new URL(baseURL), host = url.hostname;
    return ["http:", "https:"].includes(url.protocol) && !url.username && !url.password
      && (host === "localhost" || host === "[::1]" || /^127\.\d+\.\d+\.\d+$/.test(host));
  } catch { return false; }
}

export async function localModels(baseURL: string): Promise<string[]> {
  const response = await fetch(`${baseURL.replace(/\/+$/, "")}/models`, {
    signal: AbortSignal.timeout(5000), redirect: "error",
  }).catch(() => { throw new Error("连接不上本机模型服务，请先打开服务并检查地址"); });
  if (!response.ok) throw new Error(`本机模型服务返回 HTTP ${response.status}，请检查服务设置`);
  let body: any;
  try { body = await response.json(); } catch { throw new Error("本机模型服务没有返回有效的模型列表"); }
  if (!Array.isArray(body?.data) || body.data.some((m: any) => typeof m?.id !== "string" || !m.id.trim() || m.id.length > 200 || /[\x00-\x1f\x7f]/.test(m.id))) {
    throw new Error("本机模型服务没有返回有效的模型列表");
  }
  return [...new Set<string>(body.data.map((m: { id: string }) => m.id))].sort();
}
