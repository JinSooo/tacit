export const AUDIO_SOURCES = new Set(["mac.audio", "android.audio"]);
export const SKELETON_SOURCES = new Set(["mac.screen", "mac.browser", "mac.app", "android.usage"]);

// 模块内固定来源集合共用同一份 SQL 和 TypeScript 口径。
export const sourceList = (sources: Iterable<string>) => [...sources].map(source => `'${source}'`).join(",");

// 只用于用户读筛选。设备鉴权、所有权和同步仍按完整 ID 匹配。
export function recordDeviceFilter(device: string): string {
  return device === "mac"
    ? "(r.device=? OR r.device GLOB 'mac-[a-z2-7][a-z2-7][a-z2-7][a-z2-7][a-z2-7][a-z2-7][a-z2-7][a-z2-7]')"
    : "r.device=?";
}
