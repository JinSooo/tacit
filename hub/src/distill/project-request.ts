import { ulid } from "../../../packages/record/index.ts";
import { redactString } from "../redact.ts";
import { DistillStore, type Fact, type Thread } from "./store.ts";
import { materialBody } from "./material.ts";
import * as P from "./prompts.ts";

interface Resolution { open_fact_id: string; by_fact_id: string; record_id: string; quote: string; reason: string }
export type ProjectModelOutput = P.ProjectOutput & { resolutions?: Resolution[] };

/**
 * 复用项目汇总识别同一对象的后续证据。替换自动未决事实或补充旧摘要的依据，不修改用户事实或归属。
 * 只有 since 之后新写入的决定才作为完成依据：更早的依据上一次项目整理已经核对过，
 * 每次都重送最近 30 条原文会让单次输入涨到十万 token 以上（2026-11-18）。
 */
export function projectRequest(store: DistillStore, projectId: string, name: string, threads: P.ThreadView[], since = Number.NEGATIVE_INFINITY) {
  const facts = store.facts("project_id", projectId);
  const byRef = new Map(facts.map((f, i) => [`f${i + 1}`, f]));
  const factRefs = new Map([...byRef].map(([ref, f]) => [f.id, ref]));
  const targets = facts.filter(f => f.origin === "llm" && (f.kind === "open" || f.kind === "next") && f.thread_id);
  const summaries = new Map<string, Thread>(threads.flatMap((t, i) => {
    const thread = store.thread(t.id);
    return thread?.brief && thread.project_id === projectId ? [[`t${i + 1}`, thread] as const] : [];
  }));
  const records = new Map<string, { id: string; source: string; excerpt: string; at: string; end: string }>();
  const sources = facts.filter(f => f.kind === "decision" && f.thread_id && Date.parse(f.created_at) > since)
    .sort((a, b) => Date.parse(b.valid_at) - Date.parse(a.valid_at));
  const evidence = new Map<string, string[]>();
  if (targets.length || summaries.size) for (const f of sources) {
    const refs: string[] = [];
    for (const id of f.evidence) {
      const r = store.hub.effective(id);
      if (!r || r.sensitivity === "private") continue;
      let ref = [...records].find(([, value]) => value.id === r.id)?.[0];
      if (!ref && records.size < 30) {
        ref = `r${records.size + 1}`;
        records.set(ref, { id: r.id, source: r.source, excerpt: P.excerpt(materialBody(r), 1800), at: r.t_start, end: r.t_end ?? r.t_start });
      }
      if (ref) refs.push(ref);
    }
    if (refs.length) evidence.set(f.id, refs);
  }
  // 详细版由线程简略版写成；事实只送待消解的未决、本次的新依据和用户写的事实。
  const targetIds = new Set(targets.map(f => f.id));
  const views = facts.filter(f => targetIds.has(f.id) || evidence.has(f.id) || f.origin === "user").map(f => ({ id: factRefs.get(f.id), kind: f.kind, text: redactString(f.text).text, origin: f.origin, at: f.valid_at,
    scope: { thread_id: f.thread_id ?? null, project_id: f.project_id ?? null }, evidence: evidence.get(f.id) ?? [] }));
  const options = [...targets.map(f => factRefs.get(f.id)!), ...summaries.keys()];
  const sourceOptions = sources.filter(f => evidence.has(f.id)).map(f => factRefs.get(f.id)!);
  const schema = { ...P.PROJECT_SCHEMA, required: [...P.PROJECT_SCHEMA.required, "resolutions"], properties: { ...P.PROJECT_SCHEMA.properties,
    resolutions: { type: "array", maxItems: options.length && sourceOptions.length ? 12 : 0, items: {
      type: "object", additionalProperties: false, required: ["open_fact_id", "by_fact_id", "record_id", "quote", "reason"], properties: {
        open_fact_id: { type: "string", ...(options.length ? { enum: options } : {}) },
        by_fact_id: { type: "string", ...(sourceOptions.length ? { enum: sourceOptions } : {}) },
        record_id: { type: "string", ...(records.size ? { enum: [...records.keys()] } : {}) },
        quote: { type: "string", minLength: 12 }, reason: { type: "string", minLength: 12 },
      },
    } },
  } };
  return {
    schema,
    refs: Object.fromEntries([...byRef].map(([ref, f]) => [ref, f.id]).concat([...records].map(([ref, r]) => [ref, r.id]), [...summaries].map(([ref, t]) => [ref, t.id]))),
    prompt: `项目：${name}\n\n<data>\n${JSON.stringify({ threads, facts: views, summary_targets: [...summaries].map(([ref, t]) => ({ id: ref, title: t.title, brief: t.brief, last: t.last_ms })), resolution_targets: options, completion_evidence: [...records].map(([ref, { id, ...r }]) => ({ id: ref, ...r })) })}\n</data>`,
    apply(out: ProjectModelOutput, now: number): number {
      let resolved = 0;
      const updated = new Set<string>();
      for (const resolution of out.resolutions ?? []) {
        const old = byRef.get(resolution.open_fact_id), by = byRef.get(resolution.by_fact_id), record = records.get(resolution.record_id);
        const oldSummary = summaries.get(resolution.open_fact_id);
        if ((!old && !oldSummary) || !by || !record || !options.includes(resolution.open_fact_id) || !sourceOptions.includes(resolution.by_fact_id)) continue;
        const live = store.facts("project_id", projectId), target = old && live.find(f => f.id === old.id), source = live.find(f => f.id === by.id);
        const threadId = oldSummary?.id ?? target?.thread_id;
        const thread = threadId && store.thread(threadId);
        if (!thread || !source?.thread_id || thread.id === source.thread_id || source.project_id !== projectId
          || thread.project_id !== projectId || store.thread(source.thread_id)?.project_id !== projectId || source.text !== by.text) continue;
        if (oldSummary) {
          // 长会话的开始时间不是完成时间；后半段的运行结果可能晚于旧事项结束。
          if ((!updated.has(thread.id) && thread.brief !== oldSummary.brief) || Date.parse(record.end) <= (thread.last_ms ?? 0)) continue;
          // 同一依据已经带入过，不因措辞不同重复补事实。
          if (store.facts("thread_id", thread.id).some(f => f.evidence.includes(record.id) && f.text.includes(resolution.quote))) continue;
        } else if (!target || target.origin !== "llm" || !["open", "next"].includes(target.kind)
          || target.project_id !== projectId || target.text !== old!.text || Date.parse(source.valid_at) <= Date.parse(target.valid_at)) continue;
        const raw = store.hub.effective(record.id);
        if (!raw || raw.sensitivity === "private" || !source.evidence.includes(record.id)
          || resolution.quote.trim().length < 12 || resolution.reason.trim().length < 12
          || !record.excerpt.includes(resolution.quote) || !raw.body.includes(resolution.quote)) continue;
        const sourceTitle = store.thread(source.thread_id)!.title;
        const replacement: Fact = { ...source, id: ulid(), thread_id: thread.id, project_id: projectId, origin: "llm",
          text: `后续进展（${sourceTitle}）：${resolution.quote}`, evidence: [...new Set([...(target?.evidence ?? []), record.id])],
          reason: resolution.reason, valid_at: record.end, created_at: new Date(now).toISOString() };
        const mark = store.getState<Record<string, unknown>>(`digest:${thread.id}`);
        if (mark) store.setState(`digest:${thread.id}`, { ...mark, fact_ids: store.facts("thread_id", thread.id).map(f => f.id).sort() });
        store.writeFact(replacement, target?.id);
        // 旧简略版不能继续把已经有后续证据的事项描述为待办；详细版保留给下一次整理核对。
        store.upsertThread({ ...thread, brief: null, needs_regen: 1 });
        updated.add(thread.id);
        store.setState("now", null);
        resolved++;
      }
      return resolved;
    },
  };
}
