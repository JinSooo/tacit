import type { Lang } from "./i18n/language.ts";
import { cliText } from "./agent-cli/locale.ts";
import { readHubBinding } from "./hub-binding.ts";
// 应用自己完成安装后的准备：数据目录与密钥、AI 工具连接路径、后台服务的启动配置。
// 安装包首次打开、升级后打开，以及源码安装的 install.sh 都走这里；重复运行只改有变化的部分。
import { accessSync, chmodSync, closeSync, constants, existsSync, fchmodSync, mkdirSync, openSync, readFileSync, readdirSync, realpathSync, rmSync, statSync, writeFileSync } from "node:fs";
import { createServer } from "node:net";
import { homedir, userInfo } from "node:os";
import { dirname, join } from "node:path";
import { spawnSync } from "node:child_process";
import { dataDirOf, resolveLanBinding, resolvePort, writeHubPort } from "./hub-json.ts";
import { initializeCodexConfig } from "./llm/config.ts";
import { SHELL_ENV } from "./llm/process.ts";

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

function toolLocations(home: string, search: string[], system = SYSTEM) {
  const nvm = join(home, ".nvm/versions/node");
  let latestNvm: string | undefined;
  try {
    latestNvm = readdirSync(nvm)
      .filter(version => /^v\d+\.\d+\.\d+$/.test(version) && executable(join(nvm, version, "bin/node")))
      .sort((a, b) => b.localeCompare(a, "en", { numeric: true }))[0];
  } catch {}
  const fallback = [".local/share/mise/shims", ".local/bin", ".bun/bin", ".npm-global/bin",
    ".fnm/aliases/default/bin", ".volta/bin", ".asdf/shims"].map(p => join(home, p));
  if (latestNvm) fallback.push(join(nvm, latestNvm, "bin"));
  const candidates = [...search, ...fallback, ...system];
  return {
    codex: toolDirectory("codex", candidates),
    claude: toolDirectory("claude", candidates),
    node: toolDirectory("node", candidates),
  };
}

/** 后台服务的 PATH：整理工具与它们通过 env 调用的 node 都要能找到。 */
export function servicePath(bun: string, home: string, search: string[], warn: (message: string) => void = () => {}, lang: Lang = "zh"): string {
  return pathForTools(bun, toolLocations(home, search), warn, lang);
}

function pathForTools(bun: string, tools: ReturnType<typeof toolLocations>, warn: (message: string) => void, lang: Lang): string {
  for (const name of ["codex", "claude"] as const) {
    if (!tools[name]) warn(cliText(`没找到 ${name}；装好并登录后点“重新准备”即可使用。`, `Could not find ${name}. Install it, sign in, and click Prepare again.`, lang));
  }
  return [...new Set([...Object.values(tools).filter(dir => dir !== null), dirname(bun), ...SYSTEM])].join(":");
}

/** 从 Finder 或 launchd 启动时没有终端的环境，读一次用户登录 shell 的 PATH、代理和 CODEX_HOME（不读其他变量，密钥不落进启动配置）。 */
export function loginShellEnv(): Record<string, string> {
  let shell = "/bin/zsh";
  try { shell = userInfo().shell || shell; } catch {}
  const marker = "__TACIT_ENV__";
  const result = spawnSync(shell, ["-ilc", `printf '\\n%s\\n' ${marker}; env; printf '\\n%s\\n' ${marker}`], {
    encoding: "utf8", timeout: 5000, stdio: ["ignore", "pipe", "ignore"],
  });
  return parseShellEnv(result.stdout ?? "", marker);
}
export function parseShellEnv(stdout: string, marker = "__TACIT_ENV__"): Record<string, string> {
  const body = stdout.split(`\n${marker}\n`)[1];
  if (body === undefined) return {};
  const out: Record<string, string> = {};
  for (const line of body.split("\n")) {
    const i = line.indexOf("=");
    if (i <= 0) continue;
    const key = line.slice(0, i), value = line.slice(i + 1);
    if ((key === "PATH" || SHELL_ENV.test(key)) && value) out[key] = value;
  }
  return out;
}

export interface ServiceLayout { app: string; runtime: string; bun: string; data: string; path: string; cliEnv?: Record<string, string>; hubEnv?: Record<string, string> }

export function plist(job: Job, l: ServiceLayout): string {
  const cli = join(l.runtime, "hub/src/cli.ts");
  const program = job === "collector" ? [join(l.app, "Contents/MacOS/Tacit")] : [l.bun, cli, job === "hub" ? "serve" : "distill"];
  const path = job === "collector" ? [dirname(l.bun), ...SYSTEM].join(":") : l.path;
  const body: string[] = [
    `  <key>Label</key><string>${label(job)}</string>`,
    `  <key>ProgramArguments</key><array>${program.map(p => `<string>${xml(p)}</string>`).join("")}</array>`,
  ];
  if (job !== "collector") body.push(`  <key>WorkingDirectory</key><string>${xml(l.runtime)}</string>`);
  const extra = job !== "collector" && l.cliEnv && Object.keys(l.cliEnv).length ? `<key>TACIT_CLI_ENV</key><string>${xml(JSON.stringify(l.cliEnv))}</string>` : "";
  const hubEnv = job === "collector" ? "" : Object.entries(l.hubEnv ?? {})
    .map(([key, value]) => `<key>${xml(key)}</key><string>${xml(value)}</string>`).join("");
  body.push(`  <key>EnvironmentVariables</key><dict><key>PATH</key><string>${xml(path)}</string>${extra}${hubEnv}</dict>`, `  <key>RunAtLoad</key><true/>`);
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
  lang?: Lang;
  app: string;
  /** 源码安装：无论记录如何都完整初始化，并启动采集端。 */
  install?: boolean;
  retry?: boolean;
  /** 源码安装的 RA_NO_DISTILL=1：停用整理并记住这个选择。 */
  distill?: boolean;
  home?: string;
  env?: NodeJS.ProcessEnv;
  launchctl?: (args: string[]) => number;
  healthy?: (port: number) => Promise<boolean>;
  probePort?: typeof probePort;
  wait?: (ms: number) => Promise<void>;
  shellEnv?: () => Record<string, string>;
  systemPath?: string[];
  initialize?: () => Promise<void>;
  relocate?: (runtime: string, bun: string, home: string) => string[];
  dropRemovedSettings?: () => void;
  version?: (app: string) => string;
  log?: (message: string) => void;
}
interface Stamp { app: string; version: string; distill: boolean }
/** 只装入写给用户的固定文案，系统异常交给 CLI 按错误码处理。 */
export class SetupError extends Error {
  constructor(readonly reason: "bundle_incomplete" | "database" | "background_blocked" | "service_unhealthy" | "port_in_use", message: string) {
    super(message);
  }
}

/** Bind briefly to distinguish an occupied port from one the system can allocate. */
export function probePort(port: number, host: string): Promise<number | null> {
  return new Promise((resolve, reject) => {
    const server = createServer();
    server.once("error", (error: NodeJS.ErrnoException) => {
      if (error.code === "EADDRINUSE") resolve(null);
      else reject(error);
    });
    server.listen(port, host, () => {
      const address = server.address();
      server.close(error => {
        if (error) reject(error);
        else resolve(typeof address === "object" && address !== null ? address.port : null);
      });
    });
  });
}

function writePrivate(file: string, text: string) {
  writeFileSync(file, text, { mode: 0o600 }); chmodSync(file, 0o600);
}
function readJSON(file: string): any {
  try { return JSON.parse(readFileSync(file, "utf8")); } catch { return null; }
}

export async function setup(o: SetupOptions): Promise<{ full: boolean; restarted: boolean }> {
  const home = o.home ?? homedir(), env = o.env ?? process.env, log = o.log ?? (m => console.log(m));
  const lang = o.lang ?? "zh";
  const t = (zh: string, en: string) => cliText(zh, en, lang);
  const runtime = join(o.app, "Contents/Resources/runtime"), bun = join(o.app, "Contents/Helpers/Tacit");
  if (!existsSync(join(runtime, "hub/src/cli.ts")) || !executable(bun)) throw new SetupError("bundle_incomplete", t("Tacit 安装包不完整", "The Tacit installation is incomplete"));
  const data = dataDirOf(env);
  const { remote } = readHubBinding(data);
  const launchctl = o.launchctl ?? ((args: string[]) => spawnSync("/bin/launchctl", args, { stdio: "ignore" }).status ?? 1);
  const domain = `gui/${process.getuid?.() ?? 0}`;
  const version = (o.version ?? (app => {
    const r = spawnSync("/usr/bin/plutil", ["-extract", "CFBundleVersion", "raw", "-o", "-", join(app, "Contents/Info.plist")], { encoding: "utf8" });
    return r.status === 0 ? r.stdout.trim() : "";
  }))(o.app);

  const stampFile = join(data, "app-setup.json");
  const previous = readJSON(stampFile) as Stamp | null;
  const distill = (remote ? previous?.distill : o.distill ?? previous?.distill) ?? true;
  // 运行时换过位置（2026-11-24 从 Contents/MacOS/bun 移到 Contents/Helpers/Tacit）也要重新准备，AI 工具连接才会改到新路径；同版本重装时也成立。
  const full = !!o.install || previous?.app !== o.app || previous?.version !== version
    || readJSON(join(data, "collector.json"))?.bun !== bun;

  mkdirSync(join(data, "logs"), { recursive: true });
  chmodSync(data, 0o700);
  const setupLog = openSync(join(data, "logs", "setup.log"), constants.O_WRONLY | constants.O_CREAT | constants.O_NOFOLLOW, 0o600);
  try { fchmodSync(setupLog, 0o600); } finally { closeSync(setupLog); }
  if (full) {
    // 前台创建或读取钥匙串里的数据库密钥，并试开一次数据库，失败当场可见。
    if (!remote) {
      // 在数据库初始化前校验端口，配置错误由 setup 按未知失败处理。
      resolvePort(env, data);
      resolveLanBinding(data, env);
      try {
        await (o.initialize ?? (async () => {
          const [{ loadConfig }, { HubDB }] = await Promise.all([import("./config.ts"), import("./db.ts")]);
          const config = loadConfig(env);
          new HubDB(join(config.dataDir, "history.db"), config.dbKey).close();
        }))();
      } catch {
        throw new SetupError("database", t(
          "无法打开加密数据库，请检查钥匙串和数据库密钥。",
          "Could not open the encrypted database. Check the Keychain and your database key.",
        ));
      }
    }
    // 采集端配置只更新运行目录和 bun，保留用户改过的其他项。
    const collector = join(data, "collector.json");
    writePrivate(collector, JSON.stringify({ ...(readJSON(collector) ?? {}), repo: runtime, bun }, null, 2) + "\n");
    const relocate = o.relocate ?? (await import("./relocate-install.ts")).relocateInstall;
    // 连接迁移失败不能挡住后台启动；用户可以在设置里重新连接。
    try {
      const count = relocate(runtime, bun, home).length;
      log(t(`已更新 ${count} 份 AI 工具连接配置。`, `Updated ${count} AI tool ${count === 1 ? "connection" : "connections"}.`));
    }
    catch { log(t("AI 工具连接没有迁移，请在 设置 › AI 工具 里重新连接。", "AI tool connections could not be moved. Reconnect them in Settings → AI tools.")); }
    (o.dropRemovedSettings ?? (() => {
      for (const key of REMOVED_SETTINGS) spawnSync("/usr/bin/defaults", ["delete", "dev.record-anything.collector", key], { stdio: "ignore" });
    }))();
  }

  // 关闭登录启动时定义保存在数据目录；升级沿用这个选择。
  const manual = join(data, "launch-agents");
  const agents = existsSync(join(manual, `${label("collector")}.plist`)) ? manual : join(home, "Library/LaunchAgents");
  mkdirSync(agents, { recursive: true });
  // 终端里运行 install.sh 和从 Finder 打开应用得到同一个 PATH：都先看登录 shell 的 PATH。
  const { PATH: shellPath = "", ...shellVars } = (o.shellEnv ?? loginShellEnv)();
  const search = [...shellPath.split(":").filter(Boolean), ...(env.PATH ?? "").split(":").filter(Boolean)];
  const tools = toolLocations(home, search, o.systemPath);
  const path = pathForTools(bun, tools, log, lang);
  if (full && !remote && !tools.claude && tools.codex && !existsSync(join(data, "models.json"))) {
    await initializeCodexConfig(data);
  }
  // 终端里的代理和 CODEX_HOME 交给后台调用的 codex、claude，不然终端里能用、Tacit 里连不上。
  const hubEnv: Record<string, string> = { RA_DATA_DIR: data };
  for (const key of ["RA_PORT", "RA_LAN_PORT"]) {
    if (env[key] !== undefined) hubEnv[key] = env[key];
  }
  const layout: ServiceLayout = { app: o.app, runtime, bun, data, path, cliEnv: shellVars, hubEnv };
  const changed = new Set<Job>();
  for (const job of remote ? ["collector"] as const : JOBS) {
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
      log(t(`后台任务 ${label(job)} 加载返回 launchctl 退出码 ${status}（第 ${i + 1} 次）`, `launchctl exited with code ${status} while loading ${label(job)} (attempt ${i + 1})`));
      if (loaded(job)) return;
      await wait(1000);
    }
    throw new SetupError("background_blocked", t(`后台任务 ${label(job)} 没能加载，请重新打开 Tacit`, `Could not load ${label(job)}. Reopen Tacit.`));
  };
  const restart = !remote && (full || o.retry === true || changed.has("hub") || changed.has("distill"));
  if (restart) for (const job of ["distill", "hub"] as const) await unload(job);
  if (!remote) {
    const startupMarker = join(data, "hub-startup-error.json");
    if (restart || !loaded("hub")) rmSync(startupMarker, { force: true });
    let { port, source } = resolvePort(env, data);
    const probe = o.probePort ?? probePort;
    const occupied = () => new SetupError("port_in_use", t(
      "后台服务的端口被占用了。请在设置 › 后台与连接里更换端口。",
      "The background service port is in use. Change it in Settings → Background & connection.",
    ));
    if (restart || !loaded("hub")) {
      if (port !== 0 && await probe(port, "127.0.0.1") === null) {
        if (source !== "default") throw occupied();
        const free = await probe(0, "127.0.0.1");
        if (free === null) throw occupied();
        writeHubPort(data, free);
        port = free;
      }
      // Mac 的设备监听按需打开。只为默认值腾出端口，用户固定的设备端口保持原值。
      const lan = resolveLanBinding(data, env);
      if (lan.source === "default" && (lan.port === port || await probe(lan.port, "0.0.0.0") === null)) {
        const free = await probe(0, "0.0.0.0");
        if (free !== null && free !== port) writeHubPort(data, free, "lan_port");
      }
      await load("hub");
    }
    const healthy = o.healthy ?? (async (p: number) => {
      for (let i = 0; i < 15; i++) {
        const started = Date.now();
        try {
          const response = await fetch(`http://127.0.0.1:${p}/v1/health`, { signal: AbortSignal.timeout(1000) });
          if (response.ok && (await response.json() as { ok?: boolean }).ok === true) return true;
        } catch {}
        await wait(Math.max(0, 1000 - (Date.now() - started)));
      }
      return false;
    });
    if (!(await healthy(port))) {
      const code = readJSON(startupMarker)?.code;
      if (code === "port_in_use") throw occupied();
      if (["db_key_missing", "db_key_unreadable", "db_open_failed", "db_migration_failed"].includes(code)) {
        throw new SetupError("database", t("无法打开加密数据库。请检查钥匙串和数据库密钥。", "Could not open the encrypted database. Check the Keychain and your database key."));
      }
      throw new SetupError("service_unhealthy", t("后台服务没能启动。请重新准备。", "The background service did not start. Prepare it again."));
    }
  }
  if (!remote && distill && (restart || !loaded("distill"))) await load("distill");
  // 先记下已完成，采集端启动后自己再跑一次时就不会重复初始化。
  if (full || previous?.distill !== distill) writePrivate(stampFile, JSON.stringify({ app: o.app, version, distill } satisfies Stamp) + "\n");
  if (o.install) await load("collector");
  return { full, restarted: restart };
}
