import type { RecordV1 } from "../../packages/record/index.ts";

/** 只用于比较；记录和显示名称保留原文。 */
export const chatKey = (name: string): string => name.replace(/\s/gu, "");

export const ANDROID_WECHAT = "com.tencent.mm";
const MAC_WECHAT = "com.tencent.xinWeChat";
type ChatRecord = Pick<RecordV1, "source" | "title" | "context">;
export const recordChat = (record: ChatRecord) => record.source === "android.notification" ? record.title : record.context?.chat;
export function chatApp(record: ChatRecord) {
  const app = record.context?.app;
  return record.source === "android.notification" && app === ANDROID_WECHAT ? MAC_WECHAT
    : app ?? record.source;
}
export function notificationMessage(body: string) {
  // 手机有发送人时用全角冒号拼接；老版普通通知可能只上传正文。
  const match = /^([^：\r\n]{1,256})：([\s\S]+)$/u.exec(body);
  return match ? { sender: match[1]!.trim(), text: match[2]!.trim() } : { text: body.trim() };
}
