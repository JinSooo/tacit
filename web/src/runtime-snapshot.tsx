import React, { useEffect, useState } from "react";
import type { Api } from "./distillation.ts";
import { snapshotMessage, type CallSnapshot } from "./runtime.ts";

export function RuntimeSnapshot({ api, id }: { api: Api; id: string }) {
  const [value,setValue] = useState<CallSnapshot>();
  const [error,setError] = useState("");
  useEffect(() => {
    const controller = new AbortController(); let active = false;
    setValue(undefined); setError("");
    const load = async () => {
      if (active) return; active = true;
      try {
        const detail = await api<CallSnapshot>(`/v1/runtime/calls/${encodeURIComponent(id)}`,{signal:controller.signal});
        if (!controller.signal.aborted) { setValue(detail); setError(""); }
      } catch (e) {
        if (!controller.signal.aborted) { setValue(undefined); setError(e instanceof Error ? e.message : "读取失败"); }
      } finally { active = false; }
    };
    void load();
    // 页面不缓存正文；删除后、返回窗口时重新确认快照仍然可读。
    const timer = setInterval(() => { if (!document.hidden) void load(); },5000);
    const refresh = () => { if (!document.hidden) void load(); };
    window.addEventListener("focus",refresh); document.addEventListener("visibilitychange",refresh);
    return () => { controller.abort(); clearInterval(timer); window.removeEventListener("focus",refresh); document.removeEventListener("visibilitychange",refresh); };
  },[api,id]);
  if (error) return <p className="error" role="alert">{error}</p>;
  if (!value) return <p className="muted" role="status">正在读取当时的内容…</p>;
  const missing = snapshotMessage(value.content_state);
  if (missing) return <p className="muted">{missing}</p>;
  const context = value.kind === "context";
  return <div className="runtime-snapshot">
    {!context && <p className="muted">{value.transport === "cli" ? "这是交给命令行工具的内容；工具内部附加的说明和网络请求不可见。" : "这是交给模型服务的请求正文，认证凭据不在其中。"}</p>}
    {value.redactions > 0 && <p className="muted">已隐藏 {value.redactions} 处可能的密钥。</p>}
    <details open><summary>{context ? "当时自动带入的内容" : "发送内容"}</summary><pre>{context ? String((value.request as {text?:string})?.text ?? "") : JSON.stringify(value.request,null,2)}</pre></details>
    {!context && <details><summary>返回内容{value.response_truncated ? "（仅保留前 128000 字符）" : ""}</summary>{value.response == null ? <p className="muted">尚无可展示的返回内容。</p> : <pre>{value.response}</pre>}</details>}
  </div>;
}
