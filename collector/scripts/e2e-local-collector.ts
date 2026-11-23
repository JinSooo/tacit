// 从仓库根目录运行：bun collector/scripts/e2e-local-collector.ts
import assert from "node:assert/strict";
import { randomBytes } from "node:crypto";
import { mkdtempSync, readFileSync, rmSync, statSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { readHub } from "../../hub/src/agent-cli/client.ts";
import { fileAgentSecrets, readAgentLink } from "../../hub/src/agent-cli/identity.ts";

const root = resolve(import.meta.dir, "../..");
const temp = mkdtempSync(join(tmpdir(), "tacit-local-collector-e2e-"));
const data = join(temp, "hub"), masterKey = join(temp, "test-master-key");
const env = { PATH: process.env.PATH, RA_DATA_DIR: data, RA_PORT: "0",
  RA_SECRET_BACKEND: "sealed-file", RA_MASTER_KEY_FILE: masterKey };

async function startOrigin(stream: ReadableStream<Uint8Array>) {
  const reader = stream.getReader();
  const timeout = setTimeout(() => void reader.cancel(), 10_000);
  let output = "";
  try {
    for (;;) {
      const { done, value } = await reader.read();
      if (done) throw new Error("临时中枢未启动");
      output += new TextDecoder().decode(value);
      const origin = output.match(/http:\/\/127\.0\.0\.1:\d+/)?.[0];
      if (origin) return origin;
    }
  } finally {
    clearTimeout(timeout);
    reader.releaseLock();
  }
}

let child: ReturnType<typeof Bun.spawn> | undefined;
try {
  writeFileSync(masterKey, randomBytes(32), { mode: 0o600 });
  const hub = Bun.spawn([process.execPath, "hub/src/cli.ts", "serve"], { cwd: root, env, stdout: "pipe", stderr: "inherit" });
  child = hub;
  const origin = await startOrigin(hub.stdout);
  const port = new URL(origin).port;
  const register = async (ingest: boolean) => {
    const swift = Bun.spawn(["swift", "test", "--filter", "localCollectorLiveHubProbe"], {
      cwd: join(root, "collector"),
      env: { ...process.env, TACIT_E2E_COLLECTOR_DIR: data, TACIT_E2E_COLLECTOR_PORT: port,
        TACIT_E2E_COLLECTOR_INGEST: ingest ? "1" : "0" },
      stdout: "pipe", stderr: "pipe", timeout: 120_000,
    });
    const [stdout, stderr, code] = await Promise.all([new Response(swift.stdout).text(), new Response(swift.stderr).text(), swift.exited]);
    assert.equal(code, 0, stdout + stderr);
    assert.match(stdout, /localCollectorLiveHubProbe\(\) passed/);
    for (const file of ["collector-link.json", "agent-link.json"]) {
      assert.equal(statSync(join(data, file)).mode & 0o777, 0o600);
    }
    const collector = JSON.parse(readFileSync(join(data, "collector-link.json"), "utf8"));
    assert.deepEqual(collector.addrs, [origin]);
    assert.equal(collector.mode, "local");
    assert.equal(collector.relay, null);
    const agent = await readAgentLink(data, AbortSignal.timeout(5_000));
    assert.ok(agent);
    assert.equal(agent.address, origin);
    const sent = stdout.split("\n").find(line => line.startsWith("Swift ingest "));
    if (ingest) assert.ok(sent);
    return { collector, agent, sent };
  };

  const first = await register(false);
  console.log(`Swift local-bootstrap wrote 0600 links: ${first.collector.device_id}, ${first.agent.device_id}`);
  // 模拟两份配置之间进程退出。保留 Agent 文件和两把临时私钥。
  rmSync(join(data, "collector-link.json"));
  const second = await register(true);
  assert.deepEqual(second.collector, first.collector);
  assert.deepEqual(second.agent, first.agent);
  console.log(`Swift local-bootstrap retry reused both IDs: ${second.collector.device_id}, ${second.agent.device_id}`);
  console.log(second.sent);

  const token = readFileSync(join(data, "token"), "utf8").trim();
  const get = (path: string) => fetch(origin + path, { headers: { Authorization: "Bearer " + token } });
  const response = await get("/v1/records?device=mac");
  assert.equal(response.status, 200);
  const { records } = await response.json() as { records: { id: string; device: string }[] };
  assert.equal(records.length, 6);
  assert.ok(records.every(row => row.device === second.collector.device_id));
  console.log(`Hub /v1/records?device=mac: ${records.length} stored rows, all device=${second.collector.device_id}`);

  const result = await readHub("search", new URLSearchParams({ tool: "codex", q: "虚构风速计样本" }),
    AbortSignal.timeout(5_000), undefined, { env: { ...env, RA_PORT: port }, secrets: fileAgentSecrets(data) }) as {
      records: { id: string }[];
    };
  assert.ok(result.records.some(row => records.some(stored => stored.id === row.id)));
  const audit = await get("/v1/audit");
  assert.equal(audit.status, 200);
  assert.ok((await audit.text()).includes(second.agent.device_id));
  console.log(`agent-cli agent.search: ${result.records.length} matches, audited as ${second.agent.device_id}`);
} finally {
  if (child && child.exitCode === null) {
    child.kill("SIGTERM");
    await child.exited;
  }
  rmSync(temp, { recursive: true, force: true });
}
