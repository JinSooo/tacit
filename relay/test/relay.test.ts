import { afterEach, describe, expect, test } from "bun:test";
import { startRelay } from "../src/bun.ts";
import { defaultLimits, randomID } from "../src/core.ts";

let relay: ReturnType<typeof startRelay> | undefined;
afterEach(() => { relay?.stop(true); relay = undefined; });

function start(options: Parameters<typeof startRelay>[0] = {}) {
  relay = startRelay({ port: 0, hostname: "127.0.0.1", ...options });
  return `http://127.0.0.1:${relay.server.port}`;
}
const auth = (token: string) => ({ Authorization: `Bearer ${token}` });
async function openSpace(base: string, body: object = {}) {
  const r = await fetch(`${base}/v1/spaces`, { method: "POST", body: JSON.stringify(body) });
  expect(r.status).toBe(201);
  return await r.json() as { space: string; token: string };
}

describe("中转信箱", () => {
  test("设备只能写自己的上行、读删自己的下行，中枢能取到并删除", async () => {
    const base = start();
    const { space, token } = await openSpace(base);
    const up = randomID(), down = randomID(), other = randomID();
    const s = `${base}/v1/spaces/${space}`;
    expect((await fetch(`${s}/boxes`, { method: "POST", headers: auth(token), body: JSON.stringify({ boxes: [up, down, other] }) })).status).toBe(200);
    const issued = await (await fetch(`${s}/tokens`, { method: "POST", headers: auth(token), body: JSON.stringify({ write: [up], read: [down] }) })).json() as { id: string; token: string };

    const msg = randomID();
    expect((await fetch(`${s}/boxes/${up}/messages/${msg}`, { method: "PUT", headers: auth(issued.token), body: "{\"v\":1}" })).status).toBe(201);
    // 同 id 再写不覆盖
    expect((await fetch(`${s}/boxes/${up}/messages/${msg}`, { method: "PUT", headers: auth(issued.token), body: "{\"v\":2}" })).status).toBe(200);
    expect((await fetch(`${s}/boxes/${other}/messages/${randomID()}`, { method: "PUT", headers: auth(issued.token), body: "x" })).status).toBe(403);
    expect((await fetch(`${s}/boxes/${up}/messages`, { headers: auth(issued.token) })).status).toBe(403);
    expect((await fetch(`${s}/boxes`, { method: "POST", headers: auth(issued.token), body: JSON.stringify({ boxes: [randomID()] }) })).status).toBe(403);

    const listed = await (await fetch(`${s}/boxes/${up}/messages`, { headers: auth(token) })).json() as { messages: { id: string; size: number }[]; next: string | null };
    expect(listed.messages.map(m => m.id)).toEqual([msg]);
    expect(listed.next).toBeNull();
    expect(await (await fetch(`${s}/boxes/${up}/messages/${msg}`, { headers: auth(token) })).text()).toBe("{\"v\":1}");
    expect((await fetch(`${s}/boxes/${up}/messages/${msg}`, { method: "DELETE", headers: auth(token) })).status).toBe(200);
    expect((await fetch(`${s}/boxes/${up}/messages/${msg}`, { headers: auth(token) })).status).toBe(404);

    // 吊销后设备令牌失效
    await fetch(`${s}/tokens/${issued.id}`, { method: "DELETE", headers: auth(token) });
    expect((await fetch(`${s}/boxes/${down}/messages`, { headers: auth(issued.token) })).status).toBe(401);
  });

  test("别的空间的令牌进不来", async () => {
    const base = start();
    const a = await openSpace(base), b = await openSpace(base);
    expect((await fetch(`${base}/v1/spaces/${a.space}/boxes`, { method: "POST", headers: auth(b.token), body: "{\"boxes\":[]}" })).status).toBe(401);
  });

  test("开通码、同一 IP 每天的开通次数", async () => {
    const base = start({ createCode: "letmein", limits: { ...defaultLimits, spaces_per_ip: 2 } });
    expect((await fetch(`${base}/v1/spaces`, { method: "POST", body: "{}" })).status).toBe(403);
    await openSpace(base, { code: "letmein" });
    await openSpace(base, { code: "letmein" });
    expect((await fetch(`${base}/v1/spaces`, { method: "POST", body: JSON.stringify({ code: "letmein" }) })).status).toBe(429);
  });

  test("单条消息、空间总量和每日请求的上限", async () => {
    const base = start({ limits: { ...defaultLimits, message_bytes: 10, space_bytes: 15, daily_requests: 8 } });
    const { space, token } = await openSpace(base);
    const s = `${base}/v1/spaces/${space}`, box = randomID();
    await fetch(`${s}/boxes`, { method: "POST", headers: auth(token), body: JSON.stringify({ boxes: [box] }) });
    expect((await fetch(`${s}/boxes/${box}/messages/${randomID()}`, { method: "PUT", headers: auth(token), body: "x".repeat(11) })).status).toBe(413);
    expect((await fetch(`${s}/boxes/${box}/messages/${randomID()}`, { method: "PUT", headers: auth(token), body: "x".repeat(10) })).status).toBe(201);
    expect((await fetch(`${s}/boxes/${box}/messages/${randomID()}`, { method: "PUT", headers: auth(token), body: "x".repeat(6) })).status).toBe(507);
    let last = 0;
    for (let i = 0; i < 5; i++) last = (await fetch(`${s}/boxes/${box}/messages`, { headers: auth(token) })).status;
    expect(last).toBe(429);
  });

  test("过期消息和长期没人用的空间会被清掉", async () => {
    let now = Date.parse("2026-11-01T00:00:00Z");
    const base = start({ now: () => now });
    const { space, token } = await openSpace(base);
    const s = `${base}/v1/spaces/${space}`, box = randomID(), msg = randomID();
    await fetch(`${s}/boxes`, { method: "POST", headers: auth(token), body: JSON.stringify({ boxes: [box] }) });
    await fetch(`${s}/boxes/${box}/messages/${msg}`, { method: "PUT", headers: auth(token), body: "hi" });
    now += 31 * 86_400_000;
    relay!.store.sweep();
    expect((await (await fetch(`${s}/boxes/${box}/messages`, { headers: auth(token) })).json() as { messages: unknown[] }).messages).toEqual([]);
    now += 91 * 86_400_000;
    relay!.store.sweep();
    expect((await fetch(`${s}/boxes/${box}/messages`, { headers: auth(token) })).status).toBe(401);
  });

  test("watch 在有新消息时通知中枢", async () => {
    const base = start();
    const { space, token } = await openSpace(base);
    const s = `${base}/v1/spaces/${space}`, box = randomID();
    await fetch(`${s}/boxes`, { method: "POST", headers: auth(token), body: JSON.stringify({ boxes: [box] }) });
    const ws = new WebSocket(`${s.replace("http", "ws")}/watch`, { headers: auth(token) } as never);
    await new Promise<void>((resolve, reject) => { ws.onopen = () => resolve(); ws.onerror = () => reject(new Error("watch 连不上")); });
    const note = new Promise<string>(resolve => { ws.onmessage = e => resolve(String(e.data)); });
    await fetch(`${s}/boxes/${box}/messages/${randomID()}`, { method: "PUT", headers: auth(token), body: "hi" });
    expect(JSON.parse(await note)).toEqual({ box });
    ws.close();
  });

  test("hello 返回实际限额", async () => {
    const base = start();
    expect(await (await fetch(`${base}/v1/hello`)).json()).toEqual({ tacit_relay: 1, limits: {
      space_bytes: defaultLimits.space_bytes, message_bytes: defaultLimits.message_bytes, retention_days: defaultLimits.retention_days,
    } });
  });
});
