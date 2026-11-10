import type { Api } from "./distillation.ts";

export interface Speaker {
  id: string; label: string; name: string | null; is_me: boolean | number;
  confirmed: boolean | number; conversations: number; seconds: number;
}
export function speakerNames(people: string[] = [], speakers: Speaker[] = []): string[] {
  const names = new Map(speakers.map(speaker => [speaker.id, speaker.name || speaker.label]));
  return people.map(id => names.get(id) ?? id);
}
export function retentionDays(value: string | number): number {
  const days = typeof value === "string" && !value.trim() ? NaN : Number(value);
  if (!Number.isInteger(days) || days < 1 || days > 365) throw new Error("录音保留天数须为 1–365 的整数");
  return days;
}
export function createAudioApi(api: Api) {
  return {
    speakers: (signal?: AbortSignal) => api<{ speakers: Speaker[] }>("/v1/speakers", { signal }),
    sample: (id: string, signal?: AbortSignal) => api<Blob>(`/v1/audio/samples/${encodeURIComponent(id)}`, { signal, cache: "no-store" }),
    settings: (signal?: AbortSignal) => api<{ retention_days: number }>("/v1/audio/settings", { signal }),
    saveSettings: (value: string | number) => api<{ retention_days: number }>("/v1/audio/settings", { method: "PUT", body: JSON.stringify({ retention_days: retentionDays(value) }) }),
    purge: () => api("/v1/audio/purge", { method: "POST" }),
  };
}
export type AudioApi = ReturnType<typeof createAudioApi>;

/** 收起或离开时中止取回，并释放已创建的 URL；迟到的响应不能重新创建 URL。 */
export function samplePlayback(load: (signal: AbortSignal) => Promise<Blob>, urls = URL) {
  const controller = new AbortController();
  let url: string | undefined;
  return {
    async open() {
      const blob = await load(controller.signal);
      if (controller.signal.aborted) return undefined;
      url = urls.createObjectURL(blob);
      return url;
    },
    dispose() {
      controller.abort();
      if (url) { urls.revokeObjectURL(url); url = undefined; }
    },
  };
}
