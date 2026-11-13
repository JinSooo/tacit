/** 固定位置 + 受限的类型/错误码；绝不记录消息、堆栈、路径或请求内容。 */
export function diagnostic(error: unknown, location: string) {
  const e = error as { name?: unknown; code?: unknown } | null;
  const label = (v: unknown, fallback: string) => typeof v === "string" && /^[A-Za-z][A-Za-z0-9_]{0,63}$/.test(v) ? v : fallback;
  return { location, name: label(e?.name, "Error"), code: label(e?.code, "UNKNOWN") };
}
export function logFailure(location: string, error: unknown) {
  console.error(JSON.stringify(diagnostic(error, location)));
}
