import Foundation

/// 应用的显示名。和采集端写进记录标题的 NSRunningApplication.localizedName 取同一个名字：
/// 按用户的系统语言，不按本应用的界面语言。本应用声明了 zh-Hans 界面，
/// FileManager.displayName 会跟着变成"微信"，和记录标题里的 WeChat、搜索词对不上。
public enum AppNames {
  public static func systemLanguageName(_ url: URL, preferences: [String] = Locale.preferredLanguages) -> String {
    let fallback = url.deletingPathExtension().lastPathComponent
    guard let b = Bundle(url: url) else { return fallback }
    for lang in Bundle.preferredLocalizations(from: b.localizations, forPreferences: preferences) {
      if let path = b.path(forResource: "InfoPlist", ofType: "strings", inDirectory: nil, forLocalization: lang),
         let d = NSDictionary(contentsOfFile: path) as? [String: Any],
         let n = (d["CFBundleDisplayName"] ?? d["CFBundleName"]) as? String, !n.isEmpty { return n }
    }
    let info = b.infoDictionary ?? [:]
    return (info["CFBundleDisplayName"] ?? info["CFBundleName"]) as? String ?? fallback
  }
}
