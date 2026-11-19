// 录音用的本机语音模型：第一次开启录音时下载到数据目录，逐个校验 sha256 后原子替换。
import { createHash } from "node:crypto";
import { createReadStream, existsSync, mkdirSync, mkdtempSync, renameSync, rmSync, statSync } from "node:fs";
import { open } from "node:fs/promises";
import { dirname, join } from "node:path";
import { spawnSync } from "node:child_process";

const GITHUB = "https://github.com/k2-fsa/sherpa-onnx/releases/download";
const SENSE = "sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2024-07-17";
const SPEAKER = "3dspeaker_speech_eres2net_base_sv_zh-cn_3dspeaker_16k.onnx";

export interface Model {
  file: string; sha256: string;
  /** 依次尝试的地址。 */
  urls: string[];
  /** 从压缩包取文件时的包内路径；压缩包地址排在 urls 之后，其他地址失败才用。 */
  archive?: { url: string; member: string };
}
export const AUDIO_MODELS: Model[] = [
  { file: "silero_vad.onnx", sha256: "9e2449e1087496d8d4caba907f23e0bd3f78d91fa552479bb9c23ac09cbb1fd6", urls: [`${GITHUB}/asr-models/silero_vad.onnx`] },
  { file: SPEAKER, sha256: "1a331345f04805badbb495c775a6ddffcdd1a732567d5ec8b3d5749e3c7a5e4b", urls: [`${GITHUB}/speaker-recongition-models/${SPEAKER}`] },
  // 单独下载约 240MB；GitHub 只有约 1GB 的整包，单独下载失败时才用。
  { file: "sense-voice/model.int8.onnx", sha256: "c71f0ce00bec95b07744e116345e33d8cbbe08cef896382cf907bf4b51a2cd51",
    urls: [`https://huggingface.co/csukuangfj/${SENSE}/resolve/main/model.int8.onnx`],
    archive: { url: `${GITHUB}/asr-models/${SENSE}.tar.bz2`, member: `${SENSE}/model.int8.onnx` } },
  { file: "sense-voice/tokens.txt", sha256: "f449eb28dc567533d7fa59be34e2abca8784f771850c78a47fb731a31429a1dc",
    urls: [`https://huggingface.co/csukuangfj/${SENSE}/resolve/main/tokens.txt`],
    archive: { url: `${GITHUB}/asr-models/${SENSE}.tar.bz2`, member: `${SENSE}/tokens.txt` } },
];

export async function sha256(file: string): Promise<string> {
  const hash = createHash("sha256");
  for await (const chunk of createReadStream(file)) hash.update(chunk);
  return hash.digest("hex");
}

class HttpError extends Error { constructor(readonly status: number) { super(`下载失败（HTTP ${status}）`); } }

/** 断线或服务端出错时从已下载的位置续传，最多 6 次；4xx 不重试。 */
async function download(url: string, target: string, o: Required<Options>) {
  let failure: unknown;
  for (let attempt = 0; attempt < 6; attempt++) {
    if (attempt) await o.wait(Math.min(30_000, 2000 * 2 ** (attempt - 1)));
    const have = existsSync(target) ? statSync(target).size : 0;
    try {
      const response = await o.fetcher(url, { redirect: "follow", headers: have ? { Range: `bytes=${have}-` } : {} });
      if (have && response.status === 416) return;
      if (!response.ok || !response.body) throw new HttpError(response.status);
      const append = have > 0 && response.status === 206;
      // 逐块写盘：断线时已收到的部分留在文件里，下次从这里续传。
      const file = await open(target, append ? "a" : "w");
      try { for await (const chunk of response.body) await file.write(chunk); } finally { await file.close(); }
      return;
    } catch (error) {
      failure = error;
      if (error instanceof HttpError && error.status >= 400 && error.status < 500 && ![408, 429].includes(error.status)) break;
      o.log(`${error instanceof Error ? error.message : "下载中断"}，稍后续传`);
    }
  }
  throw failure instanceof Error ? failure : new Error("下载失败");
}

export interface Options {
  fetcher?: typeof fetch;
  log?: (message: string) => void;
  models?: Model[];
  wait?: (ms: number) => Promise<void>;
}

/** 缺什么下载什么；已有且校验通过的文件不再下载。 */
export async function ensureAudioModels(dir: string, options: Options = {}): Promise<void> {
  const o: Required<Options> = { fetcher: fetch, log: () => {}, models: AUDIO_MODELS, wait: ms => Bun.sleep(ms), ...options };
  const { log, models } = o;
  mkdirSync(dir, { recursive: true });
  const missing: Model[] = [];
  for (const model of models) {
    const file = join(dir, model.file);
    if (!existsSync(file) || await sha256(file) !== model.sha256) missing.push(model);
  }
  if (!missing.length) return;
  const staging = mkdtempSync(join(dir, ".download-"));
  try {
    const archives = new Map<string, string>();
    for (const model of missing) {
      const staged = join(staging, model.file.replaceAll("/", "_"));
      let ok = false;
      for (const url of model.urls) {
        try { log(`下载 ${model.file}`); await download(url, staged, o); ok = await sha256(staged) === model.sha256; }
        catch (error) { log(`${model.file}：${error instanceof Error ? error.message : "下载失败"}`); }
        if (ok) break;
        rmSync(staged, { force: true });
      }
      if (!ok && model.archive) {
        let extracted = archives.get(model.archive.url);
        if (!extracted) {
          extracted = join(staging, `archive-${archives.size}`); mkdirSync(extracted);
          const packed = join(staging, `archive-${archives.size}.tar.bz2`);
          log(`下载 ${model.archive.url}`);
          await download(model.archive.url, packed, o);
          const members = missing.filter(m => m.archive?.url === model.archive!.url).map(m => m.archive!.member);
          const tar = spawnSync("/usr/bin/tar", ["-xjf", packed, "-C", extracted, ...members], { stdio: "ignore" });
          rmSync(packed, { force: true });
          if (tar.status !== 0) throw new Error("语音模型压缩包解压失败");
          archives.set(model.archive.url, extracted);
        }
        const from = join(extracted, model.archive.member);
        if (existsSync(from)) { renameSync(from, staged); ok = await sha256(staged) === model.sha256; }
      }
      if (!ok) throw new Error(`语音模型下载或校验失败：${model.file}`);
      const target = join(dir, model.file);
      mkdirSync(dirname(target), { recursive: true });
      renameSync(staged, target);
    }
  } finally { rmSync(staging, { recursive: true, force: true }); }
}
