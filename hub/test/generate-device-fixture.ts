// From the repository root: bun hub/test/generate-device-fixture.ts
import { identityFromRaw, requestInfo, responseInfo, responseSealer, suite } from "../src/devices/envelope.ts";
import { DeviceClient } from "../src/devices/client.ts";

export async function deviceFixture() {
  const hubPrivate = "01".repeat(32), devicePrivate = "02".repeat(32);
  const hub = await identityFromRaw(hubPrivate), device = await identityFromRaw(devicePrivate);
  const client = new DeviceClient(hub.keys.publicKey, device.keys);
  const ts = "2026-11-19T08:00:00.000Z";
  const deviceID = "android-aebagbaf";
  const pair = {
    op: "pair", ts, nonce: Buffer.alloc(16, 0xa1).toString("base64url"),
    body: {
      code: Buffer.alloc(16, 0xc1).toString("base64url"), device_pk: device.publicKey.toString("base64url"),
      name: "Fixture Phone", platform: "android",
    },
  };
  const sync = { op: "sync", ts, nonce: Buffer.alloc(16, 0xa2).toString("base64url"), body: { cursor: 0 } };
  const pairReply = { status: 200, body: { device_id: deviceID, hub_id: hub.hubID, name: pair.body.name } };
  const syncReply = { status: 200, body: { changes: [], cursor: 0, more: false } };

  async function vector(mode: "base" | "auth", plaintext: typeof pair | typeof sync, reply: typeof pairReply | typeof syncReply,
    requestSeed: number, responseSeed: number) {
    const requestIkm = Buffer.alloc(32, requestSeed), responseIkm = Buffer.alloc(32, responseSeed);
    return {
      request: {
        mode, info_utf8: requestInfo, aad_utf8: client.device ?? "", ephemeral_ikm_hex: requestIkm.toString("hex"),
        plaintext_json_utf8: JSON.stringify(plaintext), envelope: await client.envelope(plaintext, requestIkm),
      },
      response: {
        mode: "auth", info_utf8: responseInfo, aad_utf8: plaintext.nonce, ephemeral_ikm_hex: responseIkm.toString("hex"),
        plaintext_json_utf8: JSON.stringify(reply),
        envelope: await (await responseSealer(hub.keys, device.keys.publicKey, plaintext.nonce, responseIkm))(reply),
      },
    };
  }
  const pairing = await vector("base", pair, pairReply, 3, 4);
  client.device = deviceID;
  const syncVector = await vector("auth", sync, syncReply, 5, 6);
  return {
    v: 1,
    hpke: { kem: "DHKEM(X25519, HKDF-SHA256)", kdf: "HKDF-SHA256", aead: "AES-128-GCM" },
    hub: { hub_id: hub.hubID, private_key_hex: hubPrivate, public_key_base64url: hub.publicKey.toString("base64url") },
    device: {
      device_id: deviceID, private_key_hex: devicePrivate,
      public_key_base64url: Buffer.from(await suite.kem.serializePublicKey(device.keys.publicKey)).toString("base64url"),
    },
    pairing,
    sync: syncVector,
  };
}

if (import.meta.main) {
  await Bun.write(new URL("../../schema/fixtures/device-envelope.json", import.meta.url),
    JSON.stringify(await deviceFixture(), null, 2) + "\n");
}
