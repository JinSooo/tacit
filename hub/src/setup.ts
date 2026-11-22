// 应用自己完成安装后的准备：数据目录与密钥、AI 工具连接路径、后台服务的启动配置。
// 安装包首次打开、升级后打开，以及源码安装的 install.sh 都走这里；重复运行只改有变化的部分。
import { accessSync, chmodSync, closeSync, constants, existsSync, fchmodSync, mkdirSync, openSync, readFileSync, realpathSync, rmSync, statSync, writeFileSync } from "node:fs";
import { homedir, userInfo } from "node:os";
import { dirname, join } from "node:path";
import { spawnSync } from "node:child_process";
import { dataDirOf, resolvePort } from "./hub-json.ts";

const SYSTEM = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"];
/** 已撤下的采集来源（2026-11-22）：升级时清掉它们在采集端留下的开关和配置。 */
const REMOVED_SETTINGS = ["git", "shell", "files", "clipboard", "calendar"].map(s => `source.${s}.enabled`).concat("files.directories");
export const JOBS = ["hub", "distill", "collector"] as const;
type Job = typeof JOBS[number];
const label = (job: Job) => `dev.record-anything.${job}`;
const xml = (s: string) => s.replaceAll("&", "&amp;").replaceAll("<", "&lt;").replaceAll(">", "&gt;");

function temporary(path: string) {
  return /^\/(?:private\/)?(?:var\/folders|tmp)\//.test(path) || path.includes("-shims");
}
function executable(path: string) {
  try { accessSync(path, constants.X_OK); return statSync(path).isFile(); } catch { return false; }
}
function real(path: string) { try { return realpathSync(path); } catch { return null; } }

/** CLI 所在的稳定目录：优先同名稳定入口（升级只改链接目标，不把 PATH 钉在旧版本目录）；只有临时 shim 时退到真实目录。 */
export function toolDirectory(name: string, candidates: string[]): string | null {
  for (const dir of candidates) {
    if (!dir || temporary(dir)) continue;
    const target = real(join(dir, name));
    if (executable(join(dir, name)) && target && !temporary(target)) return dir;
  }
  for (const dir of candidates) {
    const target = dir ? real(join(dir, name)) : null;
    if (!target || temporary(target) || !executable(target)) continue;
    const entry = join(dirname(target), name);
    if (executable(entry) && real(entry) === target) return dirname(target);
  }
  return null;
}

/** 后台服务的 PATH：设置页“测试连接”和整理都要找到本机已登录的 codex、claude。 */
export function servicePath(bun: string, home: string, search: string[], warn: (message: string) => void = () => {}): string {
  const fallback = [".local/share/mise/shims", ".local/bin", ".bun/bin", ".npm-global/bin"].map(p => join(home, p)).concat(SYSTEM);
  const dirs: string[] = [];
  for (const name of ["codex", "claude"]) {
    const found = toolDirectory(name, [...search, ...fallback]);
    if (found) dirs.push(found);
    else warn(`没找到 ${name}；装好并登录后重新打开 Tacit 即可使用。`);
  }
  return [...new Set([...dirs, dirname(bun), ...SYSTEM])].join(":");
}

/** 从 Finder 或 launchd 启动时没有终端的 PATH，读一次用户登录 shell 的 PATH。 */
export function loginShellPath(): string[] {
  let shell = "/bin/zsh";
  try { shell = userInfo().shell || shell; } catch {}
  const marker = "__TACIT_PATH__";
  const result = spawnSync(shell, ["-ilc", `printf '%s%s%s' ${marker} "$PATH" ${marker}`], {
    encoding: "utf8", timeout: 5000, stdio: ["ignore", "pipe", "ignore"],
  });
  const match = new RegExp(`${marker}(.*?)${marker}`).exec(result.stdout ?? "");
  return match ? match[1]!.split(":").filter(Boolean) : [];
}

export interface ServiceLayout { app: string; runtime: string; bun: string; data: string; path: string }

export function plist(job: Job, l: ServiceLayout): string {
  const cli = join(l.runtime, "hub/src/cli.ts");
  const program = job === "collector" ? [join(l.app, "Contents/MacOS/Tacit")] : [l.bun, cli, job === "hub" ? "serve" : "distill"];
  const path = job === "collector" ? [dirname(l.bun), ...SYSTEM].join(":") : l.path;
  const body: string[] = [
    `  <key>Label</key><string>${label(job)}</string>`,
    `  <key>ProgramArguments</key><array>${program.map(p => `<string>${xml(p)}</string>`).join("")}</array>`,
  ];
  if (job !== "collector") body.push(`  <key>WorkingDirectory</key><string>${xml(l.runtime)}</string>`);
  body.push(`  <key>EnvironmentVariables</key><dict><key>PATH</key><string>${xml(path)}</string></dict>`, `  <key>RunAtLoad</key><true/>`);
  if (job === "hub") body.push(`  <key>KeepAlive</key><true/>`, `  <key>ThrottleInterval</key><integer>10</integer>`, `  <key>ProcessType</key><string>Background</string>`);
  if (job === "distill") body.push(`  <key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>`, `  <key>ThrottleInterval</key><integer>60</integer>`,
    `  <key>ProcessType</key><string>Background</string>`, `  <key>LowPriorityIO</key><true/>`, `  <key>Nice</key><integer>10</integer>`);
  // 从菜单“退出”是正常退出，不自动拉起；崩溃才拉起。
  if (job === "collector") body.push(`  <key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>`,
    `  <key>LimitLoadToSessionType</key><string>Aqua</string>`, `  <key>ProcessType</key><string>Interactive</string>`);
  const log = join(l.data, "logs", `${job}.log`);
  if (job !== "collector") body.push(`  <key>StandardOutPath</key><string>${xml(log)}</string>`);
  body.push(`  <key>StandardErrorPath</key><string>${xml(log)}</string>`);
  return `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
${body.join("\n")}
</dict></plist>
`;
}

export interface SetupOptions {
  app: string;
  /** 源码安装：无论记录如何都完整初始化，并启动采集端。 */
  install?: boolean;
  /** 源码安装的 RA_NO_DISTILL=1：停用整理并记住这个选择。 */
  distill?: boolean;
  home?: string;
  env?: NodeJS.ProcessEnv;
  launchctl?: (args: string[]) => number;
  healthy?: (port: number) => Promise<boolean>;
  wait?: (ms: number) => Promise<void>;
  shellPath?: () => string[];
  initialize?: () => Promise<void>;
  relocate?: (runtime: string, bun: string, home: string) => string[];
  dropRemovedSettings?: () => void;
  version?: (app: string) => string;
  log?: (message: string) => void;
}
interface Stamp { app: string; version: string; distill: boolean }
/** 只装入写给用户的固定文案，系统异常交给 CLI 按错误码处理。 */
export class SetupError extends Error {}

function writePrivate(file: string, text: string) {
  writeFileSync(file, text, { mode: 0o600 }); chmodSync(file, 0o600);
}
function readJSON(file: string): any {
  try { return JSON.parse(readFileSync(file, "utf8")); } catch { return null; }
}

export async function setup(o: SetupOptions): Promise<{ full: boolean; restarted: boolean }> {
  const home = o.home ?? homedir(), env = o.env ?? process.env, log = o.log ?? (m => console.log(m));
  const runtime = join(o.app, "Contents/Resources/runtime"), bun = join(o.app, "Contents/MacOS/bun");
  if (!existsSync(join(runtime, "hub/src/cli.ts")) || !executable(bun)) throw new SetupError("Tacit 安装包不完整");
  const data = dataDirOf(env);
  const launchctl = o.launchctl ?? ((args: string[]) => spawnSync("/bin/launchctl", args, { stdio: "ignore" }).status ?? 1);
  const domain = `gui/${process.getuid?.() ?? 0}`;
  const version = (o.version ?? (app => {
    const r = spawnSync("/usr/bin/plutil", ["-extract", "CFBundleVersion", "raw", "-o", "-", join(app, "Contents/Info.plist")], { encoding: "utf8" });
    return r.status === 0 ? r.stdout.trim() : "";
  }))(o.app);

  const stampFile = join(data, "app-setup.json");
  const previous = readJSON(stampFile) as Stamp | null;
  const distill = o.distill ?? previous?.distill ?? true;
  const full = !!o.install || previous?.app !== o.app || previous?.version !== version;

  mkdirSync(join(data, "logs"), { recursive: true });
  chmodSync(data, 0o700);
  const setupLog = openSync(join(data, "logs", "setup.log"), constants.O_WRONLY | constants.O_CREAT | constants.O_NOFOLLOW, 0o600);
  try { fchmodSync(setupLog, 0o600); } finally { closeSync(setupLog); }
  if (full) {
    // 前台创建或读取钥匙串里的数据库密钥，并试开一次数据库，失败当场可见。
    await (o.initialize ?? (async () => {
      const [{ loadConfig }, { HubDB }] = await Promise.all([import("./config.ts"), import("./db.ts")]);
      const config = loadConfig(env);
      // 打开失败的消息可能带出密钥，只报原因类别。
      try { new HubDB(join(config.dataDir, "history.db"), config.dbKey).close(); }
      catch { throw new SetupError("无法打开加密数据库，请确认钥匙串里的数据库密钥与数据目录匹配"); }
    }))();
    // 采集端配置只更新运行目录和 bun，保留用户改过的其他项。
    const collector = join(data, "collector.json");
    writePrivate(collector, JSON.stringify({ ...(readJSON(collector) ?? {}), repo: runtime, bun }, null, 2) + "\n");
    const relocate = o.relocate ?? (await import("./relocate-install.ts")).relocateInstall;
    // 连接迁移失败不能挡住后台启动；用户可以在设置里重新连接。
    try { log(`已更新 ${relocate(runtime, bun, home).length} 份 AI 工具连接配置。`); }
    catch { log("AI 工具连接没有迁移，请在 设置 › AI 工具 里重新连接。"); }
    (o.dropRemovedSettings ?? (() => {
      for (const key of REMOVED_SETTINGS) spawnSync("/usr/bin/defaults", ["delete", "dev.record-anything.collector", key], { stdio: "ignore" });
    }))();
  }

  // 关闭登录启动时定义保存在数据目录；升级沿用这个选择。
  const manual = join(data, "launch-agents");
  const agents = existsSync(join(manual, `${label("collector")}.plist`)) ? manual : join(home, "Library/LaunchAgents");
  mkdirSync(agents, { recursive: true });
  // 终端里运行 install.sh 和从 Finder 打开应用得到同一个 PATH：都先看登录 shell 的 PATH。
  const search = [...(o.shellPath ?? loginShellPath)(), ...(env.PATH ?? "").split(":").filter(Boolean)];
  const path = servicePath(bun, home, search, log);
  const layout: ServiceLayout = { app: o.app, runtime, bun, data, path };
  const changed = new Set<Job>();
  for (const job of JOBS) {
    const file = join(agents, `${label(job)}.plist`);
    if (job === "distill" && !distill) {
      if (existsSync(file)) { rmSync(file); changed.add(job); }
      continue;
    }
    const text = plist(job, layout);
    let before: string | null = null;
    try { before = readFileSync(file, "utf8"); } catch {}
    if (before !== text) { writeFileSync(file, text); changed.add(job); }
  }

  const wait = o.wait ?? (ms => Bun.sleep(ms));
  const loaded = (job: Job) => launchctl(["print", `${domain}/${label(job)}`]) === 0;
  // bootout 返回时旧任务可能还没退完，紧接着 bootstrap 会失败、任务就此没有加载（2026-11-19 升级实测）。
  const unload = async (job: Job) => {
    launchctl(["bootout", `${domain}/${label(job)}`]);
    for (let i = 0; i < 40 && loaded(job); i++) await wait(250);
  };
  const load = async (job: Job) => {
    for (let i = 0; i < 5; i++) {
      const status = launchctl(["bootstrap", domain, join(agents, `${label(job)}.plist`)]);
      if (status === 0) return;
      log(`后台任务 ${label(job)} 加载返回 launchctl 退出码 ${status}（第 ${i + 1} 次）`);
      if (loaded(job)) return;
      await wait(1000);
    }
    throw new SetupError(`后台任务 ${label(job)} 没能加载，请重新打开 Tacit`);
  };
  const restart = full || changed.has("hub") || changed.has("distill");
  if (restart) for (const job of ["distill", "hub"] as const) await unload(job);
  if (restart || !loaded("hub")) {
    await load("hub");
    const { port } = resolvePort(env, data);
    const healthy = o.healthy ?? (async (p: number) => {
      for (let i = 0; i < 15; i++) {
        try { if ((await fetch(`http://127.0.0.1:${p}/v1/health`)).ok) return true; } catch {}
        await wait(1000);
      }
      return false;
    });
    if (!(await healthy(port))) throw new SetupError("后台服务没能启动，请查看 logs/hub.log");
  }
  if (distill && (restart || !loaded("distill"))) await load("distill");
  // 先记下已完成，采集端启动后自己再跑一次时就不会重复初始化。
  if (full || previous?.distill !== distill) writePrivate(stampFile, JSON.stringify({ app: o.app, version, distill } satisfies Stamp) + "\n");
  if (o.install) await load("collector");
  return { full, restarted: restart };
}
