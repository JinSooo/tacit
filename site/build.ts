// 官网构建：分别展开中英文模板，内联公共样式、脚本和来源符号。
// 用法：bun site/build.ts          构建到 site/dist
//       bun site/build.ts --serve  构建并在 http://localhost:4300 预览，每次请求页面时重新构建
import { cpSync, mkdirSync, readdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const root = dirname(fileURLToPath(import.meta.url));
const src = join(root, "src");
const dist = join(root, "dist");

function expand(file: string, seen: string[] = []): string {
  if (seen.includes(file)) throw new Error(`循环引用：${[...seen, file].join(" → ")}`);
  const text = readFileSync(file, "utf8");
  return text.replace(/<!--\s*include:\s*([^\s]+)\s*-->/g, (_, rel: string) =>
    expand(resolve(dirname(file), rel), [...seen, file]),
  );
}

// 产物是单个自带样式、脚本和来源符号的 index.html，双击用 file:// 打开也能完整显示；图片仍在 assets/。
// 来源符号的 id 加 src- 前缀，避免和区块 id（如 #ai）重名。
// 脚本改成普通脚本并各自包一层块作用域，避免 file:// 下模块脚本被拦，也避免各区块的顶层变量重名。
function inline(html: string, assetPrefix: string): string {
  const read = (rel: string) => readFileSync(join(src, rel), "utf8");
  const sprite = read("assets/sources.svg").replace(/<!--[\s\S]*?-->/g, "")
    .replace("<svg ", '<svg aria-hidden="true" width="0" height="0" style="position:absolute" ')
    .replace(/<symbol id="/g, '<symbol id="src-');
  return html
    .replace(/<link rel="stylesheet" href="([^"]+)">/g, (_, rel: string) => `<style>\n${read(rel)}</style>`)
    .replace(/<script type="module" src="([^"]+)"><\/script>/g, (_, rel: string) => `<script>{\n${read(rel)}}</script>`)
    .replaceAll("assets/sources.svg#", "#src-")
    .replace(/\b(href|src|srcset)="assets\//g, `$1="${assetPrefix}assets/`)
    .replace(/<body([^>]*)>/, (m) => `${m}\n${sprite}`);
}

function readPage(locale: "zh" | "en") {
  const directory = join(src, locale);
  const sectionFiles = readdirSync(join(directory, "sections")).filter(name => name.endsWith(".html")).sort();
  const html = expand(join(directory, "index.html"));
  const ids = new Set<string>();
  const sections: string[] = [];
  const downloads: string[] = [];
  new HTMLRewriter()
    .on("[id]", {
      element(element) {
        const id = element.getAttribute("id")!;
        if (ids.has(id)) throw new Error(`${locale} 重复的 id：${id}`);
        ids.add(id);
      },
    })
    .on("main > section", {
      element(element) {
        const id = element.getAttribute("id");
        if (!id) throw new Error(`${locale} 的一级区块缺少 id`);
        sections.push(id);
      },
    })
    .on("a[data-platform-target]", {
      element(element) {
        downloads.push(`${element.getAttribute("data-platform-target")} ${element.getAttribute("href")}`);
      },
    })
    .transform(html);
  return { html, sectionFiles, sections, ids: [...ids].sort(), downloads };
}

function assertParity(label: string, zh: string[], en: string[]) {
  if (JSON.stringify(zh) !== JSON.stringify(en)) {
    throw new Error(`中英文${label}不一致\nzh: ${zh.join(", ")}\nen: ${en.join(", ")}`);
  }
}

export function build() {
  const zh = readPage("zh");
  const en = readPage("en");
  assertParity("区块文件", zh.sectionFiles, en.sectionFiles);
  assertParity("区块顺序", zh.sections, en.sections);
  assertParity("元素 id", zh.ids, en.ids);
  assertParity("版本下载链接", zh.downloads, en.downloads);

  const pages = [
    { path: "index.html", html: inline(zh.html, "") },
    { path: "en/index.html", html: inline(en.html, "../") },
  ];
  for (const { path, html } of pages) {
    const missing = html.match(/<!--\s*include:[^>]*-->|type="module"|sources\.svg#/);
    if (missing) throw new Error(`${path} 未处理的引用：${missing[0]}`);
  }

  rmSync(dist, { recursive: true, force: true });
  mkdirSync(join(dist, "en"), { recursive: true });
  cpSync(join(src, "assets"), join(dist, "assets"), { recursive: true });
  // Mac 应用每天读一次，判断有没有新版本（collector UpdateManifest）。
  cpSync(join(src, "latest.json"), join(dist, "latest.json"));
  for (const { path, html } of pages) writeFileSync(join(dist, path), html);
  console.log(`中英文一致性检查通过：${zh.sections.length} 个区块、${zh.ids.length} 个元素 id、${zh.downloads.length} 个下载链接`);
}

build();
console.log(`已构建 ${dist}`);

if (process.argv.includes("--serve")) {
  const port = Number(process.env.PORT ?? 4300);
  Bun.serve({
    port,
    hostname: "127.0.0.1",
    fetch(req) {
      let path = new URL(req.url).pathname;
      if (path === "/en") path = "/en/";
      if (path.endsWith("/")) path += "index.html";
      if (path === "/index.html" || path === "/en/index.html") build();
      const file = Bun.file(join(dist, path));
      return file.size ? new Response(file) : new Response("未找到", { status: 404 });
    },
  });
  console.log(`预览 http://localhost:${port}`);
}
