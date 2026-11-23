// Run from the repo root: bun hub/test/local-agent-e2e.ts
import assert from "node:assert/strict";
import { randomBytes } from "node:crypto";
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { ulid } from "../../packages/record/index.ts";
import { atomicWrite, deviceAccount, fileAgentSecrets, type AgentLink } from "../src/agent-cli/identity.ts";
import { loadConfig } from "../src/config.ts";
import { HubDB } from "../src/db.ts";
import { DeviceClient } from "../src/devices/client.ts";
import { identityFromRaw, suite } from "../src/devices/envelope.ts";
import { DistillStore } from "../src/distill/store.ts";
import { fixture } from "./helpers.ts";

const tmp = mkdtempSync(join(tmpdir(), "tacit-local-agent-e2e-"));
const dataDir = join(tmp, "hub"), masterKey = join(tmp, "test-master-key"), cwd = join(tmp, "maple-ledger");
const env = { PATH: process.env.PATH, RA_DATA_DIR: dataDir, RA_PORT: "0",
  RA_SECRET_BACKEND: "sealed-file", RA_MASTER_KEY_FILE: masterKey };
const cli = [process.execPath, "hub/src/cli.ts"];
let hub: ReturnType<typeof startHub> | undefined;
function startHub() {
  return Bun.spawn([...cli, "serve"], { env, stdout: "pipe", stderr: "inherit" });
}

async function runningOrigin(child: ReturnType<typeof startHub>) {
  const reader = child.stdout.getReader();
  let output = "";
  try {
    for (;;) {
      const { done, value } = await reader.read();
      if (done) throw new Error("中枢子进程未启动");
      output += new TextDecoder().decode(value);
      const origin = output.match(/http:\/\/127\.0\.0\.1:\d+/)?.[0];
      if (origin) return origin;
    }
  } finally { reader.releaseLock(); }
}

async function sessionStart(origin: string) {
  // Explicitly inject a temporary file store so this macOS test never opens the real Keychain.
  const script = `
    import { runAgentCommand } from "./hub/src/agent-cli/index.ts";
    import { fileAgentSecrets } from "./hub/src/agent-cli/identity.ts";
    await runAgentCommand(["hook", "session-start", "--tool", "codex"], { secrets: fileAgentSecrets(process.env.RA_DATA_DIR) });`;
  const start = performance.now();
  const child = Bun.spawn([process.execPath, "-e", script], {
    env: { ...env, RA_PORT: new URL(origin).port },
    stdin: Buffer.from(JSON.stringify({ cwd, source: "startup", session_id: "synthetic-session" })),
    stdout: "pipe", stderr: "pipe", timeout: 3000,
  });
  const [stdout, stderr, exit] = await Promise.all([
    new Response(child.stdout).text(), new Response(child.stderr).text(), child.exited,
  ]);
  assert.equal(exit, 0);
  assert.equal(stderr, "");
  const ms = Math.round(performance.now() - start);
  return { text: JSON.parse(stdout).hookSpecificOutput.additionalContext as string, ms };
}

try {
  writeFileSync(masterKey, randomBytes(32), { mode: 0o600 });
  mkdirSync(cwd, { mode: 0o700 });
  hub = startHub();
  const origin = await runningOrigin(hub);
  const config = loadConfig(env);
  const agentHex = randomBytes(32).toString("hex");
  const agent = await identityFromRaw(agentHex), mac = await identityFromRaw(randomBytes(32).toString("hex"));
  const admin = (path: string, body: object) => fetch(origin + path, {
    method: "POST", headers: { Authorization: "Bearer " + config.token, "Content-Type": "application/json" },
    body: JSON.stringify(body),
  });
  const bootstrap = async () => {
    const response = await admin("/v1/settings/devices/local-bootstrap", {
      agent_pk: agent.publicKey.toString("base64url"), mac_pk: mac.publicKey.toString("base64url"),
    });
    assert.equal(response.status, 200);
    return await response.json() as { mac_device_id: string; agent_device_id: string; endpoint: string; hub_id: string; hub_pk: string };
  };
  const first = await bootstrap();
  assert.deepEqual(await bootstrap(), first);
  assert.equal(first.endpoint, origin + "/v1/device");
  console.log(`local-bootstrap ×2：200，ID 相同（${first.mac_device_id}、${first.agent_device_id}）`);
  await fileAgentSecrets(dataDir).create(deviceAccount, agentHex, AbortSignal.timeout(1000));
  const link: AgentLink = { hub_id: first.hub_id, hub_pk: first.hub_pk, device_id: first.agent_device_id, address: origin };
  await atomicWrite(join(dataDir, "agent-link.json"), JSON.stringify(link));

  const row = fixture({ source: "manual.note", title: "枫叶账本虚构记录", body: "第一轮对账采用合成数据" });
  const seeded = await admin("/v1/ingest", { device: row.device, records: [row] });
  assert.equal(seeded.status, 200);
  assert.equal((await seeded.json() as { accepted: number }).accepted, 1);
  const db = new HubDB(join(dataDir, "history.db"), config.dbKey);
  try {
    const store = new DistillStore(db), projectId = ulid();
    store.upsertProject({ id: projectId, name: "枫叶账本", keys: { repos: [cwd], hosts: [], chats: [] } });
    store.upsertThread({ id: ulid(), project_id: projectId, domain: "work", status: "active", title: "对账", brief: "第一轮合成对账已完成" });
  } finally { db.close(); }

  const client = new DeviceClient(await suite.kem.deserializePublicKey(Buffer.from(link.hub_pk, "base64url")), agent.keys, origin);
  client.device = link.device_id;
  const found = await client.send<{ records: { id: string; title: string }[] }>("agent.search", { tool: "codex", q: "虚构记录" });
  assert.equal(found.status, 200);
  assert.equal(found.body.records[0]?.id, row.id);
  console.log(`HTTP/HPKE agent.search：200，命中「${found.body.records[0]!.title}」`);
  const denied = await client.send("delete", { ids: [row.id] });
  assert.deepEqual(denied, { status: 403, body: { error: "当前设备权限不足" } });
  console.log("HTTP/HPKE delete：403 当前设备权限不足");

  const online = await sessionStart(origin);
  assert.ok(online.text.includes("第一轮合成对账已完成"));
  assert.ok(!online.text.includes("离线缓存"));
  hub.kill("SIGTERM");
  assert.equal(await hub.exited, 0);
  const offline = await sessionStart(origin);
  assert.ok(offline.ms < 2000);
  assert.match(offline.text, /^（离线缓存，同步于 \d{4}-\d{2}-\d{2} \d{2}:\d{2}）/);
  assert.ok(offline.text.endsWith(online.text));
  console.log(`停止 Hub 后 SessionStart：${offline.ms} ms，${offline.text.split("\n")[0]} 第一轮合成对账已完成`);
} finally {
  if (hub && hub.exitCode === null) {
    hub.kill("SIGTERM");
    await hub.exited;
  }
  rmSync(tmp, { recursive: true, force: true });
}
