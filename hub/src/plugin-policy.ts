/** 与 CollectorCore/CapturePolicy 同口径。第三方输出在写库前再过一遍。 */
const blocked = new Set(["com.apple.keychainaccess", "com.apple.Passwords", "me.proton.pass.electron", "com.1password.1password", "com.agilebits.onepassword7", "com.bitwarden.desktop", "com.lastpass.LastPass", "com.dashlane.dashlanephonefinal"]);
const privateWindows = ["private browsing", "private window", "incognito", "inprivate", "隐私浏览", "无痕", "私密浏览", "隐身"];
export function pluginRecordPolicy(value: unknown, source: string): "allow" | "blocked" | "invalid" {
  if (!value || typeof value !== "object") return "invalid";
  const r = value as { source?: string; source_ref?: string; context?: { app?: string; window?: string } };
  if (r.source !== source || typeof r.source_ref !== "string" || !r.source_ref.trim()) return "invalid";
  if (blocked.has(r.context?.app ?? "") || typeof r.context?.window === "string" && privateWindows.some(w => r.context!.window!.toLowerCase().includes(w))) return "blocked";
  return "allow";
}
