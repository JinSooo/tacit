import { chmodSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { randomBytes } from "node:crypto";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { loadConfig } from "../../hub/src/config.ts";
import { HubDB } from "../../hub/src/db.ts";
import { DistillStore } from "../../hub/src/distill/store.ts";
import { localDateString } from "../../hub/src/distill/requests.ts";
import { ulid } from "../../packages/record/index.ts";

const repoRoot = resolve(import.meta.dir, "../..");
const workDir = mkdtempSync(join(tmpdir(), "tacit-projection-e2e-"));
const dataDir = join(workDir, "data");
const masterKeyFile = join(workDir, "master.key");

async function freePort(): Promise<number> {
  const probe = Bun.serve({ hostname: "127.0.0.1", port: 0, fetch: () => new Response() });
  const port = probe.port!;
  await probe.stop(true);
  return port;
}

async function waitForHealth(origin: string, timeoutMs = 15_000): Promise<void> {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    try {
      const res = await fetch(`${origin}/v1/health`);
      if (res.ok) return;
    } catch { /* 启动中 */ }
    await Bun.sleep(100);
  }
  throw new Error(`等待中枢启动超时：${origin}`);
}

let hubProcess: ReturnType<typeof Bun.spawn> | undefined;

try {
  mkdirSync(dataDir, { recursive: true, mode: 0o700 });
  // 根密钥文件放在数据目录之外，使用 sealed-file 后端，完全不触碰系统钥匙串。
  writeFileSync(masterKeyFile, randomBytes(32).toString("hex") + "\n", { mode: 0o400 });
  chmodSync(masterKeyFile, 0o400);

  const httpPort = await freePort();
  const lanPort = await freePort();
  writeFileSync(join(dataDir, "hub.json"), JSON.stringify({ port: httpPort, lan_port: lanPort }, null, 2) + "\n", { mode: 0o600 });

  const hubEnv: Record<string, string> = {
    ...Object.fromEntries(Object.entries(process.env).filter((entry): entry is [string, string] => typeof entry[1] === "string")),
    RA_DATA_DIR: dataDir,
    RA_PORT: String(httpPort),
    RA_SECRET_BACKEND: "sealed-file",
    RA_MASTER_KEY_FILE: masterKeyFile,
  };

  // 1. 先初始化并写入合成数据（全部使用虚构内容）。
  const config = loadConfig(hubEnv);
  const db = new HubDB(join(config.dataDir, "history.db"), config.dbKey);
  const nowMs = Date.now();
  const today = localDateString(nowMs);
  const yesterday = localDateString(nowMs - 86_400_000);
  const tKeep = new Date(nowMs - 10 * 60_000).toISOString();
  const tDelete = new Date(nowMs - 5 * 60_000).toISOString();
  const tYesterday = new Date(nowMs - 86_400_000).toISOString();

  const recKeep = {
    schema: 1,
    id: ulid(),
    device: "mac",
    source: "manual.note",
    kind: "event",
    t_start: tKeep,
    title: "风速仪固件核对",
    body: "完成北塔风速仪采样率校准，连续 10 分钟读数稳定。",
    capture: { method: "ax" },
    sensitivity: "normal",
  };
  const recToDelete = {
    schema: 1,
    id: ulid(),
    device: "mac",
    source: "manual.note",
    kind: "event",
    t_start: tDelete,
    title: "气压计临时日志",
    body: "这是一条将在 E2E 中被删除的合成记录。",
    capture: { method: "ax" },
    sensitivity: "normal",
  };
  const recYesterday = {
    schema: 1,
    id: ulid(),
    device: "mac",
    source: "manual.note",
    kind: "event",
    t_start: tYesterday,
    title: "蓄电池巡检",
    body: "检查南坡太阳能供电电压，记录为 24.3V。",
    capture: { method: "ax" },
    sensitivity: "normal",
  };

  const ingested = db.ingest([recKeep, recToDelete, recYesterday]);
  if (ingested.accepted !== 3) {
    throw new Error(`合成记录入库失败：${JSON.stringify(ingested)}`);
  }

  const store = new DistillStore(db);
  store.upsertProject({
    id: "proj-starport",
    name: "星港气象站",
    confirmed: 1,
    keys: { repos: ["/Users/demo/starport-weather"], hosts: [], chats: [] },
    brief: "维护星港自动气象站传感器与供电巡检。",
    detail: { goal: "保障全年连续采集", status: "北塔风速仪已校准", people: ["林工"] },
    salience: 0.9,
    last_ms: nowMs,
    needs_regen: 0,
    updated_at: tDelete,
  });

  const addThread = (id: string, title: string, brief: string, rec: typeof recKeep, atMs: number) => {
    store.upsertThread({
      id,
      project_id: "proj-starport",
      status: "active",
      domain: "work",
      title,
      brief,
      detail: { goal: title, progress: brief, artifacts: { files: [], urls: [], commands: [], people: [] }, quotes: [{ record_id: rec.id, text: rec.body }] },
      first_ms: atMs,
      last_ms: atMs,
      active_minutes: 12,
      sessions: 1,
      needs_regen: 0,
      updated_at: new Date(atMs).toISOString(),
    });
    const frameId = `frame-${id}`;
    store.createFrame({
      id: frameId,
      key: frameId,
      t_start_ms: atMs,
      t_end_ms: atMs,
      record_ids: [rec.id],
      chars: rec.body.length,
      private: 0,
      status: "new",
    });
    store.assign(frameId, id, "rule", 1);
  };

  addThread("th-anemometer", "校准北塔风速仪", "完成采样率核对，读数稳定", recKeep, nowMs - 10 * 60_000);
  addThread("th-barometer", "排查临时气压计日志", "待清理的合成排查事项", recToDelete, nowMs - 5 * 60_000);

  store.upsertDay({
    date: today,
    brief: "校准星港气象站北塔风速仪并记录临时气压计日志。",
    detail: {
      summary: "校准星港气象站北塔风速仪并记录临时气压计日志。",
      cutoff: tDelete,
      record_ids: [recKeep.id, recToDelete.id],
      omitted_record_ids: [],
      items: [
        {
          id: "seg-keep",
          title: "校准北塔风速仪",
          description: "完成采样率校准且读数稳定。",
          t_start: tKeep,
          t_end: tKeep,
          active_seconds: 600,
          sources: ["manual.note"],
          record_ids: [recKeep.id],
          project_id: "proj-starport",
          evidence: [{ id: recKeep.id, at: tKeep, source: "manual.note", title: recKeep.title }],
        },
        {
          id: "seg-delete",
          title: "记录临时气压计日志",
          description: "记录待删除的气压计条目。",
          t_start: tDelete,
          t_end: tDelete,
          active_seconds: 300,
          sources: ["manual.note"],
          record_ids: [recToDelete.id],
          project_id: "proj-starport",
          evidence: [{ id: recToDelete.id, at: tDelete, source: "manual.note", title: recToDelete.title }],
        },
      ],
    },
    needs_regen: 0,
    updated_at: tDelete,
  });

  store.upsertDay({
    date: yesterday,
    brief: "完成南坡蓄电池巡检。",
    detail: {
      summary: "完成南坡蓄电池巡检。",
      cutoff: tYesterday,
      record_ids: [recYesterday.id],
      omitted_record_ids: [],
      items: [
        {
          id: "seg-battery",
          title: "南坡蓄电池巡检",
          description: "测量太阳能供电电压 24.3V。",
          t_start: tYesterday,
          t_end: tYesterday,
          active_seconds: 420,
          sources: ["manual.note"],
          record_ids: [recYesterday.id],
          project_id: "proj-starport",
          evidence: [{ id: recYesterday.id, at: tYesterday, source: "manual.note", title: recYesterday.title }],
        },
      ],
    },
    needs_regen: 0,
    updated_at: tYesterday,
  });

  db.close();

  // 2. 启动真实中枢子进程 `bun hub/src/cli.ts serve`。
  hubProcess = Bun.spawn([process.execPath, "hub/src/cli.ts", "serve"], {
    cwd: repoRoot,
    env: hubEnv,
    stdin: "ignore",
    stdout: "pipe",
    stderr: "pipe",
  });

  const adminOrigin = `http://127.0.0.1:${httpPort}`;
  const lanOrigin = `http://127.0.0.1:${lanPort}`;
  await waitForHealth(adminOrigin);
  const adminToken = readFileSync(join(dataDir, "token"), "utf8").trim();

  // 3. 经本机管理接口创建查看邀请（role: "view"）。
  const pairRes = await fetch(`${adminOrigin}/v1/settings/devices/pairing`, {
    method: "POST",
    headers: {
      Authorization: `Bearer ${adminToken}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({ role: "view" }),
  });
  if (!pairRes.ok) {
    throw new Error(`创建查看邀请失败：HTTP ${pairRes.status} ${await pairRes.text()}`);
  }
  const { uri } = await pairRes.json() as { uri: string; expires_at: string };

  // 4. 运行 Swift 端端到端测试：配对 -> 拉取进 ProjectionCache -> 核对数量 -> 删记录 -> 验证撤下。
  const expectedCounts = { day: 2, project: 1, thread: 2, project_context: 1, now: 1 };
  const swiftRunner = Bun.spawn(
    [join(repoRoot, "collector/swift.sh"), "test", "--filter", "projectionLiveHubEndToEnd"],
    {
      cwd: join(repoRoot, "collector"),
      stdin: "ignore",
      stdout: "inherit",
      stderr: "inherit",
      env: {
        ...hubEnv,
        TACIT_PROJECTION_E2E_INVITE: uri,
        TACIT_PROJECTION_E2E_ORIGIN: lanOrigin,
        TACIT_PROJECTION_E2E_ADMIN: adminOrigin,
        TACIT_PROJECTION_E2E_TOKEN: adminToken,
        TACIT_PROJECTION_E2E_EXPECT_COUNTS: JSON.stringify(expectedCounts),
        TACIT_PROJECTION_E2E_DELETE_RECORD_ID: recToDelete.id,
        TACIT_PROJECTION_E2E_DELETED_THREAD_ID: "th-barometer",
        TACIT_PROJECTION_E2E_DELETED_DAY: today,
      },
    }
  );

  const exitCode = await swiftRunner.exited;
  if (exitCode !== 0) {
    process.exitCode = exitCode;
  }
} finally {
  if (hubProcess) {
    hubProcess.kill("SIGTERM");
    await Promise.race([hubProcess.exited, Bun.sleep(3_000)]);
    try { hubProcess.kill("SIGKILL"); } catch { /* 已退出 */ }
  }
  rmSync(workDir, { recursive: true, force: true });
}
