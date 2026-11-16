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
  groupedAfter?: number;
  groupedSince?: number;
  closedThrough?: number[];
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
  legacy: 0 | 1;
}
interface Page {
  id: number;
  time: number;
  url: string;
  host: string;
  title: string;
  transition: number | null;
}
const CONTINUOUS_GAP_MS = 30_000;
const MAX_GROUP_MS = 5 * 60_000;
const MAX_GROUP_URL_CHARS = 199_799; // 给换行和最长 200 字的标题留出空间。

function replayBatch(visitId: number, closedThrough: number[]): number {
  let first = 0, end = closedThrough.length;
  while (first < end) {
    const middle = Math.floor((first + end) / 2);
    if (visitId <= closedThrough[middle]!) end = middle;
    else first = middle + 1;
  }
  return first;
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
  const now = options.now ?? Date.now();
  const cutoff = options.since?.getTime() ?? now - 7 * 86400_000;
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
      // 启用合并前已经读过的访问沿用旧的 source_ref 和逐条重放方式。
      const groupedAfter = previous?.groupedAfter ?? previous?.lastId ?? 0;
      const groupedSince = previous ? previous.groupedSince : cutoff;
      const closedThrough = previous?.closedThrough ?? [];
      let next: ProfileState;
      try {
        next = withDatabaseCopy(join(home, relativePath), (db) => {
          const engine = ENGINES[browser.engine];
          const groupingStart = groupedSince === undefined ? null : (groupedSince - engine.epoch) / engine.scale;
          const rows = db.query<Visit, [number, number | null, number]>(
            `SELECT v.id, ${engine.time} AS time, ${engine.url} AS url,
             ${engine.title} AS title, ${engine.transition} AS transition,
             CASE WHEN v.id <= ? OR ${engine.time} < ? THEN 1 ELSE 0 END AS legacy
             FROM ${engine.from} WHERE v.id > ?
             ORDER BY legacy DESC, ${engine.time}, v.id`,
          // 重导时先重放旧访问，已入库的旧访问不打断合并启用后的访问序列。
          ).all(groupedAfter, groupingStart, options.since ? 0 : previous?.lastId ?? 0);
          const replaying = options.since && closedThrough.length > 0;
          const visits = rows.map(row => ({ row, batch: row.legacy ? -1 : replaying ? replayBatch(row.id, closedThrough) : 0 }));
          if (replaying) visits.sort((a, b) => a.batch - b.batch || a.row.time - b.row.time || a.row.id - b.row.id);
          const previousLastId = previous?.lastId ?? 0;
          let highestVisitId = previousLastId;
          const outOfOrder = visits.some(({ row }) => {
            if (row.id <= previousLastId) return false;
            const reordered = row.id < highestVisitId;
            highestVisitId = row.id;
            return reordered;
          });
          const buffered: RecordV1[] = [];
          let lastId = previousLastId;
          const recent = new Map(options.since ? [] : previous?.recent ?? []);
          let latest = Math.max(-Infinity, ...recent.values());
          let pages: Page[] = [];
          let lastPage: Page | undefined;
          let minOpenId = Infinity, maxIdBeforeOpen = 0;
          const openRecent = new Map<string, number>();
          let urlChars = 0;
          const close = () => {
            const first = pages[0], last = lastPage;
            if (!first || !last) return;
            if (!options.since || first.time >= cutoff) {
              const record: RecordV1 = {
                id: ulid(), schema: 1, device: options.device, source: "mac.browser", source_ref: `${key}:${first.id}`,
                kind: pages.length === 1 ? "event" : "span", t_start: toLocalIso(first.time),
                ...(pages.length === 1 ? {} : { t_end: toLocalIso(last.time) }),
                context: {
                  app: browser.bundleId, url: last.url,
                  extra: { profile, ...(last.transition === null ? {} : { transition: last.transition }) },
                },
                title: last.title, body: [last.title, ...new Set(pages.map(page => page.url))].join("\n"),
                capture: { method: "db" }, sensitivity: "normal",
              };
              if (!validateRecord(record).ok) throw new Error("浏览记录不符合记录契约");
              if (outOfOrder) buffered.push(record);
              else options.onRecord(record);
            }
            for (const [hash, time] of openRecent) recent.set(hash, time);
            latest = Math.max(latest, last.time);
            openRecent.clear();
            pages = [];
            lastPage = undefined;
            minOpenId = Infinity;
            urlChars = 0;
          };
          let lastBatch = visits[0]?.batch ?? 0;
          for (const { row, batch } of visits) {
            if (batch !== lastBatch) {
              // 按上次成功 checkpoint 的范围重放，避免迟到访问并入已经写入的记录。
              close();
              if (lastBatch !== -1) for (const [hash, time] of recent) {
                if (time < latest - CONTINUOUS_GAP_MS) recent.delete(hash);
              }
              lastBatch = batch;
            }
            const maxIdBeforeVisit = lastId;
            lastId = Math.max(lastId, row.id);
            const time = row.time * engine.scale + engine.epoch;
            if (!Number.isFinite(time) || Math.abs(time) > 8.64e15) continue;
            if (!previous && time < cutoff) continue;
            const oldVisit = row.legacy === 1;
            const cleaned = cleanUrl(row.url);
            if (!cleaned) continue;
            const hash = createHash("sha256").update(cleaned.url).digest("hex");
            const title = clampTitle(row.title?.trim() || cleaned.hostname);
            const host = cleaned.hostname.toLowerCase().replace(/\.$/, "");
            const last = lastPage, chars = cleaned.url.length + 1;
            if (last && (oldVisit || host !== last.host || time - last.time > CONTINUOUS_GAP_MS
              || time - pages[0]!.time >= MAX_GROUP_MS)) close();
            const page = { id: row.id, time, url: cleaned.url, host, title, transition: row.transition };
            const first = openRecent.get(hash) ?? recent.get(hash);
            if (first !== undefined && Math.abs(time - first) <= CONTINUOUS_GAP_MS) {
              // 30 秒内的同页去重保留，回到这组已读过的一页时仍使用最后看到的标题和地址。
              if (openRecent.has(hash)) {
                lastPage = page;
                minOpenId = Math.min(minOpenId, row.id);
              }
              continue;
            }
            if (urlChars + chars > MAX_GROUP_URL_CHARS) close();
            if (!lastPage) maxIdBeforeOpen = maxIdBeforeVisit;
            pages.push(page);
            lastPage = page;
            minOpenId = Math.min(minOpenId, row.id);
            openRecent.set(hash, time);
            urlChars += chars;
            if (oldVisit) close();
          }
          const first = pages[0], last = lastPage;
          if (first && last) {
            if (now >= Math.min(last.time + CONTINUOUS_GAP_MS, first.time + MAX_GROUP_MS)
              || (replaying && lastBatch < closedThrough.length)) close();
            else {
              lastId = Math.max(previousLastId, minOpenId - 1);
              // 时间早但 ID 较晚的访问跨过游标时，等片段关闭再一起提交。
              if (maxIdBeforeOpen > lastId) return previous ?? { lastId: previousLastId, recent: [], groupedAfter, groupedSince };
            }
          }
          for (const record of buffered) options.onRecord(record);
          const updatedBoundaries = lastId > (closedThrough.at(-1) ?? groupedAfter) ? [...closedThrough, lastId] : closedThrough;
          return {
            lastId, groupedAfter, ...(groupedSince === undefined ? {} : { groupedSince }),
            ...(updatedBoundaries.length ? { closedThrough: updatedBoundaries } : {}),
            recent: [...recent].filter(([, time]) => time >= latest - CONTINUOUS_GAP_MS),
          };
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
      || (entry.groupedAfter !== undefined && (!Number.isSafeInteger(entry.groupedAfter) || entry.groupedAfter < 0 || entry.groupedAfter > entry.lastId))
      || (entry.groupedSince !== undefined && !Number.isFinite(entry.groupedSince))
      || (entry.closedThrough !== undefined && (!Array.isArray(entry.closedThrough) || !entry.closedThrough.every((id, index, ids) =>
        Number.isSafeInteger(id) && id > (ids[index - 1] ?? entry.groupedAfter ?? 0) && id <= entry.lastId)))
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
