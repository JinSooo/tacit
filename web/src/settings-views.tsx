import React, { useEffect, useRef, useState } from "react";
import { fallbackRanges, generalKeys, generalLabels, hubPort, integerIn, keyProviders, tierConfig, tierPayload, tiers, type GeneralKey, type KeyProvider, type ModelSettingsData, type Provider, type SettingsApi, type TestResult, type Tier } from "./settings.ts";
const message = (error: unknown) => error instanceof Error ? error.message : "请求失败，请重试";
type TierForm = Record<Tier, { provider: Provider; model: string; base_url: string }>;
const formOf = (data: ModelSettingsData): TierForm => Object.fromEntries(tiers.map(t => [t, { provider: data.tiers[t].provider, model: data.tiers[t].model, base_url: data.tiers[t].base_url ?? "" }])) as TierForm;
const keyLabel = (state: boolean | null | undefined) => state === null || state === undefined ? "无法读取钥匙串" : state ? "已设置" : "未设置";

/** 读取一块设置，失败时给重新读取；各块独立，一块出错不影响其他块。 */
function useLoad<T>(load: (signal: AbortSignal) => Promise<T>, apply: (data: T) => void) {
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState("");
  const [revision, setRevision] = useState(0);
  useEffect(() => {
    const controller = new AbortController();
    setLoading(true); setError("");
    load(controller.signal).then(data => { if (!controller.signal.aborted) apply(data); }).catch(e => { if (!controller.signal.aborted) setError(message(e)); }).finally(() => { if (!controller.signal.aborted) setLoading(false); });
    return () => controller.abort();
  }, [load, revision]);
  return { loading, error, retry: () => setRevision(v => v + 1) };
}

export function ModelSettings({ api }: { api: SettingsApi }) {
  const [data, setData] = useState<ModelSettingsData>();
  const [form, setForm] = useState<TierForm>();
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState("");
  const [status, setStatus] = useState("");
  const [tests, setTests] = useState<Partial<Record<Tier, TestResult | "running" | { failed: string }>>>({});
  const [keyInput, setKeyInput] = useState<Record<KeyProvider, string>>({ anthropic: "", "openai-compatible": "" });
  const [removing, setRemoving] = useState<KeyProvider>();
  const dialog = useRef<HTMLDialogElement>(null);
  const loaded = useLoad(api.models, value => { setData(value); setForm(formOf(value)); });
  const providers = data?.providers ?? [];
  const update = (tier: Tier, patch: Partial<TierForm[Tier]>) => { setForm(f => f && { ...f, [tier]: { ...f[tier], ...patch } }); setStatus(""); };
  const valid = form && tiers.every(t => form[t].model.trim());

  async function save(event: React.SubmitEvent<HTMLFormElement>) {
    event.preventDefault(); if (!form) return;
    setBusy(true); setError(""); setStatus("");
    try { const value = await api.saveModels(tierPayload(form, providers)); setData(value); setForm(formOf(value)); setStatus("已保存，下一次模型调用起生效"); }
    catch (e) { setError(message(e)); } finally { setBusy(false); }
  }
  async function test(tier: Tier) {
    if (!form) return;
    setTests(t => ({ ...t, [tier]: "running" }));
    try { const result = await api.test(tier, tierConfig(form[tier], providers)); setTests(t => ({ ...t, [tier]: result })); }
    catch (e) { setTests(t => ({ ...t, [tier]: { failed: message(e) } })); }
  }
  async function setKey(event: React.SubmitEvent<HTMLFormElement>, provider: KeyProvider) {
    event.preventDefault(); setBusy(true); setError(""); setStatus("");
    try {
      await api.setKey(provider, keyInput[provider]);
      setKeyInput(k => ({ ...k, [provider]: "" }));
      setData(d => d && { ...d, keys: { ...d.keys, [provider]: true } }); setStatus("API key 已存进钥匙串");
    } catch (e) { setError(message(e)); } finally { setBusy(false); }
  }
  async function removeKey() {
    if (!removing) return;
    setBusy(true); setError(""); setStatus("");
    try { await api.deleteKey(removing); setData(d => d && { ...d, keys: { ...d.keys, [removing]: false } }); setStatus("API key 已删除"); }
    catch (e) { setError(message(e)); } finally { setBusy(false); dialog.current?.close(); setRemoving(undefined); }
  }
  const testLine = (tier: Tier) => {
    const t = tests[tier];
    if (!t) return null;
    if (t === "running") return <p className="muted" role="status">测试中，最长 60 秒…</p>;
    if ("failed" in t) return <p className="error" role="alert">{t.failed}</p>;
    return t.ok ? <p role="status">连接正常，用时 {(t.ms / 1000).toFixed(1)} 秒</p> : <p className="error" role="alert">连接失败：{t.error}</p>;
  };

  return <section className="settings-block"><h3>AI 模型</h3>
    {loaded.loading && <p role="status">正在读取…</p>}
    {loaded.error && <p className="error" role="alert">{loaded.error} <button onClick={loaded.retry}>重新读取</button></p>}
    {data?.config_error && <p className="error" role="alert">models.json 无效，提炼会失败：{data.config_error}。下面是默认值，保存会覆盖原文件。</p>}
    {form && data && <form onSubmit={save}>
      {tiers.map(tier => {
        const info = providers.find(p => p.id === form[tier].provider);
        return <fieldset key={tier} className="tier-row" disabled={busy}>
          <legend>{data.tier_info[tier].label}</legend><p className="muted">{data.tier_info[tier].description}</p>
          <div className="tier-fields">
            <label>提供方<select value={form[tier].provider} onChange={e => update(tier, { provider: e.target.value as Provider })}>{providers.map(p => <option key={p.id} value={p.id}>{p.label}</option>)}</select></label>
            <label>模型<input required maxLength={200} value={form[tier].model} onChange={e => update(tier, { model: e.target.value })} /></label>
            {info?.base_url && <label>Base URL<input type="url" placeholder="留空用官方地址" value={form[tier].base_url} onChange={e => update(tier, { base_url: e.target.value })} /></label>}
          </div>
          {info?.needs_key && !data.keys[info.id as KeyProvider] && <p className="muted">还没有设置 {info.label} 的 API key，见下方。</p>}
          <div className="actions"><button type="button" className="compact" disabled={tests[tier] === "running" || !form[tier].model.trim()} onClick={() => void test(tier)}>测试连接</button></div>
          {testLine(tier)}
        </fieldset>;
      })}
      <button type="submit" disabled={busy || !valid}>保存模型配置</button>
    </form>}
    {error && <p className="error" role="alert">{error}</p>}{status && <p role="status">{status}</p>}
    {data && <div className="key-rows"><h4>API key</h4><p className="muted">只存在本机钥匙串，界面上不显示 key 本身。账号登录方式（Claude Code、Codex）用本机已登录的命令，不需要 key。</p>
      {keyProviders.map(provider => <form key={provider} className="key-row" onSubmit={e => void setKey(e, provider)}>
        <span className="key-name">{providers.find(p => p.id === provider)?.label ?? provider}</span>
        <span className={data.keys[provider] ? "" : "muted"}>{keyLabel(data.keys[provider])}</span>
        <input type="password" autoComplete="off" spellCheck={false} aria-label={`${provider} 的 API key`} placeholder={data.keys[provider] ? "输入新 key 替换" : "粘贴 API key"} value={keyInput[provider]} disabled={busy} onChange={e => setKeyInput(k => ({ ...k, [provider]: e.target.value }))} />
        <button type="submit" className="compact" disabled={busy || keyInput[provider].trim().length < 8}>保存</button>
        {data.keys[provider] && <button type="button" className="compact danger" disabled={busy} onClick={() => { setRemoving(provider); dialog.current?.showModal(); }}>删除</button>}
      </form>)}
    </div>}
    <dialog ref={dialog} aria-labelledby="remove-key-title" onCancel={event => { if (busy) event.preventDefault(); }} onClose={() => setRemoving(undefined)}><h2 id="remove-key-title">删除 API key？</h2><p>会从钥匙串删除 {removing} 的 key。用这个提供方的档位之后会调用失败，直到重新设置。</p><div className="actions"><button className="danger" disabled={busy} onClick={() => void removeKey()}>{busy ? "删除中…" : "确认删除"}</button><button disabled={busy} onClick={() => dialog.current?.close()}>取消</button></div></dialog>
  </section>;
}

export function GeneralSettings({ api }: { api: SettingsApi }) {
  const [values, setValues] = useState<Record<GeneralKey, string>>({ inject_tokens: "", ask_done_days: "", archive_days: "" });
  const [ranges, setRanges] = useState(fallbackRanges);
  const [defaults, setDefaults] = useState<Record<GeneralKey, number>>();
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState("");
  const [status, setStatus] = useState("");
  const apply = (data: Awaited<ReturnType<SettingsApi["general"]>>) => { setValues(Object.fromEntries(generalKeys.map(k => [k, String(data[k])])) as Record<GeneralKey, string>); setRanges(data.ranges); setDefaults(data.defaults); };
  const loaded = useLoad(api.general, apply);
  const valid = generalKeys.every(k => { try { integerIn(values[k], ranges[k], ""); return true; } catch { return false; } });
  async function save(event: React.SubmitEvent<HTMLFormElement>) {
    event.preventDefault(); setBusy(true); setError(""); setStatus("");
    try { apply(await api.saveGeneral(values, ranges)); setStatus("已保存，提炼下一轮和下一次注入起生效"); }
    catch (e) { setError(message(e)); } finally { setBusy(false); }
  }
  return <section className="settings-block"><h3>通用</h3>
    <form className="pending-form" onSubmit={save}>
      {generalKeys.map(k => <label key={k}>{generalLabels[k].label}（{generalLabels[k].unit}）
        <input type="number" required min={ranges[k][0]} max={ranges[k][1]} step={1} value={values[k]} disabled={loaded.loading || busy} onChange={e => { setValues(v => ({ ...v, [k]: e.target.value })); setStatus(""); }} />
        <span className="hint">{generalLabels[k].hint}{defaults ? `默认 ${defaults[k]}，范围 ${ranges[k][0]}–${ranges[k][1]}。` : ""}</span>
      </label>)}
      <button type="submit" disabled={loaded.loading || busy || !valid}>保存</button>
    </form>
    {loaded.loading && <p role="status">正在读取…</p>}
    {loaded.error && <p className="error" role="alert">{loaded.error} <button onClick={loaded.retry}>重新读取</button></p>}
    {error && <p className="error" role="alert">{error}</p>}{status && <p role="status">{status}</p>}
  </section>;
}

export function HubSettingsBlock({ api, token }: { api: SettingsApi; token: string }) {
  const [current, setCurrent] = useState<{ port: number; locked: boolean }>();
  const [port, setPort] = useState("");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState("");
  const [moved, setMoved] = useState<{ port: number; restarting: boolean }>();
  const loaded = useLoad(api.hub, data => { setCurrent(data); setPort(String(data.port)); });
  let valid = false;
  try { valid = hubPort(port) !== current?.port; } catch { /* 无效输入留在输入框，由按钮状态提示 */ }
  async function save(event: React.SubmitEvent<HTMLFormElement>) {
    event.preventDefault(); setBusy(true); setError("");
    try { setMoved(await api.saveHub(port)); } catch (e) { setError(message(e)); } finally { setBusy(false); }
  }
  const next = moved && `http://127.0.0.1:${moved.port}/#token=${encodeURIComponent(token)}`;
  return <section className="settings-block"><h3>中枢</h3>
    <p className="muted">中枢只接受本机（127.0.0.1）连接。配对设备并启用加密后才开放局域网。</p>
    <form className="pending-form" onSubmit={save}>
      <label>端口<input type="number" required min={1024} max={65535} step={1} value={port} disabled={loaded.loading || busy || current?.locked || Boolean(moved)} onChange={e => setPort(e.target.value)} />
        <span className="hint">{current?.locked ? "端口由环境变量 RA_PORT 固定，这里不能改。" : "保存后中枢会用新端口重启，这个网页需要换到新地址打开。Mac 采集端下次启动时用新端口。"}</span></label>
      <button type="submit" disabled={loaded.loading || busy || !valid || current?.locked || Boolean(moved)}>保存并重启中枢</button>
    </form>
    {loaded.loading && <p role="status">正在读取…</p>}
    {loaded.error && <p className="error" role="alert">{loaded.error} <button onClick={loaded.retry}>重新读取</button></p>}
    {error && <p className="error" role="alert">{error}</p>}
    {moved && next && <p role="status">{moved.restarting ? `中枢正在用端口 ${moved.port} 重启，几秒后` : `已写入端口 ${moved.port}，中枢下次启动后`}<a href={next}>在新地址打开</a>。</p>}
  </section>;
}
