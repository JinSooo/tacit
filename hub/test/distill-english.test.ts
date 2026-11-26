import { expect, test } from "bun:test";
import Ajv2020 from "ajv/dist/2020.js";
import { dayDrafts } from "../src/distill/day-review.ts";
import {
  CONVERSATION_SYSTEM_EN, briefSchema, conversationSchema, dayOverviewSchema, daySchema,
  fitSummary, getPrompts, summaryLength, summaryProblem, summarySentences,
} from "../src/distill/prompts.ts";
import { localDayStart } from "../src/distill/requests.ts";
import { conversationStep, dayStep } from "../src/distill/run.ts";
import { requestOnly } from "../src/distill/session-purpose.ts";
import { DistillStore } from "../src/distill/store.ts";
import { updateGeneral } from "../src/general-settings.ts";
import { createLLM } from "../src/llm/index.ts";
import { fixture, setup } from "./helpers.ts";

const date = "2026-02-06", start = localDayStart(date)!;
const at = (minutes: number) => new Date(start + minutes * 60_000).toISOString();
const chat = (minutes: number, body: string, from_me = 1, name = "Sunledger") => fixture({
  source: "mac.wechat", title: name, t_start: at(minutes), body,
  context: { chat: name, extra: { from_me } },
});

test("English and Chinese drafts share speech units and short-reply filtering", () => {
  const ctx = setup();
  try {
    for (const message of ["OK.", "Okay!", " YES ", "Sure…", "Continue?", "Go ahead.", "go on", "Proceed!", "Sounds good",
      "Do it.", "LGTM!", "Approved.", "Install it.", "继续吧。"]) expect(requestOnly(message), message).toBe(true);
    expect(requestOnly("Approved the Sunledger export.")).toBe(false);

    const filler = chat(480, "Absolutely wonderful."),
      progress = chat(481, "Export passed smoke tests."),
      assent = chat(520, "Sounds good!", 1, "Separate Sunledger chat"),
      audio = fixture({ source: "mac.audio", kind: "span", t_start: at(540), t_end: at(545),
        body: `[${new Date(start + 541 * 60_000).toTimeString().slice(0, 8)}] 我：Checked the invoice export.` });
    expect(ctx.db.ingest([filler, progress, assent, audio]).accepted).toBe(4);
    for (const language of ["en", "zh"] as const) {
      updateGeneral(ctx.db, { language });
      const drafts = dayDrafts(ctx.db, start, Date.parse(at(600)), { covered: new Set() });
      expect(drafts).toHaveLength(2);
      expect(drafts[0]).toMatchObject({ title: "Sunledger", excerpt: "Export passed smoke tests." });
      expect(drafts[1]).toMatchObject({ title_kind: "conversation", excerpt: "Checked the invoice export." });
    }
  } finally { ctx.cleanup(); }
});

test("English overview counts words and retains complete sentences around abbreviations", () => {
  const first = "Met Dr. Rao and Ms. Fox about Sunledger, e.g. its export settings.",
    second = "Compared v1.2 vs. v1.3 with Mrs. Hale and Mr. Lane.", third = "Chose a narrower scope.";
  expect(summaryLength("Checked Sunledger v1.2.", "en")).toBe(3);
  expect(summarySentences(`${first} ${second} ${third}`, "en")).toBe(3);
  expect(summarySentences("Reviewed docs, checklists, etc. with the team. Ran the export, i.e. the CSV path.", "en")).toBe(2);
  const tooLong = `${first} ${second} ${"word ".repeat(70)}closed.`;
  expect(fitSummary(tooLong, "en")).toBe(`${first} ${second}`);
  expect(summaryProblem(tooLong, "en")).toContain("70-word limit");
  expect(summaryProblem(first, "en")).toContain("2–4 sentences");
  expect(summaryProblem("已完成账单导出验证。准备交接结果。", "en")).toContain("Write the generated prose in English");
});

test("English schemas keep the same fields and enforce their character limits", () => {
  const ajv = new Ajv2020({ strict: false });
  const enDay = ajv.compile(daySchema("en"));
  const day = (title: string, description: string, text: string) => ({
    highlight: { activities: ["a1"], text },
    items: [{ activity: "a1", title, description, refs: ["a1:r1"], content: "result" }], omissions: [],
  });
  expect(enDay(day("x".repeat(64), "x".repeat(320), "x".repeat(700)))).toBe(true);
  expect(enDay(day("x".repeat(65), "x", "x"))).toBe(false);
  expect(enDay(day("x", "x".repeat(321), "x"))).toBe(false);
  expect(enDay(day("x", "x", "x".repeat(701)))).toBe(false);
  const enBrief = ajv.compile(briefSchema("en")), enOverview = ajv.compile(dayOverviewSchema("en"));
  expect(enBrief({ brief: "x".repeat(260) })).toBe(true);
  expect(enBrief({ brief: "x".repeat(261) })).toBe(false);
  expect(enOverview({ summary: "x".repeat(700) })).toBe(true);
  expect(enOverview({ summary: "x".repeat(701) })).toBe(false);
  const enConversation = ajv.compile(conversationSchema("en"));
  expect(enConversation({ title: "x".repeat(80), summary: "x".repeat(700), points: ["x".repeat(200)] })).toBe(true);
  expect(enConversation({ title: "x".repeat(81), summary: "x", points: [] })).toBe(false);
  expect(enConversation({ title: "x", summary: "x".repeat(701), points: [] })).toBe(false);
  expect(enConversation({ title: "x", summary: "x", points: ["x".repeat(201)] })).toBe(false);
});

test("English day and conversation send one language retry through the model adapter", async () => {
  const ctx = setup();
  const store = new DistillStore(ctx.db);
  const requests: { system: string; content: string }[] = [];
  let keepLeaking = false;
  const server = Bun.serve({ hostname: "127.0.0.1", port: 0, async fetch(req) {
    const { messages } = await req.json() as { messages: { content: string }[] };
    const system = messages[0]!.content, content = messages[1]!.content;
    const retry = content.includes("Write the generated prose in English.");
    requests.push({ system, content });
    const leak = !retry || keepLeaking;
    let output;
    if (system.includes(CONVERSATION_SYSTEM_EN)) {
      output = { title: "Review Sunledger invoice exports",
        summary: leak ? "检查了账单导出。约好了交接时间。" : "Reviewed invoice exports. Agreed to hand them over on Friday.", points: [] };
    } else {
      const { activities: [activity] } = JSON.parse(content.split("<data>\n")[1]!.split("\n</data>")[0]!);
      output = {
        highlight: { activities: [activity.key], text: "Ran the Sunledger export. Shared the invoice files for review." },
        items: [{ activity: activity.key, title: "Ran the Sunledger export", content: "result",
          description: leak ? "完成了账单导出并核对了发票。" : "Exported the invoice files and shared them for review.",
          refs: [activity.evidence[0].key] }],
        omissions: [],
      };
    }
    return Response.json({ choices: [{ finish_reason: "stop", message: { content: JSON.stringify(output) } }] });
  } });
  try {
    updateGeneral(ctx.db, { language: "en" });
    const config = { provider: "openai-compatible" as const, model: "fictional", base_url: new URL("/v1", server.url).href };
    const llm = createLLM({ dataDir: ctx.dir, configs: async () => ({ minute: config, hour: config, day: config }), recordUsage: () => {} });
    const deps = { db: ctx.db, llm };
    expect(ctx.db.ingest([chat(480, "Exported the Sunledger invoice files."),
      chat(482, "Shared the CSV with the finance team.")]).accepted).toBe(2);
    expect(await dayStep(deps, store, date, Date.parse(at(520)))).toEqual({ calls: 1, ok: true });
    expect(requests).toHaveLength(2);
    expect(requests[0]!.system).toContain(getPrompts("en").DAY_SYSTEM);
    expect(requests[1]!.content).toContain("Write the generated prose in English.");
    expect(store.day(date)?.detail.items[0].description).toBe("Exported the invoice files and shared them for review.");

    keepLeaking = true;
    expect(await dayStep(deps, store, date, Date.parse(at(520)))).toEqual({ calls: 1, ok: false, error: "schema_mismatch" });
    expect(requests).toHaveLength(4);
    expect(store.day(date)?.detail.items[0].description).toBe("Exported the invoice files and shared them for review.");

    keepLeaking = false;
    const clock = new Date(start + 541 * 60_000).toTimeString().slice(0, 8);
    const audio = fixture({ source: "mac.audio", kind: "span", t_start: at(540), t_end: at(545),
      body: `[${clock}] 我：${"Reviewed sample invoices and compared export options for the Sunledger team. ".repeat(12)}` });
    ctx.db.ingest([audio]);
    expect(await conversationStep(deps, Date.parse(at(570)))).toMatchObject({ calls: 1, done: 1 });
    expect(requests).toHaveLength(6);
    expect(requests[4]!.system).toContain(CONVERSATION_SYSTEM_EN);
    expect(requests[5]!.content).toContain("Write the generated prose in English.");
  } finally {
    server.stop(true);
    ctx.cleanup();
  }
});
