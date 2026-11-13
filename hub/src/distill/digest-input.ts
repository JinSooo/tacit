import { createHash } from "node:crypto";
import type { FrameView } from "./prompts.ts";
import { withUserStatements } from "./quotes.ts";

export interface DigestPiece { key: string; frameId: string; v: FrameView }
const hash = (value: unknown) => createHash("sha256").update(JSON.stringify(value)).digest("hex");
export const digestFrameSize = (frame: FrameView) => JSON.stringify({ ...frame, records: frame.records.map(withUserStatements) }).length;

/** 详细整理保留所有正文；按序列化后的预算拆片段/记录，不用抽样或截尾代替。 */
export function digestPieces(frames: FrameView[], budget: number): DigestPiece[] {
  const result: DigestPiece[] = [];
  for (const frame of frames) {
    const fingerprint = hash(frame), parts: FrameView[] = [];
    const withRecords = (records: FrameView["records"]): FrameView => ({ ...frame, records });
    const fits = (records: FrameView["records"]) => digestFrameSize(withRecords(records)) + 2 <= budget;
    let records: FrameView["records"] = [];
    const flush = () => { if (records.length) { parts.push(withRecords(records)); records = []; } };
    for (const record of frame.records) {
      if (fits([...records, record])) { records.push(record); continue; }
      flush();
      if (fits([record])) { records.push(record); continue; }
      const points = Array.from(record.excerpt);
      let offset = 0;
      // 同一条原始记录的多段仍用同一个 record id；位置只描述本次输入的覆盖范围。
      const fragment = (end: number) => ({ ...record, excerpt: points.slice(offset, end).join(""), part: { start: offset, end, total: points.length } });
      do {
        let low = offset, high = points.length;
        while (low < high) {
          const mid = Math.ceil((low + high) / 2);
          if (fits([fragment(mid)])) low = mid; else high = mid - 1;
        }
        if (low === offset) throw new Error("记录元信息超出详细整理单批预算");
        parts.push(withRecords([fragment(low)]));
        offset = low;
      } while (offset < points.length);
    }
    flush();
    if (!parts.length) parts.push(withRecords([]));
    for (const [i, v] of parts.entries()) result.push({ key: `${fingerprint}:${i}`, frameId: frame.id, v });
  }
  return result;
}
