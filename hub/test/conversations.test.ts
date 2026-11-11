import { afterEach, beforeEach, expect, test } from "bun:test";
import { AudioStore } from "../src/audio.ts";
import { conversationDetail, groupConversations, isNoise, parseTranscript, readableTurns, speakerNamer, type Line } from "../src/conversations.ts";
import { conversationStep, conversationTranscript, type LLM } from "../src/distill/run.ts";
import type { LLMRequest } from "../src/llm/index.ts";
import { historySegments } from "../src/history.ts";
import { fixture, setup } from "./helpers.ts";
import type { RecordV1 } from "../../packages/record/index.ts";

// 全部是合成的转写文字和假模型，不读用户录音、不调用真实模型。
let ctx: ReturnType<typeof setup>;
beforeEach(() => { ctx = setup(); });
afterEach(() => ctx.cleanup());

const MIN = 60_000;
const at = (hhmmss: string) => `2026-11-11T${hhmmss}+09:00`;
function talk(start: string, end: string, body: string, extra: Partial<RecordV1> = {}): RecordV1 {
  return fixture({ source: "mac.audio", source_ref: `c-${start}`, kind: "span", t_start: at(start), t_end: at(end), title: `对话 · ${start.slice(0, 5)}`, body, capture: { method: "asr" }, context: { app: null }, ...extra });
}
const long = (who: string, clock: string) => `[${clock}] ${who}：${"这一段在说面试准备和薪资结构的事情，内容足够长。".repeat(9)}`;

// 用户报告：一场面试被静音切成五条记录，开会和会后聊天又混在一起。
test("一场对话按会议软件和间隔合并，开会和不开会的不连在一起", () => {
  const row = (id: string, s: string, e: string, app: string | null) => ({ id, start_ms: Date.parse(at(s)), end_ms: Date.parse(at(e)), app, private: false });
  const groups = groupConversations([
    row("a", "10:26:36", "10:34:43", null), row("b", "10:41:34", "11:10:28", null), row("c", "11:13:49", "11:17:50", null),
    row("d", "15:57:01", "15:59:43", "com.tencent.meeting"), row("e", "16:03:27", "16:45:11", "com.tencent.meeting"),
    row("f", "16:46:23", "17:17:24", null), row("g", "17:40:00", "17:41:00", null),
  ]);
  expect(groups.map(g => g.record_ids)).toEqual([["a", "b", "c"], ["d", "e"], ["f"], ["g"]]);
  expect(groups[0]!.end_ms).toBe(Date.parse(at("11:17:50")));
});

test("转写去掉语气词、假名碎片和两路录到的同一句，同一个人接着说的合成一段", () => {
  expect(["Yeah.", "The.", "うん。", "嗯嗯。", "あ。", "被から？", "好。", "对对"].every(isNoise)).toBe(true);
  expect(isNoise("React 组件")).toBe(false);
  expect(["可以听到我们说话吗？", "目前的月薪是17000"].some(isNoise)).toBe(false);
  const lines = parseTranscript([
    "[16:03:31] 未知说话人：哎，你好。", "[16:03:31] 说话人 NR：哎，你好。", "[16:03:38] 说话人 NR：可以听到我们说话吗",
    "[16:03:41] 我：这个老师的麦好像没有声音。", "[16:03:43] 未知说话人：Yeah.", "[16:03:45] 我：稍等一下", "[16:05:30] 我：好了",
    "[16:05:31] 我：现在可以了吧", "不是转写行",
  ].join("\n"), at("16:03:27"));
  expect(lines).toHaveLength(8);
  const turns = readableTurns(lines, l => l === "我" ? "我" : l === "说话人 NR" ? "对方 1" : "其他人");
  expect(turns.map(t => [t.speaker, t.text])).toEqual([
    ["其他人", "哎，你好。"], ["对方 1", "可以听到我们说话吗"], ["我", "这个老师的麦好像没有声音。稍等一下"], ["我", "现在可以了吧"],
  ]);
});

test("跨过午夜的转写行算到第二天", () => {
  const lines = parseTranscript("[23:59:50] 我：快到十二点了\n[00:00:10] 我：过了十二点", "2026-11-10T23:59:40+09:00");
  expect(lines[1]!.at_ms - lines[0]!.at_ms).toBe(20_000);
});

test("说话人按现在的状态叫：确认的写名字，并走的跟过去，没确认的按出场顺序编号", () => {
  const audio = new AudioStore(ctx.db);
  const v = (axis: number) => { const x = Array<number>(512).fill(0); x[axis] = 1; return x; };
  const ids = audio.embeddings({ device: "mac", conversation_ref: "r1", t_start: at("10:00:00"), t_end: at("10:10:00"),
    speakers: [0, 1, 2, 3].map(i => ({ local: `S${i}`, track: "mic", seconds: 120, centroid: v(i) })) }).speakers.map(s => s.speaker_id);
  const label = (id: string) => audio.speaker(id)!.label;
  const [a, b, c, d] = ids as [string, string, string, string];
  audio.resolve(a, "rename", "李家辰");
  audio.resolve(b, "merge_into", undefined, a);
  const name = speakerNamer(ctx.db)();
  expect([label(a), label(b), label(d), label(c), "我", "未知说话人", "刘朝刚"].map(l => name(l))).toEqual(["李家辰", "李家辰", "对方 1", "对方 2", "我", "其他人", "刘朝刚"]);
  expect(speakerNamer(ctx.db)()(label(c))).toBe("对方 1");
});

function fakeLLM(out: { title: string; summary: string; points: string[] } | null = { title: "线上面试复盘", summary: "我和同事复盘了刚结束的面试。", points: ["等对方反馈"] }) {
  const calls: LLMRequest[] = [];
  const llm: LLM = { async complete<T>(req: LLMRequest) { calls.push(req); return out ? { ok: true as const, data: out as T, ms: 1 } : { ok: false as const, error: "模型不可用", ms: 1 }; } };
  return { llm, calls };
}

test("对话结束 10 分钟后才写总结；太短、私密的不写；写完列表用总结标题", async () => {
  ctx.db.ingest([
    talk("10:00:00", "10:20:00", [long("我", "10:00:05"), long("说话人 A", "10:01:00")].join("\n")),
    talk("10:25:00", "10:30:00", long("我", "10:25:05")),
    talk("12:00:00", "12:01:00", "[12:00:05] 我：喂"),
    talk("13:00:00", "13:20:00", long("我", "13:00:05"), { sensitivity: "private" }),
  ]);
  const { llm, calls } = fakeLLM();
  // 10:35 时上一场才结束 5 分钟，可能还会接上。
  expect((await conversationStep({ db: ctx.db, llm }, Date.parse(at("10:35:00")))).calls).toBe(0);
  const now = Date.parse(at("15:00:00"));
  expect(await conversationStep({ db: ctx.db, llm }, now)).toEqual({ calls: 1, done: 1, pending: 0 });
  expect(calls[0]!.prompt).toContain("对方 1：");
  expect(calls[0]!.prompt).not.toContain("说话人 A");
  expect(calls.some(c => c.prompt.includes("13:00"))).toBe(false);
  const first = ctx.db.db.prepare("SELECT id FROM records WHERE t_start=?").get(at("10:00:00")) as { id: string };
  const detail = conversationDetail(ctx.db, first.id, now);
  expect(detail).toMatchObject({ id: first.id, state: "ready", title: "线上面试复盘", points: ["等对方反馈"] });
  expect(detail.record_ids).toHaveLength(2);
  expect(detail.records.map(r => r.body.slice(0, 12))).toEqual([long("我", "10:00:05").slice(0, 12), long("我", "10:25:05").slice(0, 12)]);
  const short = ctx.db.db.prepare("SELECT id FROM records WHERE t_start=?").get(at("12:00:00")) as { id: string };
  expect(conversationDetail(ctx.db, short.id, now).state).toBe("short");
  const priv = ctx.db.db.prepare("SELECT id FROM records WHERE t_start=?").get(at("13:00:00")) as { id: string };
  expect(conversationDetail(ctx.db, priv.id, now).state).toBe("private");
  const list = historySegments(ctx.db, new URLSearchParams({ from: at("00:00:00"), to: at("23:59:00") })).conversations;
  expect(list.map(c => c.title)).toEqual(["线上面试复盘", null, null]);
  // 已有总结的不再调用。
  expect((await conversationStep({ db: ctx.db, llm }, now)).calls).toBe(0);
});

test("删掉其中一条记录时总结一起删，下一轮按剩下的重写；模型失败不写", async () => {
  ctx.db.ingest([talk("10:00:00", "10:20:00", long("我", "10:00:05")), talk("10:25:00", "10:40:00", long("我", "10:25:05"))]);
  const now = Date.parse(at("15:00:00"));
  await conversationStep({ db: ctx.db, llm: fakeLLM().llm }, now);
  const second = ctx.db.db.prepare("SELECT id FROM records WHERE t_start=?").get(at("10:25:00")) as { id: string };
  expect(ctx.db.delete(second.id)).toBe(true);
  expect(ctx.db.db.prepare("SELECT COUNT(*) n FROM conversation_summaries").get()).toEqual({ n: 0 });
  const failing = fakeLLM(null);
  expect(await conversationStep({ db: ctx.db, llm: failing.llm }, now)).toEqual({ calls: 1, done: 0, pending: 1 });
  expect(failing.calls[0]!.prompt).not.toContain("10:25");
});

test("原文超出预算时留头尾", () => {
  const turns = Array.from({ length: 100 }, (_, i) => ({ at: new Date(Date.parse(at("10:00:00")) + i * MIN).toISOString(), speaker: "我", text: `第${i}句`.padEnd(40, "。") }));
  const text = conversationTranscript(turns, 600);
  expect(text).toContain("第0句"); expect(text).toContain("第99句"); expect(text).toContain("（中间省略）");
  expect(Array.from(text).length).toBeLessThan(620);
});

// 2026-11-11 实测：和李家辰的面试复盘先被移出面试事项，下一轮又被归进开发线程，因为模型只看到转写开头的噪声。
test("归线程时对话片段给的是总结；没有事实可挂时也能把一条对话移出线程，且不能再分回去", async () => {
  const { DistillStore } = await import("../src/distill/store.ts");
  const { frameView, loadFrames, sliceStep } = await import("../src/distill/run.ts");
  ctx.db.ingest([talk("10:00:00", "10:20:00", `[10:00:01] 未知说话人：Yeah.\n${long("我", "10:00:05")}`)]);
  const now = Date.parse(at("15:00:00"));
  const store = new DistillStore(ctx.db);
  store.setState("enabled_ms", Date.parse(at("00:00:00")));
  sliceStep(ctx.db, false, now, Date.parse(at("00:00:00")));
  const frame = store.hub.db.prepare("SELECT frame_id FROM frame_records").get() as { frame_id: string };
  const load = () => loadFrames(store, "WHERE id=?", frame.frame_id)[0]!;
  const opts = { maxRecords: 10, excerpt: () => 240 };
  expect(frameView(store, load(), opts).records[0]!.title).toBe("对话 · 10:00");
  await conversationStep({ db: ctx.db, llm: fakeLLM().llm }, now);
  const view = frameView(store, load(), opts).records[0]!;
  expect(view.title).toBe("对话：线上面试复盘");
  expect(view.excerpt.startsWith("我和同事复盘了刚结束的面试。")).toBe(true);

  store.upsertThread({ id: "t-dev", status: "active", title: "开发对话功能" });
  store.assign(frame.frame_id, "t-dev", "llm", 0.8);
  const record = (ctx.db.db.prepare("SELECT id FROM records").get() as { id: string }).id;
  expect(store.detachRecord(record)).toEqual({ frames: 1, facts: 0, thread: "t-dev" });
  expect(ctx.db.db.prepare("SELECT COUNT(*) n FROM assignments").get()).toEqual({ n: 0 });
  expect(store.rejectedThreads(frame.frame_id)).toEqual(["t-dev"]);
  expect(store.detachRecord(record)).toEqual({ frames: 0, facts: 0, thread: null });
});

// 2026-11-11：旧记录里短句写成"未知说话人"、放歌的歌词进了正文；采集端重认后另存每句是谁、哪句是扬声器声音。
test("采集端重认的每句说话人优先于正文里的叫法，扬声器声音不显示，总结重写", async () => {
  const { AudioStore } = await import("../src/audio.ts");
  const audio = new AudioStore(ctx.db);
  const v = (axis: number) => { const a = Array<number>(512).fill(0); a[axis] = 1; return a; };
  const [li] = audio.embeddings({ device: "mac", conversation_ref: "c-10:00:00", t_start: at("10:00:00"), t_end: at("10:20:00"), speakers: [{ local: "S1", track: "mic", seconds: 200, centroid: v(1) }] }).speakers;
  ctx.db.ingest([talk("10:00:00", "10:20:00", [long("我", "10:00:05"), "[10:01:00] 未知说话人：好，给我看懵了，几个人啊", "[10:02:00] 说话人 E：在清晨把自己踩进了你"].join("\n"))]);
  const record = (ctx.db.db.prepare("SELECT id FROM records").get() as { id: string }).id;
  const now = Date.parse(at("15:00:00"));
  await conversationStep({ db: ctx.db, llm: fakeLLM().llm }, now);
  expect(conversationDetail(ctx.db, record, now).state).toBe("ready");
  await new DistillStoreForTest(ctx.db).resolve(li!.speaker_id, "李家辰");
  expect(audio.lines({ device: "mac", conversation_ref: "c-10:00:00", lines: [
    { at: "10:01:00", speaker_id: li!.speaker_id, hidden: false }, { at: "10:02:00", speaker_id: null, hidden: true },
  ] })).toEqual({ stored: 2 });
  const d = conversationDetail(ctx.db, record, now);
  expect(d.turns.map(t => t.speaker)).toEqual(["我", "李家辰"]);
  expect(d.turns.some(t => t.text.includes("清晨"))).toBe(false);
  expect(d.state).toBe("waiting");
  expect(() => audio.lines({ device: "ipad", conversation_ref: "c-10:00:00", lines: [] })).toThrow();
  expect(() => audio.lines({ device: "mac", conversation_ref: "c-10:00:00", lines: [{ at: "10:01", speaker_id: null, hidden: false }] })).toThrow();
  expect(() => audio.lines({ device: "mac", conversation_ref: "c-10:00:00", lines: [{ at: "10:01:00", speaker_id: "nobody", hidden: false }] })).toThrow();
  // 删掉记录时一起删
  ctx.db.delete(record);
  expect(ctx.db.db.prepare("SELECT COUNT(*) n FROM conversation_lines").get()).toEqual({ n: 0 });
});

class DistillStoreForTest {
  constructor(readonly db: typeof ctx.db) {}
  resolve(speakerId: string, name: string) {
    const p = (this.db.db.prepare("SELECT id,payload FROM pending WHERE kind='voice' AND resolved_at IS NULL").all() as { id: string; payload: string }[]).find(p => JSON.parse(p.payload).speaker_id === speakerId)!;
    return import("../src/distill/store.ts").then(({ DistillStore }) => new DistillStore(this.db).resolvePending(p.id, "rename", name));
  }
}
