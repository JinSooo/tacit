#!/usr/bin/env bun
import { Database } from "bun:sqlite";
import { createHash } from "node:crypto";
import { copyFileSync, existsSync, mkdtempSync, readFileSync, rmSync } from "node:fs";
import { homedir, tmpdir } from "node:os";
import { basename, join } from "node:path";
import {
  clampTitle, emitCheckpoint, emitRecord, parsePluginArgs, toLocalIso, ulid, validateRecord,
  type RecordV1,
} from "../../packages/record/index.ts";

type Engine = "chromium" | "firefox" | "safari";
export interface Browser {
  name: string;
  bundleId: string;
  pathGlob: string;
  engine: Engine;
}

export const BROWSERS: readonly Browser[] = [
  { name: "Chrome", bundleId: "com.google.Chrome", pathGlob: "Library/Application Support/Google/Chrome/*/History", engine: "chromium" },
  { name: "Arc", bundleId: "company.thebrowser.Browser", pathGlob: "Library/Application Support/Arc/User Data/*/History", engine: "chromium" },
  { name: "ego lite", bundleId: "com.citrolabs.ego.lite", pathGlob: "Library/Application Support/Citro Labs/ego lite/*/History", engine: "chromium" },
  { name: "Zen", bundleId: "app.zen-browser.zen", pathGlob: "Library/Application Support/zen/Profiles/*/places.sqlite", engine: "firefox" },
  { name: "Safari", bundleId: "com.apple.Safari", pathGlob: "Library/Safari/History.db", engine: "safari" },
];

interface ProfileState {
  lastId: number;
  recent: [string, number][];
}
export interface BrowserState {
  version: 1;
  profiles: { [key: string]: ProfileState };
}
interface Visit {
  id: number;
  time: number;
  url: string | null;
  title: string | null;
  transition: number | null;
}

const ENGINES = {
  chromium: {
    from: "visits v LEFT JOIN urls u ON v.url = u.id",
    time: "v.visit_time", url: "u.url", title: "u.title", transition: "v.transition",
    epoch: Date.UTC(1601, 0, 1), scale: 0.001,
  },
  firefox: {
    from: "moz_historyvisits v LEFT JOIN moz_places u ON v.place_id = u.id",
    time: "v.visit_date", url: "u.url", title: "u.title", transition: "v.visit_type",
    epoch: 0, scale: 0.001,
  },
  safari: {
    from: "history_visits v LEFT JOIN history_items u ON v.history_item = u.id",
    time: "v.visit_time", url: "u.url", title: "v.title", transition: "NULL",
    epoch: Date.UTC(2001, 0, 1), scale: 1000,
  },
} as const;

/** 保留原始查询串，只移除 URL 权限段中的用户名和密码。 */
export function cleanUrl(raw: string | null): { url: string; hostname: string } | null {
  if (!raw) return null;
  try {
    const parsed = new URL(raw);
    if (!["https:", "http:"].includes(parsed.protocol)) return null;
    const host = parsed.hostname.toLowerCase().replace(/\.$/, "");
    if (host === "localhost" || host.endsWith(".localhost") || host === "[::1]" || /^127\./.test(host)) return null;
    return { url: raw.replace(/^(https?:\/\/)[^/?#]*@/i, "$1"), hostname: parsed.hostname };
  } catch {
    return null;
  }
}

/** 只读副本；即使复制、查询或下游输出失败，也清除 DB 和旁文件。 */
export function withDatabaseCopy<T>(source: string, read: (db: Database) => T): T {
  const dir = mkdtempSync(join(tmpdir(), "ra-browser-"));
  let db: Database | undefined;
  try {
    const destination = join(dir, basename(source));
    copyFileSync(source, destination);
    for (const suffix of ["-wal", "-shm"]) {
      try { copyFileSync(source + suffix, destination + suffix); }
      catch (error) {
        if ((error as NodeJS.ErrnoException).code !== "ENOENT") throw error;
      }
    }
    db = new Database(destination, { readonly: true });
    return read(db);
  } finally {
    try { db?.close(); } finally { rmSync(dir, { recursive: true, force: true }); }
  }
}

interface CollectOptions {
  device: string;
  home?: string;
  state?: BrowserState;
  since?: Date | null;
  now?: number;
  browsers?: readonly Browser[];
  onRecord: (record: RecordV1) => void;
  log?: (message: string) => void;
}

export async function collectBrowserHistory(options: CollectOptions): Promise<{ state: BrowserState; failed: boolean }> {
  const home = options.home ?? process.env.RA_BROWSER_HOME ?? homedir();
  const state: BrowserState = structuredClone(options.state ?? { version: 1, profiles: {} });
  const log = options.log ?? ((message: string) => console.error(message));
  const cutoff = options.since?.getTime() ?? (options.now ?? Date.now()) - 7 * 86400_000;
  if (!Number.isFinite(cutoff)) throw new Error("--since 必须是有效的 RFC3339 时间");
  let failed = false;
  for (const browser of options.browsers ?? BROWSERS) {
    let paths: string[];
    try {
      // Safari 使用固定路径，必须尝试打开，不能把无权限误当成不存在。
      paths = browser.engine === "safari"
        ? [browser.pathGlob]
        : [...new Bun.Glob(browser.pathGlob).scanSync({ cwd: home, onlyFiles: true })].sort();
    } catch {
      log(`${browser.name}：无法枚举历史库，已跳过。`);
      failed = true;
      continue;
    }
    for (const relativePath of paths) {
      const profile = basename(join(relativePath, ".."));
      const key = `${browser.name}:${profile}`;
      const previous = state.profiles[key];
      let next: ProfileState;
      try {
        next = withDatabaseCopy(join(home, relativePath), (db) => {
          const engine = ENGINES[browser.engine];
          const rows = db.query<Visit, [number]>(
            `SELECT v.id, ${engine.time} AS time, ${engine.url} AS url,
             ${engine.title} AS title, ${engine.transition} AS transition
             FROM ${engine.from} WHERE v.id > ? ORDER BY ${engine.time}, v.id`,
          ).all(previous?.lastId ?? 0);
          let lastId = previous?.lastId ?? 0;
          const recent = new Map(previous?.recent ?? []);
          let latest = Math.max(-Infinity, ...recent.values());
          for (const row of rows) {
            lastId = Math.max(lastId, row.id);
            const time = row.time * engine.scale + engine.epoch;
            if (!Number.isFinite(time) || Math.abs(time) > 8.64e15) continue;
            if ((!previous || options.since) && time < cutoff) continue;
            const cleaned = cleanUrl(row.url);
            if (!cleaned) continue;
            const hash = createHash("sha256").update(cleaned.url).digest("hex");
            const first = recent.get(hash);
            if (first !== undefined && Math.abs(time - first) <= 30_000) continue;
            const title = clampTitle(row.title?.trim() || cleaned.hostname);
            const record: RecordV1 = {
              id: ulid(), schema: 1, device: options.device, source: "mac.browser",
              source_ref: `${key}:${row.id}`, kind: "event", t_start: toLocalIso(time),
              context: {
                app: browser.bundleId, url: cleaned.url,
                extra: { profile, ...(row.transition === null ? {} : { transition: row.transition }) },
              },
              title, body: `${title}\n${cleaned.url}`, capture: { method: "db" }, sensitivity: "normal",
            };
            const validation = validateRecord(record);
            if (!validation.ok) throw new Error("浏览记录不符合记录契约");
            options.onRecord(record);
            recent.set(hash, time);
            latest = Math.max(latest, time);
          }
          return { lastId, recent: [...recent].filter(([, time]) => time >= latest - 30_000) };
        });
      } catch {
        if (browser.engine === "safari") {
          log("Safari：无法读取历史库，请检查是否存在及采集端的完全磁盘访问权限，已跳过。");
        } else {
          log(`${browser.name}：历史库读取或记录输出失败，已跳过该 profile；本次 checkpoint 不应保存。`);
          failed = true;
        }
        continue;
      }
      state.profiles[key] = next;
    }
  }
  return { state, failed };
}

function loadState(file: string | null): BrowserState | undefined {
  if (!file || !existsSync(file)) return undefined;
  const state = JSON.parse(readFileSync(file, "utf8")) as BrowserState;
  if (state.version !== 1 || !state.profiles || typeof state.profiles !== "object" || Array.isArray(state.profiles)) {
    throw new Error("浏览器 checkpoint 格式无效");
  }
  for (const entry of Object.values(state.profiles)) {
    if (!entry || !Number.isSafeInteger(entry.lastId) || entry.lastId < 0 || !Array.isArray(entry.recent)
      || !entry.recent.every((pair) => Array.isArray(pair) && pair.length === 2
        && typeof pair[0] === "string" && /^[a-f0-9]{64}$/.test(pair[0]) && Number.isFinite(pair[1]))) {
      throw new Error("浏览器 checkpoint 进度无效");
    }
  }
  return state;
}

if (import.meta.main) {
  try {
    const args = parsePluginArgs();
    if (!args.argv.includes("--device") || !/^[a-z0-9][a-z0-9-]{0,62}$/.test(args.device)) {
      throw new Error("请用 --device 指定有效的设备名");
    }
    if (args.since && (!Number.isFinite(args.since.getTime())
      || !/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:\d{2})$/i.test(args.argv[args.argv.indexOf("--since") + 1] ?? ""))) {
      throw new Error("--since 必须是带时区的 RFC3339 时间");
    }
    for (const flag of ["--state", "--since"]) {
      const index = args.argv.indexOf(flag);
      if (index >= 0 && (!args.argv[index + 1] || args.argv[index + 1].startsWith("--"))) throw new Error(`${flag} 缺少参数`);
    }
    const result = await collectBrowserHistory({ device: args.device, state: loadState(args.stateFile), since: args.since, onRecord: emitRecord });
    if (result.failed) process.exitCode = 1;
    else emitCheckpoint(result.state);
  } catch (error) {
    // 不输出底层异常，避免数据库内容、URL 或凭据进入日志。
    console.error(error instanceof Error && /^(请用|--|浏览器 checkpoint)/.test(error.message) ? error.message : "浏览器插件运行失败。");
    process.exitCode = 1;
  }
}
