import { readFileSync, statSync } from "node:fs";
import { basename, isAbsolute } from "node:path";
import { createHash, randomBytes } from "node:crypto";

// 插件只读取配置、来源和 runner 提供的游标，不写文件、不联网。
const config = JSON.parse(process.env.RA_PLUGIN_CONFIG ?? "{}");
if (typeof config.path !== "string" || !isAbsolute(config.path)) throw new Error("请填写文件完整路径");
const args = process.argv.slice(2);
const arg = (name: string) => { const i = args.indexOf(name); return i < 0 ? undefined : args[i + 1]; };
const stat = statSync(config.path);
if (!stat.isFile() || stat.size > 200_000) throw new Error("需要不超过 200 KB 的 UTF-8 文本文件");
const body = readFileSync(config.path, "utf8");
const digest = createHash("sha256").update(config.path + "\0" + body).digest("hex");
let previous: { digest?: string } = {};
try { if (arg("--state")) previous = JSON.parse(readFileSync(arg("--state")!, "utf8")); } catch {}
const since = arg("--since");
if (body.trim() && (since ? stat.mtimeMs >= Date.parse(since) : previous.digest !== digest)) {
  const alphabet = "0123456789ABCDEFGHJKMNPQRSTVWXYZ";
  let time = Date.now(), prefix = "";
  for (let i = 0; i < 10; i++) { prefix = alphabet[time % 32] + prefix; time = Math.floor(time / 32); }
  const id = prefix + [...randomBytes(16)].map(n => alphabet[n % 32]).join("");
  console.log(JSON.stringify({ type: "record", record: {
    id, schema: 1, device: arg("--device") ?? "mac", source: "plugin.ext_text_file", source_ref: digest,
    kind: "event", t_start: stat.mtime.toISOString(), title: basename(config.path).slice(0, 200), body,
    context: { extra: { path: config.path } }, capture: { method: "file" }, sensitivity: "normal",
  } }));
}
console.log(JSON.stringify({ type: "checkpoint", state: { digest } }));
