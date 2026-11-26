import Foundation
import Testing
@testable import CollectorCore

@Test func systemLanguageFollowsFirstPreferredLanguage() {
  for code in ["zh", "zh-Hans-CN", "zh-Hant-TW", "ZH-HK"] {
    #expect(AppLanguage.system(preferredLanguages: [code, "en-US"]) == .zh)
  }
  #expect(AppLanguage.system(preferredLanguages: ["en-GB", "zh-Hans"]) == .en)
  #expect(AppLanguage.system(preferredLanguages: ["ja-JP"]) == .en)
  #expect(AppLanguage.system(preferredLanguages: []) == .en)
  #expect(LanguagePreference.zh.resolved(preferredLanguages: ["en-US"]) == .zh)
  #expect(LanguagePreference.en.resolved(preferredLanguages: ["zh-Hans"]) == .en)
}

@Test func formattingUsesResolvedLanguageAndSystemRegion() throws {
  #expect(AppLanguage.en.locale(region: "GB").identifier == "en_GB")
  #expect(AppLanguage.en.locale(region: "US").identifier == "en_US")
  #expect(AppLanguage.zh.locale(region: "CN").identifier == "zh_CN")
  #expect(AppLanguage.en.locale(region: nil).identifier == "en")
  var calendar = Calendar(identifier: .gregorian)
  calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
  let date = try #require(calendar.date(from: .init(year: 2026, month: 11, day: 26, hour: 16, minute: 45)))
  let us = L10n.clock(date, lang: .en, calendar: calendar, region: "US")
  #expect(us.hasPrefix("4:45"))
  #expect(us.hasSuffix("PM"))
  #expect(L10n.clock(date, lang: .en, calendar: calendar, region: "GB") == "16:45")
  #expect(L10n.clock(date, lang: .zh, calendar: calendar, region: "US") == "16:45")
  #expect(ViewerFormat.date(date, now: date, calendar: calendar, lang: .en) == "Nov 26")
  #expect(ViewerFormat.date(date, now: date, calendar: calendar, lang: .zh) == "11 月 26 日")
}

@Test func languageUpgradePinDistinguishesFreshAndExistingInstalls() {
  #expect(!LanguagePreference.hasExistingInstallation(fileNames: ["collector.lock"], defaultsKeys: ["AppleLanguages"]))
  #expect(LanguagePreference.hasExistingInstallation(fileNames: ["history.db"], defaultsKeys: []))
  #expect(LanguagePreference.hasExistingInstallation(fileNames: ["collector.json"], defaultsKeys: []))
  #expect(LanguagePreference.hasExistingInstallation(fileNames: [], defaultsKeys: ["source.screen.enabled"]))
  #expect(LanguagePreference.initial(stored: nil, existingInstallation: true) == .zh)
  #expect(LanguagePreference.initial(stored: nil, existingInstallation: false) == .system)
  #expect(LanguagePreference.initial(stored: "system", existingInstallation: true) == .system)
  #expect(LanguagePreference.initial(stored: "en", existingInstallation: true) == .en)
  #expect(LanguagePreference.initial(stored: "invalid", existingInstallation: true) == .system)
}

@MainActor @Test func languageStorePersistsPinAndEmitsResolvedChanges() throws {
  let name = "test.tacit.language.\(UUID())"
  let defaults = try #require(UserDefaults(suiteName: name))
  defer { defaults.removePersistentDomain(forName: name) }
  var preferred = ["en-GB"]
  let store = LanguageStore(defaults: defaults, preferredLanguages: { preferred })
  var changes: [AppLanguage] = []
  store.onResolvedChange = { changes.append($0) }
  store.initialize(existingInstallation: true)
  #expect(defaults.string(forKey: LanguagePreference.defaultsKey) == "zh")
  #expect(store.resolved == .zh)
  store.preference = .system
  preferred = ["zh-Hans"]
  store.refreshSystemLanguage()
  store.refreshSystemLanguage()
  #expect(changes == [.zh, .en, .zh])
  #expect(LanguageStore(defaults: defaults, preferredLanguages: { ["en-GB"] }).preference == .system)
}

@Test func textPreservesOriginalQuotesAndLocalizesFormatting() {
  let now = Date(timeIntervalSince1970: 1_800_000_000)
  #expect(L10n.text(zh: "补写", en: "Note", lang: .zh) == "补写")
  #expect(L10n.text(zh: "补写", en: "Note", lang: .en) == "Note")
  #expect(L10n.count(1, one: "%@ record", other: "%@ records", zh: "%@ 条", lang: .en) == "1 record")
  #expect(L10n.count(1_234, one: "%@ record", other: "%@ records", zh: "%@ 条", lang: .en) == "1,234 records")
  #expect(L10n.count(0, one: "%@ record", other: "%@ records", zh: "%@ 条", lang: .zh) == "0 条")
  #expect(ViewerFormat.duration(34_020, lang: .en) == "9 hr 27 min")
  #expect(ViewerFormat.duration(34_020, lang: .zh) == "9 小时 27 分")
  #expect(ViewerFormat.updated(now.addingTimeInterval(-360), now: now, lang: .en) == "Updated 6 min ago")
  #expect(ViewerFormat.updated(now, now: now, lang: .en) == "Just now")
  #expect(ViewerFormat.updated(now, now: now, lang: .zh) == "刚刚更新")
  #expect(L10n.speaker("我", lang: .en) == "Me")
  #expect(L10n.speaker("对方 2", lang: .en) == "Speaker 2")
  #expect(L10n.speaker("对方 2", lang: .zh) == "对方 2")
  #expect(L10n.speaker("其他人", lang: .en) == "Others")
  #expect(L10n.speaker("林老师", lang: .en) == "林老师")
  #expect(SampleNote.line(stamp: "4:45 PM", said: "去花园", lang: .en) == "4:45 PM, said: 去花园")
  #expect(RecordTitles.display("微信 · 温室 · 小叶", source: "mac.wechat", lang: .en) == "温室: 小叶")
}

@Test func widgetLanguageRoundTripsAndLegacySnapshotRemainsChinese() throws {
  let decoder = JSONDecoder()
  let old = try decoder.decode(WidgetSnapshot.self, from: Data(#"{"day":"2026-11-26","segments":[]}"#.utf8))
  #expect(old.language == nil)
  #expect(old.resolvedLanguage == .zh)
  for language in AppLanguage.allCases {
    let snapshot = WidgetSnapshot(day: "2026-11-26", language: language)
    let decoded = try decoder.decode(WidgetSnapshot.self, from: JSONEncoder().encode(snapshot))
    #expect(decoded == snapshot)
    #expect(decoded.resolvedLanguage == language)
  }
}

@Test func modelErrorTextLocalizesCodesAndPreservesFreeText() {
  #expect(ModelErrorText.plain("auth:401", lang: .zh) == "API key 没设置或无效；用账号登录的，请确认已登录。")
  #expect(ModelErrorText.plain("auth:401", lang: .en) == "Check your API key or sign in if you connect with an account.")
  #expect(ModelErrorText.plain("schema_mismatch", lang: .en) == ModelErrorText.plain("invalid_json", lang: .en))
  #expect(ModelErrorText.plain("unknown", lang: .en) == "An unexpected error occurred. Check your model settings.")
  #expect(ModelErrorText.plain("请求未完成。", lang: .en) == "请求未完成。")
}

struct ChineseUITrait: TestTrait, TestScoping {
  func provideScope(for test: Test, testCase: Test.Case?, performing function: @Sendable () async throws -> Void) async throws {
    try await AppLanguage.$scopedLanguage.withValue(.zh, operation: function)
  }
}
