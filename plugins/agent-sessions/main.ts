import { cliLanguage, cliText } from "../../hub/src/agent-cli/locale.ts";
import type { Lang } from "../../hub/src/i18n/language.ts";
import { capturePrefix } from "../../packages/record/capture-prefix.ts";
import fs from "node:fs";
import path from "node:path";
import os from "node:os";
import { createHash } from "node:crypto";
import { readEvents } from "./json-lines.ts";
import { clampTitle, parsePluginArgs, toLocalIso, ulid, validateRecord, type RecordV1 } from "../../packages/record/index.ts";
import { messageBuffer, type Message } from "./message-buffer.ts";
import { adapters, adaptersByCheckpointKey } from "./adapters/index.ts";
import type { DatabaseProgress, SessionDirectories } from "./adapters/types.ts";

const HOUR = 3_600_000;
// 会话安静满 3 分钟，或一批最早的消息已等了 15 分钟，就先输出这一批；同一小时后续内容用 #2、#3 接着编号。
const QUIET = 3 * 60_000;
const BATCH = 15 * 60_000;
const RETENTION = 8 * 86400_000;
const BODY_LIMIT = 150_000;
const TRUNCATED = "…[已截断]";
const PENDING_BYTES = 32 * 1024 * 1024;
const PENDING_MESSAGES = 20_000;
const PENDING_LIMIT = "当前会话待保存内容超过上限，关闭后重试";
interface SessionWarnings { unrecognized?: number; damaged?: number }
interface Bucket { part: number; messages: Message[] }
interface Session { provider: string; id: string; cwd: string | null; seen: { [hour: string]: string[] }; buckets: { [hour: string]: Bucket }; mtime: number; lastActivity?: number }
interface FileProgress { offset: number; mtime: number; size: number; identity: string; session: string | null; cwd?: string | null; skipped?: true }
export interface State { version: 2; since: number; replaySince: number; files: { [file: string]: FileProgress }; sessions: { [id: string]: Session }; databases?: { [file: string]: DatabaseProgress } }
export interface Options extends SessionDirectories { device: string; lang?: Lang; now?: number; since?: number; state?: State; excludeDirs?: string[]; onRecord?: (record: RecordV1) => void | Promise<void>; onWarning?: (message: string) => void; onDiagnostics?: (warnings: SessionWarnings) => void }

function repoRoot(cwd: string | null): string | null {
  if (!cwd || !path.isAbsolute(cwd)) return null;
  for (let dir = cwd; ; dir = path.dirname(dir)) {
    if (fs.existsSync(path.join(dir, ".git"))) return dir;
    if (path.dirname(dir) === dir) return null;
  }
}
function shorten(text: string, length: number): string {
  let end = 0;
  for (const char of text) {
    if (length-- === 0) break;
    end += char.length;
  }
  return capturePrefix(text, end);
}

async function emitBucket(options: Options, session: Session, hour: string, bucket: Bucket, messages: Iterable<Message>) {
  const { id: app, label: name, source } = adaptersByCheckpointKey.get(session.provider)!.tool;
  const repo = repoRoot(session.cwd);
  const ref = `${session.id}#${new Date(Number(hour)).toISOString()}`;
  let body = "", firstUser: string | undefined, start = 0, end = 0;
  const flush = async () => {
    const part = bucket.part + 1;
    const record: RecordV1 = {
      id: ulid(), schema: 1, device: options.device, source,
      source_ref: part === 1 ? ref : `${ref}#${part}`,
      kind: "span", t_start: toLocalIso(start), t_end: toLocalIso(end),
      context: { app, cwd: session.cwd, repo }, title: clampTitle(`${name} · ${path.basename(repo ?? session.cwd ?? "未知项目")} · ${firstUser ?? "AI 回复"}`),
      body, capture: { method: "file" }, sensitivity: "normal",
    };
    if (!validateRecord(record).ok) throw new Error("记录不符合契约");
    await options.onRecord?.(record);
    bucket.part = part;
    body = ""; firstUser = undefined;
  };
  for (const message of messages) {
    let text = message.text;
    if (message.role === "assistant" && text.length > 4000) {
      const prefix = shorten(text, 4000);
      if (prefix.length < text.length) text = prefix + TRUNCATED;
    }
    let rendered = `[${message.role === "user" ? "我" : "AI"}] ${text}`;
    if (rendered.length > BODY_LIMIT) rendered = capturePrefix(rendered, BODY_LIMIT - TRUNCATED.length) + TRUNCATED;
    if (body && body.length + 2 + rendered.length > BODY_LIMIT) await flush();
    if (!body) start = message.time;
    end = message.time;
    if (firstUser === undefined && message.role === "user") firstUser = shorten(message.text, 40);
    body += body ? "\n\n" + rendered : rendered;
  }
  if (body) await flush();
}

export async function collect(options: Options): Promise<State> {
  let buffer: ReturnType<typeof messageBuffer> | undefined;
  try { return await collectSessions(options, () => buffer ??= messageBuffer()); }
  finally { buffer?.close(); }
}

async function collectSessions(options: Options, getBuffer: () => ReturnType<typeof messageBuffer>): Promise<State> {
  const now = options.now ?? Date.now();
  const initialSince = options.since ?? now - 7 * 86400_000;
  const state: State = options.state ? structuredClone(options.state) : { version: 2, since: initialSince, replaySince: initialSince, files: {}, sessions: {} };
  // v1 哈希没有时间信息，迁移时暂存到当前小时，八天后一起过期。
  const legacy = state as unknown as { version: number };
  if (legacy.version === 1) {
    legacy.version = 2; state.replaySince = state.since;
    for (const session of Object.values(state.sessions)) if (Array.isArray(session.seen)) session.seen = { [Math.floor(now / HOUR) * HOUR]: session.seen };
  }
  if (state.version !== 2 || !Number.isFinite(state.since) || !Number.isFinite(state.replaySince)) throw new Error("不支持的 checkpoint 格式");
  let damaged = 0, parsed = 0, unrecognized = 0, unrecognizedFile = false;
  for (const file of Object.keys(state.files)) if (!fs.existsSync(file)) delete state.files[file];
  // 已有 state 时再传 --since 表示从该时刻起重新读取（重新导入、导入全部历史）：之后改过的文件从头读，
  // 窗口内已输出过的消息靠 seen 跳过，更早的靠 hub 按 source_ref 去重；state 的增量游标不倒退。
  const rescan = options.state !== undefined && options.since !== undefined;
  const floor = rescan ? options.since! : Math.max(state.since, state.replaySince);
  const seen = new Map<string, Set<string>>();
  const bucketIds = new Map<Bucket, number>();
  const add = (bucket: Bucket, message: Message, hash: string | null) => {
    let id = bucketIds.get(bucket);
    if (id === undefined) { id = bucketIds.size; bucketIds.set(bucket, id); }
    getBuffer().add(id, message, hash);
  };
  const queueMessage = (key: string, session: Session, message: Message | undefined) => {
    if (!message || message.time < floor) return;
    session.lastActivity = Math.max(session.lastActivity ?? session.mtime, message.time);
    const hash = createHash("sha256").update(JSON.stringify([message.time, message.role, message.text])).digest("hex");
    let known = seen.get(key);
    if (!known) { known = new Set(Object.values(session.seen).flat()); seen.set(key, known); }
    if (known.has(hash)) return;
    const hour = String(Math.floor(message.time / HOUR) * HOUR);
    const bucket = session.buckets[hour] ??= { part: 0, messages: [] };
    add(bucket, message, hash);
  };
  for (const session of Object.values(state.sessions)) for (const bucket of Object.values(session.buckets)) {
    for (const message of bucket.messages) add(bucket, message, null);
    bucket.messages = [];
  }
  for (const adapter of adapters) if ("files" in adapter) for (const sessionFile of adapter.files(options)) {
    const provider = adapter.checkpointKey;
    const file = sessionFile.path;
    const metadata = sessionFile.session;
    const sessionKey = metadata && `${provider}:${metadata.id}`;
    if (metadata?.subagent && sessionKey) {
      delete state.sessions[sessionKey];
      delete state.files[file];
      continue;
    }
    const stat = fs.statSync(file);
    const old = state.files[file];
    if (!old && stat.mtimeMs < (rescan ? floor : state.since)) continue;
    const identity = `${stat.dev}:${stat.ino}`;
    const reset = (rescan && stat.mtimeMs >= floor) || (file.endsWith(".zst") && (stat.size !== old?.size || stat.mtimeMs !== old?.mtime)) || !old || old.identity !== identity || stat.size < old.size || (stat.size === old.size && stat.mtimeMs !== old.mtime);
    const fallback = sessionFile.fallbackSessionId;
    const progress: FileProgress = reset ? { offset: 0, mtime: stat.mtimeMs, size: stat.size, identity, session: old?.session ?? (fallback ? `${provider}:${fallback}` : null), cwd: old?.cwd ?? null } : { ...old };
    if (!progress.skipped && metadata && sessionKey) {
      progress.session = sessionKey;
      if (metadata.cwd !== undefined) {
        progress.cwd = metadata.cwd;
        const session = state.sessions[sessionKey];
        if (session) session.cwd = metadata.cwd;
      }
    }
    // 未修改文件不读取，但仍在下面检查它的待关闭桶。
    if (!progress.skipped && (reset || stat.size !== old?.size || stat.mtimeMs !== old?.mtime)) {
      let fileParsed = 0, fileUnknown = 0;
      const events = adapter.readEvents ?? readEvents;
      for await (const line of events(file, progress.offset, stat.size, adapter.additionalRootFields, adapter.additionalMessageFields, adapter.genaiParts)) {
        progress.offset = line.end;
        if (line.damaged) { damaged++; continue; }
        const event = line.event;
        if (event === undefined) continue;
        const id = adapter.sessionId?.(event, sessionFile);
        if (typeof id === "string" && id) progress.session = `${provider}:${id}`;
        if (event && adapter.skipSession?.(event)) {
          if (progress.session) delete state.sessions[progress.session];
          progress.session = null;
          progress.skipped = true;
          break;
        }
        const result = adapter.parse(event, !!progress.session);
        fileParsed++;
        if (!result.recognized) fileUnknown++;
        if (!progress.session || !event) continue;
        const session = state.sessions[progress.session] ??= { provider, id: progress.session.slice(provider.length + 1), cwd: progress.cwd ?? null, seen: {}, buckets: {}, mtime: stat.mtimeMs };
        const cwd = adapter.cwd?.(event, sessionFile);
        if (typeof cwd === "string") session.cwd = cwd;
        progress.cwd = session.cwd;
        queueMessage(progress.session, session, result.message);
      }
      parsed += fileParsed;
      unrecognized += fileUnknown;
      if (fileUnknown >= 20 && fileUnknown === fileParsed) unrecognizedFile = true;
    }
    progress.mtime = stat.mtimeMs; progress.size = stat.size;
    state.files[file] = progress;
  }
  for (const adapter of adapters) if ("readDatabase" in adapter) {
    const file = adapter.database(options);
    if (!file) continue;
    const scan = adapter.readDatabase(file, state.databases?.[file], floor, rescan);
    if (!scan) continue;
    (state.databases ??= {})[file] = scan.progress;
    const provider = adapter.checkpointKey;
    let databaseUnknown = 0;
    for (const { sessionId, cwd, mtime, result } of scan.rows) {
      if (!result.recognized) databaseUnknown++;
      const key = `${provider}:${sessionId}`;
      const session = state.sessions[key] ??= { provider, id: sessionId, cwd, seen: {}, buckets: {}, mtime };
      session.cwd = cwd;
      session.mtime = Math.max(session.mtime, mtime);
      queueMessage(key, session, result.message);
    }
    parsed += scan.rows.length;
    unrecognized += databaseUnknown;
    if (databaseUnknown >= 20 && databaseUnknown === scan.rows.length) unrecognizedFile = true;
  }
  // 同一会话可能同时出现在活动目录和归档目录，统一去重、分桶和计算最近修改时间。
  // 保留已移走文件的最近活动时间，避免把仍有待输出内容的会话误判为空。
  for (const progress of Object.values(state.files)) if (progress.session && state.sessions[progress.session]) {
    const session = state.sessions[progress.session]!;
    session.mtime = Math.max(session.mtime, progress.mtime);
    progress.cwd = session.cwd;
  }
  // 提炼层自己调用 claude/codex 时在 distill-work 里运行；这些会话不是用户的活动，绝不能采回 History（否则会自己记录自己）。
  const excluded = (options.excludeDirs ?? [path.join(process.env.RA_DATA_DIR ?? path.join(os.homedir(), "Library/Application Support/record-anything"), "distill-work")])
    .flatMap(dir => { const all = [path.resolve(dir)]; try { all.push(fs.realpathSync(dir)); } catch {} return all; });
  const isExcluded = (cwd: string | null) => !!cwd && excluded.some(dir => cwd === dir || cwd.startsWith(dir + path.sep));
  const isClosed = (hour: string, session: Session, id: number) => now > Number(hour) + HOUR + 10 * 60_000
    || now - session.mtime >= QUIET || now - (getBuffer().size(id).first ?? now) >= BATCH;
  // 活动桶要随 checkpoint 保留。超限时在发送任何记录前结束本轮，
  // runner 保留旧游标，等桶关闭后重读；中途输出会改变分条边界。
  let pendingBytes = 0, pendingMessages = 0;
  for (const session of Object.values(state.sessions)) {
    if (isExcluded(session.cwd)) continue;
    for (const [hour, bucket] of Object.entries(session.buckets)) {
      const id = bucketIds.get(bucket);
      if (id === undefined || isClosed(hour, session, id)) continue;
      const size = getBuffer().size(id);
      pendingBytes += size.bytes;
      pendingMessages += size.count;
      if (pendingBytes > PENDING_BYTES || pendingMessages > PENDING_MESSAGES) throw new Error(PENDING_LIMIT);
    }
  }
  const cutoff = now - RETENTION;
  for (const session of Object.values(state.sessions)) {
    const excluded = isExcluded(session.cwd);
    for (const [hour, bucket] of Object.entries(session.buckets).sort(([a], [b]) => Number(a) - Number(b))) {
      const id = bucketIds.get(bucket);
      if (id === undefined) continue;
      const closed = isClosed(hour, session, id);
      const buffer = getBuffer();
      if (!excluded) {
        if (closed) await emitBucket(options, session, hour, bucket, buffer.messages(id));
        else bucket.messages = Array.from(buffer.messages(id));
      }
      if (Number(hour) + HOUR > cutoff || bucket.messages.length) {
        for (const { hash } of buffer.hashes(id)) (session.seen[hour] ??= []).push(hash);
      }
    }
  }
  // 已过期的桶不再重放；文件偏移和 cwd 仍保留，休眠会话追加时可直接恢复。
  const replaySince = Math.floor(cutoff / HOUR) * HOUR;
  for (const [key, session] of Object.entries(state.sessions)) {
    for (const hour of Object.keys(session.seen)) {
      if (Number(hour) + HOUR <= cutoff && !session.buckets[hour]?.messages.length) delete session.seen[hour];
    }
    for (const [hour, bucket] of Object.entries(session.buckets)) {
      if (Number(hour) + HOUR <= cutoff && !bucket.messages.length) delete session.buckets[hour];
    }
    if (Math.max(session.mtime, session.lastActivity ?? 0) < cutoff && !Object.values(session.buckets).some(bucket => bucket.messages.length)) delete state.sessions[key];
  }
  state.replaySince = Math.max(state.replaySince, replaySince);
  const warnings: SessionWarnings = {};
  const warn = options.onWarning ?? console.error;
  const lang = options.lang ?? "zh";
  if (unrecognizedFile || (unrecognized >= 50 && unrecognized * 2 > parsed)) {
    warnings.unrecognized = unrecognized;
    warn(cliText(
      `AI 会话格式可能已变化，有 ${unrecognized} 行没有识别`,
      `The AI session format may have changed. Skipped ${unrecognized} unrecognized lines.`,
      lang,
    ));
  }
  if (damaged) {
    warnings.damaged = damaged;
    warn(cliText(`跳过 ${damaged} 行损坏数据`, `Skipped ${damaged} damaged log ${damaged === 1 ? "line" : "lines"}.`, lang));
  }
  if (warnings.unrecognized || warnings.damaged) options.onDiagnostics?.(warnings);
  return state;
}

if (import.meta.main) {
  try {
    const args = parsePluginArgs();
    if (args.since && !Number.isFinite(args.since.getTime())) throw new Error("--since 必须是有效的 RFC3339 时间");
    // runner 首次运行也会传 --state，文件还不存在，按首次运行处理；文件存在但损坏时明确失败，不能默默当成首次运行导致增量丢失。
    const state = args.stateFile && fs.existsSync(args.stateFile) ? JSON.parse(fs.readFileSync(args.stateFile, "utf8")) as State : undefined;
    let sessionWarnings: SessionWarnings | undefined;
    const checkpoint = await collect({
      device: args.device, since: args.since?.getTime(), state, lang: cliLanguage(),
      onRecord: record => new Promise<void>((resolve, reject) => {
        process.stdout.write(JSON.stringify({ type: "record", record }) + "\n", error => error ? reject(error) : resolve());
      }),
      onDiagnostics: warnings => { sessionWarnings = warnings; },
    });
    process.stdout.write(JSON.stringify({ type: "checkpoint", state: checkpoint, sessionWarnings }) + "\n");
  } catch (error) {
    // 不回显日志行、JSON.parse 的片段或文件路径，避免泄露真实数据。
    const message = error instanceof Error ? error.message : "";
    const known = new Map([
      ["不支持的 checkpoint 格式", "Unsupported session checkpoint format"],
      ["--since 必须是有效的 RFC3339 时间", "--since must be a valid RFC 3339 timestamp"],
      ["记录不符合契约", "The session record does not match the record schema"],
      [PENDING_LIMIT, "This session has too much unsaved content. Close it and try again."],
    ]);
    console.error(cliText(
      /^(?:不支持的 checkpoint|--since|记录不符合契约|当前会话待保存内容超过上限)/.test(message) ? message : "读取会话日志或 checkpoint 失败",
      known.get(message) ?? "Could not read the session logs or checkpoint",
    ));
    process.exitCode = 1;
  }
}
