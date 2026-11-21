import type { RecordV1 } from "../../../packages/record/index.ts";
import { ANDROID_WECHAT, chatKey, notificationMessage } from "../chat.ts";
import type { HubDB } from "../db.ts";

const WINDOW_MS = 2 * 60_000;
type Message = Pick<RecordV1, "source" | "title" | "body" | "context" | "t_start">;
type MessageRow = Omit<Message, "context"> & { id: string; context: string | null };
const messageOf = (row: MessageRow): Message => ({ ...row, context: row.context ? JSON.parse(row.context) : undefined });
const nameKey = (name: string) => chatKey(name.normalize("NFC"));
const conversationKey = (name: string) => nameKey(name.replace(/\s*[（(]\s*\d+\s*[）)]\s*$/u, ""));
const textKey = (text: string) => text.normalize("NFC").replace(/\s+/gu, " ").trim();

function samePreview(body: string, preview: string) {
  const full = textKey(body), phone = textKey(preview);
  if (!full || !phone) return false;
  if (full === phone) return true;
  const prefix = phone.replace(/(?:\.{3}|…)+$/u, "").trimEnd();
  // 缺失截断标记时需要更长的共同前缀，避免把同一人刚发的短回复一起去掉。
  return Array.from(prefix).length >= (prefix === phone ? 8 : 4) && full.startsWith(prefix);
}

function couldBeWeChat(phone: Message) {
  return phone.source === "android.notification" && (!phone.context?.app || phone.context.app === ANDROID_WECHAT);
}

function sameMessage(mac: Message, phone: Message) {
  if (!couldBeWeChat(phone) || mac.context?.extra?.from_me === 1) return false;
  const chat = mac.context?.chat, sender = mac.context?.extra?.sender;
  if (!chat || typeof sender !== "string" || !sender.trim() || conversationKey(chat) !== conversationKey(phone.title)) return false;
  const preview = notificationMessage(phone.body);
  if (preview.sender && nameKey(preview.sender) === nameKey(sender) && samePreview(mac.body, preview.text)) return true;
  // 私聊旧通知没有独立发送人；只有对方就是会话名才用整条正文比较。
  return mac.context?.extra?.group !== 1 && nameKey(sender) === nameKey(chat) && samePreview(mac.body, phone.body);
}

export function wechatRecordForNotification(hub: HubDB, phone: Message): string | null {
  if (!couldBeWeChat(phone)) return null;
  const at = Date.parse(phone.t_start);
  const nearby = hub.db.prepare<[number, number, number], MessageRow>(`SELECT id,source,title,body,context,t_start FROM records
    WHERE t_start_ms BETWEEN ? AND ? AND source='mac.wechat' ORDER BY ABS(t_start_ms-?),id`);
  for (const row of nearby.iterate(at - WINDOW_MS, at + WINDOW_MS, at)) if (sameMessage(messageOf(row), phone)) return row.id;
  return null;
}

/** 只重算已用来命名候选或整理事项的通知；其余记录在正常读取时去重。 */
export function usedNotificationsMatching(hub: HubDB, macs: Iterable<Message>, throughRowid = Number.MAX_SAFE_INTEGER) {
  const nearby = hub.db.prepare<[number, number, number], MessageRow>(`SELECT r.id,r.source,r.title,r.body,r.context,r.t_start
    FROM records r JOIN frame_records fr ON fr.record_id=r.id JOIN frames f ON f.id=fr.frame_id
    WHERE r.t_start_ms BETWEEN ? AND ? AND r.rowid<=? AND r.source='android.notification' AND f.status IN ('candidate','assigned')`);
  const affected = new Map<string, Message>();
  for (const mac of macs) {
    const at = Date.parse(mac.t_start);
    for (const candidate of nearby.iterate(at - WINDOW_MS, at + WINDOW_MS, throughRowid)) {
      const phone = messageOf(candidate);
      if (sameMessage(mac, phone)) affected.set(candidate.id, phone);
    }
  }
  return affected;
}

export function notificationsShadowedSince(hub: HubDB, lastRowid: number) {
  if (!lastRowid) return [];
  const rows = hub.db.prepare<[number], MessageRow>(`SELECT id,source,title,body,context,t_start FROM records
    WHERE rowid>? AND source='mac.wechat'`).all(lastRowid);
  return [...usedNotificationsMatching(hub, rows.map(messageOf), lastRowid).keys()];
}
