// Run from the repo root: bun hub/test/device-roles-e2e.ts
import assert from "node:assert/strict";
import { randomBytes } from "node:crypto";
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import type { PairingRole } from "../src/devices/permissions.ts";
import { decodePairing, DeviceClient } from "../src/devices/client.ts";
import { HubDB } from "../src/db.ts";
import { loadConfig } from "../src/config.ts";
import { DistillStore } from "../src/distill/store.ts";
import { localDateString } from "../src/distill/requests.ts";
import { identityFromRaw, suite } from "../src/devices/envelope.ts";
import type { ProjectionPage } from "../src/devices/projection.ts";
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

  const remoteAdmin = await pair("admin", "mac");
  const [macKey, agentKey] = await Promise.all(
    [1, 2].map(() => identityFromRaw(randomBytes(32).toString("hex"))),
  );
  const registration = await adminHTTP("/v1/settings/devices/local-bootstrap", "POST", {
    mac_pk: macKey!.publicKey.toString("base64url"), agent_pk: agentKey!.publicKey.toString("base64url"),
  });
  assert.equal(registration.status, 200);
  const link = await registration.json() as { hub_pk: string; mac_device_id: string };
  const hubKey = await suite.kem.deserializePublicKey(Buffer.from(link.hub_pk, "base64url"));
  const local = new DeviceClient(hubKey, macKey!.keys, origin);
  local.device = link.mac_device_id;

  const recorded = Date.now() - 86_400_000;
  const date = localDateString(recorded), at = new Date(recorded).toISOString();
  const members = Array.from({ length: 300 }, () => fixture({ device: local.device!, source: "manual.note", t_start: at }));
  const args = { date, id: members[0]!.id };
  const record_ids = members.map(r => r.id);
  // Seed only the encrypted fixture database with the kind of day saved by distillation.
  const db = new HubDB(join(dataDir, "history.db"), loadConfig(env).dbKey);
  try {
    assert.equal(db.ingest(members).accepted, 300);
    new DistillStore(db).upsertDay({ date, detail: { items: [{
      id: args.id, title: "虚构苗圃", description: "先检查苗床。", t_start: at, t_end: at,
      active_seconds: 0, sources: ["manual.note"], apps: [], project_id: null, record_ids,
      evidence: [{ id: args.id, at, source: "manual.note", title: "检查苗床" }],
    }] } });
  } finally { db.close(); }

  const description = "更正为先检查河边苗床。";
  assert.equal((await local.send("segment.correct", { ...args, description })).status, 200);
  async function pullDay(from?: ProjectionPage) {
    let next = from;
    let day: ProjectionPage["changes"][number] | undefined;
    for (let page = 0; page < 20; page++) {
      const result = await local.send<ProjectionPage>("projection.pull",
        next ? { epoch: next.epoch, cursor: next.cursor, limit: 200 } : { cursor: 0, limit: 200 });
      assert.equal(result.status, 200);
      assert.equal(result.body.reset, false);
      day = result.body.changes.find(change => change.kind === "day" && change.id === date) ?? day;
      next = result.body;
      if (!next.more) {
        assert.ok(day, "投影没有返回合成日期");
        return { next, day };
      }
    }
    throw new Error("合成日期的投影没有读完");
  }
  const pull = await pullDay();
  assert.ok(JSON.stringify(pull.day).includes(description));
  console.log(`本机 admin segment.correct：200，projection.pull 200，描述=「${description}」`);

  const deniedDelete = await remoteAdmin.send("segment.delete", { ...args, record_ids });
  assert.deepEqual(deniedDelete, { status: 429, body: { error: limitError } });
  console.log(`远程 admin segment.delete（300 条）：${deniedDelete.status} ${limitError}`);
  const localDelete = await local.send("segment.delete", { ...args, record_ids });
  assert.deepEqual(localDelete, { status: 200, body: { deleted: 300 } });
  const deleted = await local.send<{ missing: string[] }>("records.get", { ids: [record_ids[0], record_ids.at(-1)] });
  assert.deepEqual(deleted.body.missing, [record_ids[0], record_ids.at(-1)]);
  const withdrawn = await pullDay(pull.next);
  assert.ok(!JSON.stringify(withdrawn.day).includes(description));
  console.log(`本机 admin segment.delete（同一段）：${localDelete.status} deleted=300，原文已删、旧投影已撤下`);

  const settingsDenied = await viewer.send("settings.models.put", { tiers: {} });
  assert.deepEqual(settingsDenied, { status: 403, body: { error: "当前设备权限不足" } });
  console.log("view settings.models.put：403 当前设备权限不足");
} finally {
  if (child && child.exitCode === null) {
    child.kill("SIGTERM");
    await child.exited;
  }
  rmSync(tmp, { recursive: true, force: true });
}
