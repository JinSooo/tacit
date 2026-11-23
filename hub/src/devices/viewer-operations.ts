import { InputError } from "../db.ts";
import { localDayStart } from "../distill/requests.ts";
import { GENERAL_DEFAULTS } from "../general-settings.ts";
import { KEY_PROVIDERS } from "../llm/config.ts";
import { deviceID } from "./envelope.ts";

type PathCheck = (value: string) => boolean;
type Route = {
  method: string;
  path: string;
  params?: Readonly<Record<string, PathCheck>>;
  query?: Readonly<Record<string, "number" | "string">>;
  body?: readonly string[];
  record?: boolean;
  native?: boolean;
  relayLock?: boolean;
  binary?: boolean;
};
const safeID = (value: string) => /^[\w-]{1,128}$/.test(value);
const segmentID = (value: string) => /^[\w:.-]{1,200}$/.test(value) && value !== "." && value !== "..";
const day = (value: string) => localDayStart(value) !== null;
const provider = (value: string) => KEY_PROVIDERS.some(key => key === value);
const device = (value: string) => deviceID.test(value);
const pagination = { limit: "number", cursor: "string" } as const;
const routes: ReadonlyMap<string, Route> = new Map<string, Route>([
  ["records.create", { method: "POST", path: "/v1/records", record: true }],
  ["delete", { method: "DELETE", path: "/v1/records", body: ["ids", "device"], native: true }],
  ["segment.correct", { method: "PATCH", path: "/v1/days/:date/segments/:id", params: { date: day, id: segmentID }, body: ["description"] }],
  ["segment.delete", { method: "DELETE", path: "/v1/days/:date/segments/:id", params: { date: day, id: segmentID }, body: ["record_ids"], native: true }],
  ["project.remove", { method: "DELETE", path: "/v1/projects/:id", params: { id: safeID } }],
  ["pending.list", { method: "GET", path: "/v1/pending" }],
  ["pending.resolve", { method: "POST", path: "/v1/pending/:id", params: { id: safeID }, body: ["action", "name", "target"] }],
  ["facts.create", { method: "POST", path: "/v1/facts", body: ["kind", "text", "evidence", "thread_id", "project_id", "reason", "supersedes", "valid_at", "confidence"] }],
  ["facts.detach", { method: "POST", path: "/v1/facts/:id/detach", params: { id: safeID } }],
  ["distill.request", { method: "POST", path: "/v1/distill/requests", body: ["kind", "from", "to"] }],
  ["distill.list", { method: "GET", path: "/v1/distill/requests" }],
  ["audio.settings.get", { method: "GET", path: "/v1/audio/settings" }],
  ["audio.settings.put", { method: "PUT", path: "/v1/audio/settings", body: ["retention_days"] }],
  ["audio.purge", { method: "POST", path: "/v1/audio/purge" }],
  ["speakers.list", { method: "GET", path: "/v1/speakers" }],
  ["audio.sample.get", { method: "GET", path: "/v1/audio/samples/:id", params: { id: safeID }, binary: true }],
  ["status.get", { method: "GET", path: "/v1/status", native: true }],
  ["diagnostics.get", { method: "GET", path: "/v1/runtime/background" }],
  ["runtime.models", { method: "GET", path: "/v1/runtime/models", query: pagination }],
  ["runtime.call", { method: "GET", path: "/v1/runtime/calls/:id", params: { id: safeID } }],
  ["runtime.background", { method: "GET", path: "/v1/runtime/background", query: { source: "string" } }],
  ["audit.list", { method: "GET", path: "/v1/audit", query: { ...pagination, tool: "string" } }],
  ["settings.hub.get", { method: "GET", path: "/v1/settings/hub" }],
  ["settings.hub.put", { method: "PUT", path: "/v1/settings/hub", body: ["port"] }],
  ["settings.models.get", { method: "GET", path: "/v1/settings/models" }],
  ["settings.models.put", { method: "PUT", path: "/v1/settings/models", body: ["tiers"] }],
  ["settings.models.local", { method: "POST", path: "/v1/settings/models/local", body: ["base_url"] }],
  ["settings.models.test", { method: "POST", path: "/v1/settings/models/test", body: ["tier", "config"] }],
  ["settings.keys.put", { method: "PUT", path: "/v1/settings/keys/:provider", params: { provider }, body: ["key"] }],
  ["settings.keys.delete", { method: "DELETE", path: "/v1/settings/keys/:provider", params: { provider } }],
  ["settings.general.get", { method: "GET", path: "/v1/settings/general" }],
  ["settings.general.put", { method: "PUT", path: "/v1/settings/general", body: Object.keys(GENERAL_DEFAULTS) }],
  ["settings.relay.get", { method: "GET", path: "/v1/settings/relay" }],
  ["settings.relay.put", { method: "PUT", path: "/v1/settings/relay", body: ["mode", "url", "code"], relayLock: true }],
  ["settings.relay.test", { method: "POST", path: "/v1/settings/relay/test", body: ["url"] }],
  ["devices.list", { method: "GET", path: "/v1/settings/devices", relayLock: true }],
  ["devices.pairing.create", { method: "POST", path: "/v1/settings/devices/pairing", body: ["role", "viewer"], relayLock: true }],
  ["devices.pairing.cancel", { method: "DELETE", path: "/v1/settings/devices/pairing", relayLock: true }],
  ["devices.remove", { method: "DELETE", path: "/v1/settings/devices/:id", params: { id: device }, native: true, relayLock: true }],
  ["devices.role.update", { method: "PUT", path: "/v1/settings/devices/:id/role", params: { id: device }, body: ["role"], native: true, relayLock: true }],
]);

export const viewerOperationNeedsRelayLock = (op: string) => routes.get(op)?.relayLock === true;

export type ViewerOperation = {
  method: string;
  url: URL;
  input?: Record<string, unknown>;
  native: boolean;
  binary: boolean;
};

export function viewerOperation(op: string, body: Record<string, unknown>): ViewerOperation | undefined {
  const route = routes.get(op);
  if (!route) return;
  const keys = [...Object.keys(route.params ?? {}), ...Object.keys(route.query ?? {}), ...(route.body ?? [])];
  if (route.record) {
    // 字段校验交给原接口的 ingest：格式不对时和 HTTP 一样返回逐字段的 rejected，而不是一句笼统的 400。
  } else if (Object.keys(body).some(key => !keys.includes(key))) {
    throw new InputError("设备操作包含未登记的参数");
  }
  const path = route.path.replace(/:(\w+)/g, (_, name: string) => {
    const value = body[name];
    if (typeof value !== "string" || !route.params?.[name]?.(value)) throw new InputError("路径参数无效");
    return value; // Every path check admits only literal characters safe in this path segment.
  });
  const url = new URL(path, "http://127.0.0.1");
  for (const [key, type] of Object.entries(route.query ?? {})) {
    const value = body[key];
    if (value === undefined) continue;
    if (typeof value !== type) throw new InputError("查询参数类型无效");
    url.searchParams.set(key, String(value));
  }
  const input = route.record ? body : route.body && Object.fromEntries(
    route.body.filter(key => Object.hasOwn(body, key)).map(key => [key, body[key]]),
  );
  return { method: route.method, url, input, native: !!route.native, binary: !!route.binary };
}

export type ViewerActor = { device: string; relayLocked: boolean; fromRelay: boolean };
