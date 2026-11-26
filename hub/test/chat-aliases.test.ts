import { expect, test } from "bun:test";
import { toLocalIso } from "../../packages/record/index.ts";
import { buildChatAliases, chatAliases } from "../src/chat-aliases.ts";
import { reviewPlan } from "../src/distill/day-review.ts";
import { frameKey } from "../src/distill/frames.ts";
import { updateGeneral } from "../src/general-settings.ts";
import { fixture, setup } from "./helpers.ts";

// 2026-11-26 真实数据的合成版：同一个单聊被识字读成“C合成文科”“C合戊文科”，同一条消息在两个名字下各存了一遍。
const base = Date.parse("2026-11-16T10:00:00"), min = 60_000;
const message = (minute: number, chat: string, body: string, fromMe: 0 | 1 = 0, shown = "10:00") => fixture({
  source: "mac.wechat", t_start: toLocalIso(base + minute * min), body, title: `微信 · ${chat}`,
  context: { app: "com.tencent.xinWeChat", chat, extra: { from_me: fromMe, sender: fromMe ? "我" : chat, group: 0, shown_time: shown } },
});
const row = (chat: string, body: string, me = 0, shown = "10:00") => ({ app: "com.tencent.xinWeChat", chat, me, shown, body });

test("同一条消息出现在只差一个字的两个聊天名下时合成一个聊天，用记录最多的写法", () => {
  const aliases = buildChatAliases([
    row("C合成文科", "展板明天上午送到"), row("C合成文科", "好的", 1), row("C合成文科", "入口那块也换掉"),
    row("C合戊文科", "展板明天上午送到"), row("C合戊文科", "下午三点到现场"), row("C合戊文料", "下午三点到现场"),
  ]);
  expect(aliases.name("com.tencent.xinWeChat", "C合戊文科")).toBe("C合成文科");
  expect(aliases.name("com.tencent.xinWeChat", "C合戊文料")).toBe("C合成文科");
  expect(aliases.name("com.tencent.xinWeChat", "C合成文科")).toBe("C合成文科");
  expect(aliases.variants("合成文科").sort()).toEqual(["合戊文科", "合戊文料"].sort());
  expect(aliases.variants("没关系")).toEqual([]);
});

test("名字相近但只共有一句很短的话、或共有消息但名字差得远，都不合并", () => {
  const aliases = buildChatAliases([
    row("合成张伟群", "收到", 1), row("合成张玮群", "收到", 1),
    row("合成项目甲", "展板明天上午送到"), row("另一个讨论组", "展板明天上午送到"),
    row("図", "展板明天上午送到"), row("国", "展板明天上午送到"),
    row("合成项目1群", "展板明天上午送到"), row("合成项目10群", "展板明天上午送到"),
    row("合成甲组", "展板明天上午送到", 0, ""), row("合成乙组", "展板明天上午送到", 0, ""),
  ]);
  for (const name of ["合成张玮群", "另一个讨论组", "国", "合成项目10群", "合成乙组"]) expect(aliases.name("com.tencent.xinWeChat", name)).toBe(name);
});

test("时间线、事项分组和搜索把同一聊天的几种写法当成一个，重复存下的消息只算一条", () => {
  const ctx = setup();
  try {
    updateGeneral(ctx.db, { language: "zh" });
    const records = [
      message(0, "C合成文科", "展板明天上午送到"), message(1, "C合成文科", "入口那块也换掉"), message(2, "C合成文科", "好的我去安排", 1),
      message(2, "C合成文科", "图例也补上", 1),
      message(3, "C合戊文科", "展板明天上午送到"), message(4, "C合戊文科", "入口那块也换掉"), message(5, "C合戊文科", "下午三点到现场"),
    ];
    ctx.db.ingest(records);
    expect(chatAliases(ctx.db).name("com.tencent.xinWeChat", "C合戊文科")).toBe("C合成文科");
    expect(frameKey(ctx.db.get(records[6]!.id)!, chatAliases(ctx.db))).toBe(frameKey(ctx.db.get(records[0]!.id)!));

    const segments = reviewPlan(ctx.db, base, base + 30 * min).segments;
    expect(segments).toHaveLength(1);
    expect(segments[0]!.records.map(r => r.id).sort()).toEqual(records.map(r => r.id).sort());
    const texts = segments[0]!.evidence.map(e => e.text);
    expect(texts.sort()).toEqual(["下午三点到现场", "入口那块也换掉", "图例也补上", "好的我去安排", "展板明天上午送到"]);
    expect(segments[0]!.evidence.every(e => e.chat === "C合成文科")).toBe(true);

    const found = ctx.db.list(new URLSearchParams({ q: "合成文科" })).records.map(r => r.id);
    expect(found).toContain(records[6]!.id);
  } finally { ctx.cleanup(); }
});
