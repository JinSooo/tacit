import { expect, test } from "bun:test";
import { EventParser } from "./json-lines.ts";

function parse(text: string, chunkSize: number) {
  const parser = new EventParser();
  for (let index = 0; index < text.length; index += chunkSize) parser.push(text.slice(index, index + chunkSize));
  return parser.finish();
}

test("任意切块和字段顺序保持投影，转义、嵌套工具内容不伪装成可见消息", () => {
  const event = {
    payload: { content: [{ text: '中文\n"引号"\\路径\t😀', type: "input_text" }], role: "user", type: "message" },
    ignored: [{ type: "user", payload: { text: "伪造消息" } }, true, false, null, -1.5e4],
    timestamp: "2026-11-07T10:01:00Z", type: "response_item",
  };
  for (const size of [1, 2, 7, 64, 1000]) {
    const result = parse(JSON.stringify(event), size);
    expect(result.damaged).toBe(false);
    expect(JSON.parse(JSON.stringify(result.event))).toEqual({ payload: event.payload, timestamp: event.timestamp, type: event.type });
  }
  const escaped = parse('{"\\u0074ype":"user","message":{"content":"\\u4e2d\\u6587\\ud83d\\ude00","role":"user"}}', 1);
  expect(escaped.damaged).toBe(false); expect(escaped.event?.message.content).toBe("中文😀");
});

test("忽略的大字符串无正文驻留，直接可见字符串保留有界前缀", () => {
  const huge = "合成工具输出".repeat(200000);
  const event = { message: { content: [{ content: huge, type: "tool_result" }, { text: "真正用户输入", type: "text" }], role: "user" }, type: "user" };
  const result = parse(JSON.stringify(event), 4096);
  expect(result.damaged).toBe(false);
  expect(JSON.stringify(result.event).length).toBeLessThan(200);
  expect(result.event?.message.content).toEqual([{ type: "tool_result" }, { text: "真正用户输入", type: "text" }]);
  const visible = parse(JSON.stringify({ type: "user", message: { role: "user", content: huge } }), 8192);
  expect(visible.damaged).toBe(false); expect(visible.event?.message.content.length).toBeLessThanOrEqual(150064 + "…[已截断]".length);
});

test("损坏语法被识别，空行和合法无关 JSON 不算损坏", () => {
  for (const text of ['{"type":"user",}', '{"a":[1,]}', '{"a":true false}', '{"a":"bad\\q"}', '{"a":"bad\t"}', '{"a":01}', '{"a":1e}', '{}{}', '{"type":', '{"a":"\\u00xx"}']) {
    expect(parse(text, 1).damaged).toBe(true);
  }
  for (const text of ["", "  \r", "{}", "[]", "null", '{"ignored":' + "9".repeat(5000) + "}", '{"unused":{"array":[1,2,{},null,true,false]}}']) expect(parse(text, 2).damaged).toBe(false);
});
