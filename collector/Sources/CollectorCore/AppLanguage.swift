import Foundation
import Combine

public enum AppLanguage: String, Codable, Sendable, CaseIterable {
  case zh, en

  // Keep an explicit formatting scope local to its task, leaving process preferences intact.
  @TaskLocal static var scopedLanguage: Self?

  public static var current: Self {
    if let scopedLanguage { return scopedLanguage }
    return LanguagePreference(rawValue: UserDefaults.standard.string(forKey: LanguagePreference.defaultsKey) ?? "")?
      .resolved() ?? system()
  }

  public static func system(preferredLanguages: [String] = Locale.preferredLanguages) -> Self {
    preferredLanguages.first?.lowercased().hasPrefix("zh") == true ? .zh : .en
  }

  public func locale(region: String? = Locale.current.region?.identifier) -> Locale {
    Locale(identifier: region.map { "\(rawValue)_\($0)" } ?? rawValue)
  }
}

public enum LanguagePreference: String, Codable, Sendable, CaseIterable {
  case system, zh, en

  public static let defaultsKey = "languagePreference"

  public func resolved(preferredLanguages: [String] = Locale.preferredLanguages) -> AppLanguage {
    AppLanguage(rawValue: rawValue) ?? .system(preferredLanguages: preferredLanguages)
  }

  public static func initial(stored: String?, existingInstallation: Bool) -> Self {
    if let stored { return Self(rawValue: stored) ?? .system }
    return existingInstallation ? .zh : .system
  }

  public static func hasExistingInstallation(fileNames: Set<String>, defaultsKeys: Set<String>) -> Bool {
    !fileNames.isDisjoint(with: ["history.db", "collector.json", "hub-binding.json"])
      || !defaultsKeys.isDisjoint(with: ["source.screen.enabled", "source.wechat.enabled",
                                        "source.agent-sessions.enabled", "source.browser.enabled", "ocrEnabled", "recordingEnabled",
                                        "micDevice", "NSWindow Frame RecordAnythingMain"])
  }
}

@MainActor public final class LanguageStore: ObservableObject {
  public static let shared = LanguageStore()

  @Published public var preference: LanguagePreference {
    didSet {
      defaults.set(preference.rawValue, forKey: LanguagePreference.defaultsKey)
      refreshSystemLanguage()
    }
  }

  @Published public private(set) var resolved: AppLanguage
  public var onResolvedChange: ((AppLanguage) -> Void)?
  private let defaults: UserDefaults
  private let preferredLanguages: () -> [String]

  public init(defaults: UserDefaults = .standard, preferredLanguages: @escaping () -> [String] = { Locale.preferredLanguages }) {
    self.defaults = defaults
    self.preferredLanguages = preferredLanguages
    let preference = LanguagePreference.initial(stored: defaults.string(forKey: LanguagePreference.defaultsKey),
                                                existingInstallation: false)
    self.preference = preference
    resolved = preference.resolved(preferredLanguages: preferredLanguages())
  }

  /// Call before the app starts creating its own files and preferences.
  public func initialize(existingInstallation: Bool) {
    preference = LanguagePreference.initial(stored: defaults.string(forKey: LanguagePreference.defaultsKey),
                                            existingInstallation: existingInstallation)
  }

  public func refreshSystemLanguage() {
    let language = preference.resolved(preferredLanguages: preferredLanguages())
    guard language != resolved else { return }
    resolved = language
    onResolvedChange?(language)
  }
}
