import type { Api } from "./distillation.ts";

export interface Speaker {
  id: string; label: string; name: string | null; is_me: boolean | number;
  confirmed: boolean | number; conversations: number; seconds: number;
}
export function speakerNames(people: string[] = [], speakers: Speaker[] = []): string[] {
  const names = new Map(speakers.map(speaker => [speaker.id, speaker.name || speaker.label]));
  return people.map(id => names.get(id) ?? id);
}
/** 和 Mac 端 SpeakerMenu 同一套规则：同名的已确认的人只留一条（取最活跃的作为合并目标）。 */
export function knownSpeakers(speakers: Speaker[], excludeId?: string): { id: string; name: string; conversations: number }[] {
  const best = new Map<string, Speaker>();
  for (const s of speakers) {
    if (!s.confirmed || s.id === excludeId) continue;
    const name = (s.name || s.label).trim();
    const old = best.get(name);
    if (old && (old.conversations > s.conversations || old.conversations === s.conversations && old.seconds >= s.seconds)) continue;
    best.set(name, s);
  }
  return [...best.entries()]
    .map(([name, s]) => ({ id: s.id, name, conversations: s.conversations, seconds: s.seconds }))
    .sort((a, b) => b.conversations - a.conversations || b.seconds - a.seconds);
}
/** 还没确认的声音：只列出现过 2 段对话或累计 30 秒以上的，最多 limit 条。 */
export function unknownSpeakers(speakers: Speaker[], excludeId?: string, limit = 12) {
  return speakers
    .filter(s => !s.confirmed && s.id !== excludeId && (s.conversations >= 2 || s.seconds >= 30))
    .sort((a, b) => b.conversations - a.conversations || b.seconds - a.seconds)
    .slice(0, limit)
    .map(s => ({ id: s.id, name: s.name || s.label, conversations: s.conversations }));
}
/** 填的名字已经有人用了就返回那个人，改为并过去，不再新建同名的。 */
export function sameNamedSpeaker(speakers: Speaker[], name: string): Speaker | undefined {
  const key = name.trim();
  if (!key) return undefined;
  return speakers
    .filter(s => s.confirmed && (s.name || s.label).trim() === key)
    .sort((a, b) => b.conversations - a.conversations || b.seconds - a.seconds)[0];
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
