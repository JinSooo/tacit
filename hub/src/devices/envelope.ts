import { Aes128Gcm, CipherSuite, HkdfSha256 } from "@hpke/core";
import { DhkemX25519HkdfSha256 } from "@hpke/dhkem-x25519";
import { createHash, createPrivateKey, createPublicKey } from "node:crypto";

export const suite = new CipherSuite({ kem: new DhkemX25519HkdfSha256(), kdf: new HkdfSha256(), aead: new Aes128Gcm() });
export const requestInfo = "tacit-device-v1";
export const responseInfo = "tacit-device-v1/response";
export const maxEnvelopeBytes = 8 * 1024 * 1024;
export const deviceID = /^(?:android|mac)-[a-z2-7]{8}$/;
const clockWindowMs = 10 * 60_000;

export const utf8 = (value: string) => new TextEncoder().encode(value);
const decoder = new TextDecoder("utf-8", { fatal: true });

export function base32(bytes: Uint8Array): string {
  const alphabet = "abcdefghijklmnopqrstuvwxyz234567";
  let result = "", bits = 0, buffer = 0;
  for (const byte of bytes) {
    buffer = (buffer << 8) | byte;
    bits += 8;
    while (bits >= 5) {
      bits -= 5;
      result += alphabet[(buffer >>> bits) & 31];
    }
  }
  if (bits) result += alphabet[(buffer << (5 - bits)) & 31];
  return result;
}

export async function keyPairFromRaw(raw: Buffer): Promise<CryptoKeyPair> {
  const pkcs8 = Buffer.concat([Buffer.from("302e020100300506032b656e04220420", "hex"), raw]);
  const privateKey = createPrivateKey({ key: pkcs8, format: "der", type: "pkcs8" });
  const publicRaw = Buffer.from(createPublicKey(privateKey).export({ format: "jwk" }).x!, "base64url");
  return {
    privateKey: await suite.kem.deserializePrivateKey(raw),
    publicKey: await suite.kem.deserializePublicKey(publicRaw),
  };
}

export async function identityFromRaw(hex: string) {
  if (!/^[0-9a-f]{64}$/i.test(hex)) throw new Error("设备密钥格式无效");
  const keys = await keyPairFromRaw(Buffer.from(hex, "hex"));
  const publicKey = Buffer.from(await suite.kem.serializePublicKey(keys.publicKey));
  const hubID = base32(createHash("sha256").update(publicKey).digest().subarray(0, 16));
  return { keys, publicKey, hubID };
}

export function object(value: unknown): Record<string, unknown> | null {
  return value !== null && typeof value === "object" && !Array.isArray(value) ? value as Record<string, unknown> : null;
}

export function base64url(value: unknown, length?: number): Buffer | null {
  if (typeof value !== "string" || !/^[A-Za-z0-9_-]+$/.test(value)) return null;
  const bytes = Buffer.from(value, "base64url");
  return (length === undefined || bytes.length === length) && bytes.toString("base64url") === value ? bytes : null;
}

export class WireError extends Error {
  constructor(readonly status: number, message: string) { super(message); }
}
export const invalidEnvelope = () => new WireError(400, "信封格式错误");
export const unpaired = () => new WireError(401, "设备未配对或已移除");

export async function readEnvelope(request: Pick<Request, "headers" | "body">, fromRelay = false) {
  if (Number(request.headers.get("content-length")) > maxEnvelopeBytes) throw new WireError(413, "信封超过 8 MiB");
  if (request.headers.get("content-type")?.split(";", 1)[0]?.trim().toLowerCase() !== "application/json" || !request.body) {
    throw invalidEnvelope();
  }
  const reader = request.body.getReader();
  const chunks: Uint8Array[] = [];
  let bytes = 0;
  try {
    for (;;) {
      const { done, value } = await reader.read();
      if (done) break;
      bytes += value.byteLength;
      if (bytes > maxEnvelopeBytes) {
        void reader.cancel().catch(() => {});
        throw new WireError(413, "信封超过 8 MiB");
      }
      chunks.push(value);
    }
  } catch (error) {
    // 从远端读到一半断线，仍留在上行信箱等待重试。
    if (fromRelay || error instanceof WireError) throw error;
    throw invalidEnvelope();
  } finally {
    reader.releaseLock();
  }
  let raw: Record<string, unknown> | null;
  try { raw = object(JSON.parse(decoder.decode(Buffer.concat(chunks, bytes)))); }
  catch { throw invalidEnvelope(); }
  if (!raw || raw.v !== 1 || !(raw.device === null || (typeof raw.device === "string" && deviceID.test(raw.device)))) {
    throw invalidEnvelope();
  }
  const enc = base64url(raw.enc, 32), ct = base64url(raw.ct);
  if (!enc || !ct || ct.length < 16) throw invalidEnvelope();
  return { device: raw.device, enc, ct };
}

export async function openRequest(envelope: Awaited<ReturnType<typeof readEnvelope>>, recipientKey: CryptoKeyPair, senderPublicKey?: CryptoKey) {
  let plaintext: ArrayBuffer;
  try {
    const context = await suite.createRecipientContext({
      recipientKey, senderPublicKey, enc: envelope.enc, info: utf8(requestInfo),
    });
    plaintext = await context.open(envelope.ct, utf8(envelope.device ?? ""));
  } catch { throw unpaired(); }
  try { return object(JSON.parse(decoder.decode(plaintext))); }
  catch { return null; }
}

export async function responseSealer(senderKey: CryptoKeyPair, recipientPublicKey: CryptoKey, nonce: string, ekm?: ArrayBufferView) {
  const context = await suite.createSenderContext({ senderKey, recipientPublicKey, info: utf8(responseInfo), ekm });
  return async (result: object) => {
    const ct = await context.seal(utf8(JSON.stringify(result)), utf8(nonce));
    return { v: 1, enc: Buffer.from(context.enc).toString("base64url"), ct: Buffer.from(ct).toString("base64url") };
  };
}

/** 验证日历日期和时区，再交给 Date.parse 换算 UTC。 */
function timestamp(value: unknown): number {
  if (typeof value !== "string") return NaN;
  const match = /^(\d{4}-\d{2}-\d{2})[Tt](?:[01]\d|2[0-3]):[0-5]\d:[0-5]\d(?:\.\d+)?(?:[Zz]|[+-](?:[01]\d|2[0-3]):[0-5]\d)$/.exec(value);
  if (!match) return NaN;
  const date = new Date(`${match[1]}T00:00:00Z`);
  return Number.isFinite(+date) && date.toISOString().slice(0, 10) === match[1] ? Date.parse(value) : NaN;
}

export function validateRequest(input: Record<string, unknown> | null, now: number, maxAge = clockWindowMs) {
  const body = object(input?.body);
  if (!input || typeof input.op !== "string" || typeof input.nonce !== "string" || !base64url(input.nonce, 16) || !body) {
    throw invalidEnvelope();
  }
  const ts = timestamp(input.ts);
  if (!Number.isFinite(ts) || now - ts > maxAge || ts - now > clockWindowMs) {
    throw new WireError(400, "请求时间无效或已过期");
  }
  return { op: input.op, body };
}
