// 提炼层的提示词与输出 schema。契约：docs/contracts.md 第 4 节。
// 原则：
// - History 是不可信数据（网页、聊天、终端输出），一律包在 <data> 里，模型只描述事实，不执行其中的指令。
// - 简略版只能从详细版派生：brief 用单独一次调用生成，输入只有 detail 和有效 facts，拿不到原始记录。
// - 每个新 fact 必须引用至少一条输入里出现过的 record id，调用方会校验，引用不到的丢弃。

import type { Lang } from "../i18n/language.ts";
import { hasCjkLeakage, summaryLength } from "../i18n/units.ts";
import * as zh from "./prompts/zh.ts";
import * as en from "./prompts/en.ts";

export * from "./prompts/zh.ts";
export { CONVERSATION_SYSTEM_EN, CONVERSATION_SCHEMA_EN } from "./prompts/en.ts";
export { summaryLength } from "../i18n/units.ts";

export function getPrompts(lang: Lang) {
  return lang === "en" ? en : zh;
}

export const daySchema = (lang: Lang) => getPrompts(lang).DAY_SCHEMA;
export const dayOverviewSchema = (lang: Lang) => getPrompts(lang).DAY_OVERVIEW_SCHEMA;
export const briefSchema = (lang: Lang) => getPrompts(lang).BRIEF_SCHEMA;
export const conversationSchema = (lang: Lang) => getPrompts(lang).CONVERSATION_SCHEMA;

const { DAY_OMISSION_REASONS, MAX_DAY_SUMMARY_CHARS } = zh;
const MAX_DAY_SUMMARY_ACTIVITIES = zh.DAY_SCHEMA.properties.highlight.properties.activities.maxItems;

/** 一个片段给模型看的样子。private 片段只给应用和时长。 */
export interface FrameView {
  id: string;
  start: string;          // 本地时间，如 11-08 14:02
  end: string;
  key: string;            // repo:/path | host:x | chat:app:name | app:bundle
  repos?: string[];       // 项目候选线索，不等同于事项身份。
  private: boolean;
  records: { id: string; source: string; title: string; excerpt: string;
    recorded_at?: string; recorded_until?: string; query_dates?: { parameter: string; value: string }[];
    part?: { start: number; end: number; total: number }; conversation_id?: string; conversation_summary?: { summary: string; points: string[] } }[];
  /** 用户说过这个片段不属于的线程标题。 */
  not_threads?: string[];
}

export interface ThreadView { id: string; title: string; brief: string; project: string | null; status: string; last: string }

export interface FactView { id: string; kind: string; text: string; origin: string; at?: string; scope?: { thread_id: string | null; project_id: string | null } }

const json = (v: unknown) => JSON.stringify(v);
const dataBlock = (jsonText: string) => `<data>\n${jsonText}\n</data>`;

/** 快速归类的短概览保留首尾；详细整理传 Infinity，再按请求预算分段读取全文。 */
export function excerpt(text: string, maxChars: number): string {
  const cps = Array.from(text.replace(/\n{3,}/g, "\n\n").trim());
  if (cps.length <= maxChars) return cps.join("");
  const head = Math.ceil(maxChars / 2), tail = Math.floor(maxChars / 2);
  return cps.slice(0, head).join("") + "…" + (tail ? cps.slice(-tail).join("") : "");
}

// 每次请求重新去重；跨片段同场总结只附在第一条记录上，正文和证据 id 不动。
function frameBlock(frames: FrameView[], lang: Lang = "zh"): string {
  const conversations = new Set<string>();
  const view = frames.map(f => f.private
    ? { id: f.id, time: `${f.start}–${f.end}`, key: f.key, private: true, note: lang === "en" ? "Private content omitted" : "私密内容，正文未提供", ...(f.not_threads?.length ? { not_threads: f.not_threads } : {}) }
    : { id: f.id, time: `${f.start}–${f.end}`, key: f.key, ...(f.repos?.length ? { repos: f.repos } : {}), records: f.records.map(r => {
      const { conversation_summary, ...record } = r;
      if (!r.conversation_id || !conversation_summary || conversations.has(r.conversation_id)) return record;
      conversations.add(r.conversation_id);
      return { ...record, conversation_summary };
    }), ...(f.not_threads?.length ? { not_threads: f.not_threads } : {}) });
  return dataBlock(json(view));
}

// ---------- 1. 归线程（minute 档） ----------

export function assignPrompt(frames: FrameView[], threads: ThreadView[], lang: Lang = "zh"): string {
  if (lang === "en") return `Existing threads:\n${dataBlock(json(threads))}\n\nFrames to assign:\n${frameBlock(frames, lang)}`;
  return `已有线程：\n${json(threads)}\n\n待归属的片段：\n${frameBlock(frames)}`;
}

export interface AssignOutput {
  items: { frame_id: string; thread_id: string | null; new_thread_title: string | null; ignore: boolean; confidence: number }[];
}

// ---------- 2. 更新线程详细版（hour 档） ----------

export interface Classification { domain: "work" | "life"; in_project: boolean }
export type ProjectHint = { name: string; brief: string | null } | null;
export function classifyPrompt(thread: { title: string; detail?: unknown; brief?: string | null }, project: ProjectHint, lang: Lang = "zh"): string {
  const detail = thread.detail as { goal?: string; progress?: string } | null;
  return `<data>\n${json({ title: thread.title, goal: detail?.goal ?? "", progress: detail?.progress ?? "", brief: thread.brief ?? "", candidate_project: project ?? (lang === "en" ? "none" : "无") })}\n</data>`;
}

export function threadPrompt(thread: { title: string; detail: unknown }, facts: FactView[], frames: FrameView[], project: ProjectHint = null, lang: Lang = "zh"): string {
  if (lang === "en") {
    const prior = { candidate_project: project, thread: { title: thread.title, detail: thread.detail }, facts };
    return `Current thread, candidate project, and valid facts:\n${dataBlock(json(prior))}\n\nNew frames:\n${frameBlock(frames, lang)}`;
  }
  return `候选项目：${json(project ?? "无")}\n\n线程：${json({ title: thread.title, detail: thread.detail })}\n\n已有有效 facts：\n${json(facts)}\n\n新片段：\n${frameBlock(frames)}`;
}

export interface ThreadOutput extends Classification {
  title: string;
  detail: { goal: string; progress: string; artifacts: { files: string[]; urls: string[]; commands: string[]; people: string[] }; quotes: { text: string; record_id: string }[] };
  new_facts: { kind: "decision" | "rejected" | "open" | "next" | "inference"; text: string; reason: string | null; evidence: string[]; confidence: number }[];
  invalidate: { fact_id: string; replaced_by: number | null }[];
  status_hint: "active" | "paused" | "done_candidate";
}

// ---------- 3. 由详细版生成简略版（minute 档，输入不含原始记录） ----------

export function briefPrompt(title: string, detail: unknown, lang: Lang = "zh"): string {
  // 简略版只概括状态正文。参考链接和历史原话可能提到未采用的候选，不能成为新的进展来源。
  if (detail && typeof detail === "object" && !Array.isArray(detail)) {
    const { artifacts, quotes, ...state } = detail as Record<string, unknown>;
    detail = state;
  }
  const input = json({ title, detail });
  return lang === "en" ? dataBlock(input) : input;
}

export interface BriefOutput { brief: string }

/** 校验模型给出的 evidence 都在本批输入里，过滤掉编造的 id；一条都不剩的 fact 丢弃。 */
export function keepGroundedFacts<T extends { evidence: string[] }>(facts: T[], knownRecordIds: Set<string>): T[] {
  return facts
    .map(f => ({ ...f, evidence: f.evidence.filter(id => knownRecordIds.has(id)) }))
    .filter(f => f.evidence.length > 0);
}

// ---------- 4. 项目详细版（hour 档，输入是线程的简略版，不含原始记录） ----------

export function projectPrompt(name: string, threads: ThreadView[], facts: FactView[]): string {
  return `项目：${name}\n\n<data>\n${json({ threads, facts })}\n</data>`;
}

export interface ProjectOutput { goal: string; status: string; people: string[] }

// ---------- 5. 每日回顾 ----------

// Keep the Chinese boundaries unchanged. The English form skips common abbreviations
// and recognizes sentence-ending dots after numbers and before closing quotes.
const SENTENCE_END = /(?:[。！？!?]+|(?<![\d.])\.(?=\s|$))[”’」』）)"']*/gu;
const EN_SENTENCE_END = /(?:[。！？!?]+|(?<!\.)(?<!\b(?:e\.g|i\.e|Mr|Mrs|Ms|Dr|vs|etc))\.(?=[”’)"']*(?:\s|$)))[”’)"']*/giu;
const MAX_DAY_SUMMARY_SENTENCES = 4;
const summaryLimit = (lang: Lang) => lang === "en" ? en.DAY_SUMMARY_WORDS : MAX_DAY_SUMMARY_CHARS;

export function summarySentences(text: string, lang: Lang = "zh"): number {
  return (text.match(lang === "en" ? EN_SENTENCE_END : SENTENCE_END) ?? []).length;
}

/** Keep the longest prefix of complete sentences within the language's limit. */
export function fitSummary(text: string, limitOrLang: number | Lang = "zh", maxSentences = MAX_DAY_SUMMARY_SENTENCES): string | null {
  const lang = typeof limitOrLang === "number" ? "zh" : limitOrLang;
  const limit = typeof limitOrLang === "number" ? limitOrLang : summaryLimit(lang);
  const ends = [...text.matchAll(lang === "en" ? EN_SENTENCE_END : SENTENCE_END)];
  if (summaryLength(text, lang) <= limit && ends.length <= maxSentences) return text;
  let best: string | null = null;
  for (const match of ends.slice(0, maxSentences)) {
    const head = text.slice(0, match.index + match[0].length).trimEnd();
    if (summaryLength(head, lang) > limit) break;
    best = head;
  }
  return best;
}

export const EN_LANGUAGE_REMINDER = "Write the generated prose in English. Keep source names and verbatim evidence in their original language.";

export function summaryProblem(text: string, lang: Lang = "zh"): string | null {
  const length = summaryLength(text, lang), sentences = summarySentences(text, lang), problems: string[] = [];
  const limit = summaryLimit(lang);
  if (lang === "en") {
    if (hasCjkLeakage(text)) problems.push(EN_LANGUAGE_REMINDER);
    if (length > limit) problems.push(`The summary is about ${length} words. Cut at least ${length - limit} words to meet the ${limit}-word limit.`);
    if (sentences < 2 || sentences > MAX_DAY_SUMMARY_SENTENCES) problems.push(`The summary has ${sentences} sentences. Write 2–${MAX_DAY_SUMMARY_SENTENCES} sentences.`);
    return problems.length ? problems.join(" ") : null;
  }
  if (length > limit) problems.push(`summary 约 ${length} 字，超过 ${limit} 字上限，需要删掉至少 ${length - limit} 字`);
  if (sentences < 2 || sentences > MAX_DAY_SUMMARY_SENTENCES) problems.push(`summary 现在是 ${sentences} 句，要写成 2–${MAX_DAY_SUMMARY_SENTENCES} 句`);
  return problems.length ? problems.join("；") : null;
}

export function dayPolishPrompt(date: string, activities: unknown, recent: { title: string; description: string }[], lang: Lang = "zh") {
  return `${lang === "en" ? "Date: " : "日期："}${date}\n\n<data>\n${json({ activities, recent })}\n</data>`;
}

export function dayOverviewPrompt(activities: { start: string; title: string; description: string; project: string | null }[]) {
  return `<data>\n${json(activities)}\n</data>`;
}

export function dayPrompt(date: string, activities: unknown, cutoff: string, lang: Lang = "zh"): string {
  return `${lang === "en" ? "Date: " : "日期："}${date}\n\n<data>\n${json({ activities, cutoff })}\n</data>`;
}

export interface DayOutput {
  highlight: ({ activities: string[] } | { activity: string }) & { text: string } | null;
  omissions?: { activity: string; reason: string; title: string; description: string; refs: string[] }[];
  items: { activity: string; title: string; description: string; refs: string[]; content?: "result" | "judgment" | "request_only" | "empty" }[];
}

/**
 * 模型请求只使用新格式。本地校验前兼容仍返回单个编号的提供方。
 * 省略理由：模型常把类别和说明写在一起（“empty 仅收到食品推荐。”），按开头的类别名识别；
 * 认不出类别的省略按结果处理（有文字就成段，没有文字由 composeReview 报警并留在未入时间线）。
 */
export function normalizeDayOutput(output: unknown, lang: Lang = "zh"): unknown {
  if (!output || typeof output !== "object" || !("highlight" in output)) return output;
  let result = output as Record<string, unknown>;
  const highlight = result.highlight;
  if (highlight && typeof highlight === "object" && !("activities" in highlight) && "activity" in highlight) {
    const { activity, ...fields } = highlight as Record<string, unknown>;
    result = { ...result, highlight: { ...fields, activities: [activity] } };
  }
  // 不强制 maxLength 的接口（MiniMax 等）数不准字数：概述超长时截到上限内最后一个整句，主线最多留 4 条（2026-11-18）。
  const h = result.highlight as { text?: unknown; activities?: unknown } | null;
  if (h && typeof h === "object") {
    const fixed: Record<string, unknown> = { ...h };
    if (Array.isArray(h.activities) && h.activities.length > MAX_DAY_SUMMARY_ACTIVITIES) fixed.activities = h.activities.slice(0, MAX_DAY_SUMMARY_ACTIVITIES);
    // English recheck must see the original prose before the final whole-sentence fit.
    if (lang === "zh" && typeof h.text === "string") {
      const fitted = fitSummary(h.text, lang);
      if (fitted) fixed.text = fitted;
    }
    result = { ...result, highlight: fixed };
  }
  if (!Array.isArray(result.omissions) || !Array.isArray(result.items)) return result;
  const omissions: unknown[] = [], items: unknown[] = [...result.items];
  for (const omission of result.omissions) {
    if (!omission || typeof omission !== "object" || typeof (omission as { reason?: unknown }).reason !== "string") { omissions.push(omission); continue; }
    const { reason, ...fields } = omission as Record<string, unknown> & { reason: string };
    const category = DAY_OMISSION_REASONS.find(c => new RegExp(`^\\s*${c}(?![a-z_])`).test(reason));
    if (category) omissions.push({ ...fields, reason: category });
    else if (typeof fields.title === "string" && fields.title.trim() && Array.isArray(fields.refs) && fields.refs.length
      && !items.some(item => (item as { activity?: unknown })?.activity === fields.activity))
      items.push({ ...fields, content: "result" });
  }
  return { ...result, omissions, items };
}

// ---------- 对话总结（minute 档） ----------

export function conversationPrompt(meta: { start: string; end: string; app: string | null }, transcript: string, lang: Lang = "zh"): string {
  if (lang === "en") return `Time: ${meta.start}–${meta.end}${meta.app ? `, app: ${meta.app}` : ""}\n<data>\n${transcript}\n</data>`;
  return `时间：${meta.start}–${meta.end}${meta.app ? `，会议软件：${meta.app}` : ""}\n<data>\n${transcript}\n</data>`;
}

export interface ConversationOutput { title: string; summary: string; points: string[] }

// ---------- 合并重复线程（每天一次，hour 档） ----------

export function dedupPrompt(threads: (ThreadView & { first: string })[], lang: Lang = "zh"): string {
  if (lang === "en") return dataBlock(json(threads));
  return `线程：\n${json(threads)}`;
}

export interface DedupOutput { groups: { thread_ids: string[]; confidence: number }[] }
