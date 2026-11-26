// Mac 安装包上传到 GitHub Release 之后运行：把 site/src/latest.json 的 Mac 条目和 site/src/appcast.json
// 改成这一版，提交后部署官网，已装用户才会看到“可以更新了”并能在应用里直接更新。
// 签名来自 scripts/release-dmg.sh 写出的 dist/Tacit-<版本>.dmg.sparkle。
import { readFileSync, statSync, writeFileSync } from "node:fs";
import { join } from "node:path";

const root = join(import.meta.dir, "..");
const version = JSON.parse(readFileSync(join(root, "package.json"), "utf8")).version as string;
const dmg = join(root, "dist", `Tacit-${version}.dmg`);
const signed = readFileSync(`${dmg}.sparkle`, "utf8");
const edSignature = /sparkle:edSignature="([^"]+)"/.exec(signed)?.[1];
const length = Number(/length="(\d+)"/.exec(signed)?.[1]);
if (!edSignature || length !== statSync(dmg).size) throw new Error(`${dmg}.sparkle 与安装包不符，重新运行 scripts/release-dmg.sh`);

const tag = `mac-v${version}`;
const asset = `https://github.com/JinSooo/tacit/releases/download/${tag}/Tacit-${version}.dmg`;
const head = await fetch(asset, { method: "HEAD", redirect: "follow" });
if (!head.ok) throw new Error(`Release 上还没有 ${asset}（HTTP ${head.status}），先上传安装包`);

const latestPath = join(root, "site/src/latest.json");
const latest = JSON.parse(readFileSync(latestPath, "utf8"));
latest.mac = { version, url: `https://github.com/JinSooo/tacit/releases/tag/${tag}` };
writeFileSync(latestPath, `{\n  "mac": ${JSON.stringify(latest.mac).replaceAll('":', '": ').replaceAll(',"', ', "').replace("{", "{ ").replace(/}$/, " }")},\n  "android": ${JSON.stringify(latest.android).replaceAll('":', '": ').replaceAll(',"', ', "').replace("{", "{ ").replace(/}$/, " }")}\n}\n`);
writeFileSync(join(root, "site/src/appcast.json"), JSON.stringify({ version, length, edSignature }, null, 2) + "\n");
console.log(`已把官网的 Mac 最新版本改成 ${version}；提交后运行 bun site/build.ts 并部署。`);
