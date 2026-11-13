import { existsSync, lstatSync, realpathSync, statSync } from "node:fs";
import { homedir } from "node:os";
import { dirname, isAbsolute, join, relative, sep } from "node:path";

/** Entries name string configuration fields, never executable code or free-form policy. */
export interface PluginAccess { readFiles?: string[]; readDirectories?: string[] }
export interface SandboxManifest { access?: PluginAccess; config: { key: string; type: string }[] }
export interface PluginSandbox { code: string; manifest: SandboxManifest; values: Record<string, unknown> }
export class SandboxError extends Error { readonly code = "EACCES"; }
export class SandboxUnavailableError extends SandboxError { readonly name = "SandboxUnavailableError"; }
const fail = (message: string): never => { throw new SandboxError(message); };
const inside = (root: string, path: string) => { const r = relative(root, path); return !r || r !== ".." && !r.startsWith(`..${sep}`) && !isAbsolute(r); };
const overlaps = (a: string, b: string) => inside(a, b) || inside(b, a);
const canonical = (path: string) => existsSync(path) ? realpathSync(path) : path;
const quote = (path: string) => JSON.stringify(path);

export function validatePluginAccess(manifest: SandboxManifest): void {
  const a = manifest.access;
  if (a === undefined) return;
  if (!a || typeof a !== "object" || Array.isArray(a) || Object.keys(a).some(k => !["readFiles", "readDirectories"].includes(k))) fail("插件 access 只支持 readFiles 和 readDirectories");
  const seen = new Set<string>();
  for (const kind of ["readFiles", "readDirectories"] as const) {
    const keys = a[kind];
    if (keys === undefined) continue;
    if (!Array.isArray(keys) || keys.length > 20) fail("插件读取范围格式不正确");
    for (const key of keys) {
      if (typeof key !== "string" || seen.has(key) || !manifest.config.some(f => f.key === key && f.type === "string")) fail("插件读取范围必须引用不重复的文本配置项");
      seen.add(key);
    }
  }
}

function protectedRoots(dataDir: string): string[] {
  const home = homedir();
  return [dataDir, join(home, "Library/Keychains"), "/Library/Keychains", join(home, ".ssh"), join(home, ".aws"), join(home, ".codex"), join(home, ".claude")].map(canonical);
}

/** Called both when granting configuration and immediately before executing it. */
export function pluginReadAccess(manifest: SandboxManifest, values: Record<string, unknown>, dataDir: string) {
  validatePluginAccess(manifest);
  const protectedPaths = protectedRoots(realpathSync(dataDir));
  const files: string[] = [], directories: string[] = [];
  for (const kind of ["readFiles", "readDirectories"] as const) for (const key of manifest.access?.[kind] ?? []) {
    const value = values[key];
    if (value === undefined || value === "") continue;
    if (typeof value !== "string" || !isAbsolute(value) || /[\x00-\x1f]/.test(value)) fail("获准读取的路径必须是完整路径");
    let path: string;
    try { path = realpathSync(value as string); } catch { return fail("获准读取的文件或目录不存在"); }
    const s = statSync(path);
    if (kind === "readFiles" ? !s.isFile() : !s.isDirectory()) fail("获准路径与文件或目录类型不符");
    if (protectedPaths.some(root => inside(root, path) || kind === "readDirectories" && overlaps(root, path))) fail("不能授权读取 Tacit 数据、钥匙串或凭据目录");
    (kind === "readFiles" ? files : directories).push(path);
  }
  return { files, directories, protectedPaths };
}

/** Current macOS implementation. Missing/deprecated tooling never silently falls back to unrestricted execution. */
export function sandboxLaunch(options: { sandbox: PluginSandbox; dataDir: string; stateFile: string; command: string[]; env?: NodeJS.ProcessEnv }) {
  if (process.platform !== "darwin" || !existsSync("/usr/bin/sandbox-exec")) throw new SandboxUnavailableError("当前系统不支持第三方数据源隔离，未执行插件");
  const { sandbox, dataDir, stateFile } = options;
  const code = realpathSync(sandbox.code), runtime = realpathSync(options.command[0]!);
  if (!inside(realpathSync(dataDir), code)) fail("插件代码必须来自安装快照");
  const access = pluginReadAccess(sandbox.manifest, sandbox.values, dataDir);
  if (existsSync(stateFile) && lstatSync(stateFile).isSymbolicLink()) fail("插件游标不能是符号链接");
  const state = existsSync(stateFile) ? realpathSync(stateFile) : join(realpathSync(dirname(stateFile)), "state.json");
  if (!inside(realpathSync(dataDir), state)) fail("插件游标不能指向数据目录外");
  const read = [
    '(literal "/")', // dyld opens the root directory itself; no recursive grant.
    '(subpath "/System/Library")', '(subpath "/System/Volumes/Preboot/Cryptexes/OS")', '(subpath "/usr/lib")',
    '(literal "/dev/urandom")', '(literal "/dev/random")',
    `(literal ${quote(runtime)})`, `(subpath ${quote(code)})`, `(literal ${quote(state)})`,
    ...access.files.map(p => `(literal ${quote(p)})`), ...access.directories.map(p => `(subpath ${quote(p)})`),
  ];
  // Deny beats allow: code and this plugin's read-only checkpoint are the only exceptions inside Tacit data.
  const data = realpathSync(dataDir);
  const profile = `(version 1)\n(deny default)\n(allow process-exec (literal ${quote(runtime)}))\n(allow sysctl-read)\n(allow file-read-metadata)\n(allow file-read* ${read.join(" ")})\n(allow file-write* (literal "/dev/null"))\n(allow dynamic-code-generation)\n(deny file-read* (require-all (subpath ${quote(data)}) (require-not (require-any (subpath ${quote(code)}) (literal ${quote(state)})))))\n${access.protectedPaths.filter(p => p !== data).map(p => `(deny file-read* (subpath ${quote(p)}))`).join("\n")}`;
  return {
    command: ["/usr/bin/sandbox-exec", "-p", profile, runtime, ...options.command.slice(1)],
    env: { PATH: "/usr/bin:/bin", HOME: "/var/empty", TMPDIR: "/var/empty", RA_PLUGIN_CONFIG: JSON.stringify(sandbox.values) },
    cwd: code,
  };
}
