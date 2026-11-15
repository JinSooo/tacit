export interface ModelCall {
  id: string; at: string; task: string | null; tier: string | null; provider: string | null; model: string | null;
  transport: string | null; provider_state: string; validation_state: string; application_state: string;
  content_state: string; ms: number | null; input_tokens: number | null; output_tokens: number | null; error: string | null;
}
export interface CallSnapshot extends ModelCall {
  kind: string; request: unknown; response: string | null; response_truncated: number; redactions: number;
}
export const taskNames: Record<string,string> = {
  assign: "整理活动", thread_digest: "整理事项", thread_brief: "事项摘要", classify: "判断归属", dedupe: "合并事项",
  project: "项目进展", project_brief: "项目摘要", day: "每日日记", day_brief: "日记摘要", conversation_summary: "对话总结", connection_test: "测试连接",
};
export const callTask = (task: string | null) => task ? taskNames[task] ?? "模型整理" : "早期调用";
export function callStatus(call: ModelCall): string {
  if (call.application_state === "discarded") return "记录已变化，未采用";
  if (call.application_state === "applied") return "已用于更新";
  if (call.error) return "失败";
  if (call.application_state === "unknown") return call.validation_state === "passed" ? "调用成功，采用情况未记录" : "调用失败";
  if (call.validation_state === "passed") return "校验通过，待确认采用";
  if (call.provider_state === "sending") return "等待模型返回";
  if (call.provider_state === "returned") return "已返回，校验未通过";
  return "准备发送";
}
export function snapshotMessage(state: string): string | null {
  return ({ deleted: "删除历史记录时，调用正文已一并清空。", expired: "已超过 7 天，正文已清除。", not_recorded: "这次调用发生时没有保存正文，无法还原当时发送的内容。", unavailable: "当时未能保存正文。" } as Record<string,string>)[state] ?? null;
}
export const elapsed = (ms: number | null) => ms == null ? "进行中" : ms < 1000 ? `${ms} ms` : `${(ms/1000).toFixed(1)} 秒`;
