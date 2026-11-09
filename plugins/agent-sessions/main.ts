import fs from "node:fs";
import path from "node:path";
import os from "node:os";
import { createHash } from "node:crypto";
import { readEvents } from "./json-lines.ts";
import { clampTitle, emitCheckpoint, emitRecord, parsePluginArgs, toLocalIso, ulid, validateRecord, type RecordV1 } from "../../packages/record/index.ts";
import { cleanUserText } from "./filters.ts";

const HOUR = 3_600_000;
const RETENTION = 8 * 86400_000;
const BODY_LIMIT = 150_000;
const TRUNCATED = "…[已截断]";
type Provider = "claude" | "codex";
type Json = { [key: string]: any };
interface Message { time: number; role: "user" | "assistant"; text: string }
interface Bucket { part: number; messages: Message[] }
interface Session { provider: Provider; id: string; cwd: string | null; seen: { [hour: string]: string[] }; buckets: { [hour: string]: Bucket }; mtime: number; lastActivity?: number }
interface FileProgress { offset: number; mtime: number; size: number; identity: string; session: string | null; cwd?: string | null }
export interface State { version: 2; since: number; replaySince: number; files: { [file: string]: FileProgress }; sessions: { [id: string]: Session } }
export interface Options { device: string; now?: number; since?: number; state?: State; claudeDir?: string; codexDir?: string; excludeDirs?: string[]; onRecord?: (record: RecordV1) => void; onWarning?: (message: string) => void }

function* walk(root: string): Generator<string> {
  if (!fs.existsSync(root)) return;
  for (const entry of fs.readdirSync(root, { withFileTypes: true })) {
    const file = path.join(root, entry.name);
    if (entry.isDirectory()) yield* walk(file);
    else if (entry.isFile() && /\.jsonl(?:\.zst)?$/.test(entry.name)) yield file;
  }
}

function visibleMessage(event: Json, provider: Provider): { role: Message["role"]; text: string } | null {
  let message: Json;
  if (provider === "claude") {
    if (!["user", "assistant"].includes(event.type) || event.isSidechain || event.isMeta || event.isCompactSummary) return null;
    if (event.type === "user" && (event.promptSource === "system" || ["task_notification", "hook"].includes(event.turnOrigin) || /task-notification|hook/.test(event.origin?.kind ?? ""))) return null;
    message = event.message ?? {};
  } else {
    if (event.type !== "response_item" || event.payload?.type !== "message") return null;
    message = event.payload;
    if (message.role === "assistant" && (message.channel === "analysis" || (message.recipient && message.recipient !== "all"))) return null;
  }
  const role = message.role ?? event.type;
  if (role !== "user" && role !== "assistant") return null;
  const content = typeof message.content === "string" ? [{ type: "text", text: message.content }] : message.content;
  if (!Array.isArray(content)) return null;
  const text = content.filter((b: Json) => b && ["text", "input_text", "output_text"].includes(b.type) && typeof b.text === "string")
    .map((b: Json) => role === "user" ? cleanUserText(b.text) : b.text.trim()).filter(Boolean).join("\n");
  return text ? { role, text } : null;
}

function repoRoot(cwd: string | null): string | null {
  if (!cwd || !path.isAbsolute(cwd)) return null;
  for (let dir = cwd; ; dir = path.dirname(dir)) {
    if (fs.existsSync(path.join(dir, ".git"))) return dir;
    if (path.dirname(dir) === dir) return null;
  }
}
function shorten(text: string, length: number): string { return Array.from(text).slice(0, length).join(""); }
function safePrefix(text: string, length: number): string {
  const prefix = text.slice(0, length);
  return /[\uD800-\uDBFF]$/.test(prefix) ? prefix.slice(0, -1) : prefix;
}

export async function collect(options: Options): Promise<State> {
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
  let damaged = 0;
  for (const file of Object.keys(state.files)) if (!fs.existsSync(file)) delete state.files[file];
  const roots: [Provider, string][] = [
    ["claude", path.join(options.claudeDir ?? process.env.RA_CLAUDE_DIR ?? path.join(os.homedir(), ".claude"), "projects")],
    ["codex", path.join(options.codexDir ?? process.env.RA_CODEX_DIR ?? path.join(os.homedir(), ".codex"), "sessions")],
    ["codex", path.join(options.codexDir ?? process.env.RA_CODEX_DIR ?? path.join(os.homedir(), ".codex"), "archived_sessions")],
  ];
  // 已有 state 时再传 --since 表示从该时刻起重新读取（重新导入、导入全部历史）：之后改过的文件从头读，
  // 窗口内已输出过的消息靠 seen 跳过，更早的靠 hub 按 source_ref 去重；state 的增量游标不倒退。
  const rescan = options.state !== undefined && options.since !== undefined;
  const floor = rescan ? options.since! : Math.max(state.since, state.replaySince);
  const seen = new Map<string, Set<string>>();
  for (const [provider, root] of roots) for (const file of walk(root)) {
    // Claude 的子 Agent 日志不是用户直接参与的会话。
    if (provider === "claude" && file.split(path.sep).includes("subagents")) continue;
    const stat = fs.statSync(file);
    const old = state.files[file];
    if (!old && stat.mtimeMs < (rescan ? floor : state.since)) continue;
    const identity = `${stat.dev}:${stat.ino}`;
    const reset = (rescan && stat.mtimeMs >= floor) || (file.endsWith(".zst") && (stat.size !== old?.size || stat.mtimeMs !== old?.mtime)) || !old || old.identity !== identity || stat.size < old.size || (stat.size === old.size && stat.mtimeMs !== old.mtime);
    const progress: FileProgress = reset ? { offset: 0, mtime: stat.mtimeMs, size: stat.size, identity, session: old?.session ?? null, cwd: old?.cwd ?? null } : { ...old };
    // 未修改文件不读取，但仍在下面检查它的待关闭桶。
    if (reset || stat.size !== old?.size || stat.mtimeMs !== old?.mtime) {
      for await (const line of readEvents(file, progress.offset, stat.size)) {
        progress.offset = line.end;
        if (line.damaged) { damaged++; continue; }
        const event = line.event;
        if (!event) continue;
        const id = provider === "claude" ? event.sessionId ?? path.basename(file, ".jsonl") : event.type === "session_meta" ? event.payload?.id : null;
        if (typeof id === "string" && id) progress.session = `${provider}:${id}`;
        if (!progress.session) continue;
        const session = state.sessions[progress.session] ??= { provider, id: progress.session.slice(provider.length + 1), cwd: progress.cwd ?? null, seen: {}, buckets: {}, mtime: stat.mtimeMs };
        const cwd = provider === "claude" ? event.cwd : event.type === "session_meta" ? event.payload?.cwd : null;
        if (typeof cwd === "string") session.cwd = cwd;
        progress.cwd = session.cwd;
        const time = Date.parse(event.timestamp);
        if (!Number.isFinite(time) || time < floor) continue;
        const visible = visibleMessage(event, provider);
        if (!visible) continue;
        session.lastActivity = Math.max(session.lastActivity ?? session.mtime, time);
        const hash = createHash("sha256").update(JSON.stringify([time, visible.role, visible.text])).digest("hex");
        let known = seen.get(progress.session);
        if (!known) { known = new Set(Object.values(session.seen).flat()); seen.set(progress.session, known); }
        if (known.has(hash)) continue;
        known.add(hash);
        const hour = String(Math.floor(time / HOUR) * HOUR);
        (session.seen[hour] ??= []).push(hash);
        const bucket = session.buckets[hour] ??= { part: 0, messages: [] };
        bucket.messages.push({ time, ...visible });
      }
    }
    progress.mtime = stat.mtimeMs; progress.size = stat.size;
    state.files[file] = progress;
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
  for (const session of Object.values(state.sessions)) for (const [hour, bucket] of Object.entries(session.buckets).sort(([a], [b]) => Number(a) - Number(b))) {
    if (isExcluded(session.cwd)) { bucket.messages = []; continue; }
    if (!bucket.messages.length || !(now > Number(hour) + HOUR + 10 * 60_000 || now - session.mtime >= 30 * 60_000)) continue;
    const messages = bucket.messages.sort((a, b) => a.time - b.time);
    const app = session.provider === "claude" ? "claude-code" : "codex";
    const name = session.provider === "claude" ? "Claude Code" : "Codex";
    const repo = repoRoot(session.cwd);
    // 在消息边界拆分；单条过长时把前缀和截断标记也计入正文上限。
    const pieces: { messages: Message[]; body: string }[] = [];
    let current: { messages: Message[]; body: string } = { messages: [], body: "" };
    for (const message of messages) {
      let text = message.text;
      if (message.role === "assistant" && Array.from(text).length > 4000) text = shorten(text, 4000) + TRUNCATED;
      let rendered = `[${message.role === "user" ? "我" : "AI"}] ${text}`;
      if (rendered.length > BODY_LIMIT) rendered = safePrefix(rendered, BODY_LIMIT - TRUNCATED.length) + TRUNCATED;
      if (current.messages.length && current.body.length + 2 + rendered.length > BODY_LIMIT) {
        pieces.push(current); current = { messages: [], body: "" };
      }
      if (current.messages.length) current.body += "\n\n";
      current.body += rendered; current.messages.push(message);
    }
    if (current.messages.length) pieces.push(current);
    for (const piece of pieces) {
      const firstUser = piece.messages.find(m => m.role === "user");
      const part = bucket.part + 1;
      const record: RecordV1 = {
        id: ulid(), schema: 1, device: options.device, source: session.provider === "claude" ? "claude_code.session" : "codex.session",
        source_ref: `${session.id}#${new Date(Number(hour)).toISOString()}${part > 1 ? `#${part}` : ""}`,
        kind: "span", t_start: toLocalIso(piece.messages[0]!.time), t_end: toLocalIso(piece.messages.at(-1)!.time),
        context: { app, cwd: session.cwd, repo }, title: clampTitle(`${name} · ${path.basename(repo ?? session.cwd ?? "未知项目")} · ${firstUser ? shorten(firstUser.text, 40) : "AI 回复"}`),
        body: piece.body, capture: { method: "file" }, sensitivity: "normal",
      };
      const validation = validateRecord(record);
      if (!validation.ok) throw new Error(`记录不符合契约：${validation.errors.join("；")}`);
      options.onRecord?.(record); bucket.part = part;
    }
    bucket.messages = [];
  }
  const cutoff = now - RETENTION;
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
  if (damaged) (options.onWarning ?? console.error)(`跳过 ${damaged} 行损坏数据`);
  return state;
}

if (import.meta.main) {
  try {
    const args = parsePluginArgs();
    if (args.since && !Number.isFinite(args.since.getTime())) throw new Error("--since 必须是有效的 RFC3339 时间");
    // runner 首次运行也会传 --state，文件还不存在，按首次运行处理；文件存在但损坏时明确失败，不能默默当成首次运行导致增量丢失。
    const state = args.stateFile && fs.existsSync(args.stateFile) ? JSON.parse(fs.readFileSync(args.stateFile, "utf8")) as State : undefined;
    emitCheckpoint(await collect({ device: args.device, since: args.since?.getTime(), state, onRecord: emitRecord }));
  } catch (error) {
    // 不回显日志行、JSON.parse 的片段或文件路径，避免泄露真实数据。
    console.error(error instanceof Error && /^(?:不支持的 checkpoint|--since|记录不符合契约)/.test(error.message) ? error.message : "读取会话日志或 checkpoint 失败");
    process.exitCode = 1;
  }
}
