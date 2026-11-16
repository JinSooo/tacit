import { expect, test } from "bun:test";
import { summarize } from "./agent-metrics.ts";

const from = Date.parse("2026-11-16T12:00:00Z");
const context = (tool: string, project = "project-a") => ({
  id: tool + "-context", at: new Date(from).toISOString(), tool, kind: "context",
  args: { session: tool + "-hook", cwd: "/synthetic/project", project }, result_ids: ["context-source"], ok: 1 as const,
});
const search = (tool: string, result_ids: string[]) => ({
  id: tool + "-search", at: new Date(from + 1000).toISOString(), tool, kind: "search",
  args: { session: tool + "-mcp", cwd: "/synthetic/project", q: "synthetic search" }, result_ids, ok: 1 as const,
});

test("默认排除评测和发布检查，排除工具不参与利用率或命中率", () => {
  const reads = [search("accuracy-eval", []), search("release-check", []), search("codex", ["result"]),
    context("accuracy-eval"), context("release-check"), context("codex")];
  const report = summarize(reads, new Set());
  expect(report.utilization.overall).toEqual({ injected: 1, queried: 1, rate: 1 });
  expect(report.retrieval.search).toMatchObject({ calls: 1, hits: 1, empty: 0, empty_rate: 0 });
  expect(report.retrieval.empty_searches).toEqual([]);
  expect(report.excluded_tools).toEqual([
    { tool: "accuracy-eval", reads: 2 }, { tool: "release-check", reads: 2 },
    { tool: "qa-readonly", reads: 0 }, { tool: "test", reads: 0 },
  ]);
  const all = summarize(reads, new Set(), new Set());
  expect(all.retrieval.search).toMatchObject({ calls: 3, hits: 1, empty: 2 });
});

test("自定义工具和项目排除可同时生效", () => {
  const reads = [search("fixture-agent", []), search("claude-code", []), context("claude-code", "skipped-project"), context("codex")];
  const report = summarize(reads, new Set(["skipped-project"]), new Set(["fixture-agent"]));
  expect(report.excluded_tools).toEqual([{ tool: "fixture-agent", reads: 1 }]);
  expect(report.utilization.overall).toEqual({ injected: 1, queried: 0, rate: 0 });
  expect(report.retrieval.search).toMatchObject({ calls: 1, hits: 0, empty: 1 });
});
