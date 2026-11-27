import { spawnSync } from "node:child_process";
import { isIP } from "node:net";

type SystemProxy = {
  http?: string;
  https?: string;
  socks?: string;
  pac?: boolean;
  exceptions: string[];
};

const DIRECT = [
  "localhost", "*.localhost", "127.0.0.0/8", "::1", "10.0.0.0/8", "172.16.0.0/12",
  "192.168.0.0/16", "169.254.0.0/16", "fe80::/10", "fc00::/7", "*.local",
];

export function parseScutilProxy(output: string): SystemProxy {
  const fields = new Map<string, string>(), exceptions: string[] = [];
  let readingExceptions = false;
  for (const line of output.split("\n")) {
    const field = /^\s*(\w+)\s*:\s*(.*?)\s*$/.exec(line);
    if (readingExceptions) {
      if (/^\s*}/.test(line)) readingExceptions = false;
      else if (field && /^\d+$/.test(field[1]!) && field[2]) exceptions.push(field[2]);
    } else if (field?.[1] === "ExceptionsList" && field[2] === "<array> {") readingExceptions = true;
    else if (field) fields.set(field[1]!, field[2]!);
  }
  const address = (type: string, scheme: string) => {
    const host = fields.get(type + "Proxy"), port = Number(fields.get(type + "Port"));
    if (fields.get(type + "Enable") !== "1" || !host || !Number.isInteger(port) || port < 1 || port > 65535) return;
    return scheme + "://" + (isIP(host) === 6 ? `[${host}]` : host) + ":" + port;
  };
  // HTTPSProxy 是 HTTPS 目标用的 HTTP CONNECT 代理。
  return { http: address("HTTP", "http"), https: address("HTTPS", "http"), socks: address("SOCKS", "socks5"),
    pac: fields.get("ProxyAutoConfigEnable") === "1", exceptions };
}

let cached: { until: number; value: SystemProxy } | undefined;
function readSystemProxy(): SystemProxy {
  if (process.platform !== "darwin") return { exceptions: [] };
  if (cached && Date.now() < cached.until) return cached.value;
  let value: SystemProxy = { exceptions: [] };
  try {
    const result = spawnSync("/usr/sbin/scutil", ["--proxy"], { encoding: "utf8", timeout: 1000 });
    if (result.status === 0) value = parseScutilProxy(result.stdout);
  } catch { /* 系统设置读不到时仍可使用环境变量。 */ }
  cached = { until: Date.now() + 30_000, value };
  return value;
}

const aliases = {
  http: ["http_proxy", "HTTP_PROXY"],
  https: ["https_proxy", "HTTPS_PROXY"],
  all: ["all_proxy", "ALL_PROXY"],
  no: ["no_proxy", "NO_PROXY"],
} as const;

export function capturedCLIEnv(source: NodeJS.ProcessEnv): NodeJS.ProcessEnv {
  try {
    const parsed: unknown = JSON.parse(source.TACIT_CLI_ENV ?? "{}");
    if (parsed && typeof parsed === "object") {
      return Object.fromEntries(Object.entries(parsed).filter(([, value]) => typeof value === "string"));
    }
  } catch { /* 读不懂就当没有。 */ }
  return {};
}

function proxySetting(layers: NodeJS.ProcessEnv[], ...keys: string[]): [string, string] | undefined {
  for (const layer of layers) {
    for (const key of keys) {
      const value = layer[key]?.trim();
      if (value) return [key, value];
    }
  }
}

function bypassList(...values: (string | undefined)[]): string[] {
  return [...new Set(values.flatMap(value => value?.split(",").map(rule => rule.trim()).filter(Boolean) ?? []))];
}

export function systemProxyEnv(system = readSystemProxy()): Record<string, string> {
  // 打包的 Bun 1.4.4 实测会拒绝 socks5://（UnsupportedProxyProtocol）；仅设置 PAC 时也直连。
  const http = system.http ?? system.https, https = system.https ?? system.http;
  return {
    ...(http ? { HTTP_PROXY: http } : {}),
    ...(https ? { HTTPS_PROXY: https } : {}),
    NO_PROXY: bypassList(...DIRECT, ...system.exceptions).join(","),
  };
}

export function cliProxyEnv(source: NodeJS.ProcessEnv, captured: NodeJS.ProcessEnv, defaults: Record<string, string>): Record<string, string> {
  const layers = [source, captured, defaults];
  const all = proxySetting(layers, ...aliases.all);
  const http = proxySetting(layers, ...aliases.http, ...aliases.all);
  const https = proxySetting(layers, ...aliases.https, ...aliases.all);
  const no = bypassList(...layers.flatMap(layer => aliases.no.map(key => layer[key]))).join(",");
  // 大小写视为同一个设置。高层的 ALL_PROXY 也能覆盖低层的 HTTP(S)_PROXY。
  return {
    ...Object.fromEntries([all, http, https].filter(entry => entry !== undefined)),
    NO_PROXY: no,
    ...(source.no_proxy !== undefined || captured.no_proxy !== undefined ? { no_proxy: no } : {}),
  };
}

function ipv4Number(host: string): bigint {
  return host.split(".").reduce((value, part) => (value << 8n) | BigInt(part), 0n);
}

function ipNumber(host: string, version: number): bigint {
  if (version === 4) return ipv4Number(host);
  const expanded = host.split("%", 1)[0]!.replace(/\d+\.\d+\.\d+\.\d+$/, ipv4 => {
    const value = ipv4Number(ipv4);
    return `${(value >> 16n).toString(16)}:${(value & 65535n).toString(16)}`;
  });
  const [left = "", right] = expanded.split("::");
  const groups = (side: string) => side ? side.split(":") : [];
  const head = groups(left), tail = groups(right ?? "");
  const full = right === undefined ? head : [...head, ...Array<string>(8 - head.length - tail.length).fill("0"), ...tail];
  return full.reduce((value, part) => (value << 16n) | BigInt("0x" + part), 0n);
}

function matches(host: string, port: string, rule: string): boolean {
  const [network, width, extra] = rule.split("/");
  if (width !== undefined) {
    const ip = network!.replace(/^\[(.*)\]$/, "$1");
    const version = isIP(ip), bits = version === 4 ? 32 : 128, prefix = Number(width);
    if (extra !== undefined || !version || isIP(host) !== version || !/^\d+$/.test(width) || prefix > bits) return false;
    const shift = BigInt(bits - prefix);
    return (ipNumber(host, version) >> shift) === (ipNumber(ip, version) >> shift);
  }
  const withPort = /^(\[[^\]]+\]|[^:]+):(\d+)$/.exec(rule);
  if (withPort && withPort[2] !== port) return false;
  const pattern = (withPort?.[1] ?? rule).replace(/^\[(.*)\]$/, "$1").replace(/\.$/, "").toLowerCase();
  if (isIP(pattern) === 6) return isIP(host) === 6 && ipNumber(host, 6) === ipNumber(pattern, 6);
  if (pattern.startsWith(".")) return host === pattern.slice(1) || host.endsWith(pattern);
  if (!pattern.includes("*")) return host === pattern;
  const wildcard = pattern.split("*").map(part => part.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")).join(".*");
  return new RegExp("^" + wildcard + "$").test(host);
}

export function proxyFor(url: string | URL, source = process.env, system = readSystemProxy()): string | undefined {
  const target = new URL(url);
  const secure = target.protocol === "https:" || target.protocol === "wss:";
  if (!secure && target.protocol !== "http:" && target.protocol !== "ws:") return;
  const host = target.hostname.replace(/^\[(.*)\]$/, "$1").replace(/\.$/, "");
  const port = target.port || (secure ? "443" : "80");
  const ipv6 = isIP(host) === 6 ? ipNumber(host, 6) : 0n;
  const mapped = ipv6 >> 32n === 0xffffn
    ? [24n, 16n, 8n, 0n].map(shift => Number((ipv6 >> shift) & 255n)).join(".")
    : undefined;
  const defaults = systemProxyEnv(system);
  const layers = [source, capturedCLIEnv(source), defaults];
  if (bypassList(...layers.flatMap(layer => aliases.no.map(key => layer[key])))
    .some(rule => matches(host, port, rule) || (mapped !== undefined && matches(mapped, port, rule)))) return;

  const proxy = proxySetting(layers, ...aliases[secure ? "https" : "http"], ...aliases.all)?.[1];
  // Bun 的 HTTP 和 WebSocket 代理只接受 HTTP(S) 地址。
  if (proxy && /^https?:\/\//i.test(proxy) && URL.canParse(proxy)) return proxy;
}

export function proxiedFetch(input: string | URL | Request, init?: RequestInit,
  proxy: string | false | undefined = proxyFor(input instanceof Request ? input.url : input)): Promise<Response> {
  // false 才能保证直连；undefined 会再次让 Bun 从环境变量选代理。
  return fetch(input, { ...init, proxy: proxy ? { url: proxy, respectNoProxy: false } : false });
}
