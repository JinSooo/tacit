import { capturePrefix } from "../../packages/record/capture-prefix.ts";
import fs from "node:fs";
import { StringDecoder } from "node:string_decoder";
import { createZstdDecompress } from "node:zlib";

type Json = { [key: string]: any };
type Context = "root" | "message" | "origin" | "blocks" | "block" | "ignored";
interface Frame { kind: "object" | "array"; context: Context; value: any; state: string; key: string; hasInvalidBlock?: boolean }
const fields: { [context: string]: Set<string> } = {
  root: new Set(["type", "sessionId", "timestamp", "cwd", "isSidechain", "isMeta", "isCompactSummary", "promptSource", "turnOrigin", "origin", "message", "payload"]),
  message: new Set(["type", "id", "cwd", "role", "channel", "recipient", "content"]),
  origin: new Set(["kind"]), block: new Set(["type", "text"]),
};
const STRING_LIMIT = 150_064;
const ESCAPES: { [key: string]: string } = { '"': '"', "\\": "\\", "/": "/", b: "\b", f: "\f", n: "\n", r: "\r", t: "\t" };

/** 小型 JSON 投影解析器：完整检查语法，只保存白名单字段，巨大的工具字符串不分配正文。
 * 不依赖字段顺序，也不在原始字符串中搜索伪造的 type/role。
 */
export class EventParser {
  private stack: Frame[] = [];
  private mode: "normal" | "string" | "primitive" = "normal";
  private token = "";
  private truncated = false;
  private primitiveState = "";
  private primitivePosition = 0;
  private capture = false;
  private keyToken = false;
  private escape = false;
  private unicode: string | null = null;
  private done = false;
  private invalid = false;
  private nonempty = false;
  private result: Json | null = null;

  private keep(): boolean {
    const top = this.stack.at(-1);
    return !!top && top.kind === "object" && !!fields[top.context]?.has(top.key);
  }
  private append(value: string) {
    if (this.capture && this.token.length + value.length > (this.keyToken ? 512 : STRING_LIMIT)) this.truncated = true;
    if (this.capture && this.token.length < (this.keyToken ? 512 : STRING_LIMIT)) {
      this.token += value.slice(0, (this.keyToken ? 512 : STRING_LIMIT) - this.token.length);
    }
  }
  private accept(value: any) {
    const top = this.stack.at(-1);
    if (!top) { if (this.done) throw Error(); this.done = true; return; }
    if (top.kind === "object") {
      if (top.state !== "value") throw Error();
      if (this.keep()) top.value[top.key] = value;
    } else {
      if (!["value", "first"].includes(top.state)) throw Error();
      if (top.context === "blocks") {
        if (value && typeof value === "object") top.value.push(value);
        else if (!top.hasInvalidBlock) {
          top.value.push(null);
          top.hasInvalidBlock = true;
        }
      }
    }
    top.state = "comma";
  }
  private open(kind: Frame["kind"]) {
    const parent = this.stack.at(-1);
    let context: Context = "ignored";
    if (!parent) { if (this.done) throw Error(); context = kind === "object" ? "root" : "ignored"; }
    else if (parent.context === "root" && kind === "object") {
      if (["message", "payload"].includes(parent.key)) context = "message";
      if (parent.key === "origin") context = "origin";
    } else if (parent.context === "message" && parent.key === "content" && kind === "array") context = "blocks";
    else if (parent.context === "blocks" && kind === "object") context = "block";
    const value = context === "ignored" ? null : kind === "object" ? Object.create(null) : [];
    this.accept(value);
    if (context === "root") this.result = value;
    this.stack.push({ kind, context, value, state: kind === "object" ? "first-key" : "first", key: "" });
  }
  private symbol(char: string) {
    const top = this.stack.at(-1);
    if (char === "{" || char === "[") { this.open(char === "{" ? "object" : "array"); return; }
    if (!top) throw Error();
    if (char === "}" || char === "]") {
      if (top.kind !== (char === "}" ? "object" : "array") || !["comma", "first", "first-key"].includes(top.state)) throw Error();
      this.stack.pop(); return;
    }
    if (char === ":" && top.kind === "object" && top.state === "colon") { top.state = "value"; return; }
    if (char === "," && top.state === "comma") { top.state = top.kind === "object" ? "key" : "value"; return; }
    throw Error();
  }
  private finishString() {
    if (this.truncated) {
      if (this.keyToken) throw Error();
      this.token = capturePrefix(this.token, this.token.length, true) + "…[已截断]";
    }
    if (this.keyToken) {
      const top = this.stack.at(-1)!; top.key = this.token; top.state = "colon";
    } else this.accept(this.capture ? this.token : null);
    this.token = ""; this.mode = "normal";
  }
  private primitiveChar(char: string) {
    if (!this.primitiveState) {
      if (char === "t" || char === "f" || char === "n") this.primitiveState = { t: "true", f: "false", n: "null" }[char];
      else if (char === "-") this.primitiveState = "sign";
      else if (char === "0") this.primitiveState = "zero";
      else if (/[1-9]/.test(char)) this.primitiveState = "integer";
      else throw Error();
      this.primitivePosition = 1;
    } else if (["true", "false", "null"].includes(this.primitiveState)) {
      if (this.primitiveState[this.primitivePosition++] !== char) throw Error();
    } else {
      const digit = /[0-9]/.test(char);
      switch (this.primitiveState) {
        case "sign": if (!digit) throw Error(); this.primitiveState = char === "0" ? "zero" : "integer"; break;
        case "zero": case "integer":
          if (digit && this.primitiveState === "integer") break;
          if (char === ".") this.primitiveState = "dot";
          else if (char === "e" || char === "E") this.primitiveState = "exponent";
          else throw Error();
          break;
        case "dot": if (!digit) throw Error(); this.primitiveState = "fraction"; break;
        case "fraction": if (digit) break; if (char === "e" || char === "E") this.primitiveState = "exponent"; else throw Error(); break;
        case "exponent":
          if (char === "+" || char === "-") this.primitiveState = "exponent-sign";
          else if (digit) this.primitiveState = "exponent-digits";
          else throw Error();
          break;
        case "exponent-sign": if (!digit) throw Error(); this.primitiveState = "exponent-digits"; break;
        case "exponent-digits": if (!digit) throw Error(); break;
      }
    }
    // 协议字段中的数值很小；无关字段的任意长数字只验证，不驻留 token。
    if (this.keep()) this.token += char;
  }
  private finishPrimitive() {
    const state = this.primitiveState;
    const literal = ["true", "false", "null"].includes(state);
    if (!(literal ? this.primitivePosition === state.length : ["zero", "integer", "fraction", "exponent-digits"].includes(state))) throw Error();
    this.accept(this.keep() ? JSON.parse(this.token) : null);
    this.token = ""; this.primitiveState = ""; this.mode = "normal";
  }
  push(text: string) {
    if (this.invalid) return;
    try {
      let index = 0;
      // 大段普通字符串由正则原生扫描，不逐字符创建字符串或拼接工具正文。
      const special = /["\\\x00-\x1f]/g;
      while (index < text.length) {
        if (this.mode === "string") {
          if (this.unicode !== null) {
            const char = text[index++]!;
            if (!/[0-9a-fA-F]/.test(char)) throw Error();
            this.unicode += char;
            if (this.unicode.length === 4) { this.append(String.fromCharCode(parseInt(this.unicode, 16))); this.unicode = null; }
            continue;
          }
          if (this.escape) {
            const char = text[index++]!; this.escape = false;
            if (char === "u") this.unicode = "";
            else {
              if (!(char in ESCAPES)) throw Error();
              this.append(ESCAPES[char]!);
            }
            continue;
          }
          special.lastIndex = index;
          const match = special.exec(text);
          const end = match?.index ?? text.length;
          this.append(text.slice(index, end)); index = end;
          if (!match) continue;
          const char = text[index++]!;
          if (char === '"') this.finishString();
          else if (char === "\\") this.escape = true;
          else throw Error();
          continue;
        }
        if (this.mode === "primitive") {
          while (index < text.length && !/[ \t\r\n,}\]]/.test(text[index]!)) this.primitiveChar(text[index++]!);
          if (index < text.length) this.finishPrimitive();
          continue;
        }
        const char = text[index++]!;
        if (/^[ \t\r\n]$/.test(char)) continue;
        this.nonempty = true;
        if (char === '"') {
          const top = this.stack.at(-1);
          this.keyToken = !!top && top.kind === "object" && ["key", "first-key"].includes(top.state);
          this.capture = this.keyToken || this.keep(); this.token = ""; this.truncated = false; this.mode = "string";
        } else if ("{}[]:,".includes(char)) this.symbol(char);
        else { this.token = ""; this.primitiveState = ""; this.mode = "primitive"; this.primitiveChar(char); }
      }
    } catch { this.invalid = true; }
  }
  finish(): { event: Json | null | undefined; damaged: boolean } {
    try { if (this.mode === "primitive") this.finishPrimitive(); } catch { this.invalid = true; }
    if (!this.nonempty) return { event: undefined, damaged: false };
    return { event: this.result, damaged: this.invalid || this.mode !== "normal" || this.stack.length !== 0 || !this.done };
  }
}

/** 普通日志只读新增字节；压缩归档逐块解压。offset 均以解压后的完整行字节计。 */
export async function* readEvents(file: string, offset: number, size: number) {
  const compressed = file.endsWith(".zst");
  if (!compressed && offset >= size) return;
  const input = fs.createReadStream(file, { highWaterMark: 64 * 1024, ...(compressed ? {} : { start: offset, end: size - 1 }) });
  const stream = compressed ? input.pipe(createZstdDecompress({ chunkSize: 64 * 1024 })) : input;
  // pipe 默认不会把源的错误传给目标。
  if (compressed) input.on("error", error => stream.destroy(error));
  let parser = new EventParser(); let decoder = new StringDecoder("utf8");
  let position = compressed ? 0 : offset;
  let lineStart = position;
  try {
    for await (const value of stream) {
      const data = value as Buffer;
      let start = 0;
      while (start < data.length) {
        const newline = data.indexOf(10, start);
        const end = newline < 0 ? data.length : newline;
        const length = end - start;
        // 已处理的压缩前缀不重新解析。
        if (position + length > offset) parser.push(decoder.write(data.subarray(start + Math.max(0, offset - position), end)));
        position += length;
        if (newline < 0) break;
        position++;
        if (position > offset) { parser.push(decoder.end()); yield { ...parser.finish(), end: position }; }
        parser = new EventParser(); decoder = new StringDecoder("utf8"); lineStart = position; start = end + 1;
      }
    }
    // 归档是完整文件，允许最后一行无换行；活动日志半行留给下次。
    if (compressed && position > Math.max(offset, lineStart)) {
      parser.push(decoder.end()); yield { ...parser.finish(), end: position };
    }
  } finally { stream.destroy(); input.destroy(); }
}
