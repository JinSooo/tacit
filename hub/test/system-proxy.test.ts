import { expect, test } from "bun:test";
import { parseScutilProxy, proxiedFetch, proxyFor, systemProxyEnv } from "../src/net/system-proxy.ts";
import { cliEnv } from "../src/llm/process.ts";

const SYSTEM = parseScutilProxy(`<dictionary> {
  ExceptionsList : <array> {
    0 : *.direct.example
    1 : exact.example
    2 : *direct-suffix.example
  }
  HTTPEnable : 1
  HTTPPort : 8888
  HTTPProxy : http.example
  HTTPSEnable : 1
  HTTPSPort : 8443
  HTTPSProxy : ::1
  ProxyAutoConfigEnable : 1
  SOCKSEnable : 1
  SOCKSPort : 9999
  SOCKSProxy : socks.example
}`);

test("scutil 的 HTTP、HTTPS、SOCKS、PAC 和例外可读；PAC 或 SOCKS 单独开启时直连", () => {
  expect(SYSTEM).toEqual({
    http: "http://http.example:8888", https: "http://[::1]:8443", socks: "socks5://socks.example:9999", pac: true,
    exceptions: ["*.direct.example", "exact.example", "*direct-suffix.example"],
  });
  expect(proxyFor("https://external.example", {}, SYSTEM)).toBe(SYSTEM.https!);
  expect(proxyFor("http://external.example", {}, SYSTEM)).toBe(SYSTEM.http!);
  expect(proxyFor("https://external.example", {}, { http: SYSTEM.http, exceptions: [] })).toBe(SYSTEM.http!);
  const onlyPacAndSocks = parseScutilProxy(`HTTPEnable : 0
    HTTPProxy : disabled.example
    HTTPPort : 8080
    HTTPSEnable : 1
    HTTPSProxy : invalid.example
    HTTPSPort : 65536
    SOCKSEnable : 1
    SOCKSProxy : socks.example
    SOCKSPort : 9999
    ProxyAutoConfigEnable : 1`);
  expect(onlyPacAndSocks).toMatchObject({ http: undefined, https: undefined, socks: "socks5://socks.example:9999", pac: true });
  expect(proxyFor("https://external.example", {}, onlyPacAndSocks)).toBeUndefined();
  expect(systemProxyEnv(onlyPacAndSocks).HTTPS_PROXY).toBeUndefined();
});

test("本机、私网、scutil 例外和 NO_PROXY 直连，CIDR 边界与精确主机名不误匹配", () => {
  const env = {
    HTTPS_PROXY: "http://explicit.example:8080",
    NO_PROXY: "10.128.0.0/9, 198.51.100.0/24, 2001:db8::/32, *.no.example, exact.no-other.example, port.example:443",
    TACIT_CLI_ENV: '{"no_proxy":"captured.direct"}',
  };
  for (const host of [
    "localhost", "a.localhost.", "127.100.0.1", "[::1]", "[::ffff:192.168.0.1]", "10.0.0.1", "172.16.0.0",
    "172.31.255.255", "192.168.1.1", "169.254.1.2", "[febf::1]", "[fc00::1]", "[fd00::1]", "printer.local",
    "A.Direct.Example.", "exact.example", "a-direct-suffix.example", "198.51.100.254", "[2001:db8:ff::1]",
    "a.no.example", "exact.no-other.example", "port.example", "captured.direct",
  ]) expect(proxyFor(`https://${host}`, env, SYSTEM), host).toBeUndefined();
  for (const host of [
    "localhost.example", "128.0.0.1", "172.15.255.255", "172.32.0.0", "192.169.0.0", "[fec0::1]", "[fe7f::1]",
    "[fbff::1]", "local.example", "a.exact.example", "198.51.101.1", "[2001:db9::1]", "a.exact.no-other.example",
    "port.example:444",
  ]) expect(proxyFor(`https://${host}`, env, SYSTEM), host).toBe(env.HTTPS_PROXY);
});

test("后台和子进程都按进程、安装时环境、系统的顺序选择代理，大小写不改变优先级", () => {
  const explicit = "http://explicit.example:8080", captured = "http://captured.example:8080";
  const env = { HTTPS_PROXY: explicit, NO_PROXY: "process.direct", TACIT_CLI_ENV: JSON.stringify({
    https_proxy: captured, http_proxy: captured, no_proxy: "captured.direct",
  }) };
  expect(proxyFor("wss://external.example", env, SYSTEM)).toBe(explicit);
  expect(proxyFor("ws://external.example", env, SYSTEM)).toBe(captured);
  expect(proxyFor("https://external.example", { ...env, HTTPS_PROXY: undefined }, SYSTEM)).toBe(captured);
  const cli = cliEnv(env, systemProxyEnv(SYSTEM));
  expect(cli).toMatchObject({ HTTPS_PROXY: explicit, http_proxy: captured, CI: "1" });
  expect(cli.https_proxy).toBeUndefined();
  expect(cli.HTTP_PROXY).toBeUndefined();
  expect(cli.NO_PROXY?.split(",")).toEqual(expect.arrayContaining(["127.0.0.0/8", "fe80::/10", "*.direct.example", "captured.direct", "process.direct"]));
  expect(cli.no_proxy).toBe(cli.NO_PROXY);
  const withAll = { ...env, HTTPS_PROXY: undefined, all_proxy: explicit };
  expect(proxyFor("https://external.example", withAll, SYSTEM)).toBe(explicit);
  const allCLI = cliEnv(withAll, systemProxyEnv(SYSTEM));
  expect(allCLI.all_proxy).toBe(explicit);
  expect(allCLI.HTTPS_PROXY).toBeUndefined();
  expect(allCLI.https_proxy).toBeUndefined();
});

test("实际 fetch 把公网请求交给代理，环境里配置了代理时本地请求仍直连", async () => {
  const remote = Bun.serve({ hostname: "127.0.0.1", port: 0, fetch: () => new Response("direct") });
  const seen: string[] = [];
  const proxy = Bun.serve({ hostname: "127.0.0.1", port: 0, fetch: req => {
    seen.push(req.url);
    return new Response("proxy");
  } });
  const keys = ["HTTP_PROXY", "http_proxy", "NO_PROXY", "no_proxy", "TACIT_CLI_ENV"] as const;
  const saved = keys.map(key => process.env[key]);
  try {
    process.env.HTTP_PROXY = proxy.url.href;
    for (const key of keys.slice(1)) delete process.env[key];
    const external = "http://fetch-proxy.example.invalid/model";
    const init = { signal: AbortSignal.timeout(1_000) };
    expect(await (await proxiedFetch(new Request(external), init)).text()).toBe("proxy");
    expect(await (await proxiedFetch(remote.url, init)).text()).toBe("direct");
    expect(seen).toEqual([external]);
  } finally {
    for (const [i, key] of keys.entries()) {
      if (saved[i] === undefined) delete process.env[key]; else process.env[key] = saved[i];
    }
    await Promise.all([remote.stop(true), proxy.stop(true)]);
  }
});

test("short macOS IPv4 CIDR rules and unspecified local addresses bypass the proxy", () => {
  const env = { HTTP_PROXY: "http://proxy.example.invalid:8080" };
  const system = { exceptions: ["100.64/10", "198.18/15", "203.0.113/24", "11/8", "300.1/16", "192.0/33", "10/8"] };
  for (const host of ["100.127.255.255", "198.19.255.255", "203.0.113.4", "11.255.255.255", "10.2.3.4",
    "0.0.0.0", "0.4.5.6", "[::]", "[::ffff:100.64.3.4]"]) {
    expect(proxyFor(`http://${host}`, env, system), host).toBeUndefined();
  }
  for (const host of ["100.128.0.0", "198.20.0.0", "203.0.114.4", "12.0.0.0", "44.1.0.1", "192.0.1.2", "[::2]"]) {
    expect(proxyFor(`http://${host}`, env, system), host).toBe(env.HTTP_PROXY);
  }
});
