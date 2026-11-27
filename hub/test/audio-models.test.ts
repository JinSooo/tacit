import { expect, test } from "bun:test";
import { createHash } from "node:crypto";
import { existsSync, mkdirSync, mkdtempSync, readdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { spawnSync } from "node:child_process";
import { AUDIO_MODELS, MIRROR, audioModelsErrorCategory, ensureAudioModels, rankDownloadSources, type Model } from "../src/audio-models.ts";

const sha = (s: string) => createHash("sha256").update(s).digest("hex");

test("单独下载失败时从整包取，逐个校验；已校验的文件不再下载", async () => {
  const root = mkdtempSync(join(tmpdir(), "ra-models-")), dir = join(root, "models");
  try {
    const pack = join(root, "pack"); mkdirSync(join(pack, "bundle"), { recursive: true });
    writeFileSync(join(pack, "bundle/model.bin"), "model");
    expect(spawnSync("/usr/bin/tar", ["-cjf", join(root, "bundle.tar.bz2"), "-C", pack, "bundle"]).status).toBe(0);
    const archive = readFileSync(join(root, "bundle.tar.bz2"));
    const models: Model[] = [
      { file: "vad.onnx", sha256: [sha("vad")], urls: ["https://x/vad"] },
      { file: "sense/model.bin", sha256: [sha("model")], urls: ["https://x/model"], archive: { url: "https://x/bundle.tar.bz2", member: "bundle/model.bin" } },
    ];
    const requested: string[] = [];
    const fetcher = (async (url: string) => {
      requested.push(url);
      if (url === "https://x/vad") return new Response("vad");
      if (url === "https://x/bundle.tar.bz2") return new Response(archive);
      return new Response("", { status: 404 });
    }) as unknown as typeof fetch;
    await ensureAudioModels(dir, { fetcher, models });
    expect(readFileSync(join(dir, "vad.onnx"), "utf8")).toBe("vad");
    expect(readFileSync(join(dir, "sense/model.bin"), "utf8")).toBe("model");
    expect(readdirSync(dir).filter(n => n.startsWith(".download-"))).toEqual([]);
    requested.length = 0;
    await ensureAudioModels(dir, { fetcher, models });
    expect(requested).toEqual([]);
  } finally { rmSync(root, { recursive: true, force: true }); }
});

test("内容和校验值不符时报错，不留下半成品", async () => {
  const root = mkdtempSync(join(tmpdir(), "ra-models-")), dir = join(root, "models");
  try {
    const fetcher = (async () => new Response("tampered")) as unknown as typeof fetch;
    await expect(ensureAudioModels(dir, { fetcher, models: [{ file: "vad.onnx", sha256: [sha("vad")], urls: ["https://x/vad"] }] })).rejects.toThrow("校验失败");
    expect(existsSync(join(dir, "vad.onnx"))).toBe(false);
    expect(readdirSync(dir)).toEqual([]);
  } finally { rmSync(root, { recursive: true, force: true }); }
});

test("HTTPS 下载的每一跳都要求 HTTPS；初始 HTTP 的测试源仍可重定向", async () => {
  const dir = mkdtempSync(join(tmpdir(), "ra-models-"));
  const seen: string[] = [];
  const origin = "https://models.example.invalid";
  const cleartext = "http://models.example.invalid";
  const fetcher: Parameters<typeof rankDownloadSources>[1] = async input => {
    const url = String(input);
    seen.push(url);
    if (url.endsWith("/start")) return new Response(null, { status: 302, headers: { Location: "/next" } });
    if (url.endsWith("/next")) return new Response(null, { status: 307, headers: { Location: cleartext + "/artifact" } });
    return new Response("fixture model");
  };
  const download = (base: string) => ensureAudioModels(dir, {
    fetcher, wait: async () => {},
    models: [{ file: "fixture.bin", sha256: [sha("fixture model")], urls: [base + "/start"] }],
  });
  try {
    expect(await download(origin).catch(audioModelsErrorCategory)).toBe("network");
    expect(seen.length).toBeGreaterThan(0);
    expect(new Set(seen)).toEqual(new Set([origin + "/start", origin + "/next"]));
    seen.length = 0;
    await download(cleartext);
    expect(seen).toEqual(["/start", "/next", "/artifact"].map(path => cleartext + path));
    expect(readFileSync(join(dir, "fixture.bin"), "utf8")).toBe("fixture model");
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

// 回归：约 240MB 的模型下到一半连接被重置就整个失败（2026-11-19 实测 23 分钟后 ECONNRESET）。
test("下载中途断线时从断点续传", async () => {
  const root = mkdtempSync(join(tmpdir(), "ra-models-")), dir = join(root, "models");
  try {
    const body = "0123456789".repeat(1000), ranges: (string | null)[] = [];
    let calls = 0;
    const fetcher = (async (_url: string, init?: RequestInit) => {
      const range = new Headers(init?.headers).get("range"); ranges.push(range);
      if (calls++ === 0) {
        // 先给出一部分再断开。
        let sent = false;
        return new Response(new ReadableStream({ pull(c) { if (sent) c.error(new Error("ECONNRESET")); else { sent = true; c.enqueue(new TextEncoder().encode(body.slice(0, 4000))); } } }));
      }
      const from = Number(/bytes=(\d+)-/.exec(range ?? "")?.[1] ?? 0);
      return new Response(body.slice(from), { status: from ? 206 : 200 });
    }) as unknown as typeof fetch;
    await ensureAudioModels(dir, { fetcher, wait: async () => {}, models: [{ file: "m.bin", sha256: [sha(body)], urls: ["https://x/m"] }] });
    expect(readFileSync(join(dir, "m.bin"), "utf8")).toBe(body);
    expect(ranges).toEqual([null, "bytes=4000-"]);
  } finally { rmSync(root, { recursive: true, force: true }); }
});

// 回归：上游 2026-11-19 重传声纹模型后校验值变了，之后新装的人录音一直卡在“语音模型下载或校验失败”。
test("认可的任一版本都能装上，已装的旧版不重下，其他内容仍被拒", async () => {
  const root = mkdtempSync(join(tmpdir(), "ra-models-")), dir = join(root, "models");
  try {
    const model: Model = { file: "speaker.onnx", sha256: [sha("old"), sha("new")], urls: ["https://mirror/speaker", "https://upstream/speaker"] };
    const requested: string[] = [];
    let served = "new";
    const fetcher = (async (url: string, init?: RequestInit) => {
      if (new Headers(init?.headers).has("Range")) {
        return url === "https://mirror/speaker" ? new Response("probe") : new Response(null, { status: 404 });
      }
      requested.push(url);
      return url === "https://mirror/speaker" ? new Response("", { status: 404 }) : new Response(served);
    }) as unknown as typeof fetch;
    await ensureAudioModels(dir, { fetcher, models: [model] });
    expect(readFileSync(join(dir, "speaker.onnx"), "utf8")).toBe("new");
    expect(requested).toEqual(["https://mirror/speaker", "https://upstream/speaker"]);

    writeFileSync(join(dir, "speaker.onnx"), "old");
    requested.length = 0;
    await ensureAudioModels(dir, { fetcher, models: [model] });
    expect(requested).toEqual([]);

    rmSync(join(dir, "speaker.onnx"));
    served = "tampered";
    await expect(ensureAudioModels(dir, { fetcher, models: [model] })).rejects.toThrow("校验失败");
    expect(existsSync(join(dir, "speaker.onnx"))).toBe(false);
  } finally { rmSync(root, { recursive: true, force: true }); }
});

test("SenseVoice 有 ModelScope、Release 和 Hugging Face 候选，校验值与契约一致", () => {
  const contract = readFileSync(join(import.meta.dir, "../../docs/contracts.md"), "utf8");
  for (const model of AUDIO_MODELS) {
    if (model.file.startsWith("sense-voice/")) {
      const file = model.file.slice("sense-voice/".length);
      expect(model.urls).toEqual([
        `https://www.modelscope.cn/models/pengzhendong/sherpa-onnx-sense-voice-zh-en-ja-ko-yue/resolve/master/${file}`,
        `${MIRROR}/sense-voice-${file}`,
        `https://huggingface.co/csukuangfj/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2024-07-17/resolve/main/${file}`,
      ]);
    } else {
      expect(model.urls[0]!.startsWith(`${MIRROR}/`)).toBe(true);
      expect(model.urls.length).toBeGreaterThan(1);
    }
    for (const hash of model.sha256) expect(contract).toContain(hash);
  }
});

test("下载源并行探测，按吞吐排序，保留探测失败的候选兜底", async () => {
  const slow = "https://slow.example.invalid/model", fast = "https://fast.example.invalid/model";
  const broken = "https://broken.example.invalid/model", unavailable = "https://unavailable.example.invalid/model";
  const started: string[] = [];
  const ranked = rankDownloadSources([broken, slow, unavailable, fast], async (url, init) => {
    const address = String(url);
    started.push(address);
    expect(new Headers(init?.headers).get("Range")).toBe("bytes=0-1048575");
    if (address === broken) throw new Error("connection failed");
    if (address === unavailable) return new Response(null, { status: 503 });
    if (address === slow) await Bun.sleep(40);
    return new Response(new Uint8Array(1024 * 1024), { status: 206 });
  });
  expect(started).toEqual([broken, slow, unavailable, fast]);
  const sources = await ranked;
  expect(sources.map(({ url }) => url)).toEqual([fast, slow, broken, unavailable]);
  expect(sources[0]!.bytesPerSecond!).toBeGreaterThan(sources[1]!.bytesPerSecond!);
  expect(sources.slice(2)).toEqual([{ url: broken }, { url: unavailable }]);
});

test("只有一个候选源时直接下载，无需测速", async () => {
  const url = "https://only.example.invalid/model";
  let probes = 0;
  const ranked = await rankDownloadSources([url], async () => {
    probes++;
    return new Response("probe");
  });
  expect(probes).toBe(0);
  expect(ranked).toEqual([{ url }]);
});

test("ModelScope 内容校验失败时尝试 GitHub 副本", async () => {
  const dir = mkdtempSync(join(tmpdir(), "ra-models-"));
  try {
    const model = AUDIO_MODELS.find(item => item.file === "sense-voice/model.int8.onnx")!;
    const requested: string[] = [];
    const logs: string[] = [];
    const fetcher = (async (url: string, init?: RequestInit) => {
      if (new Headers(init?.headers).has("Range")) {
        return url === model.urls[0] ? new Response("probe") : new Response(null, { status: 404 });
      }
      requested.push(url);
      return new Response(url === `${MIRROR}/sense-voice-model.int8.onnx` ? "valid" : "tampered");
    }) as unknown as typeof fetch;
    await ensureAudioModels(dir, { fetcher, log: message => logs.push(message), models: [{ ...model, sha256: [sha("valid")] }] });
    expect(requested).toEqual([model.urls[0]!, model.urls[1]!]);
    expect(logs).toEqual([expect.stringMatching(/^下载 www\.modelscope\.cn \d+ KiB\/s$/), "下载 github.com"]);
    expect(readFileSync(join(dir, model.file), "utf8")).toBe("valid");
    expect(readdirSync(dir)).toEqual(["sense-voice"]);
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

test("下载等响应或等下一块数据超时都会重试，已收到的块从 Range 续传", async () => {
  const root = mkdtempSync(join(tmpdir(), "ra-models-")), dir = join(root, "models");
  const text = "first-second-third-fourth-fifth", seen: (string | null)[] = [];
  const encoder = new TextEncoder();
  const server = Bun.serve({
    hostname: "127.0.0.1", port: 0,
    async fetch(request) {
      const range = request.headers.get("range");
      seen.push(range);
      if (seen.length === 1) {
        await Bun.sleep(500);
        return new Response("late headers");
      }
      if (seen.length === 2) {
        return new Response(new ReadableStream({ start(c) { c.enqueue(encoder.encode("first")); } }));
      }
      const chunks = ["-second", "-third", "-fourth", "-fifth"];
      return new Response(new ReadableStream({
        async pull(c) {
          await Bun.sleep(60);
          c.enqueue(encoder.encode(chunks.shift()!));
          if (!chunks.length) c.close();
        },
      }), { status: 206 });
    },
  });
  try {
    await ensureAudioModels(dir, { idleTimeoutMs: 150, wait: async () => {},
      models: [{ file: "m.bin", sha256: [sha(text)], urls: [server.url.href] }] });
    expect(readFileSync(join(dir, "m.bin"), "utf8")).toBe(text);
    expect(seen).toEqual([null, null, "bytes=5-"]);
  } finally {
    await server.stop(true);
    rmSync(root, { recursive: true, force: true });
  }
});

test("下载重定向到本机时重新选择代理", async () => {
  const root = mkdtempSync(join(tmpdir(), "ra-models-"));
  const origin = Bun.serve({ hostname: "127.0.0.1", port: 0, fetch: () => new Response("local") });
  const seen: string[] = [];
  const proxy = Bun.serve({ hostname: "127.0.0.1", port: 0, fetch: req => {
    seen.push(req.url);
    return Response.redirect(origin.url);
  } });
  const previous = process.env.http_proxy;
  try {
    process.env.http_proxy = proxy.url.href;
    const external = "http://audio-model-proxy.example.invalid/model";
    await ensureAudioModels(root, { models: [{ file: "m.bin", sha256: [sha("local")], urls: [external] }] });
    expect(readFileSync(join(root, "m.bin"), "utf8")).toBe("local");
    expect(seen).toEqual([external]);
  } finally {
    if (previous === undefined) delete process.env.http_proxy; else process.env.http_proxy = previous;
    await Promise.all([origin.stop(true), proxy.stop(true)]);
    rmSync(root, { recursive: true, force: true });
  }
});

test("audio-models 失败时 stderr 最后一行只有固定错误类别", () => {
  const root = mkdtempSync(join(tmpdir(), "ra-models-cli-"));
  const cli = join(import.meta.dir, "../src/cli.ts");
  const args = [process.execPath, cli, "audio-models"];
  try {
    const file = join(root, "data-as-file");
    writeFileSync(file, "");
    for (const [extra, category] of [[[], "disk"], [["unexpected"], "unknown"]] as const) {
      const child = Bun.spawnSync([...args, ...extra], { env: { ...process.env, HOME: root, RA_DATA_DIR: file } });
      expect(child.exitCode).toBe(1);
      expect(child.stderr.toString()).toBe(`audio_models_error:${category}\n`);
    }
  } finally { rmSync(root, { recursive: true, force: true }); }
});

test("下载、内容校验和坏压缩包分别给出固定错误类别", async () => {
  const root = mkdtempSync(join(tmpdir(), "ra-models-"));
  try {
    const model = { file: "m.bin", sha256: [sha("valid")], urls: ["https://x/model"] };
    const badArchive = { ...model, archive: { url: "https://x/archive", member: "bundle/m.bin" } };
    const cases = [
      { model, fetcher: () => new Response(null, { status: 404 }), category: "network" },
      { model, fetcher: () => new Response("tampered"), category: "checksum" },
      { model: badArchive, fetcher: () => new Response("invalid tar content"), category: "extract" },
    ];
    for (const { model, fetcher, category } of cases) {
      const result = await ensureAudioModels(root, { models: [model], fetcher: async () => fetcher() })
        .then(() => "success", audioModelsErrorCategory);
      expect(result).toBe(category);
    }
  } finally { rmSync(root, { recursive: true, force: true }); }
});
