import { expect, test } from "bun:test";
import { callStatus, snapshotMessage, type ModelCall } from "../src/runtime.ts";
const call = (value: Partial<ModelCall>): ModelCall => ({ id:"synthetic",at:"2026-11-13T12:00:00Z",task:"thread_digest",tier:"hour",provider:"codex-cli",model:"synthetic",transport:"cli",provider_state:"returned",validation_state:"passed",application_state:"pending",content_state:"available",ms:1000,input_tokens:null,output_tokens:null,error:null,...value });
test("已返回或校验通过不能显示成已采用；历史调用不猜测采用状态", () => {
  expect(callStatus(call({}))).toBe("校验通过，待确认采用");
  expect(callStatus(call({application_state:"applied"}))).toBe("已用于更新");
  expect(callStatus(call({application_state:"discarded"}))).toContain("未采用");
  expect(callStatus(call({application_state:"unknown"}))).toContain("采用情况未记录");
  expect(callStatus(call({validation_state:"failed",error:"结果格式有误"}))).toBe("失败");
});
test("删除、过期和未保存正文分别解释，不能用当前内容冒充历史快照", () => {
  expect(snapshotMessage("deleted")).toContain("已一并清空");
  expect(snapshotMessage("expired")).toContain("7 天");
  expect(snapshotMessage("not_recorded")).toContain("无法还原");
  expect(snapshotMessage("available")).toBeNull();
});
