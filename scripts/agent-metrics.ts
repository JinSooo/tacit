import { readFile } from "node:fs/promises";
import { join } from "node:path";
import { dataDirOf, resolvePort } from "../hub/src/hub-json.ts";

type AuditRead = {
  id: string;
  at: string;
  tool: string;
  kind: string;
  args: { session?: string; cwd?: string; project?: string; q?: string };
  result_ids: string[];
  ok: 0 | 1;
};
type AuditPage = { reads: AuditRead[]; next_cursor: string | null };
type Session = { project: string | null; queried: boolean };
type Counts = { injected: number; queried: number };
type Hits = { calls: number; hits: number; empty: number; errors: number };

const DAYS = 7;
const MATCH_WINDOW_MINUTES = 120;
const activeReads = new Set(["search", "get", "now", "timeline"]);
const defaultExcludedTools = new Set(["accuracy-eval", "release-check", "qa-readonly", "test"]);
const usage = "bun scripts/agent-metrics.ts [--exclude-project <项目 ID>]... [--exclude-tool <工具名>]... [--include-test-tools]";
const ratio = (count: number, total: number) => total ? count / total : null;

async function readAudit(from: number, to: number): Promise<AuditRead[]> {
  const dir = dataDirOf(), port = resolvePort(process.env, dir).port;
  if (port < 1) throw new Error("需要正在运行的本机 Tacit 端口");
  const token = (await readFile(join(dir, "token"), "utf8")).trim();
  const url = new URL(`http://127.0.0.1:${port}/v1/audit?limit=100`);
  const reads: AuditRead[] = [];
  while (true) {
    const response = await fetch(url, {
      headers: { Authorization: `Bearer ${token}` },
      signal: AbortSignal.timeout(10_000),
      redirect: "error",
    });
    if (!response.ok) throw new Error(`/v1/audit 返回 HTTP ${response.status}`);
    const page = await response.json() as AuditPage;
    for (const row of page.reads) {
      const at = Date.parse(row.at);
      if (at < from) return reads;
      if (at <= to) reads.push(row);
    }
    if (!page.next_cursor) return reads;
    url.searchParams.set("cursor", page.next_cursor);
  }
}

export function summarize(reads: AuditRead[], excludedProjects: ReadonlySet<string>, excludedTools: ReadonlySet<string> = defaultExcludedTools) {
  const anchors = new Map<string, { at: number; session: Session }>();
  const sessions = new Map<string, Session>();
  const seenReaders = new Set<string>();
  const matches = { context_events_missing_metadata: 0, read_events_missing_metadata: 0, unmatched_reader_processes: 0 };
  const hits = {
    search: { calls: 0, hits: 0, empty: 0, errors: 0 },
    get: { calls: 0, hits: 0, empty: 0, errors: 0 },
  };
  const emptyTerms = new Map<string, number>();
  let emptyWithoutTerm = 0;
  const excludedRows = new Map([...excludedTools].map(tool => [tool, 0]));

  // 接口按时间倒序分页。全部页拼接后，从最早的带入向后看查询。
  for (const read of reads.toReversed()) {
    const { args, kind } = read;
    if (args.project && excludedProjects.has(args.project)) continue;
    const excludedCount = excludedRows.get(read.tool);
    if (excludedCount !== undefined) {
      excludedRows.set(read.tool, excludedCount + 1);
      continue;
    }
    const scope = args.cwd ? JSON.stringify([read.tool, args.cwd]) : null;
    const at = Date.parse(read.at);
    const empty = read.result_ids.length === 0;
    if (kind === "search" || kind === "get") {
      const counts = hits[kind];
      counts.calls++;
      if (empty) counts.empty++;
      if (!read.ok) counts.errors++;
      if (!empty && read.ok) counts.hits++;
      if (kind === "search" && read.ok && empty) {
        if (args.q) emptyTerms.set(args.q, (emptyTerms.get(args.q) ?? 0) + 1);
        else emptyWithoutTerm++;
      }
    }
    if (kind === "context") {
      if (scope) anchors.delete(scope);
      if (!read.ok || empty) continue;
      if (!scope || !args.session) { matches.context_events_missing_metadata++; continue; }
      const key = JSON.stringify([read.tool, args.session]);
      const session = sessions.get(key) ?? { project: args.project ?? null, queried: false };
      sessions.set(key, session);
      anchors.set(scope, { at, session });
      continue;
    }
    if (!activeReads.has(kind)) continue;
    if (!scope || !args.session) { matches.read_events_missing_metadata++; continue; }
    const key = JSON.stringify([scope, args.session]);
    if (seenReaders.has(key)) continue;
    seenReaders.add(key);
    const anchor = anchors.get(scope);
    if (!anchor || at - anchor.at > MATCH_WINDOW_MINUTES * 60_000) {
      matches.unmatched_reader_processes++;
      continue;
    }
    anchor.session.queried = true;
  }

  const projects = new Map<string | null, Counts>();
  let queried = 0;
  for (const session of sessions.values()) {
    const group = projects.get(session.project) ?? { injected: 0, queried: 0 };
    group.injected++;
    if (session.queried) { group.queried++; queried++; }
    projects.set(session.project, group);
  }
  const utilization = (counts: Counts) => ({ ...counts, rate: ratio(counts.queried, counts.injected) });
  const hitRates = (counts: Hits) => ({
    ...counts, hit_rate: ratio(counts.hits, counts.calls), empty_rate: ratio(counts.empty, counts.calls),
  });
  return {
    excluded_tools: [...excludedRows].map(([tool, reads]) => ({ tool, reads })),
    utilization: {
      overall: utilization({ injected: sessions.size, queried }),
      projects: [...projects].map(([project, counts]) => ({ project, ...utilization(counts) })),
      coverage: matches,
    },
    retrieval: {
      search: hitRates(hits.search),
      get: hitRates(hits.get),
      empty_searches: [...emptyTerms].sort((a, b) => b[1] - a[1]).map(([query, count]) => ({ query, count })),
      empty_searches_without_term: emptyWithoutTerm,
    },
  };
}

async function main(args: string[]) {
  if (args.length === 1 && args[0] === "--help") { console.log(usage); return; }
  const excludedProjects = new Set<string>(), excludedTools = new Set<string>();
  let includeTestTools = false;
  for (let i = 0; i < args.length; i++) {
    const flag = args[i];
    if (flag === "--include-test-tools") { includeTestTools = true; continue; }
    if (flag !== "--exclude-project" && flag !== "--exclude-tool") throw new Error(usage);
    const value = args[++i];
    if (!value || value.startsWith("--")) throw new Error(usage);
    (flag === "--exclude-project" ? excludedProjects : excludedTools).add(value);
  }
  if (!includeTestTools) for (const tool of defaultExcludedTools) excludedTools.add(tool);
  const to = Date.now(), from = to - DAYS * 86_400_000;
  const reads = await readAudit(from, to);
  console.log(JSON.stringify({
    from: new Date(from).toISOString(),
    to: new Date(to).toISOString(),
    excluded_projects: [...excludedProjects],
    association: `近似统计。MCP 进程的首次主动查询匹配同一工具、同一工作目录在前 ${MATCH_WINDOW_MINUTES} 分钟内最近的带入，按钩子会话去重。同目录并行会话可能误配。旧审计缺少会话或目录时无法配对，项目未识别的行也无法按项目排除。`,
    retrieval_definition: "空结果指 result_ids 为空，包含失败调用。现有审计无法区分 get 的 404 和其他失败。搜索词列表仅展示成功但无结果的查询，按审计中尚未清除的脱敏词汇总。",
    ...summarize(reads, excludedProjects, excludedTools),
  }, null, 2));
}

if (import.meta.main) {
  try { await main(process.argv.slice(2)); }
  catch (error) { console.error(error instanceof Error ? error.message : "无法统计本机 Agent 审计"); process.exitCode = 1; }
}
