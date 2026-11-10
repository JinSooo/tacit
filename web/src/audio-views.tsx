import React, { useEffect, useRef, useState } from "react";
import { retentionDays, samplePlayback, type AudioApi } from "./audio.ts";
const message = (error: unknown) => error instanceof Error ? error.message : "请求失败，请重试";

function SampleAudio({ id, api }: { id: string; api: AudioApi }) {
  const [url, setUrl] = useState<string>();
  const [error, setError] = useState("");
  useEffect(() => {
    let cancelled = false;
    const playback = samplePlayback(signal => api.sample(id, signal));
    void playback.open().then(value => { if (value) setUrl(value); }).catch(error => { if (!cancelled) setError(message(error)); });
    return () => { cancelled = true; playback.dispose(); };
  }, [id, api]);
  return error ? <p className="error" role="alert">{error}</p> : url ? <audio controls autoPlay src={url} aria-label="试听样本" /> : <span role="status">正在读取…</span>;
}
export function VoiceSamples({ samples, api }: { samples: { id: string; mime: string }[]; api: AudioApi }) {
  const [opened, setOpened] = useState<string[]>([]);
  return <div className="voice-samples">{samples.map((sample, index) => {
    const open = opened.includes(sample.id);
    return <div key={sample.id}><button className="text-button" aria-expanded={open} onClick={() => setOpened(ids => open ? ids.filter(id => id !== sample.id) : [...ids, sample.id])}>{open ? "收起" : "播放"}样本 {index + 1}</button>{open && <SampleAudio key={sample.id} id={sample.id} api={api} />}</div>;
  })}</div>;
}
export function AudioSettings({ api }: { api: AudioApi }) {
  const [days, setDays] = useState("");
  const [loading, setLoading] = useState(true);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState("");
  const [status, setStatus] = useState("");
  const [revision, setRevision] = useState(0);
  const dialog = useRef<HTMLDialogElement>(null);
  useEffect(() => {
    const controller = new AbortController();
    setLoading(true); setError("");
    api.settings(controller.signal).then(data => { if (!controller.signal.aborted) setDays(String(data.retention_days)); }).catch(error => { if (!controller.signal.aborted) setError(message(error)); }).finally(() => { if (!controller.signal.aborted) setLoading(false); });
    return () => controller.abort();
  }, [api, revision]);
  let valid = false;
  try { retentionDays(days); valid = true; } catch { /* 输入框保留无效输入，由表单和提交入口共同校验。 */ }
  async function save(event: React.SubmitEvent<HTMLFormElement>) {
    event.preventDefault(); setBusy(true); setError(""); setStatus("");
    try { const data = await api.saveSettings(days); setDays(String(data.retention_days)); setStatus("已保存"); }
    catch (error) { setError(message(error)); } finally { setBusy(false); }
  }
  async function purge() {
    setBusy(true); setError(""); setStatus("");
    try { await api.purge(); dialog.current?.close(); setStatus("已请求清理，设备下次同步时执行"); }
    catch (error) { setError(message(error)); dialog.current?.close(); } finally { setBusy(false); }
  }
  return <section className="settings-block"><h3>录音</h3><form className="pending-form" onSubmit={save}><label>音频保留天数<input type="number" required min={1} max={365} step={1} value={days} disabled={loading || busy} onChange={event => { setDays(event.target.value); setStatus(""); }} /></label><button type="submit" disabled={loading || busy || !valid}>保存</button></form>
    {loading && <p role="status">正在读取…</p>}{error && <p className="error" role="alert">{error} <button onClick={() => setRevision(value => value + 1)}>重新读取</button></p>}{status && <p role="status">{status}</p>}
    <div className="actions"><button className="danger" disabled={busy} onClick={() => dialog.current?.showModal()}>清理全部音频</button></div><p className="muted">只删原始音频，转写过的文字不受影响。</p>
    <dialog ref={dialog} aria-labelledby="purge-audio-title" onCancel={event => { if (busy) event.preventDefault(); }}><h2 id="purge-audio-title">清理全部音频？</h2><p>转写过的文字不受影响，还没转写的对话会丢失。清理将在设备下次同步时执行，正在录制的对话不受影响。</p><div className="actions"><button className="danger" disabled={busy} onClick={() => void purge()}>{busy ? "提交中…" : "确认清理"}</button><button disabled={busy} onClick={() => dialog.current?.close()}>取消</button></div></dialog>
  </section>;
}
