import React, { useEffect, useState } from "react";
import { AuditView } from "./audit-view.tsx";
import type { Api, DistillationApi } from "./distillation.ts";
import { callTask, callStatus, elapsed, snapshotMessage, type ModelCall } from "./runtime.ts";
import { RuntimeSnapshot } from "./runtime-snapshot.tsx";

export function RuntimeView(props: { api: Api; distillation: DistillationApi; onHistory: (title: string) => void }) {
  const [tab,setTab] = useState(location.search.match(/[?&](thread|project)=/) ? "reads" : "models");
  return <section aria-label="运行记录">
    <div className="runtime-tabs" role="group" aria-label="运行记录类型">{[["models","模型整理"],["reads","AI 工具读取"],["background","后台运行"]].map(([key,label]) => <button key={key} aria-pressed={tab===key} onClick={() => setTab(key!)}>{label}</button>)}</div>
    {tab === "models" ? <ModelCalls api={props.api}/> : tab === "reads" ? <AuditView {...props}/> : <BackgroundCalls api={props.api}/>}
  </section>;
}

function ModelCalls({ api }: { api: Api }) {
  const [calls,setCalls] = useState<ModelCall[]>([]), [cursor,setCursor] = useState<string|null>(null);
  const [busy,setBusy] = useState(true), [error,setError] = useState("");
  const [revision,setRevision] = useState(0), [selected,setSelected] = useState<string>();
  useEffect(() => {
    const controller = new AbortController(); setBusy(true); setError("");
    void api<{calls:ModelCall[];next_cursor:string|null}>("/v1/runtime/models",{signal:controller.signal}).then(page => {
      if (!controller.signal.aborted) { setCalls(page.calls); setCursor(page.next_cursor); }
    }).catch(e => { if(!controller.signal.aborted) setError(e.message); }).finally(() => { if(!controller.signal.aborted) setBusy(false); });
    return () => controller.abort();
  },[api,revision]);
  async function more() {
    if (!cursor || busy) return; setBusy(true); setError("");
    try {
      const page = await api<{calls:ModelCall[];next_cursor:string|null}>(`/v1/runtime/models?cursor=${encodeURIComponent(cursor)}`);
      setCalls(previous => [...new Map([...previous,...page.calls].map(c => [c.id,c])).values()]); setCursor(page.next_cursor);
    } catch(e) { setError(e instanceof Error ? e.message : "读取失败"); } finally { setBusy(false); }
  }
  return <div className="distillation-view">
    <div className="status-head"><h2 className="section-title">模型整理</h2><button onClick={() => setRevision(n=>n+1)} disabled={busy}>刷新</button></div>
    <p className="muted runtime-note">正文在本机保存 7 天。删除任一历史记录时，所有调用正文会一并清空，时间和状态保留。</p>
    {!!calls.length && <div className="group table-wrap"><table className="data-table stack-table runtime-table"><thead><tr>{["时间 / 用途","模型","状态","耗时 / 用量"].map(s=><th key={s}>{s}</th>)}</tr></thead><tbody>{calls.map(call => <React.Fragment key={call.id}>
      <tr><td className="full"><time dateTime={call.at}>{new Date(call.at).toLocaleString("zh-CN",{hour12:false})}</time><button className="text-button runtime-open" aria-expanded={selected===call.id} aria-controls={`call-${call.id}`} onClick={()=>setSelected(selected===call.id?undefined:call.id)}>{callTask(call.task)}</button></td><td className="full runtime-model">{call.model || "未记录"}</td><td className={call.error ? "full error" : "full"}>{callStatus(call)}</td><td className="end">{elapsed(call.ms)}<span className="runtime-usage">{call.input_tokens == null && call.output_tokens == null ? "用量未返回" : `输入 ${call.input_tokens ?? "未知"} / 输出 ${call.output_tokens ?? "未知"} token`}</span></td></tr>
      {selected===call.id && <tr><td colSpan={4} className="full runtime-detail" id={`call-${call.id}`}>
        <div className="runtime-stages"><span>返回：{call.provider_state === "returned" ? "已返回" : call.provider_state === "sending" ? "等待中" : call.provider_state === "failed" ? "失败" : "尚未发送"}</span><span>校验：{call.validation_state === "passed" ? "通过" : call.validation_state === "failed" ? "未通过" : "未记录"}</span><span>采用：{call.application_state === "applied" ? "已用于更新" : call.application_state === "unknown" ? "当时未记录" : call.application_state === "discarded" ? "已丢弃" : "尚未采用"}</span></div>
        {call.error && <p className="error">{call.error}</p>}
        {call.content_state === "not_recorded" ? <p className="muted">{snapshotMessage(call.content_state)}</p> : <RuntimeSnapshot api={api} id={call.id}/>}
      </td></tr>}
    </React.Fragment>)}</tbody></table></div>}
    {!calls.length && !busy && !error && <p className="empty">还没有模型调用。开始整理后，记录会显示在这里。</p>}
    {error && <p className="error" role="alert">{error}</p>}
    <div className="list-status">{busy ? <span role="status">正在读取…</span> : cursor && <button onClick={()=>void more()}>加载更多</button>}</div>
  </div>;
}

function BackgroundCalls({api}:{api:Api}) {
  const [source,setSource] = useState("hub"), [revision,setRevision] = useState(0);
  const [data,setData] = useState<{events:unknown[];skipped:number;modified_at?:string}>(), [error,setError] = useState("");
  useEffect(()=> {
    const controller=new AbortController(); setData(undefined);setError("");
    void api<{events:unknown[];skipped:number;modified_at?:string}>(`/v1/runtime/background?source=${source}`,{signal:controller.signal}).then(v=>{if(!controller.signal.aborted)setData(v);}).catch(e=>{if(!controller.signal.aborted)setError(e.message);});
    return ()=>controller.abort();
  },[api,source,revision]);
  return <div className="distillation-view"><div className="status-head"><h2 className="section-title">后台运行</h2><div className="runtime-stages"><select aria-label="日志来源" value={source} onChange={e=>setSource(e.target.value)}><option value="hub">后台服务</option><option value="distill">内容整理</option><option value="collector">活动采集</option></select><button onClick={()=>setRevision(n=>n+1)}>刷新</button></div></div>
    <p className="muted runtime-note">展示最近的结构化状态与计数。含原文的诊断行不会显示在这里。</p>
    {error ? <p className="error" role="alert">{error}</p> : !data ? <p role="status">正在读取…</p> : data.events.length ? <div className="runtime-events">{data.events.map((event,i)=><pre key={i}>{JSON.stringify(event,null,2)}</pre>)}</div> : <p className="empty">暂时没有可展示的运行状态。</p>}
  </div>;
}
