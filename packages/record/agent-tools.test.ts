import { expect, test } from "bun:test";
import { AGENT_TOOLS, AGENT_SESSION_SOURCES } from "./agent-tools.ts";
import { nativeAgentTools } from "./generate-agent-tools.ts";

test.each(Object.entries(nativeAgentTools))("the native tool catalog is current in %s", async (path, expected) => {
  expect(await Bun.file(new URL(`../../${path}`, import.meta.url)).text()).toBe(expected);
});

test("Kimi CLI 只接查询，OpenCode 使用 macOS 应用图标", () => {
  expect(AGENT_TOOLS.find(t => t.id === "kimi-cli")).toMatchObject({ label: "Kimi CLI" });
  expect([...AGENT_SESSION_SOURCES].some(source => source.startsWith("kimi"))).toBe(false);
  expect(AGENT_TOOLS.find(t => t.id === "opencode")?.macBundle).toBe("ai.opencode.desktop");
});
