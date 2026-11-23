import type { HubDB } from "./db.ts";

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

/** 本机登记的 Mac 设备（platform='mac', local_only=1）与历史 "mac" 共享同一音频身份。 */
export function localMacDeviceIds(hub: HubDB): string[] {
  return (hub.db.prepare<[], { id: string }>(
    "SELECT id FROM devices WHERE platform='mac' AND local_only=1 ORDER BY id",
  ).all()).map(row => row.id);
}

/** 音频归属与分场用的归一化设备身份：本机 Mac 设备（local_only=1）映射为 "mac"，远端设备保持原 ID。 */
export function audioIdentity(hub: HubDB, device: string): string {
  if (device === "mac") return "mac";
  const local = hub.db.prepare<[string], { id: string }>(
    "SELECT id FROM devices WHERE id=? AND platform='mac' AND local_only=1",
  ).get(device);
  return local ? "mac" : device;
}

/** 与 device 共享同一音频身份的全部设备 ID（不改写已有记录，仅用于音频归属、清理与分场查询）。 */
export function audioEquivalentDevices(hub: HubDB, device: string): string[] {
  if (audioIdentity(hub, device) !== "mac") return [device];
  return ["mac", ...localMacDeviceIds(hub)];
}

/** 构造一次查询内复用的音频设备归一化函数，避免循环里重复查表。 */
export function audioDeviceGroup(hub: HubDB): (device: string | undefined) => string | undefined {
  const localMacs = new Set(localMacDeviceIds(hub));
  return device => (device && localMacs.has(device) ? "mac" : device);
}
