import { cpSync, existsSync, lstatSync, mkdirSync, readFileSync, readdirSync, realpathSync, renameSync, rmSync, writeFileSync } from "node:fs";
import { isAbsolute, join, relative, resolve, sep } from "node:path";
import { createHash, randomUUID } from "node:crypto";
import { spawnSync } from "node:child_process";
import { redactString } from "./redact.ts";
import { dataDirOf } from "./hub-json.ts";

export interface PluginField { key: string; label: string; type: "string" | "boolean" | "number"; description?: string; required?: boolean; default?: string | boolean | number }
export interface PluginManifest { schema: 1; id: string; name: string; version: string; description: string; entry: string; permissions: string[]; config: PluginField[] }
export interface InstalledPlugin { manifest: PluginManifest; origin: string; values: Record<string, string | number | boolean>; revision?: string; contentHash?: string }
export interface PluginPreview extends InstalledPlugin { ticket: string; updating: boolean; previousRevision?: string }
export interface PluginRequest { action: "list" | "prepare" | "install" | "configure" | "uninstall" | "discard"; source?: string; id?: string; ticket?: string; values?: unknown; deleteRecords?: boolean; hub?: string }
export class PluginError extends Error {}
const fail = (message: string): never => { throw new PluginError(message); };
const object = (x: unknown): x is Record<string, unknown> => !!x && typeof x === "object" && !Array.isArray(x);
function text(x: unknown, max = 200): x is string { return typeof x === "string" && !!x.trim() && x.length <= max && !/[\x00-\x1f]/.test(x); }
export function pluginID(id: unknown): string { if (!text(id) || !/^ext-[a-z0-9][a-z0-9-]{0,48}$/.test(id)) fail("插件 id 必须是 ext- 开头的小写字母、数字或连字符"); return id as string; }
export function pluginSource(id: string): string { return "plugin." + pluginID(id).replaceAll("-", "_"); }
export function manifestAt(directory: string): PluginManifest {
  let raw: unknown;
  try { raw = JSON.parse(readFileSync(join(directory, "plugin.json"), "utf8")); } catch { fail("目录中缺少有效的 plugin.json 清单"); }
  if (!object(raw) || raw.schema !== 1 || !text(raw.name, 80) || !text(raw.version, 40) || !text(raw.description, 1000)
    || !text(raw.entry) || !Array.isArray(raw.permissions) || raw.permissions.length > 20 || !raw.permissions.every(p => text(p, 300))
    || !Array.isArray(raw.config) || raw.config.length > 30) fail("插件清单格式不正确，请对照 docs/plugins.md");
  const m = raw as unknown as PluginManifest;
  pluginID(m.id);
  if (isAbsolute(m.entry) || m.entry.split(/[\\/]/).includes("..") || !/\.(ts|js|mjs)$/.test(m.entry)) fail("插件入口必须是目录内的 JS 或 TS 文件");
  const entry = resolve(directory, m.entry);
  if (!existsSync(entry) || !lstatSync(entry).isFile()) fail("找不到插件入口文件");
  const keys = new Set<string>();
  for (const f of m.config) {
    if (!object(f) || !text(f.key) || !/^[a-z][a-z0-9_]{0,47}$/.test(f.key) || ["constructor", "prototype", "__proto__"].includes(f.key)
      || keys.has(f.key) || !text(f.label, 80) || !["string", "boolean", "number"].includes(f.type)
      || (f.description !== undefined && !text(f.description, 500)) || (f.required !== undefined && typeof f.required !== "boolean")) fail("插件配置项格式不正确");
    if (f.default !== undefined && (typeof f.default !== f.type || f.type === "number" && !Number.isFinite(f.default))) fail("插件配置默认值类型不正确");
    keys.add(f.key);
  }
  if (redactString(JSON.stringify(m)).count) fail("插件清单里含有疑似密钥，请先移除");
  return m;
}
function valuesFor(m: PluginManifest, input: unknown, required: boolean): InstalledPlugin["values"] {
  if (!object(input)) fail("配置必须是对象");
  const data = input as Record<string, unknown>;
  const result: InstalledPlugin["values"] = {};
  for (const key of Object.keys(data)) if (!m.config.some(f => f.key === key)) fail("配置中有未声明的项");
  for (const f of m.config) {
    const v = data[f.key] ?? f.default ?? (f.type === "boolean" ? false : undefined);
    if (v === undefined || v === "") { if (required && f.required) fail(`请填写${f.label}`); continue; }
    if (typeof v !== f.type || typeof v === "number" && !Number.isFinite(v) || typeof v === "string" && v.length > 4000) fail(`${f.label}的值不正确`);
    result[f.key] = v as string | boolean | number;
  }
  if (redactString(JSON.stringify(result)).count) fail("普通配置不能保存密钥，请移除疑似密钥内容");
  return result;
}
export function gitRevision(directory: string): string {
  const r = spawnSync("/usr/bin/git", ["-C", directory, "rev-parse", "--verify", "HEAD"], { encoding: "utf8", timeout: 5000 });
  const revision = r.stdout?.trim();
  if (r.status !== 0 || !/^[0-9a-f]{40,64}$/.test(revision ?? "")) fail("无法确定插件提交，未安装");
  return revision;
}
function snapshotHash(directory: string): string {
  const h = createHash("sha256"); let bytes = 0, count = 0;
  const visit = (dir: string) => {
    for (const name of readdirSync(dir).sort()) {
      if (name === ".git") continue;
      const path = join(dir, name), s = lstatSync(path);
      if (s.isSymbolicLink() || !s.isFile() && !s.isDirectory()) fail("插件不能包含符号链接或特殊文件");
      h.update(relative(directory, path) + "\0");
      if (s.isDirectory()) visit(path);
      else { bytes += s.size; count++; if (bytes > 25 * 1024 * 1024 || count > 2000) fail("插件过大，最多 25 MB、2000 个文件"); h.update(readFileSync(path)); }
    }
  }; visit(directory); return h.digest("hex");
}
function atomic(file: string, value: unknown) {
  const tmp = `${file}.${randomUUID()}.tmp`;
  try { writeFileSync(tmp, JSON.stringify(value) + "\n", { mode: 0o600, flag: "wx" }); renameSync(tmp, file); }
  finally { rmSync(tmp, { force: true }); }
}
export class PluginManager {
  root: string;
  constructor(readonly dataDir: string) { this.root = join(dataDir, "extensions"); mkdirSync(this.root, { recursive: true, mode: 0o700 }); }
  path(id: string) { return join(this.root, pluginID(id)); }
  installed(id: string): InstalledPlugin { return JSON.parse(readFileSync(join(this.path(id), "installed.json"), "utf8")); }
  list(): InstalledPlugin[] { return readdirSync(this.root).filter(x => x.startsWith("ext-")).sort().map(id => this.installed(id)); }
  async prepare(source: string, id?: string): Promise<PluginPreview> {
    if (!text(source, 2000) || redactString(source).count) fail("请选择本地目录或不含凭据的 Git 地址");
    if (id) { pluginID(id); if (this.installed(id).origin !== source) fail("更新必须使用原安装来源"); }
    const ticket = randomUUID(), stage = join(this.root, ".preview-" + ticket), code = join(stage, "code");
    mkdirSync(stage, { mode: 0o700 });
    try {
      let revision: string | undefined;
      if (isAbsolute(source)) {
        const original = realpathSync(source);
        const rel = relative(original, this.root);
        if (rel === "" || !rel.startsWith(`..${sep}`) && rel !== ".." && !isAbsolute(rel)) fail("不能把插件存储目录或其父目录作为安装来源");
        snapshotHash(original);
        cpSync(original, code, { recursive: true, filter: p => !p.split(sep).includes(".git") });
      } else {
        let url: URL; try { url = new URL(source); } catch { return fail("Git 地址需使用 https:// 或 ssh://"); }
        if (!["https:", "ssh:"].includes(url.protocol) || url.password || url.protocol === "https:" && url.username) fail("Git 地址需使用 HTTPS 或 SSH，不能包含密码或令牌");
        const r = spawnSync("/usr/bin/git", ["-c", "core.hooksPath=/dev/null", "-c", "protocol.ext.allow=never", "-c", "protocol.file.allow=never", "clone", "--depth", "1", "--", source, code],
          { timeout: 60_000, stdio: "ignore", env: { ...process.env, GIT_TERMINAL_PROMPT: "0", GIT_SSH_COMMAND: "ssh -oBatchMode=yes -oStrictHostKeyChecking=yes" } });
        if (r.status !== 0) fail("无法读取 Git 仓库，请检查地址、网络和本机 Git 权限");
        revision = gitRevision(code);
        rmSync(join(code, ".git"), { recursive: true, force: true });
      }
      const hash = snapshotHash(code), manifest = manifestAt(code);
      if (id && manifest.id !== id) fail("更新清单的 id 与原插件不同");
      if (!id && existsSync(this.path(manifest.id))) fail("这个插件已安装，请从它的详情页更新");
      const old = id ? this.installed(id) : undefined;
      const candidates = Object.fromEntries(manifest.config.filter(f => old?.values[f.key] !== undefined && typeof old.values[f.key] === f.type).map(f => [f.key, old!.values[f.key]]));
      const values = valuesFor(manifest, candidates, false);
      const preview = { ticket, manifest, origin: source, values, updating: !!id, revision, contentHash: hash, previousRevision: old?.revision };
      atomic(join(stage, "preview.json"), { ...preview, hash });
      return preview;
    } catch (error) { rmSync(stage, { recursive: true, force: true }); throw error; }
  }
  stage(ticket: string): string { if (!/^[0-9a-f-]{36}$/.test(ticket)) fail("安装预览已失效，请重新选择"); return join(this.root, ".preview-" + ticket); }
  install(ticket: string, input: unknown): InstalledPlugin {
    const stage = this.stage(ticket), p = JSON.parse(readFileSync(join(stage, "preview.json"), "utf8")) as PluginPreview & { hash: string };
    if (snapshotHash(join(stage, "code")) !== p.hash) fail("预览后的插件文件发生变化，请重新预览");
    const m = manifestAt(join(stage, "code")), values = valuesFor(m, input, true), target = this.path(m.id);
    if (existsSync(target) !== p.updating) fail("安装状态已变化，请重新预览");
    const installed = { manifest: m, origin: p.origin, values, revision: p.revision, contentHash: p.hash };
    atomic(join(stage, "installed.json"), installed);
    rmSync(join(stage, "preview.json"));
    const backup = join(this.root, ".previous-" + randomUUID());
    if (p.updating) renameSync(target, backup);
    try { renameSync(stage, target); } catch (error) { if (p.updating) renameSync(backup, target); throw error; }
    rmSync(backup, { recursive: true, force: true });
    return installed;
  }
  configure(id: string, input: unknown): InstalledPlugin {
    const p = this.installed(id); p.values = valuesFor(p.manifest, input, true); atomic(join(this.path(id), "installed.json"), p); return p;
  }
  async uninstall(id: string, deleteRecords: boolean, hub?: string) {
    this.installed(id); let deleted = 0;
    if (deleteRecords) {
      if (!hub) fail("后台服务未连接，记录尚未删除，插件也未卸载");
      const token = readFileSync(join(this.dataDir, "token"), "utf8").trim();
      const request = async (path: string, method = "GET", body?: unknown) => {
        const r = await fetch(new URL(path, hub), { method, headers: { authorization: `Bearer ${token}`, "content-type": "application/json" }, ...(body === undefined ? {} : {body: JSON.stringify(body)}), redirect: "error", signal: AbortSignal.timeout(30_000) });
        if (!r.ok) fail("删除未完成，插件仍保留且停用；请稍后重试");
        return r.json();
      };
      for (;;) {
        const page = await request(`/v1/records?source=${encodeURIComponent(pluginSource(id))}&limit=100`) as { records: { id: string }[] };
        if (!page.records.length) break;
        const result = await request("/v1/records", "DELETE", {ids: page.records.map(r=>r.id)}) as {deleted: number};
        deleted += result.deleted;
      }
    }
    rmSync(this.path(id), { recursive: true });
    rmSync(join(this.dataDir, "plugins", id), { recursive: true, force: true });
    return { deleted };
  }
  async dispatch(r: PluginRequest): Promise<unknown> {
    switch (r.action) {
      case "list": return { plugins: this.list() };
      case "prepare": return { preview: await this.prepare(r.source ?? "", r.id) };
      case "install": return { plugin: this.install(r.ticket ?? "", r.values ?? {}) };
      case "configure": return { plugin: this.configure(r.id ?? "", r.values ?? {}) };
      case "uninstall": return await this.uninstall(r.id ?? "", r.deleteRecords === true, r.hub);
      case "discard": rmSync(this.stage(r.ticket ?? ""), { recursive: true, force: true }); return {};
      default: return fail("未知插件操作");
    }
  }
}
export async function pluginCLI() {
  try { const request = await Bun.stdin.json() as PluginRequest; console.log(JSON.stringify(await new PluginManager(dataDirOf()).dispatch(request))); }
  catch (error) { console.log(JSON.stringify({ error: error instanceof PluginError ? error.message : "插件操作失败，请检查目录权限和清单后重试" })); process.exitCode = 1; }
}
