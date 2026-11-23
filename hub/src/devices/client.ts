import type { PairingRole } from "./permissions.ts";
import { randomBytes } from "node:crypto";
import { requestInfo, responseInfo, suite, utf8 } from "./envelope.ts";

export interface Pairing {
  v: 1; role: PairingRole; name: string; hub_id: string; pk: string; code: string; addrs: string[]; expires_at: string;
}
export interface DevicePlaintext {
  op: string; ts: string; nonce: string; body: object;
}
export interface ResponseEnvelope { v: number; enc: string; ct: string }

export function decodePairing(uri: string): Pairing {
  return JSON.parse(Buffer.from(new URL(uri).searchParams.get("d")!, "base64url").toString("utf8"));
}

export class DeviceTransportError extends Error {
  constructor(readonly status: number) { super(`设备传输失败 ${status}`); }
}

export class DeviceClient {
  device: string | null = null;

  constructor(readonly hub: CryptoKey, readonly keys: CryptoKeyPair, readonly origin = "") {}

  static async fromInvite(pairing: Pairing, origin: string, keys?: CryptoKeyPair) {
    return new DeviceClient(await suite.kem.deserializePublicKey(Buffer.from(pairing.pk, "base64url")),
      keys ?? await suite.kem.generateKeyPair(), origin);
  }

  async pairingBody(pairing: Pairing) {
    return {
      code: pairing.code, device_pk: Buffer.from(await suite.kem.serializePublicKey(this.keys.publicKey)).toString("base64url"),
      name: "测试手机", platform: "android",
    };
  }

  async envelope(plaintext: DevicePlaintext, ekm?: ArrayBufferView) {
    const senderKey = this.device === null ? undefined : this.keys;
    const context = await suite.createSenderContext({ recipientPublicKey: this.hub, info: utf8(requestInfo), senderKey, ekm });
    const ct = await context.seal(utf8(JSON.stringify(plaintext)), utf8(this.device ?? ""));
    return { v: 1, device: this.device, enc: Buffer.from(context.enc).toString("base64url"), ct: Buffer.from(ct).toString("base64url") };
  }

  open<T>(envelope: ResponseEnvelope, nonce: string) {
    return this.openPayload<{ status: number; body: T }>(envelope, nonce);
  }

  async openPayload<T>(envelope: ResponseEnvelope, nonce: string): Promise<T> {
    const context = await suite.createRecipientContext({
      recipientKey: this.keys, senderPublicKey: this.hub, enc: Buffer.from(envelope.enc, "base64url"), info: utf8(responseInfo),
    });
    return JSON.parse(new TextDecoder().decode(await context.open(Buffer.from(envelope.ct, "base64url"), utf8(nonce))));
  }

  post(envelope: object, signal?: AbortSignal) {
    return fetch(this.origin + "/v1/device", {
      method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(envelope), signal, redirect: "error",
    });
  }

  async send<T = Record<string, unknown>>(op: string, body: object, options: Partial<Pick<DevicePlaintext, "ts" | "nonce">> & { signal?: AbortSignal } = {}) {
    const { signal, ...overrides } = options;
    signal?.throwIfAborted();
    const input = { op, body, ts: new Date().toISOString(), nonce: randomBytes(16).toString("base64url"), ...overrides };
    const response = await this.post(await this.envelope(input), signal);
    if (response.status !== 200) {
      await response.body?.cancel();
      throw new DeviceTransportError(response.status);
    }
    return this.open<T>(await response.json() as ResponseEnvelope, input.nonce);
  }

  async pair(pairing: Pairing, platform = "android") {
    const result = await this.send<{ device_id: string }>("pair", { ...await this.pairingBody(pairing), platform });
    if (result.status === 200) this.device = result.body.device_id;
    return result;
  }
}
