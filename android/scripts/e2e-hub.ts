import { writeFileSync } from "node:fs";
import { join } from "node:path";
import { startServer } from "../../hub/src/server.ts";
import { startRelay } from "../../relay/src/bun.ts";
import { setup } from "../../hub/test/helpers.ts";

const test = setup();
const relay = startRelay({ port: 0, hostname: "127.0.0.1" });
let server: ReturnType<typeof startServer> | undefined;
try {
  const probe = Bun.serve({ hostname: "0.0.0.0", port: 0, fetch: () => new Response() });
  const port = probe.port!;
  await probe.stop(true);
  writeFileSync(join(test.dir, "hub.json"), JSON.stringify({ lan_port: port }));
  let key: string | null = null;
  const relayKeys = new Map<string, string>();
  server = startServer({
    db: test.db, token: test.config.token, port: 0, settings: { dataDir: test.dir },
    deviceDeps: {
      name: "测试 Mac", addresses: () => ["127.0.0.1"],
      keys: { read: () => key, write: (value) => { key = value; } },
      relayKeys: {
        read: space => relayKeys.get(space) ?? null,
        write: (space, value) => { relayKeys.set(space, value); },
        remove: space => { relayKeys.delete(space); },
      },
    },
  });
  const relayUrl = relay.server.url.origin;
  const relaySetup = await fetch(new URL("/v1/settings/relay", server.url), {
    method: "PUT",
    headers: { Authorization: `Bearer ${test.config.token}`, "Content-Type": "application/json" },
    body: JSON.stringify({ mode: "custom", url: relayUrl }),
  });
  if (!relaySetup.ok) throw new Error(`启用本地测试信箱失败，HTTP ${relaySetup.status}`);
  const invite = await fetch(new URL("/v1/settings/devices/pairing", server.url), {
    method: "POST", headers: { Authorization: `Bearer ${test.config.token}` },
  });
  if (!invite.ok) throw new Error(`创建测试邀请失败，HTTP ${invite.status}`);
  const { uri } = await invite.json() as { uri: string };
  const cwd = join(import.meta.dir, "..");
  const runner = Bun.spawn(["./gradlew", "--offline", "testDebugUnitTest", "--rerun",
    "--tests", "top.jinso.tacit.sync.HubE2eTest"], {
    cwd, stdin: "inherit", stdout: "inherit", stderr: "inherit",
    env: { ...process.env, TACIT_E2E_INVITE: uri, TACIT_E2E_ADMIN: server.url.origin, TACIT_E2E_TOKEN: test.config.token, TACIT_E2E_RELAY: relayUrl },
  });
  process.exitCode = await runner.exited;
} finally {
  await server?.stop(true);
  relay.stop(true);
  test.cleanup();
}
