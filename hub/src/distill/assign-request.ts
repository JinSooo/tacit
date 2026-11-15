import { assignPrompt, ASSIGN_SCHEMA, type AssignOutput, type FrameView, type ThreadView } from "./prompts.ts";

/** 模型只选择本次请求中的短编号；未知引用保持未处理，不猜测归属。 */
export function assignRequest(frames: FrameView[], threads: ThreadView[]) {
  const frameIDs = new Map(frames.map((f, i) => [`s${i + 1}`, f.id]));
  const threadIDs = new Map(threads.map((t, i) => [`t${i + 1}`, t.id]));
  const base = ASSIGN_SCHEMA.properties.items;
  return {
    refs: Object.fromEntries([...frameIDs,...threadIDs]),
    prompt: assignPrompt(frames.map((f, i) => ({ ...f, id: `s${i + 1}` })), threads.map((t, i) => ({ ...t, id: `t${i + 1}` }))),
    schema: { ...ASSIGN_SCHEMA, properties: { items: { ...base, items: { ...base.items, properties: {
      ...base.items.properties,
      frame_id: { type: "string", enum: [...frameIDs.keys()] },
      thread_id: { type: ["string", "null"], enum: [null, ...threadIDs.keys()] },
    } } } } },
    decode(out: AssignOutput): AssignOutput {
      return { items: out.items.flatMap(item => {
        const frame_id = frameIDs.get(item.frame_id);
        const thread_id = item.thread_id === null ? null : threadIDs.get(item.thread_id);
        return frame_id && thread_id !== undefined ? [{ ...item, frame_id, thread_id }] : [];
      }) };
    },
  };
}
