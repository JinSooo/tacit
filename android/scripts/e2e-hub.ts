import { writeFileSync } from "node:fs";
import { join } from "node:path";
import { startServer } from "../../hub/src/server.ts";
import { setup } from "../../hub/test/helpers.ts";

const test = setup();
let server: ReturnType<typeof startServer> | undefined;
try {
  const probe = Bun.serve({ hostname: "0.0.0.0", port: 0, fetch: () => new Response() });
  const port = probe.port!;
  await probe.stop(true);
  writeFileSync(join(test.dir, "hub.json"), JSON.stringify({ lan_port: port }));
  let key: string | null = null;
  server = startServer({
    db: test.db, token: test.config.token, port: 0, settings: { dataDir: test.dir },
    deviceDeps: {
      name: "测试 Mac", addresses: () => ["127.0.0.1"],
      keys: { read: () => key, write: (value) => { key = value; } },
    },
  });
  const invite = await fetch(new URL("/v1/settings/devices/pairing", server.url), {
    method: "POST", headers: { Authorization: `Bearer ${test.config.token}` },
  });
  if (!invite.ok) throw new Error(`创建测试邀请失败，HTTP ${invite.status}`);
  const { uri } = await invite.json() as { uri: string };
  const cwd = join(import.meta.dir, "..");
  const runner = Bun.spawn(["./gradlew", "--offline", "testDebugUnitTest", "--rerun",
    "--tests", "top.jinso.tacit.sync.HubE2eTest"], {
    cwd, stdin: "inherit", stdout: "inherit", stderr: "inherit",
    env: { ...process.env, TACIT_E2E_INVITE: uri, TACIT_E2E_ADMIN: server.url.origin, TACIT_E2E_TOKEN: test.config.token },
  });
  process.exitCode = await runner.exited;
} finally {
  await server?.stop(true);
  test.cleanup();
}
