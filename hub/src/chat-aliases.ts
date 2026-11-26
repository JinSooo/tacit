import { chatKey } from "./chat.ts";
import type { HubDB } from "./db.ts";

/**
 * 微信对话靠截图识字读聊天名，同一个聊天常被读错一两个字（“童文科”读成“重文科”），旧记录里就有好几种写法。
 * 同一条消息（是不是自己发的、规整后的内容、上方的时间分隔都相同）在两个只差一两个字的名字下都出现过，
 * 就认定是同一个聊天，统一成记录最多的写法。规则和采集端 ChatNameResolver 一致；记录本身不改。
 */
export class ChatAliases {
  constructor(private readonly canonical: ReadonlyMap<string, string>, private readonly groups: readonly string[][]) {}

  /** 这个聊天名该显示、分组时用的写法；没有别的写法时原样返回。 */
  name(app: string, chat: string): string {
    return this.canonical.get(node(app, chat)) ?? chat;
  }

  /** 搜索词落在某个聊天名里时，换成同一聊天其他写法里对应的那几个字。 */
  variants(term: string): string[] {
    const found = new Set<string>();
    for (const spellings of this.groups) {
      for (const spelling of spellings) {
        const at = spelling.indexOf(term);
        if (at < 0) continue;
        const chars = Array.from(spelling), start = Array.from(spelling.slice(0, at)).length, size = Array.from(term).length;
        for (const other of spellings) {
          if (other === spelling) continue;
          const otherChars = Array.from(other);
          if (otherChars.length === chars.length) found.add(otherChars.slice(start, start + size).join(""));
          else if (term === spelling) found.add(other);
        }
      }
    }
    found.delete(term);
    return [...found].filter(Boolean).slice(0, 12);
  }
}

const node = (app: string, chat: string) => `${app}\u0000${chatKey(chat)}`;
const normalized = (text: string) => text.replace(/[^\p{L}\p{N}]/gu, "");

/** 两个名字（已去空白）只差一个字；6 个字以上允许差两个。单字名、只差数字的（“项目1群”“项目2群”）不算。 */
export function nearChatNames(a: string, b: string): boolean {
  const x = Array.from(a), y = Array.from(b);
  if (a === b) return true;
  if (Math.min(x.length, y.length) < 2 || a.replace(/\p{N}/gu, "") === b.replace(/\p{N}/gu, "")) return false;
  const limit = Math.max(x.length, y.length) >= 6 ? 2 : 1;
  if (Math.abs(x.length - y.length) > limit) return false;
  let prev = Array.from({ length: y.length + 1 }, (_, j) => j);
  for (let i = 1; i <= x.length; i++) {
    const cur = [i];
    for (let j = 1; j <= y.length; j++) cur[j] = Math.min(prev[j]! + 1, cur[j - 1]! + 1, prev[j - 1]! + (x[i - 1] === y[j - 1] ? 0 : 1));
    prev = cur;
  }
  return prev[y.length]! <= limit;
}

type Row = { app: string | null; chat: string; me: number | null; shown: string | null; body: string };

/** 记录按新增逐条加进来；聚类每次从内存里的计数重算，不再读库。 */
class AliasIndex {
  private readonly spellings = new Map<string, Map<string, number>>();
  private readonly messages = new Map<string, Set<string>>();

  add(row: Row) {
    const app = row.app ?? "mac.wechat", id = node(app, row.chat);
    const counts = this.spellings.get(id) ?? new Map<string, number>();
    counts.set(row.chat, (counts.get(row.chat) ?? 0) + 1);
    this.spellings.set(id, counts);
    // 没有时间分隔的消息不能当作“同一条”的证据：不同聊天里的同一句话太容易撞上。
    const text = normalized(row.body);
    if (!text || !row.shown) return;
    const content = [app, row.me ?? "", text, row.shown ?? ""].join("\u0000");
    const owners = this.messages.get(content) ?? new Set<string>();
    owners.add(id);
    this.messages.set(content, owners);
  }

  aliases(): ChatAliases {
    const { spellings, messages } = this;
    const shared = new Map<string, { count: number; strong: boolean }>();
    for (const [content, owners] of messages) {
      if (owners.size < 2 || owners.size > 6) continue;
      const strong = Array.from(content.split("\u0000")[2]!).length >= 4, ids = [...owners].sort();
      for (let i = 0; i < ids.length; i++) for (let j = i + 1; j < ids.length; j++) {
        const pair = `${ids[i]}\u0001${ids[j]}`, seen = shared.get(pair) ?? { count: 0, strong: false };
        shared.set(pair, { count: seen.count + 1, strong: seen.strong || strong });
      }
    }
    const parent = new Map<string, string>();
    const find = (id: string): string => {
      let root = id;
      while (parent.has(root)) root = parent.get(root)!;
      return root;
    };
    for (const [pair, { count, strong }] of shared) {
      const [a, b] = pair.split("\u0001") as [string, string];
      const [appA, keyA] = a.split("\u0000") as [string, string], [appB, keyB] = b.split("\u0000") as [string, string];
      if (appA !== appB || !(strong || count >= 2) || !nearChatNames(keyA, keyB)) continue;
      const ra = find(a), rb = find(b);
      if (ra !== rb) parent.set(rb, ra);
    }
    const clusters = new Map<string, string[]>();
    for (const id of spellings.keys()) {
      const root = find(id);
      clusters.set(root, [...clusters.get(root) ?? [], id]);
    }
    const total = (id: string) => [...spellings.get(id)!.values()].reduce((n, v) => n + v, 0);
    const display = (id: string) => [...spellings.get(id)!.entries()].sort((a, b) => b[1] - a[1] || a[0].localeCompare(b[0]))[0]![0];
    const canonical = new Map<string, string>(), groups: string[][] = [];
    for (const ids of clusters.values()) {
      if (ids.length < 2) continue;
      const main = display([...ids].sort((a, b) => total(b) - total(a) || a.localeCompare(b))[0]!);
      for (const id of ids) canonical.set(id, main);
      groups.push(ids.flatMap(id => [...spellings.get(id)!.keys()]));
    }
    return new ChatAliases(canonical, groups);
  }
}

export function buildChatAliases(rows: Iterable<Row>): ChatAliases {
  const index = new AliasIndex();
  for (const row of rows) index.add(row);
  return index.aliases();
}

const WECHAT = "source='mac.wechat' AND json_type(context,'$.chat')='text'";
const cache = new WeakMap<HubDB, { count: number; last: number; index: AliasIndex; aliases: ChatAliases }>();

/** 按库里全部微信对话记录算。只有新增时只读新增的记录；有记录被删时整个重算。 */
export function chatAliases(db: HubDB): ChatAliases {
  const mark = db.db.prepare(`SELECT COUNT(*) n, COALESCE(MAX(rowid),0) m FROM records WHERE ${WECHAT}`).get() as { n: number; m: number };
  const cached = cache.get(db);
  if (cached && cached.count === mark.n && cached.last === mark.m) return cached.aliases;
  const read = (after: number) => db.db.prepare<[number], Row>(`SELECT json_extract(context,'$.app') app, json_extract(context,'$.chat') chat,
      json_extract(context,'$.extra.from_me') me, json_extract(context,'$.extra.shown_time') shown, body
    FROM records WHERE ${WECHAT} AND rowid>?`).all(after);
  let index = cached?.index, added = cached ? read(cached.last) : [];
  if (!index || cached!.count + added.length !== mark.n) { index = new AliasIndex(); added = read(0); }
  for (const row of added) index.add(row);
  const aliases = index.aliases();
  cache.set(db, { count: mark.n, last: mark.m, index, aliases });
  return aliases;
}
