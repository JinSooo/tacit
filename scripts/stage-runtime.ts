import { cpSync, existsSync, mkdirSync, readFileSync, realpathSync, statSync } from "node:fs";
import { dirname, join, resolve } from "node:path";

const SQLITE_PKG = "better-sqlite3-multiple-ciphers";
const SQLITE_SKIP = new Set(["deps", "src", "binding.gyp"]);

/** 安装快照仅含运行所需代码、契约、网页和生产依赖，不保留指向工作区的链接。 */
export function stageRuntime(source: string, destination: string) {
  source = resolve(source); destination = resolve(destination);
  if (existsSync(destination)) throw new Error("运行目录必须是新的暂存目录");
  mkdirSync(destination, { recursive: true });
  for (const part of ["hub/src", "packages/record", "schema", "plugins", "web/dist", "package.json", "bun.lock"]) {
    cpSync(join(source, part), join(destination, part), { recursive: true, dereference: true,
      filter: p => !/\.(?:test|spec)\.[cm]?[jt]sx?$/.test(p) });
  }
  const copied = new Set<string>();
  const copyDependency = (name: string, from: string, into: string) => {
    let root = from, found: string | null = null;
    while (true) {
      const candidate = join(root, "node_modules", name);
      if (existsSync(join(candidate, "package.json"))) { found = realpathSync(candidate); break; }
      const parent = dirname(root); if (parent === root) break; root = parent;
    }
    if (!found) throw new Error(`缺少生产依赖：${name}`);
    const target = join(into, "node_modules", name);
    if (copied.has(target)) return;
    copied.add(target);
    let keepPrebuild: string | null = null;
    if (name === SQLITE_PKG) {
      keepPrebuild = `${process.platform}-${process.arch}.node`;
      const prebuildPath = join(found, "prebuilds", keepPrebuild);
      if (!existsSync(prebuildPath) || !statSync(prebuildPath).isFile()) {
        throw new Error(`缺少当前平台的 SQLite 原生模块：${SQLITE_PKG}/prebuilds/${keepPrebuild}`);
      }
    }
    cpSync(found, target, {
      recursive: true, dereference: true,
      filter: p => {
        const parts = p === found ? [] : p.slice(found!.length + 1).split(/[\\/]/);
        if (parts.includes("node_modules")) return false;
        if (keepPrebuild) {
          if (SQLITE_SKIP.has(parts[0]!)) return false;
          if (parts[0] === "prebuilds" && parts.length > 1 && parts[1] !== keepPrebuild) return false;
        }
        return true;
      },
    });
    const manifest = JSON.parse(readFileSync(join(found, "package.json"), "utf8"));
    for (const dep of Object.keys(manifest.dependencies ?? {})) copyDependency(dep, found, target);
  };
  const manifest = JSON.parse(readFileSync(join(source, "package.json"), "utf8"));
  for (const name of Object.keys(manifest.dependencies)) copyDependency(name, source, destination);
}
if (import.meta.main) {
  if (process.argv.length !== 4) throw new Error("用法：stage-runtime <源码目录> <新运行目录>");
  stageRuntime(process.argv[2]!, process.argv[3]!);
}
