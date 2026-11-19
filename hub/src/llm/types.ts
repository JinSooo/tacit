import type { ChildProcessWithoutNullStreams, SpawnOptionsWithoutStdio } from "node:child_process";

export type Tier = "minute" | "hour" | "day";
export type Provider = "claude-cli" | "codex-cli" | "anthropic" | "openai-compatible";
export interface LLMRequest { tier: Tier; task?: string; system: string; prompt: string; schema: object; timeoutMs?: number; contentRevision?: number; refs?: Record<string, string>; normalizeOutput?: (value: unknown) => unknown }
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
