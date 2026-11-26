// 从 Sparkle 的 EdDSA 私钥文件（32 字节种子的 base64）算出公钥，发版时和应用 Info.plist 里的 SUPublicEDKey 比对。
import { createPrivateKey, createPublicKey } from "node:crypto";
import { readFileSync } from "node:fs";

const seed = Buffer.from(readFileSync(process.argv[2]!, "utf8").trim(), "base64");
if (seed.length !== 32) throw new Error("私钥文件不是 32 字节的 Ed25519 种子");
const pkcs8 = Buffer.concat([Buffer.from("302e020100300506032b657004220420", "hex"), seed]);
const der = createPublicKey(createPrivateKey({ key: pkcs8, format: "der", type: "pkcs8" })).export({ format: "der", type: "spki" });
console.log(der.subarray(-32).toString("base64"));
