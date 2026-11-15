import { threadPrompt, THREAD_SCHEMA, type FactView, type FrameView, type ProjectHint, type ThreadOutput } from "./prompts.ts";
import { groundedQuote, sessionUserTexts, withUserStatements } from "./quotes.ts";

export type ThreadModelOutput = Omit<ThreadOutput, "new_facts"> & {
  new_facts: (ThreadOutput["new_facts"][number] & { supports: { record_id: string; text: string }[] })[];
};

/** 引用只在本次请求内有效。长存储 ID 不交给模型抄写，输出也不做模糊纠错。 */
export function threadRequest(thread: { title: string; detail: unknown }, facts: FactView[], frames: FrameView[], project: ProjectHint = null,
  readRecord?: (id: string) => { source: string; body: string } | null | undefined) {
  const recordRefs = new Map<string, string>(), factRefs = new Map<string, string>();
  const excerpts = new Map<string, { source: string; body: string }[]>();
  const recordRef = (id: string) => {
    if (!recordRefs.has(id)) recordRefs.set(id, `r${recordRefs.size + 1}`);
    return recordRefs.get(id)!;
  };
  const current = new Set<string>();
  const inputFrames = frames.map((f, index) => ({ ...f, id: `s${index + 1}`, records: f.private ? [] : f.records.map(r => {
    if (!r.id) return r; // 不含正文的 private/抽样计数说明，不是可引用证据。
    const id = recordRef(r.id); current.add(id);
    excerpts.set(id, [...(excerpts.get(id) ?? []), { source: r.source, body: r.excerpt }]);
    return withUserStatements({ ...r, id });
  }) }));
  const oldDetail = thread.detail && typeof thread.detail === "object" ? thread.detail as Record<string, unknown> : {};
  const oldQuotes = Array.isArray(oldDetail.quotes) ? oldDetail.quotes as ThreadOutput["detail"]["quotes"] : [];
  const quotes = oldQuotes.filter(q => typeof q?.record_id === "string" && typeof q.text === "string")
    .map(q => ({ ...q, record_id: recordRef(q.record_id) }));
  const inputFacts = facts.map(f => {
    const id = `f${factRefs.size + 1}`; factRefs.set(f.id, id);
    return { ...f, id };
  });
  const invalidatable = inputFacts.filter(f => f.origin === "llm").map(f => f.id);
  const refSchema = (values: string[]) => ({ type: "string", ...(values.length ? { enum: values } : {}) });
  const base = THREAD_SCHEMA.properties;
  const schema = {
    ...THREAD_SCHEMA,
    properties: {
      ...base,
      detail: { ...base.detail, properties: { ...base.detail.properties, quotes: {
        ...base.detail.properties.quotes, ...(recordRefs.size ? {} : { maxItems: 0 }),
        items: { ...base.detail.properties.quotes.items, properties: { ...base.detail.properties.quotes.items.properties,
          record_id: refSchema([...recordRefs.values()]),
        } },
      } } },
      new_facts: { ...base.new_facts, ...(current.size ? {} : { maxItems: 0 }), items: {
        ...base.new_facts.items, required: [...base.new_facts.items.required, "supports"], properties: { ...base.new_facts.items.properties,
          evidence: { ...base.new_facts.items.properties.evidence, items: refSchema([...current]) },
          supports: { type: "array", minItems: 1, items: { type: "object", additionalProperties: false,
            required: ["record_id", "text"], properties: { record_id: refSchema([...current]), text: { type: "string", minLength: 1 } },
          } },
        },
      } },
      invalidate: { ...base.invalidate, ...(invalidatable.length ? {} : { maxItems: 0 }), items: {
        ...base.invalidate.items, properties: { ...base.invalidate.items.properties, fact_id: refSchema(invalidatable) },
      } },
    },
  };
  const recordsByRef = new Map([...recordRefs].map(([id, ref]) => [ref, id]));
  const factsByRef = new Map([...factRefs].map(([id, ref]) => [ref, id]));
  const currentIDs = new Set([...recordRefs].filter(([, ref]) => current.has(ref)).map(([id]) => id));
  return {
    refs: Object.fromEntries([...recordsByRef, ...factsByRef, ...frames.map((f,i) => [`s${i+1}`,f.id] as const)]),
    prompt: threadPrompt({ ...thread, detail: { ...oldDetail, quotes } }, inputFacts, inputFrames, project), schema,
    decode(out: ThreadModelOutput): ThreadOutput {
      return { ...out,
        detail: { ...out.detail, quotes: out.detail.quotes.flatMap(q => {
          const record_id = recordsByRef.get(q.record_id);
          return record_id ? [{ ...q, record_id }] : [];
        }) },
        // 保留 new_facts 的原位置，让 invalidate.replaced_by 的下标保持有效。
        new_facts: out.new_facts.map(({ supports, ...f }) => {
          // 不猜测或重挂错误引用。一条事实的每个证据都须有逐字依据；有任一错引就整条丢弃。
          const backed = supports?.length > 0 && f.evidence.length > 0
            && supports.every(s => f.evidence.includes(s.record_id) && !!s.text.trim() && excerpts.get(s.record_id)?.some(r => r.body.includes(s.text))
              && (!readRecord || !!readRecord(recordsByRef.get(s.record_id)!)?.body.includes(s.text)))
            && f.evidence.every(ref => current.has(ref) && supports.some(s => s.record_id === ref));
          const sourceRecords = f.evidence.flatMap(ref => excerpts.get(ref) ?? []);
          const sessionsOnly = sourceRecords.length > 0 && sourceRecords.every(r => sessionUserTexts(r.source, r.body) !== null);
          const confirmed = f.kind !== "decision" && f.kind !== "rejected" || !sessionsOnly || supports?.some(s => {
            const recordId = recordsByRef.get(s.record_id);
            const original = recordId ? readRecord?.(recordId) : undefined;
            return original ? groundedQuote(original, s.text) : excerpts.get(s.record_id)?.some(r => groundedQuote(r, s.text));
          });
          return { ...f, evidence: backed && confirmed ? [...new Set(f.evidence.flatMap(ref => {
            const id = recordsByRef.get(ref);
            return id && currentIDs.has(id) ? [id] : [];
          }))] : [] };
        }),
        invalidate: out.invalidate.flatMap(inv => {
          const fact_id = invalidatable.includes(inv.fact_id) ? factsByRef.get(inv.fact_id) : undefined;
          return fact_id ? [{ ...inv, fact_id }] : [];
        }),
      };
    },
  };
}
