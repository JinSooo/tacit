// Run from the repo root: bun hub/test/device-roles-e2e.ts
import assert from "node:assert/strict";
import { randomBytes } from "node:crypto";
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import type { PairingRole } from "../src/devices/permissions.ts";
import { decodePairing, DeviceClient } from "../src/devices/client.ts";
import { fixture } from "./helpers.ts";

const tmp = mkdtempSync(join(tmpdir(), "tacit-device-roles-"));
const dataDir = join(tmp, "hub");
const masterKey = join(tmp, "test-master-key");
const env = {
  PATH: process.env.PATH, RA_DATA_DIR: dataDir, RA_PORT: "0",
  RA_SECRET_BACKEND: "sealed-file", RA_MASTER_KEY_FILE: masterKey,
};
const cli = [process.execPath, "hub/src/cli.ts"];
let child: ReturnType<typeof startHub> | undefined;
function startHub() {
  return Bun.spawn([...cli, "serve"], { env, stdout: "pipe", stderr: "inherit" });
}

async function originOf(hub: ReturnType<typeof startHub>) {
  const reader = hub.stdout.getReader();
  let output = "";
  try {
    for (;;) {
      const { done, value } = await reader.read();
      if (done) throw new Error("Hub 子进程未启动");
      output += new TextDecoder().decode(value);
      const origin = output.match(/http:\/\/127\.0\.0\.1:\d+/)?.[0];
      if (origin) return origin;
    }
  } finally { reader.releaseLock(); }
}

try {
  writeFileSync(masterKey, randomBytes(32), { mode: 0o600 });
  const probe = Bun.serve({ hostname: "127.0.0.1", port: 0, fetch: () => new Response() });
  const lan = probe.url.origin;
  const lanPort = probe.port!;
  await probe.stop(true);
  mkdirSync(dataDir, { mode: 0o700 });
  writeFileSync(join(dataDir, "hub.json"), JSON.stringify({ lan_port: lanPort }));
  child = startHub();
  let origin = await originOf(child);
  const token = (await Bun.file(join(dataDir, "token")).text()).trim();
  const adminHTTP = (path: string, method = "GET", body?: object) => fetch(origin + path, {
    method, headers: { Authorization: "Bearer " + token, "Content-Type": "application/json" },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  async function pair(role: PairingRole, platform: "android" | "mac") {
    const response = await adminHTTP("/v1/settings/devices/pairing", "POST", { role });
    assert.equal(response.status, 200);
    const invite = decodePairing((await response.json() as { uri: string }).uri);
    assert.equal(invite.role, role);
    const client = await DeviceClient.fromInvite(invite, lan);
    assert.equal((await client.pair(invite, platform)).status, 200);
    return client;
  }
  const phone = await pair("collect", "android"), admin = await pair("admin", "mac");
  console.log("真 HTTP/HPKE 配对：collect（Android）200，admin（Mac）200");
  const denied = await phone.send("projection.pull", { cursor: 0 });
  assert.deepEqual(denied, { status: 403, body: { error: "当前设备权限不足" } });
  console.log("collect projection.pull：403 当前设备权限不足");

  const rows = Array.from({ length: 201 }, () => fixture({ device: phone.device!, source: "manual.note" }));
  for (const records of [rows.slice(0, 200), rows.slice(200)]) {
    const ingest = await phone.send("ingest", { records });
    assert.equal(ingest.status, 200);
    assert.equal(ingest.body.accepted, records.length);
  }
  const remove = (items: typeof rows) => admin.send("delete", { ids: items.map(row => row.id) });
  for (const items of [rows.slice(0, 100), rows.slice(100, 200)]) {
    const result = await remove(items);
    assert.deepEqual(result, { status: 200, body: { deleted: 100 } });
  }
  child.kill("SIGTERM");
  assert.equal(await child.exited, 0);
  child = startHub();
  origin = await originOf(child);
  const limited = await remove(rows.slice(200));
  const limitError = "远程删除达到安全上限，请在中枢本机执行或稍后再试";
  assert.deepEqual(limited, { status: 429, body: { error: limitError } });
  const remaining = await admin.send<{ records: { id: string }[] }>("records.get", { ids: [rows[200]!.id] });
  assert.equal(remaining.status, 200);
  assert.equal(remaining.body.records[0]?.id, rows[200]!.id);
  console.log(`admin 跨设备删除：100 + 100 条成功，重启后第 201 条 429 ${limitError}`);

  const changeRole = (target: DeviceClient, role: PairingRole) => admin.send("devices.role.update", { id: target.device, role });
  const protectedAdmin = await changeRole(admin, "collect");
  assert.deepEqual(protectedAdmin, { status: 409, body: { error: "不能移除最后一台管理设备" } });
  console.log("远程降级最后一台 admin：409 不能移除最后一台管理设备");

  const viewer = await pair("view", "mac");
  const before = await viewer.send("projection.pull", { cursor: 0 });
  assert.equal(before.status, 200);
  assert.equal((await changeRole(viewer, "collect")).status, 200);
  const reset = await viewer.send("projection.pull", { cursor: before.body.cursor, epoch: before.body.epoch });
  assert.equal(reset.status, 200);
  assert.equal(reset.body.kind, "projection.reset");
  assert.equal(reset.body.reset, true);
  assert.deepEqual(reset.body.changes, []);
  assert.equal((await viewer.send("records.list", {})).status, 403);
  console.log("view 降为 collect：收到加密 projection.reset，changes=[]，原文读取 403");

  const run = (...args: string[]) => Bun.spawnSync([...cli, "devices", ...args], { env });
  const list = run("list");
  assert.equal(list.exitCode, 0);
  assert.ok(JSON.parse(list.stdout.toString()).some((device: { role: string }) => device.role === "admin"));
  assert.equal(run("set-role", viewer.device!, "view").exitCode, 0);
  assert.equal((await viewer.send("projection.pull", { cursor: 0 })).body.reset, false);
  assert.equal(run("remove", admin.device!).exitCode, 1);
  assert.equal(run("remove", admin.device!, "--force").exitCode, 0);
  console.log("本机 CLI：list、set-role 成功，移除最后一台 admin 仅 --force 成功");
} finally {
  if (child && child.exitCode === null) {
    child.kill("SIGTERM");
    await child.exited;
  }
  rmSync(tmp, { recursive: true, force: true });
}
