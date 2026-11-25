import type { ChildProcessWithoutNullStreams, SpawnOptionsWithoutStdio } from "node:child_process";

export type Tier = "minute" | "hour" | "day";
export type Provider = "claude-cli" | "codex-cli" | "anthropic" | "openai-compatible";
export interface LLMRequest { tier: Tier; task?: string; system: string; prompt: string; schema: object; timeoutMs?: number; contentRevision?: number; refs?: Record<string, string>; normalizeOutput?: (value: unknown) => unknown;
  /**
   * 通过 schema 后的内容检查：返回问题描述（只含规则和数字，不含内容）时带着它重试一次。
   * 重试结果不合 schema、出错或 recheck(重试结果, 第一次结果) 仍报问题时用第一次的；最终是否采用由调用方判断。
   */
  recheck?: (value: unknown, first?: unknown) => string | null }
export type LLMResult<T> = ({ ok: true; data: T; ms: number } | { ok: false; error: string; ms: number; retryAfterMs?: number; discarded?: boolean }) & { call_id?: string };
export type ReasoningEffort = "none" | "low" | "medium" | "high";
export interface ModelConfig { provider: Provider; model: string; base_url?: string; reasoning_effort?: ReasoningEffort }
export interface UsageRow {
  id: string; at: string; tier: Tier; task: string | null; provider: string; model: string;
  input_chars: number; output_chars: number; input_tokens: number | null; output_tokens: number | null;
  ms: number; ok: 0 | 1; error: string | null;
}
export type ReadKey = (provider: Provider) => string | Promise<string>;
export type Spawn = (command: string, args: string[], options: SpawnOptionsWithoutStdio) => ChildProcessWithoutNullStreams;
export interface Metrics { outputChars: number; inputTokens: number | null; outputTokens: number | null }
export interface CallObserver { request(transport: "api" | "cli", payload: unknown): void; response(text: string, apiKey?: string): void }
export interface BackendContext { req: LLMRequest; config: ModelConfig; cwd: string; spawn: Spawn; metrics: Metrics; timeoutMs: number; observer?: CallObserver }
