import { expect, test } from "bun:test";
import { randomBytes } from "node:crypto";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { loadConfig } from "../src/config.ts";
import { HubDB } from "../src/db.ts";
import { DeviceClient } from "../src/devices/client.ts";
import { identityFromRaw, suite } from "../src/devices/envelope.ts";
import { jsonLines } from "../src/jsonl.ts";
import { fixture, networkDenied } from "./helpers.ts";

const bindDenied = await networkDenied();

async function runningOrigin(child: Bun.Subprocess<"ignore", "pipe", "inherit">) {
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
  } finally {
    reader.releaseLock();
  }
}

interface HostBridgeOptions {
  dataDir: string;
  pluginScript: string;
  deviceId: string;
  client: DeviceClient;
  stateFile: string;
  failOnBatch?: number;
  onBeforeReply?: (batchNumber: number) => void;
}

async function runPluginThroughDeviceProxy(options: HostBridgeOptions) {
  const child = Bun.spawn(
    [
      process.execPath, "hub/src/cli.ts", "run-plugin", "ext-synthetic",
      "--transport", "stdio", "--device", options.deviceId,
      "--", process.execPath, options.pluginScript,
    ],
    {
      env: { PATH: process.env.PATH, RA_DATA_DIR: options.dataDir },
      stdin: "pipe",
      stdout: "pipe",
      stderr: "pipe",
    },
  );
  let batchNumber = 0;
  let lastSummaryLine = "";
  for await (const line of jsonLines(child.stdout)) {
    if (!line.trim()) continue;
    let parsed: Record<string, unknown> | null = null;
    try { parsed = JSON.parse(line) as Record<string, unknown>; } catch {}
    if (parsed?.type === "ingest" && typeof parsed.id === "number" && Array.isArray(parsed.records)) {
      batchNumber++;
      options.onBeforeReply?.(batchNumber);
      if (options.failOnBatch === batchNumber) {
        child.stdin.write(JSON.stringify({
          type: "ingest_result", id: parsed.id, ok: false, status: 502, error: "simulated_failure",
        }) + "\n");
        continue;
      }
      const stamped = (parsed.records as Record<string, unknown>[]).map(r => ({ ...r, device: options.deviceId }));
      const reply = await options.client.send("ingest", { records: stamped });
      if (reply.status === 200) {
        child.stdin.write(JSON.stringify({
          type: "ingest_result", id: parsed.id, ok: true, status: 200, result: reply.body,
        }) + "\n");
      } else {
        child.stdin.write(JSON.stringify({
          type: "ingest_result", id: parsed.id, ok: false, status: reply.status, error: "hub_error",
        }) + "\n");
      }
    } else {
      lastSummaryLine = line;
    }
  }
  child.stdin.end();
  const [exitCode, stderr] = await Promise.all([child.exited, new Response(child.stderr).text()]);
  return {
    exitCode,
    stderr,
    batchNumber,
    summary: lastSummaryLine ? JSON.parse(lastSummaryLine) as Record<string, unknown> : null,
  };
}

test.skipIf(bindDenied)("端到端：外部插件走 stdio 经真实 DeviceClient+HPKE 上传至 sealed-file 真实中枢，验证回执落盘与中途失败恢复", async () => {
  const tmp = mkdtempSync(join(tmpdir(), "tacit-plugin-stdio-e2e-"));
  const dataDir = join(tmp, "hub");
  const masterKey = join(tmp, "master-key");
  const pluginDataDir = join(tmp, "collector-data");
  mkdirSync(join(pluginDataDir, "buffer"), { recursive: true, mode: 0o700 });
  writeFileSync(masterKey, randomBytes(32), { mode: 0o600 });

  const env = {
    PATH: process.env.PATH,
    RA_DATA_DIR: dataDir,
    RA_PORT: "0",
    RA_SECRET_BACKEND: "sealed-file",
    RA_MASTER_KEY_FILE: masterKey,
  };
  const hub = Bun.spawn([process.execPath, "hub/src/cli.ts", "serve"], {
    env,
    stdout: "pipe",
    stderr: "inherit",
  });

  try {
    const origin = await runningOrigin(hub);
    const config = loadConfig(env);
    const mac = await identityFromRaw(randomBytes(32).toString("hex"));
    const agent = await identityFromRaw(randomBytes(32).toString("hex"));
    const reg = await fetch(`${origin}/v1/settings/devices/local-bootstrap`, {
      method: "POST",
      headers: { authorization: `Bearer ${config.token}`, "content-type": "application/json" },
      body: JSON.stringify({
        mac_pk: mac.publicKey.toString("base64url"),
        agent_pk: agent.publicKey.toString("base64url"),
      }),
    });
    expect(reg.status).toBe(200);
    const { mac_device_id: macId, hub_pk: hubPk } = await reg.json() as { mac_device_id: string; hub_pk: string };
    expect(macId.startsWith("mac-")).toBe(true);

    const client = new DeviceClient(await suite.kem.deserializePublicKey(Buffer.from(hubPk, "base64url")), mac.keys, origin);
    client.device = macId;

    // 合成插件：输出 201 条 plugin.ext_synthetic 记录（触发 200 + 1 两批）+ checkpoint + release 缓冲文件。
    // 注意：pluginDataDir 中完全没有 token 文件，验证插件子进程不接触管理令牌。
    const releaseFile = join(pluginDataDir, "buffer", "ext-synthetic.pending.jsonl");
    writeFileSync(releaseFile, "合成缓冲记录\n");
    const records = Array.from({ length: 201 }, (_, i) => fixture({
      device: macId,
      source: "plugin.ext_synthetic",
      source_ref: `syn-${i}`,
      title: `合成插件条目 ${i}`,
      body: `合成内容编号 ${i}`,
    }));
    const pluginScript = join(tmp, "synthetic-plugin.ts");
    writeFileSync(pluginScript, `
const records = ${JSON.stringify(records)};
const args = process.argv.slice(2);
const device = args[args.indexOf("--device") + 1];
if (!device || !device.startsWith("mac-")) process.exit(11);
for (const r of records) {
  console.log(JSON.stringify({ type: "record", record: { ...r, device } }));
}
console.log(JSON.stringify({
  type: "checkpoint",
  state: { cursor: 201 },
  release: [${JSON.stringify(releaseFile)}],
}));
`);
    const stateFile = join(pluginDataDir, "plugins/ext-synthetic/state.json");

    // 1. 模拟第 2 批中途失败：第 1 批（200 条）已入库，但 state.json 不能前进，release 不能删除。
    let stateExistedBeforeReply = false;
    const failedRun = await runPluginThroughDeviceProxy({
      dataDir: pluginDataDir,
      pluginScript,
      deviceId: macId,
      client,
      stateFile,
      failOnBatch: 2,
      onBeforeReply: () => {
        if (existsSync(stateFile)) stateExistedBeforeReply = true;
      },
    });
    expect(stateExistedBeforeReply).toBe(false);
    expect(failedRun.exitCode).toBe(1);
    expect(failedRun.batchNumber).toBe(2);
    expect(failedRun.summary).toMatchObject({ accepted: 200, rejected: 1, stateWritten: false, released: 0 });
    expect(existsSync(stateFile)).toBe(false);
    expect(existsSync(releaseFile)).toBe(true);

    // 2. 重跑全部通过：前 200 条幂等去重、第 201 条入库；回执后才落盘 state.json 并清理 release。
    let stateExistedBeforeSecondReply = false;
    const okRun = await runPluginThroughDeviceProxy({
      dataDir: pluginDataDir,
      pluginScript,
      deviceId: macId,
      client,
      stateFile,
      onBeforeReply: () => {
        if (existsSync(stateFile)) stateExistedBeforeSecondReply = true;
      },
    });
    expect(stateExistedBeforeSecondReply).toBe(false);
    expect(okRun.exitCode).toBe(0);
    expect(okRun.batchNumber).toBe(2);
    expect(okRun.summary).toMatchObject({
      accepted: 1, duplicates: 200, rejected: 0, stateWritten: true, released: 1, releaseErrors: 0,
    });
    expect(JSON.parse(readFileSync(stateFile, "utf8"))).toEqual({ cursor: 201 });
    expect(existsSync(releaseFile)).toBe(false);

    // 3. 检查真实中枢数据库：201 条全部入库，device 均为 mac-<id>，source 均为 plugin.ext_synthetic。
    const db = new HubDB(join(dataDir, "history.db"), config.dbKey);
    try {
      const row = db.db.prepare(
        "SELECT COUNT(*) AS n FROM records WHERE device=? AND source='plugin.ext_synthetic'",
      ).get(macId) as { n: number };
      expect(row.n).toBe(201);
    } finally {
      db.close();
    }
  } finally {
    if (hub.exitCode === null) {
      hub.kill("SIGTERM");
      await hub.exited;
    }
    rmSync(tmp, { recursive: true, force: true });
  }
}, 20_000);
