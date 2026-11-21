export const AUDIO_SOURCES = new Set(["mac.audio", "android.audio"]);
export const SKELETON_SOURCES = new Set(["mac.screen", "mac.browser", "mac.app", "android.usage"]);

// 模块内固定来源集合共用同一份 SQL 和 TypeScript 口径。
export const sourceList = (sources: Iterable<string>) => [...sources].map(source => `'${source}'`).join(",");
