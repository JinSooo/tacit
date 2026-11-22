import type { RecordV1 } from "../../packages/record/index.ts";

/** 只用于比较；记录和显示名称保留原文。 */
export const chatKey = (name: string): string => name.replace(/\s/gu, "");

type ChatRecord = Pick<RecordV1, "source" | "title" | "context">;
export const recordChat = (record: ChatRecord) => record.context?.chat;
export const chatApp = (record: ChatRecord) => record.context?.app ?? record.source;
