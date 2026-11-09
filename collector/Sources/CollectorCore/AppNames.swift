import Foundation

/// 应用的显示名。和采集端写进记录标题的 NSRunningApplication.localizedName 取同一个名字：
/// 按用户的系统语言，不按本应用的界面语言。本应用声明了 zh-Hans 界面，
/// FileManager.displayName 会跟着变成"微信"，和记录标题里的 WeChat、搜索词对不上。
public enum AppNames {
  public static func systemLanguageName(_ url: URL, preferences: [String] = Locale.preferredLanguages) -> String {
    let fallback = url.deletingPathExtension().lastPathComponent
    guard let b = Bundle(url: url) else { return fallback }
    // 较新的系统应用把各语言的名字放在一个 InfoPlist.loctable 里（语言 → 键值），没有 lproj/InfoPlist.strings。
    // 表里通常只有翻译，开发语言（多为 en）的名字留在 Info.plist 里；不把它算进候选，en-US 会被匹配到 en_GB（"Print Centre"）。
    if let path = b.path(forResource: "InfoPlist", ofType: "loctable"),
       let table = NSDictionary(contentsOfFile: path) as? [String: [String: Any]] {
      let dev = b.developmentLocalization ?? "en"
      for lang in Bundle.preferredLocalizations(from: Array(Set(table.keys).union([dev])), forPreferences: preferences) {
        if let n = name(in: table[lang] ?? (lang == dev ? b.infoDictionary ?? [:] : [:])) { return n }
      }
    }
    for lang in Bundle.preferredLocalizations(from: b.localizations, forPreferences: preferences) {
      if let path = b.path(forResource: "InfoPlist", ofType: "strings", inDirectory: nil, forLocalization: lang),
         let d = NSDictionary(contentsOfFile: path) as? [String: Any], let n = name(in: d) { return n }
    }
    return name(in: b.infoDictionary ?? [:]) ?? fallback
  }

  static func name(in d: [String: Any]) -> String? {
    let n = (d["CFBundleDisplayName"] ?? d["CFBundleName"]) as? String
    return n?.isEmpty == false ? n : nil
  }
}
