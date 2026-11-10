import { expect, test } from "bun:test";
import { renderToStaticMarkup } from "react-dom/server";
import { createApi } from "../src/api.ts";
import { createSettingsApi, hubPort, integerIn, tierPayload, type ProviderInfo } from "../src/settings.ts";
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
  expect(sent).toEqual([
    { path: "/v1/settings/keys/anthropic", method: "PUT", body: { key: "sk-synthetic-0123456789" } },
    { path: "/v1/settings/keys/openai-compatible", method: "DELETE", body: undefined },
    { path: "/v1/settings/models/test", method: "POST", body: { tier: "hour", config: { provider: "anthropic", model: "m" } } },
    { path: "/v1/settings/models/test", method: "POST", body: { tier: "day" } },
    { path: "/v1/settings/general", method: "PUT", body: { inject_tokens: 1200, ask_done_days: 3, archive_days: 7 } },
    { path: "/v1/settings/hub", method: "PUT", body: { port: 50000 } },
  ]);
  expect(() => api.saveGeneral({ inject_tokens: "100", ask_done_days: 3, archive_days: 7 })).toThrow("200–4000");
  expect(() => hubPort("80")).toThrow("1024–65535");
  expect(() => integerIn("", [1, 30], "天数")).toThrow("天数须为 1–30 的整数");
  expect(() => integerIn("1.5", [1, 30], "天数")).toThrow();
  expect(sent).toHaveLength(6);
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
  for (const text of ["AI 模型", "通用", "中枢", "正在读取", "只接受本机（127.0.0.1）连接", "配对设备并启用加密后才开放局域网", 'min="1024"', 'max="65535"', "自动注入上限"]) expect(html).toContain(text);
  expect(html).not.toContain("synthetic-token");
});
