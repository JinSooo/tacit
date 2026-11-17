import { toLocalIso, type RecordV1 } from "../../../packages/record/index.ts";
import { parseTranscript } from "../conversations.ts";
import { materialBody } from "./material.ts";
import { excerpt } from "./prompts.ts";

export type DayRole = "user" | "assistant" | "other";
export interface DayEvidenceInput { key: string; role: DayRole; source: string; at: string; text: string; secondary?: true }
export interface DayReference { id: string; at: string; source: string; title: string }
export interface DayEvidence extends DayEvidenceInput {
  reference: DayReference;
  position?: "first" | "last" | "within_batch";
}
export type UnnumberedEvidence = Omit<DayEvidence, "key">;
type Spoken = Pick<UnnumberedEvidence, "at" | "role" | "text" | "position">;
type DayRecord = Pick<RecordV1, "source" | "t_start" | "t_end" | "context">;

function spoken(record: Pick<RecordV1, "source" | "body" | "context">, original: DayRecord, end: number): Spoken[] | null {
  const at = original.t_start;
  if (record.source === "codex.session" || record.source === "claude_code.session") {
    const finish = original.t_end ?? at;
    const messages = [...record.body.matchAll(/(?:^|\n\n)\[(我|AI)\] ([\s\S]*?)(?=\n\n\[(?:我|AI)\] |$)/g)];

    if (Date.parse(finish) >= end) return [];
    return messages.map((message, i) => {
      // 清理包装前记下首末位置。被清理掉的消息不能把批次时间借给下一条。
      const prefix = `[${message[1]}] `;
      // Only protocol prefixes are automatic; discussing them inside a message is still user input.
      const automatic = message[1] === "我" && /^(?:<codex_internal_context\s|Context handoff \(manual_context\):|Automation: .+\nAutomation ID:)/.test(message[2]!.trim());
      const text = automatic ? "" : materialBody({ ...record, body: prefix + message[2]! });
      const position = messages.length === 1 && at !== finish ? "within_batch"
        : i === 0 ? "first" : i === messages.length - 1 ? "last" : "within_batch";
      return { role: message[1] === "我" ? "user" : "assistant", text: text.startsWith(prefix) ? text.slice(prefix.length) : "",
        at: position === "last" ? finish : at, position };
    });
  }
  const body = materialBody(record);
  if (record.source === "manual.correction" || original.source === "manual.note") return [{ role: "user", text: body, at }];
  if (original.source === "mac.audio") return parseTranscript(body, at)
    .map(line => ({ role: line.label === "我" ? "user" : "other", text: line.text, at: toLocalIso(line.at_ms) }));
  const fromMe = original.context?.extra?.from_me;
  if (original.context?.chat && (fromMe === 0 || fromMe === 1)) return [{ role: fromMe === 1 ? "user" : "other", text: body, at }];
  return [];
}

export const SKELETON_SOURCES = new Set(["mac.screen", "mac.browser", "mac.app"]);

/** 屏幕、浏览器即使有补写修正，也只提供时间骨架。 */
export function readDayEvidence({ id, at, source, title }: DayReference, original: DayRecord, body: string | null,
  corrected: boolean, start: number, end: number): UnnumberedEvidence[] | null {
  if (body === null) return [];
  const reference = { id, at, source, title };
  const entries = spoken({ source: corrected ? "manual.correction" : original.source, body, context: original.context }, original, end);
  return entries?.flatMap(entry => {
    const at = Date.parse(entry.at), text = entry.text.trim();
    return at >= start && at < end && text
      ? [{ ...entry, source: original.source, text: excerpt(text, entry.role === "user" ? 600 : 350), reference }]
      : [];
  }) ?? null;
}

export function sampleDayEvidence(entries: UnnumberedEvidence[], limit: number): DayEvidence[] {
  const buckets = new Map<string, UnnumberedEvidence[]>();
  for (const entry of entries) {
    const key = JSON.stringify([entry.role, entry.source]);
    const bucket = buckets.get(key) ?? [];
    bucket.push(entry);
    buckets.set(key, bucket);
  }
  // 每段先给不同角色各留一个来源，再把预算分给其他来源。
  const groups = [...buckets.values()], firstRole = new Map<DayRole, UnnumberedEvidence[]>();
  for (const group of groups) if (!firstRole.has(group[0]!.role)) firstRole.set(group[0]!.role, group);
  const preferred = [...firstRole.values()];
  const selected = [...preferred, ...groups.filter(group => !preferred.includes(group))].slice(0, limit);
  const counts = selected.map(() => 0);
  let remaining = Math.min(limit, selected.reduce((sum, group) => sum + group.length, 0));
  while (remaining > 0) for (const [i, group] of selected.entries()) {
    if (!remaining || counts[i]! >= group.length) continue;
    counts[i] = counts[i]! + 1;
    remaining--;
  }
  const sample = selected.flatMap((group, index) => {
    const ordered = [...group].sort((a, b) => Date.parse(a.at) - Date.parse(b.at));
    const count = counts[index]!;
    if (ordered.length <= count) return ordered;
    if (count === 1) return [ordered[Math.floor((ordered.length - 1) / 2)]!];
    return Array.from({ length: count }, (_, i) => ordered[Math.round(i * (ordered.length - 1) / (count - 1))]!);
  });
  return sample.sort((a, b) => Date.parse(a.at) - Date.parse(b.at)).map((entry, i) => ({ ...entry, key: `r${i + 1}` }));
}
