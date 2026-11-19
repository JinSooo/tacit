import { expect, test } from "bun:test";
import { createHash } from "node:crypto";
import { existsSync, mkdirSync, mkdtempSync, readdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { spawnSync } from "node:child_process";
import { ensureAudioModels, type Model } from "../src/audio-models.ts";

const sha = (s: string) => createHash("sha256").update(s).digest("hex");

test("单独下载失败时从整包取，逐个校验；已校验的文件不再下载", async () => {
  const root = mkdtempSync(join(tmpdir(), "ra-models-")), dir = join(root, "models");
  try {
    const pack = join(root, "pack"); mkdirSync(join(pack, "bundle"), { recursive: true });
    writeFileSync(join(pack, "bundle/model.bin"), "model");
    expect(spawnSync("/usr/bin/tar", ["-cjf", join(root, "bundle.tar.bz2"), "-C", pack, "bundle"]).status).toBe(0);
    const archive = readFileSync(join(root, "bundle.tar.bz2"));
    const models: Model[] = [
      { file: "vad.onnx", sha256: sha("vad"), urls: ["https://x/vad"] },
      { file: "sense/model.bin", sha256: sha("model"), urls: ["https://x/model"], archive: { url: "https://x/bundle.tar.bz2", member: "bundle/model.bin" } },
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
    await expect(ensureAudioModels(dir, { fetcher, models: [{ file: "vad.onnx", sha256: sha("vad"), urls: ["https://x/vad"] }] })).rejects.toThrow("校验失败");
    expect(existsSync(join(dir, "vad.onnx"))).toBe(false);
    expect(readdirSync(dir)).toEqual([]);
  } finally { rmSync(root, { recursive: true, force: true }); }
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
    await ensureAudioModels(dir, { fetcher, wait: async () => {}, models: [{ file: "m.bin", sha256: sha(body), urls: ["https://x/m"] }] });
    expect(readFileSync(join(dir, "m.bin"), "utf8")).toBe(body);
    expect(ranges).toEqual([null, "bytes=4000-"]);
  } finally { rmSync(root, { recursive: true, force: true }); }
});
