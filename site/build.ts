// 官网构建：把 src/index.html 里的 `<!-- include: 路径 -->` 换成对应文件内容，其余文件原样复制到 dist/。
// 用法：bun site/build.ts          构建到 site/dist
//       bun site/build.ts --serve  构建并在 http://localhost:4300 预览，每次请求页面时重新构建
import { cpSync, mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";

const root = dirname(new URL(import.meta.url).pathname);
const src = join(root, "src");
const dist = join(root, "dist");

function expand(file: string, seen: string[] = []): string {
  if (seen.includes(file)) throw new Error(`循环引用：${[...seen, file].join(" → ")}`);
  const text = readFileSync(file, "utf8");
  return text.replace(/<!--\s*include:\s*([^\s]+)\s*-->/g, (_, rel: string) =>
    expand(resolve(dirname(file), rel), [...seen, file]),
  );
}

export function build() {
  rmSync(dist, { recursive: true, force: true });
  mkdirSync(dist, { recursive: true });
  for (const dir of ["styles", "scripts", "assets"]) cpSync(join(src, dir), join(dist, dir), { recursive: true });
  const html = expand(join(src, "index.html"));
  const missing = html.match(/<!--\s*include:[^>]*-->/);
  if (missing) throw new Error(`未展开的引用：${missing[0]}`);
  writeFileSync(join(dist, "index.html"), html);
}

build();
console.log(`已构建 ${dist}`);

if (process.argv.includes("--serve")) {
  const port = Number(process.env.PORT ?? 4300);
  Bun.serve({
    port,
    hostname: "127.0.0.1",
    fetch(req) {
      let path = decodeURIComponent(new URL(req.url).pathname);
      if (path.endsWith("/")) path += "index.html";
      if (path === "/index.html") build();
      const file = Bun.file(join(dist, path));
      return file.size ? new Response(file) : new Response("未找到", { status: 404 });
    },
  });
  console.log(`预览 http://localhost:${port}`);
}
