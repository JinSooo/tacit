import { expect, test } from "bun:test";
import { at } from "./adapter-fixture.ts";
import { codeBuddy } from "./adapters/codebuddy.ts";
import { copilotCli } from "./adapters/copilot-cli.ts";
import { droid } from "./adapters/droid.ts";
import { geminiCli } from "./adapters/gemini-cli.ts";
import { qwenCode } from "./adapters/qwen-code.ts";
import { workBuddy } from "./adapters/workbuddy.ts";

const timestamp = at(1);
const content = "  ## Skills\n- TypeScript  ";
const expected = { role: "assistant" as const, text: "## Skills\n- TypeScript", time: Date.parse(timestamp) };

test.each([
  ["Gemini CLI", () => geminiCli.parse({ id: "answer", type: "gemini", timestamp, content }, true)],
  ["Qwen", () => qwenCode.parse({ type: "assistant", timestamp, message: { role: "model", parts: [{ text: content }] } }, true)],
  ["Droid", () => droid.parse({ type: "message", timestamp, message: { role: "assistant", content } }, true)],
  ["Copilot CLI", () => copilotCli.parse({ type: "assistant.message", timestamp, data: { content } }, true)],
  ["CodeBuddy", () => codeBuddy.parse({ type: "message", timestamp, role: "assistant", content }, true)],
  ["WorkBuddy", () => workBuddy.parse({ type: "message", timestamp, role: "assistant", content }, true)],
] as const)("%s 保留以技能标题开头的 AI 正文", (_name, parse) => {
  expect(parse().message).toEqual(expected);
});
