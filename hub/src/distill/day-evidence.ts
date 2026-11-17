import { toLocalIso, type RecordV1 } from "../../../packages/record/index.ts";
import { parseTranscript } from "../conversations.ts";
import type { HubDB } from "../db.ts";
import { materialBody } from "./material.ts";
import { excerpt } from "./prompts.ts";

export type DayRole = "user" | "assistant" | "other";
export interface DayEvidenceInput { key: string; role: DayRole; source: string; at: string; text: string }
export interface DayReference { id: string; at: string; source: string; title: string }
interface DayEvidence extends DayEvidenceInput { reference: DayReference }
type Spoken = Pick<DayEvidenceInput, "at" | "role" | "text">;

function spoken(record: RecordV1, original: RecordV1, end: number): Spoken[] {
  const body = materialBody(record);
  const at = original.t_start;
  if (record.source === "manual.correction" || original.source === "manual.note") return [{ role: "user", text: body, at }];
  if (original.source === "mac.audio") return parseTranscript(body, at)
    .map(line => ({ role: line.label === "我" ? "user" : "other", text: line.text, at: toLocalIso(line.at_ms) }));
  if (original.source === "codex.session" || original.source === "claude_code.session") {
    // 会话导入没有逐条消息时间，不能截出还未发生或跨到下一日的部分。
    if (Date.parse(original.t_end ?? at) >= end) return [];
    const messages = [...body.matchAll(/(?:^|\n\n)\[(我|AI)\] ([\s\S]*?)(?=\n\n\[(?:我|AI)\] |$)/g)];
    if (messages.some(message => message[1] === "我" && /^Automation: .+\nAutomation ID:/m.test(message[2]!))) return [];
    return messages.map(message => ({ role: message[1] === "我" ? "user" : "assistant", text: message[2]!, at }));
  }
  const fromMe = original.context?.extra?.from_me;
  if (original.context?.chat && (fromMe === 0 || fromMe === 1)) return [{ role: fromMe === 1 ? "user" : "other", text: body, at }];
  return [];
}

/** 只从当前这件事取正文。屏幕、浏览器即使有补写修正，也只提供时间骨架。 */
export function dayEvidence(hub: HubDB, refs: DayReference[], start: number, end: number, limit: number): DayEvidence[] {
  const buckets = new Map<string, Omit<DayEvidence, "key">[]>();
  for (const reference of refs) {
    if (["mac.screen", "mac.browser", "mac.app"].includes(reference.source)) continue;
    const original = hub.get(reference.id), latest = hub.effective(reference.id);
    if (!original || !latest || original.sensitivity === "private" || latest.sensitivity === "private") continue;
    for (const entry of spoken(latest, original, end)) {
      const at = Date.parse(entry.at), text = entry.text.trim();
      if (!(at >= start && at < end) || !text) continue;
      const key = JSON.stringify([entry.role, original.source]);
      const bucket = buckets.get(key) ?? [];
      bucket.push({ ...entry, source: original.source, text: excerpt(text, entry.role === "user" ? 600 : 350), reference });
      buckets.set(key, bucket);
    }
  }
  // 每件事保留双方和较少见的来源，不让长会话挤掉较短的发言。
  const each = Math.max(1, Math.floor(limit / Math.max(1, buckets.size)));
  const sample = [...buckets.values()].flatMap(group => {
    if (group.length <= each) return group;
    if (each === 1) return [group.at(-1)!];
    return Array.from({ length: each }, (_, i) => group[Math.round(i * (group.length - 1) / (each - 1))]!);
  });
  return sample.sort((a, b) => Date.parse(a.at) - Date.parse(b.at)).map((entry, i) => ({ ...entry, key: `r${i + 1}` }));
}
