/**
 * 按 "\n" 切 JSONL，去掉行尾 "\r"。不用 node:readline：它把 U+2028 / U+2029 也当换行，
 * 而 JSON.stringify 不转义这两个字符，含有它们的记录会被切成几段、全部解析失败。
 */
export async function* jsonLines(input: AsyncIterable<Uint8Array | string>): AsyncGenerator<string> {
  const decoder = new TextDecoder();
  let rest = "";
  for await (const chunk of input) {
    rest += typeof chunk === "string" ? chunk : decoder.decode(chunk, { stream: true });
    let at: number;
    while ((at = rest.indexOf("\n")) >= 0) {
      yield rest.slice(0, at).replace(/\r$/, "");
      rest = rest.slice(at + 1);
    }
  }
  rest += decoder.decode();
  if (rest) yield rest.replace(/\r$/, "");
}
