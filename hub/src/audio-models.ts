// 录音用的本机语音模型：第一次开启录音时下载到数据目录，逐个校验 sha256 后原子替换。
import { createHash } from "node:crypto";
import { createReadStream, existsSync, mkdirSync, mkdtempSync, renameSync, rmSync, statSync } from "node:fs";
import { open } from "node:fs/promises";
import { dirname, join } from "node:path";
import { spawnSync } from "node:child_process";
import { proxiedFetch } from "./net/system-proxy.ts";

const GITHUB = "https://github.com/k2-fsa/sherpa-onnx/releases/download";
// 我们自己 Release 上的原样副本，排在上游前面：上游重传文件（2026-11-19 换了声纹模型）不会再挡住新安装。
export const MIRROR = "https://github.com/JinSooo/tacit/releases/download/models-v1";
const SENSE = "sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2024-07-17";
const SENSE_MODELSCOPE = "https://www.modelscope.cn/models/pengzhendong/sherpa-onnx-sense-voice-zh-en-ja-ko-yue/resolve/master";
const SPEAKER = "3dspeaker_speech_eres2net_base_sv_zh-cn_3dspeaker_16k.onnx";

export interface Model {
  file: string;
  /** 认可的 sha256；上游重新导出、效果一致的版本一并列上。 */
  sha256: string[];
  /** 候选下载地址，多个地址会先测速。 */
  urls: string[];
  /** 从压缩包取文件时的包内路径；压缩包地址排在 urls 之后，其他地址失败才用。 */
  archive?: { url: string; member: string };
}
export const AUDIO_MODELS: Model[] = [
  { file: "silero_vad.onnx", sha256: ["9e2449e1087496d8d4caba907f23e0bd3f78d91fa552479bb9c23ac09cbb1fd6"],
    urls: [`${MIRROR}/silero_vad.onnx`, `${GITHUB}/asr-models/silero_vad.onnx`] },
  // 上游 2026-11-19 重新导出（多 1 字节、几乎每个字节都变），实测同一段语音两版声纹余弦为 1.000000，两版都认。
  { file: SPEAKER, sha256: ["1a331345f04805badbb495c775a6ddffcdd1a732567d5ec8b3d5749e3c7a5e4b",
    "f1ee61be04000b50392a63442e5dd9feaea7e81dddd494d3647cf1c3d88a1498"],
    urls: [`${MIRROR}/${SPEAKER}`, `${GITHUB}/speaker-recongition-models/${SPEAKER}`] },
  // 单独下载约 240MB；GitHub 只有约 1GB 的整包，单独下载都失败时才用。
  { file: "sense-voice/model.int8.onnx", sha256: ["c71f0ce00bec95b07744e116345e33d8cbbe08cef896382cf907bf4b51a2cd51"],
    urls: [`${SENSE_MODELSCOPE}/model.int8.onnx`, `${MIRROR}/sense-voice-model.int8.onnx`, `https://huggingface.co/csukuangfj/${SENSE}/resolve/main/model.int8.onnx`],
    archive: { url: `${GITHUB}/asr-models/${SENSE}.tar.bz2`, member: `${SENSE}/model.int8.onnx` } },
  { file: "sense-voice/tokens.txt", sha256: ["f449eb28dc567533d7fa59be34e2abca8784f771850c78a47fb731a31429a1dc"],
    urls: [`${SENSE_MODELSCOPE}/tokens.txt`, `${MIRROR}/sense-voice-tokens.txt`, `https://huggingface.co/csukuangfj/${SENSE}/resolve/main/tokens.txt`],
    archive: { url: `${GITHUB}/asr-models/${SENSE}.tar.bz2`, member: `${SENSE}/tokens.txt` } },
];

export async function sha256(file: string): Promise<string> {
  const hash = createHash("sha256");
  for await (const chunk of createReadStream(file)) hash.update(chunk);
  return hash.digest("hex");
}

type AudioModelsErrorCategory = "network" | "checksum" | "disk" | "extract" | "unknown";
class AudioModelsError extends Error {
  constructor(readonly category: AudioModelsErrorCategory, message: string = category) { super(message); }
}
class HttpError extends AudioModelsError {
  constructor(readonly status: number) { super("network"); }
}

export function audioModelsErrorCategory(error: unknown): AudioModelsErrorCategory {
  if (error instanceof AudioModelsError) return error.category;
  const code = (error as NodeJS.ErrnoException | null)?.code;
  return code && /^(EACCES|EDQUOT|EEXIST|EFBIG|EIO|EISDIR|ELOOP|EMFILE|ENAMETOOLONG|ENFILE|ENOENT|ENOSPC|ENOTDIR|EPERM|EROFS|EXDEV)$/.test(code)
    ? "disk" : "unknown";
}

async function fetchModel(url: string, init: RequestInit, fetcher: typeof proxiedFetch): Promise<Response> {
  const allowsHttp = URL.parse(url)?.protocol === "http:";
  for (let redirects = 0; ; redirects++) {
    // 逐跳重新选代理，免得重定向到内网时沿用外网代理。
    const response = await fetcher(url, { ...init, redirect: "manual" });
    const location = response.headers.get("location");
    if (!location || ![301, 302, 303, 307, 308].includes(response.status)) return response;
    void response.body?.cancel().catch(() => {});
    const next = URL.parse(location, url);
    if (redirects === 20 || !next || next.username || next.password ||
        !(next.protocol === "https:" || allowsHttp && next.protocol === "http:")) {
      throw new AudioModelsError("network");
    }
    url = next.href;
  }
}

const PROBE_BYTES = 1024 * 1024;
const PROBE_TIMEOUT_MS = 8_000;
type DownloadSource = { url: string; bytesPerSecond?: number };

async function probeSource(url: string, fetcher: typeof proxiedFetch): Promise<DownloadSource> {
  const controller = new AbortController();
  const started = performance.now();
  let body: ReadableStreamDefaultReader<Uint8Array> | undefined;
  let timer: ReturnType<typeof setTimeout> | undefined;
  const deadline = new Promise<DownloadSource>(resolve => {
    timer = setTimeout(() => resolve({ url }), PROBE_TIMEOUT_MS);
  });
  const measure = async (): Promise<DownloadSource> => {
    const response = await fetchModel(url, {
      signal: controller.signal, headers: { Range: `bytes=0-${PROBE_BYTES - 1}` },
    }, fetcher);
    if (!response.ok || !response.body || controller.signal.aborted) {
      void response.body?.cancel().catch(() => {});
      return { url };
    }
    body = response.body.getReader();
    let bytes = 0;
    while (bytes < PROBE_BYTES) {
      const { done, value } = await body.read();
      if (done) break;
      bytes += Math.min(value.byteLength, PROBE_BYTES - bytes);
    }
    return bytes ? { url, bytesPerSecond: bytes * 1_000 / Math.max(performance.now() - started, 1) } : { url };
  };
  try { return await Promise.race([deadline, measure()]); }
  catch { return { url }; }
  finally {
    clearTimeout(timer);
    void body?.cancel().catch(() => {});
    controller.abort();
  }
}

export async function rankDownloadSources(urls: readonly string[], fetcher: typeof proxiedFetch): Promise<DownloadSource[]> {
  if (urls.length < 2) return urls.map(url => ({ url }));
  const sources = await Promise.all(urls.map(url => probeSource(url, fetcher)));
  return sources.sort((left, right) => (right.bytesPerSecond ?? 0) - (left.bytesPerSecond ?? 0));
}

async function downloadAttempt(url: string, target: string, have: number, o: Required<Options>) {
  const controller = new AbortController();
  const waitForData = async <T>(receive: () => Promise<T>): Promise<T> => {
    let timer: ReturnType<typeof setTimeout> | undefined;
    const deadline = new Promise<never>((_, reject) => {
      timer = setTimeout(() => {
        controller.abort();
        reject();
      }, o.idleTimeoutMs);
    });
    try {
      return await Promise.race([deadline, receive()]);
    } catch { throw new AudioModelsError("network"); }
    finally { clearTimeout(timer); }
  };
  try {
    const response = await fetchModel(url, {
      signal: controller.signal, headers: have ? { Range: `bytes=${have}-` } : {},
    }, (input, init) => waitForData(() => o.fetcher(input, init)));
    if (have && response.status === 416) return;
    if (!response.ok || !response.body) throw new HttpError(response.status);
    // 逐块写盘：断线时已收到的部分留在文件里，下次从这里续传。
    const file = await open(target, have > 0 && response.status === 206 ? "a" : "w");
    const reader = response.body.getReader();
    try {
      for (;;) {
        const { done, value } = await waitForData(() => reader.read());
        if (done) break;
        await file.write(value);
      }
    } finally {
      if (controller.signal.aborted) void reader.cancel().catch(() => {});
      reader.releaseLock();
      await file.close();
    }
  } finally { controller.abort(); }
}

/** 断线或服务端出错时从已下载的位置续传，最多 6 次；4xx 不重试。 */
async function download(url: string, target: string, o: Required<Options>) {
  for (let attempt = 0; attempt < 6; attempt++) {
    if (attempt) await o.wait(Math.min(30_000, 2000 * 2 ** (attempt - 1)));
    const have = existsSync(target) ? statSync(target).size : 0;
    try {
      await downloadAttempt(url, target, have, o);
      return;
    } catch (error) {
      const clientError = error instanceof HttpError && error.status >= 400 && error.status < 500 && ![408, 429].includes(error.status);
      if (clientError || attempt === 5 || audioModelsErrorCategory(error) !== "network") throw error;
      o.log("下载中断，稍后续传");
    }
  }
}

export interface Options {
  fetcher?: typeof proxiedFetch;
  log?: (message: string) => void;
  models?: Model[];
  wait?: (ms: number) => Promise<void>;
  idleTimeoutMs?: number;
}

/** 缺什么下载什么；已有且校验通过的文件不再下载。 */
export async function ensureAudioModels(dir: string, options: Options = {}): Promise<void> {
  const o: Required<Options> = { fetcher: proxiedFetch, log: () => {}, models: AUDIO_MODELS,
    wait: ms => Bun.sleep(ms), idleTimeoutMs: 30_000, ...options };
  const { log, models } = o;
  mkdirSync(dir, { recursive: true });
  const missing: Model[] = [];
  for (const model of models) {
    const file = join(dir, model.file);
    if (!existsSync(file) || !model.sha256.includes(await sha256(file))) missing.push(model);
  }
  if (!missing.length) return;
  const staging = mkdtempSync(join(dir, ".download-"));
  try {
    const archives = new Map<string, string>();
    for (const model of missing) {
      const staged = join(staging, model.file.replaceAll("/", "_"));
      let ok = false;
      let failure = new AudioModelsError("network");
      for (const { url, bytesPerSecond } of await rankDownloadSources(model.urls, o.fetcher)) {
        const rate = bytesPerSecond === undefined ? "" : ` ${Math.round(bytesPerSecond / 1024)} KiB/s`;
        log(`下载 ${URL.parse(url)?.hostname ?? "未知来源"}${rate}`);
        try {
          await download(url, staged, o);
          ok = model.sha256.includes(await sha256(staged));
          if (!ok) failure = new AudioModelsError("checksum", "语音模型校验失败");
        } catch (error) {
          if (audioModelsErrorCategory(error) !== "network") throw error;
          log("下载失败");
        }
        if (ok) break;
        rmSync(staged, { force: true });
      }
      if (!ok && model.archive) {
        let extracted = archives.get(model.archive.url);
        if (!extracted) {
          extracted = join(staging, `archive-${archives.size}`); mkdirSync(extracted);
          const packed = join(staging, `archive-${archives.size}.tar.bz2`);
          log(`下载 ${new URL(model.archive.url).hostname}`);
          await download(model.archive.url, packed, o);
          const members = missing.filter(m => m.archive?.url === model.archive!.url).map(m => m.archive!.member);
          const tar = spawnSync("/usr/bin/tar", ["-xjf", packed, "-C", extracted, ...members], { stdio: "ignore" });
          rmSync(packed, { force: true });
          if (tar.status !== 0) throw new AudioModelsError("extract");
          archives.set(model.archive.url, extracted);
        }
        const from = join(extracted, model.archive.member);
        if (!existsSync(from)) throw new AudioModelsError("extract");
        renameSync(from, staged);
        ok = model.sha256.includes(await sha256(staged));
        if (!ok) failure = new AudioModelsError("checksum", "语音模型校验失败");
      }
      if (!ok) throw failure;
      const target = join(dir, model.file);
      mkdirSync(dirname(target), { recursive: true });
      renameSync(staged, target);
    }
  } finally { rmSync(staging, { recursive: true, force: true }); }
}
