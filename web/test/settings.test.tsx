import { expect, test } from "bun:test";
import { renderToStaticMarkup } from "react-dom/server";
import { createApi } from "../src/api.ts";
import { createSettingsApi, hubPort, integerIn, isLocalURL, needsKey, providerChoice, tierConfig, tierPayload, type ProviderInfo } from "../src/settings.ts";
import { GeneralSettings, HubSettingsBlock, ModelSettings } from "../src/settings-views.tsx";

const providers: ProviderInfo[] = [
  { id: "claude-cli", label: "Claude Code", needs_key: false, base_url: false },
  { id: "anthropic", label: "Anthropic API", needs_key: true, base_url: true },
];

test("设置接口按契约发送：路径、方法、字段；数值先校验再发", async () => {
  const sent: { path: string; method: string; body: unknown }[] = [];
  const request = async (path: string, init?: RequestInit) => {
    sent.push({ path, method: init?.method ?? "GET", body: init?.body ? JSON.parse(String(init.body)) : undefined });
    return Response.json({});
  };
  const api = createSettingsApi(createApi("synthetic-token", () => {}, request));
  await api.setKey("anthropic", "  sk-synthetic-0123456789  ");
  await api.deleteKey("openai-compatible");
  await api.test("hour", { provider: "anthropic", model: "m" });
  await api.test("day");
  await api.saveGeneral({ inject_tokens: "1200", ask_done_days: 3, archive_days: "7" });
  await api.saveHub("50000");
  await api.agents();
  await api.setAgent("claude-desktop", true);
  expect(sent).toEqual([
    { path: "/v1/settings/keys/anthropic", method: "PUT", body: { key: "sk-synthetic-0123456789" } },
    { path: "/v1/settings/keys/openai-compatible", method: "DELETE", body: undefined },
    { path: "/v1/settings/models/test", method: "POST", body: { tier: "hour", config: { provider: "anthropic", model: "m" } } },
    { path: "/v1/settings/models/test", method: "POST", body: { tier: "day" } },
    { path: "/v1/settings/general", method: "PUT", body: { inject_tokens: 1200, ask_done_days: 3, archive_days: 7 } },
    { path: "/v1/settings/hub", method: "PUT", body: { port: 50000 } },
    { path: "/v1/settings/agents", method: "GET", body: undefined },
    { path: "/v1/settings/agents/claude-desktop", method: "PUT", body: { connected: true } },
  ]);
  expect(() => api.saveGeneral({ inject_tokens: "100", ask_done_days: 3, archive_days: 7 })).toThrow("200–4000");
  expect(() => hubPort("80")).toThrow("1024–65535");
  expect(() => integerIn("", [1, 30], "天数")).toThrow("天数须为 1–30 的整数");
  expect(() => integerIn("1.5", [1, 30], "天数")).toThrow();
  expect(sent).toHaveLength(8);
});

test("tiers 表单整理：去空白，账号登录类和空 base_url 不发", () => {
  expect(tierPayload({
    minute: { provider: "claude-cli", model: " haiku ", base_url: "https://ignored.invalid" },
    hour: { provider: "anthropic", model: "m", base_url: "  " },
    day: { provider: "anthropic", model: "m", base_url: " https://relay.invalid/v1 " },
  }, providers)).toEqual({
    minute: { provider: "claude-cli", model: "haiku" },
    hour: { provider: "anthropic", model: "m" },
    day: { provider: "anthropic", model: "m", base_url: "https://relay.invalid/v1" },
  });
});

test("设置页三块首屏：读取中、本机限定说明、无 key 内容", () => {
  const api = createSettingsApi(async <T,>() => new Promise<T>(() => {}));
  const html = renderToStaticMarkup(<><ModelSettings api={api} /><GeneralSettings api={api} /><HubSettingsBlock api={api} token="synthetic-token" /></>);
  for (const text of ["AI 模型", "通用", "后台服务", "正在读取", "只接受这台 Mac 上的连接", "才开放局域网", 'min="1024"', 'max="65535"', "自动带入的长度上限"]) expect(html).toContain(text);
  expect(html).not.toContain("synthetic-token");
});

test("本机预设免 key，思考参数跟随配置传递，切换后端不带不支持的参数", async () => {
  const list: ProviderInfo[] = [...providers, { id: "openai-compatible", label: "兼容接口", needs_key: true, base_url: true }];
  const local = { provider: "openai-compatible" as const, model: " qwen ", base_url: "http://127.0.0.1:11434/v1", reasoning_effort: "none" as const };
  expect(providerChoice(local)).toBe("ollama");
  expect(providerChoice({ ...local, base_url: "http://127.0.0.1:1234/v1" })).toBe("lmstudio");
  expect(needsKey(local, list)).toBe(false);
  expect(needsKey({ ...local, base_url: "https://relay.invalid/v1" }, list)).toBe(true);
  expect(isLocalURL("http://127.attacker.invalid/v1")).toBe(false);
  expect(tierConfig(local, list)).toEqual({ ...local, model: "qwen" });
  expect(tierConfig({ ...local, reasoning_effort: "" }, list)).not.toHaveProperty("reasoning_effort");
  expect(tierConfig({ ...local, provider: "anthropic" }, list)).not.toHaveProperty("reasoning_effort");
  let sent: unknown;
  const api = createSettingsApi(async <T,>(path: string, init?: RequestInit) => { sent = { path, body: JSON.parse(String(init?.body)) }; return { models: [] } as T; });
  await api.localModels(local.base_url);
  expect(sent).toEqual({ path: "/v1/settings/models/local", body: { base_url: local.base_url } });
});
