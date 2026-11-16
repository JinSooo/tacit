import { toLocalIso, type RecordV1 } from "../../../packages/record/index.ts";
import { parseTranscript } from "../conversations.ts";
import type { HubDB } from "../db.ts";
import { materialBody } from "./material.ts";
import { excerpt } from "./prompts.ts";

export type DayRole = "user" | "assistant" | "other";
export interface DayEvidenceInput { key: string; source: string; role: DayRole; at: string; text: string }
export interface DayReference { id: string; at: string }
interface DayEvidence extends DayEvidenceInput { reference: DayReference }
interface Spoken { role: DayRole; text: string; at: string }

function spoken(record: RecordV1, original: RecordV1, end: number): Spoken[] {
  const body = materialBody(record);
  const at = original.t_start;
  if (record.source === "manual.correction" || original.source === "manual.note") return [{ role: "user", text: body, at }];
  if (original.source === "mac.audio") return parseTranscript(body, at)
    .filter(line => line.at_ms < end)
    .map(line => ({ role: line.label === "我" ? "user" : "other", text: line.text, at: toLocalIso(line.at_ms) }));
  if (original.source === "codex.session" || original.source === "claude_code.session") {
    // 既有会话记录没有逐条消息时间。截止点穿过整条记录时，无法安全分出最后一段。
    if (Date.parse(original.t_end ?? at) >= end) return [];
    const messages = [...body.matchAll(/(?:^|\n\n)\[(我|AI)\] ([\s\S]*?)(?=\n\n\[(?:我|AI)\] |$)/g)];
    if (messages.some(message => message[1] === "我" && /^Automation: .+\nAutomation ID:/m.test(message[2]!))) return [];
    return messages.map(message => ({ role: message[1] === "我" ? "user" : "assistant", text: message[2]!, at }));
  }
  const fromMe = original.context?.extra?.from_me;
  if (original.context?.chat && (fromMe === 0 || fromMe === 1)) return [{ role: fromMe === 1 ? "user" : "other", text: body, at }];
  return [];
}

export function dayEvidence(hub: HubDB, start: number, end: number): DayEvidence[] {
  const rows = hub.db.prepare(`SELECT id FROM records WHERE t_start_ms>=? AND t_start_ms<? AND sensitivity!='private'
    AND (source IN ('mac.audio','mac.wechat','codex.session','claude_code.session','manual.note')
      OR (source NOT IN ('mac.screen','mac.browser','mac.shell','mac.git','mac.file','mac.clipboard','manual.correction','manual.agent')
        AND json_type(context,'$.chat')='text' AND json_extract(context,'$.extra.from_me') IN (0,1)))
    ORDER BY t_start_ms,id`).all(start, end) as { id: string }[];
  const groups = new Map<string, Omit<DayEvidence, "key">[]>();
  for (const { id } of rows) {
    const original = hub.get(id), latest = hub.effective(id);
    if (!original || !latest || latest.sensitivity === "private") continue;
    for (const entry of spoken(latest, original, end)) {
      const text = entry.text.trim();
      if (!text) continue;
      const bucket = JSON.stringify([original.source, entry.role]);
      const group = groups.get(bucket) ?? [];
      group.push({ ...entry, source: original.source, text: excerpt(text, entry.role === "user" ? 600 : 350),
        reference: { id, at: original.t_start } });
      groups.set(bucket, group);
    }
  }
  // 按来源和角色均匀取样，少量自己的笔记或录音不会被全天 AI 会话挤掉。
  const each = Math.max(1, Math.floor(120 / Math.max(1, groups.size)));
  const selected = [...groups.values()].flatMap(group => group.length <= each ? group
    : Array.from({ length: each }, (_, i) => group[Math.round(i * (group.length - 1) / Math.max(1, each - 1))]!));
  return selected.sort((a,b) => Date.parse(a.at) - Date.parse(b.at)).map((item,i) => ({ ...item, key: `r${i+1}` }));
}

export interface DayCandidate { text: string; refs: string[] }
export interface DayEntry { text: string; evidence: DayReference[] }

export function groundedDay(entries: DayCandidate[], evidence: Map<string, DayEvidence>, role: "any" | "has-user" | "user-only" = "any"): DayEntry[] {
  return entries.flatMap(entry => {
    const text = entry.text.trim(), linked = entry.refs.map(key => evidence.get(key));
    if (!text || !linked.length || linked.some(item => !item)) return [];
    const present = linked.filter(item => item !== undefined);
    if (role === "has-user" && !present.some(item => item.role === "user")) return [];
    if (role === "user-only" && present.some(item => item.role !== "user")) return [];
    return [{ text, evidence: [...new Map(present.map(item => [item.reference.id, item.reference])).values()] }];
  });
}
