import { expect, test } from "bun:test";
import { renderToStaticMarkup } from "react-dom/server";
import { createApi } from "../src/api.ts";
import { createAudioApi, retentionDays, samplePlayback, speakerNames, type Speaker } from "../src/audio.ts";
import { AudioSettings, VoiceSamples } from "../src/audio-views.tsx";
import { VoicePendingRow } from "../src/distillation-views.tsx";
import { createDistillationApi, type Api } from "../src/distillation.ts";
import { sourceNames } from "../src/history.ts";

test("样本带 token 取回原始二进制，不缓存；HTTP 错误和认证失效不会生成音频", async () => {
  const requests: { path: string; init?: RequestInit }[] = [];
  let unauthorized = 0;
  const binary = new Uint8Array([82, 73, 70, 70, 0, 255]);
  const request = (async (path: string, init?: RequestInit) => {
    requests.push({ path, init });
    return new Response(binary, { headers: { "Content-Type": "audio/wav" } });
  });
  const api = createAudioApi(createApi("synthetic-token", () => unauthorized++, request));
  const blob = await api.sample("sample/1");
  expect(new Uint8Array(await blob.arrayBuffer())).toEqual(binary);
  expect(blob.type).toBe("audio/wav");
  expect(requests[0]!.path).toBe("/v1/audio/samples/sample%2F1");
  expect(new Headers(requests[0]!.init?.headers).get("Authorization")).toBe("Bearer synthetic-token");
  expect(requests[0]!.init?.cache).toBe("no-store");
  for (const status of [401, 404, 500]) {
    const failed = createAudioApi(createApi("synthetic", () => unauthorized++, (async () => Response.json({ error: "合成错误" }, { status }))));
    await expect(failed.sample("missing")).rejects.toThrow(status === 401 ? "需要重新打开网页" : "合成错误");
  }
  expect(unauthorized).toBe(1);
});

test("收起、离开和处理后释放 URL；取回未完成就离开不会泄漏 URL", async () => {
  const created: Blob[] = [], revoked: string[] = [];
  const urls = { createObjectURL(blob: Blob) { created.push(blob); return "blob:synthetic"; }, revokeObjectURL(url: string) { revoked.push(url); } };
  for (const _reason of ["收起", "离开", "处理后"]) {
    let signal: AbortSignal | undefined;
    const playback = samplePlayback(async value => { signal = value; return new Blob(["合成音频"]); }, urls as typeof URL);
    expect(await playback.open()).toBe("blob:synthetic");
    playback.dispose(); playback.dispose();
    expect(signal!.aborted).toBe(true);
  }
  expect(revoked).toEqual(["blob:synthetic", "blob:synthetic", "blob:synthetic"]);
  let complete!: (blob: Blob) => void;
  const playback = samplePlayback(() => new Promise(resolve => { complete = resolve; }), urls as typeof URL);
  const opening = playback.open(); playback.dispose(); complete(new Blob(["迟到的样本"]));
  expect(await opening).toBeUndefined(); expect(created).toHaveLength(3);
});

test("新声音动作严格按待确认契约发送；列表和音频设置不读取真实数据", async () => {
  const calls: { path: string; method?: string; body?: unknown }[] = [];
  const fake: Api = async <T,>(path: string, init?: RequestInit) => {
    calls.push({ path, method: init?.method, body: init?.body ? JSON.parse(String(init.body)) : undefined });
    return (path === "/v1/speakers" ? { speakers: [] } : { retention_days: 7 }) as T;
  };
  const distillation = createDistillationApi(fake), audio = createAudioApi(fake);
  for (const resolution of [{ action: "me" }, { action: "rename", name: "合成人名" }, { action: "merge_into", target: "speaker-synthetic" }, { action: "ignore" }] as const) {
    await distillation.resolve("voice/1", resolution);
    expect(calls.at(-1)).toEqual({ path: "/v1/pending/voice%2F1", method: "POST", body: resolution });
  }
  await audio.speakers(); expect(calls.at(-1)!.path).toBe("/v1/speakers");
  await audio.settings(); expect(calls.at(-1)!.path).toBe("/v1/audio/settings");
  await audio.saveSettings("365"); expect(calls.at(-1)).toEqual({ path: "/v1/audio/settings", method: "PUT", body: { retention_days: 365 } });
  await audio.purge(); expect(calls.at(-1)).toEqual({ path: "/v1/audio/purge", method: "POST", body: undefined });
  const count = calls.length;
  for (const value of ["", " ", "0", "366", "1.5", "no", Infinity, NaN, -1]) expect(() => audio.saveSettings(value)).toThrow("1–365");
  expect(calls).toHaveLength(count);
  expect(retentionDays("1")).toBe(1); expect(retentionDays(365)).toBe(365);
});

test("History 显示对话和说话人最新名字，未命名用标签，未知 id 保留且不修改记录", () => {
  const people = ["me", "unnamed", "unknown"];
  const speakers = [{ id: "me", name: "合成名字", label: "说话人 A" }, { id: "unnamed", name: null, label: "说话人 B" }] as Speaker[];
  expect(speakerNames(people, speakers)).toEqual(["合成名字", "说话人 B", "unknown"]);
  expect(people).toEqual(["me", "unnamed", "unknown"]);
  expect(sourceNames["mac.audio"]).toBe("对话");
});

test("新声音显示标签、统计、待取状态和四个操作；设置有边界和清理确认", () => {
  const fake: Api = async <T,>() => ({} as T);
  const audio = createAudioApi(fake);
  const html = renderToStaticMarkup(<VoicePendingRow item={{ id: "voice", kind: "voice", payload: { speaker_id: "synthetic", label: "说话人 A", conversations: 3, seconds: 125, samples: [{ id: "sample", mime: "audio/wav" }], samples_pending: true } }} audio={audio} api={createDistillationApi(fake)} onResolved={() => {}} />);
  for (const text of ["说话人 A", "3 段", "125 秒", "样本待取", "就是我", "填名字", "和某人是同一人", "忽略", "播放样本 1"]) expect(html).toContain(text);
  const samples = renderToStaticMarkup(<VoiceSamples samples={[{ id: "s1", mime: "audio/wav" }, { id: "s2", mime: "audio/mp4" }]} api={audio} />);
  expect(samples.match(/aria-expanded="false"/g)).toHaveLength(2);
  const settings = renderToStaticMarkup(<AudioSettings api={audio} />);
  for (const text of ['min="1"', 'max="365"', 'step="1"', "转写过的文字不受影响", "还没转写的对话会丢失", "确认清理", "取消"]) expect(settings).toContain(text);
});
