// 用本机 Chrome 无头模式和 ffmpeg把 assets/readme/hero.html 渲染成 README 首页的四张大图（2160×1212）。
// 用法：bun scripts/render-readme-hero.ts [输出目录，默认 assets/readme；默认目录时同时更新官网中文分享封面]
import { copyFileSync, existsSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { pathToFileURL } from "node:url";

const chrome = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome";
if (!existsSync(chrome)) throw new Error(`没找到 Chrome：${chrome}`);
const root = resolve(import.meta.dir, "..");
const out = resolve(process.argv[2] ?? join(root, "assets/readme"));
const page = pathToFileURL(join(root, "assets/readme/hero.html")).href;
const targets = [
  ["zh", "light", "hero-light.png"], ["zh", "dark", "hero-dark.png"],
  ["en", "light", "hero-en-light.png"], ["en", "dark", "hero-en-dark.png"],
] as const;

// Chrome 的截图不带透明层，四角按页面 18px 圆角（输出 36px）用 ffmpeg 抠成透明，边缘做 1px 抗锯齿。
const radius = 36;
const dx = `max(0,max(${radius}-X,X-(W-1-${radius})))`, dy = `max(0,max(${radius}-Y,Y-(H-1-${radius})))`;
const mask = `format=rgba,geq=r='r(X,Y)':g='g(X,Y)':b='b(X,Y)':a='255*clip(${radius}+0.5-hypot(${dx},${dy}),0,1)'`;

for (const [lang, theme, name] of targets) {
  const file = join(out, name), raw = join(tmpdir(), `tacit-hero-${process.pid}-${name}`);
  try {
    const result = Bun.spawnSync([chrome, "--headless=new", "--disable-gpu", "--hide-scrollbars", "--allow-file-access-from-files",
      "--force-device-scale-factor=2", "--window-size=1080,606", "--virtual-time-budget=3000",
      `--screenshot=${raw}`, `${page}?lang=${lang}&theme=${theme}`], { stdout: "pipe", stderr: "pipe" });
    if (result.exitCode !== 0 || !existsSync(raw)) throw new Error(`${name} 渲染失败：${result.stderr.toString().slice(-400)}`);
    const masked = Bun.spawnSync(["ffmpeg", "-loglevel", "error", "-y", "-i", raw, "-vf", mask, "-pix_fmt", "rgba", file], { stdout: "pipe", stderr: "pipe" });
    if (masked.exitCode !== 0) throw new Error(`${name} 圆角处理失败：${masked.stderr.toString().slice(-400)}`);
  } finally { rmSync(raw, { force: true }); }
  console.log(file);
}

// 官网中文分享封面就是中文浅色版。只在输出到仓库默认目录时同步，避免试渲染覆盖官网资产。
if (out === join(root, "assets/readme")) {
  copyFileSync(join(out, "hero-light.png"), join(root, "site/src/assets/og-cover.png"));
  console.log(join(root, "site/src/assets/og-cover.png"));
}
