import { expect, test } from "bun:test";
import { nativeAgentTools } from "./generate-agent-tools.ts";

test.each(Object.entries(nativeAgentTools))("the native tool catalog is current in %s", async (path, expected) => {
  expect(await Bun.file(new URL(`../../${path}`, import.meta.url)).text()).toBe(expected);
});
