import type { Api } from "./distillation.ts";

export function createApi(token: string, onUnauthorized: () => void, request: (path: string, init?: RequestInit) => Promise<Response> = fetch): Api {
  return async <T,>(path: string, init?: RequestInit): Promise<T> => {
    const headers = new Headers(init?.headers);
    headers.set("Authorization", `Bearer ${token}`);
    headers.set("Content-Type", "application/json");
    const response = await request(path, { ...init, headers });
    if (response.status === 401) { onUnauthorized(); throw new Error("需要重新打开网页"); }
    if (response.ok && path.startsWith("/v1/audio/samples/")) return await response.blob() as T;
    const text = await response.text();
    const result = text ? JSON.parse(text) : undefined;
    if (!response.ok) throw Object.assign(new Error(result?.error ?? `请求失败（${response.status}）`), { status: response.status });
    return result as T;
  };
}
