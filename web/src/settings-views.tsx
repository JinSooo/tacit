import React, { useEffect, useRef, useState } from "react";
import { fallbackRanges, generalKeys, generalLabels, hubPort, integerIn, keyProviders, providerNames, tierConfig, tierDescriptions, tierPayload, tiers, type GeneralKey, type KeyProvider, type ModelSettingsData, type Provider, type SettingsApi, type TestResult, type Tier } from "./settings.ts";
import { tierNames } from "./status.ts";
const message = (error: unknown) => error instanceof Error ? error.message : "请求失败，请重试";
type TierForm = Record<Tier, { provider: Provider; model: string; base_url: string }>;
const formOf = (data: ModelSettingsData): TierForm => Object.fromEntries(tiers.map(t => [t, { provider: data.tiers[t].provider, model: data.tiers[t].model, base_url: data.tiers[t].base_url ?? "" }])) as TierForm;
const keyLabel = (state: boolean | null | undefined) => state === null || state === undefined ? "读不到钥匙串" : state ? "已设置" : "未设置";
const number = (value: number) => value.toLocaleString("zh-CN");

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
function LoadState({ loaded }: { loaded: { loading: boolean; error: string; retry: () => void } }) {
  return <>{loaded.loading && <p className="muted" role="status">正在读取…</p>}{loaded.error && <p className="error" role="alert">{loaded.error} <button onClick={loaded.retry}>重新读取</button></p>}</>;
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
  const providerName = (id: string) => providerNames[id as Provider] ?? providers.find(p => p.id === id)?.label ?? id;
  const update = (tier: Tier, patch: Partial<TierForm[Tier]>) => { setForm(f => f && { ...f, [tier]: { ...f[tier], ...patch } }); setStatus(""); };
  const valid = form && tiers.every(t => form[t].model.trim());

  async function save(event: React.SubmitEvent<HTMLFormElement>) {
    event.preventDefault(); if (!form) return;
    setBusy(true); setError(""); setStatus("");
    try { const value = await api.saveModels(tierPayload(form, providers)); setData(value); setForm(formOf(value)); setStatus("已保存，下次整理时生效"); }
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
    if (t === "running") return <p className="muted test-line" role="status">正在连接，最长等 1 分钟…</p>;
    if ("failed" in t) return <p className="error test-line" role="alert">{t.failed}</p>;
    return t.ok ? <p className="test-line" role="status">连接正常，用时 {(t.ms / 1000).toFixed(1)} 秒</p> : <p className="error test-line" role="alert">连不上：{t.error}</p>;
  };

  return <section className="settings-block"><h2>AI 模型</h2>
    <LoadState loaded={loaded} />
    {data?.config_error && <p className="error" role="alert">模型配置文件 <code>models.json</code> 有误，整理会失败：{data.config_error}。下面显示的是默认设置，保存后会覆盖这个文件。</p>}
    {form && data && <form className="tiers" onSubmit={save}>
      {tiers.map(tier => {
        const info = providers.find(p => p.id === form[tier].provider);
        return <fieldset key={tier} className="tier-row group" disabled={busy}>
          <legend>{tierNames[tier] ?? data.tier_info[tier].label}</legend><p>{tierDescriptions[tier]}</p>
          <div className="tier-fields">
            <label>提供商<select value={form[tier].provider} onChange={e => update(tier, { provider: e.target.value as Provider })}>{providers.map(p => <option key={p.id} value={p.id}>{providerName(p.id)}</option>)}</select></label>
            <label>模型<input required maxLength={200} spellCheck={false} value={form[tier].model} onChange={e => update(tier, { model: e.target.value })} /></label>
            {info?.base_url && <label>接口地址<input type="url" spellCheck={false} placeholder="不填就用官方地址" value={form[tier].base_url} onChange={e => update(tier, { base_url: e.target.value })} /></label>}
          </div>
          {info?.needs_key && !data.keys[info.id as KeyProvider] && <p className="error">还没填 {providerName(info.id)} 的 key，在下面填写。</p>}
          <div className="actions"><button type="button" className="compact" disabled={tests[tier] === "running" || !form[tier].model.trim()} onClick={() => void test(tier)}>测试连接</button></div>
          {testLine(tier)}
        </fieldset>;
      })}
      <div className="actions"><button className="primary" type="submit" disabled={busy || !valid}>保存</button>{status && <span role="status">{status}</span>}</div>
    </form>}
    {error && <p className="error" role="alert">{error}</p>}
    {data && <div className="key-rows"><h3>API key</h3><p className="muted">key 只存在这台 Mac 的钥匙串里，存好后不再显示。用 Claude Code 或 Codex 账号不需要 key。</p>
      {keyProviders.map(provider => <form key={provider} className="key-row" onSubmit={e => void setKey(e, provider)}>
        <span className="key-name">{providerName(provider)}</span>
        <span className={data.keys[provider] ? "" : "key-state"}>{keyLabel(data.keys[provider])}</span>
        <input type="password" autoComplete="off" spellCheck={false} aria-label={`${providerName(provider)} 的 API key`} placeholder={data.keys[provider] ? "粘贴新的 key 来替换" : "粘贴 API key"} value={keyInput[provider]} disabled={busy} onChange={e => setKeyInput(k => ({ ...k, [provider]: e.target.value }))} />
        <button type="submit" disabled={busy || keyInput[provider].trim().length < 8}>保存</button>
        {data.keys[provider] && <button type="button" className="danger" disabled={busy} onClick={() => { setRemoving(provider); dialog.current?.showModal(); }}>删除</button>}
      </form>)}
    </div>}
    <dialog ref={dialog} aria-labelledby="remove-key-title" onCancel={event => { if (busy) event.preventDefault(); }} onClose={() => setRemoving(undefined)}><h2 id="remove-key-title">删除 {removing ? providerName(removing) : ""} 的 key？</h2><p>删除后，用这个提供商的模型会连不上，直到重新填写。</p><div className="actions"><button className="danger" disabled={busy} onClick={() => void removeKey()}>{busy ? "正在删除…" : "删除"}</button><button disabled={busy} onClick={() => dialog.current?.close()}>取消</button></div></dialog>
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
    try { apply(await api.saveGeneral(values, ranges)); setStatus("已保存，下次整理和新会话开始时生效"); }
    catch (e) { setError(message(e)); } finally { setBusy(false); }
  }
  return <section className="settings-block"><h2>通用</h2>
    <form onSubmit={save}>
      {generalKeys.map(k => <label key={k}>{generalLabels[k].label}
        <span className="field-row"><input type="number" required min={ranges[k][0]} max={ranges[k][1]} step={1} value={values[k]} disabled={loaded.loading || busy} onChange={e => { setValues(v => ({ ...v, [k]: e.target.value })); setStatus(""); }} /><span>{generalLabels[k].unit}</span></span>
        <span className="hint">{[generalLabels[k].hint, defaults && `默认 ${number(defaults[k])}，可填 ${number(ranges[k][0])}–${number(ranges[k][1])}。`].filter(Boolean).join("")}</span>
      </label>)}
      <div className="actions"><button className="primary" type="submit" disabled={loaded.loading || busy || !valid}>保存</button>{status && <span role="status">{status}</span>}</div>
    </form>
    <LoadState loaded={loaded} />
    {error && <p className="error" role="alert">{error}</p>}
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
  return <section className="settings-block"><h2>后台服务</h2>
    <p className="muted">现在只接受这台 Mac 上的连接。设备配对和加密做好以后，才开放局域网。</p>
    <form onSubmit={save}>
      <label>端口<input type="number" required min={1024} max={65535} step={1} value={port} disabled={loaded.loading || busy || current?.locked || Boolean(moved)} onChange={e => setPort(e.target.value)} />
        <span className="hint">{current?.locked ? <>端口由环境变量 <code>RA_PORT</code> 固定，这里改不了。</> : "保存后后台服务会换到新端口重启，网页要从新地址打开，Mac 客户端下次启动时换过去。"}</span></label>
      <button className="primary" type="submit" disabled={loaded.loading || busy || !valid || current?.locked || Boolean(moved)}>保存并重启</button>
    </form>
    <LoadState loaded={loaded} />
    {error && <p className="error" role="alert">{error}</p>}
    {moved && next && <p role="status">{moved.restarting ? `后台服务正在用端口 ${moved.port} 重启，几秒后` : `已改成端口 ${moved.port}，后台服务下次启动后`}<a href={next}>打开新地址</a>。</p>}
  </section>;
}
