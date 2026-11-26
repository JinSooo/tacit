import Foundation
import Testing
@testable import CollectorCore

@Test func settingsLanguageOptionsKeepTheirNativeNames() {
  for language in AppLanguage.allCases {
    #expect(L10n.Settings.languageOption(.zh, lang: language) == "中文")
    #expect(L10n.Settings.languageOption(.en, lang: language) == "English")
  }
  #expect(L10n.Settings.languageOption(.system, lang: .zh) == "跟随系统")
  #expect(L10n.Settings.languageOption(.system, lang: .en) == "Follow system")
  AppLanguage.$scopedLanguage.withValue(.zh) {
    #expect(L10n.Settings.language == "语言")
    #expect(L10n.Settings.displayLanguage == "显示语言")
  }
  AppLanguage.$scopedLanguage.withValue(.en) {
    #expect(L10n.Settings.language == "Language")
    #expect(L10n.Settings.displayLanguage == "Display language")
  }
}

@Test(arguments: AppLanguage.allCases)
func audioRetentionUsesTheSameValuesInBothLanguages(_ language: AppLanguage) {
  AppLanguage.$scopedLanguage.withValue(language) {
    #expect(L10n.Settings.audioRetentionValue(keepForever: true, days: 7) == 0)
    #expect(L10n.Settings.audioRetentionValue(keepForever: false, days: 17) == 17)
    #expect(L10n.Settings.audioRetentionValue(keepForever: false, days: 0) == nil)
    #expect(L10n.Settings.audioRetentionValue(keepForever: false, days: 366) == nil)
    #expect(L10n.Settings.neverClearAutomatically == (language == .zh ? "不自动清除" : "Never clear automatically"))
    #expect(L10n.Settings.retentionUnit(1) == (language == .zh ? "天" : "day"))
    #expect(L10n.Settings.retentionUnit(17) == (language == .zh ? "天" : "days"))
  }
}

@Test func modelFailureUsesPlainLanguageInBothSettingsLocales() {
  let expected: [(AppLanguage, String)] = [
    (.zh, "模型返回的内容不合格式，可以换个模型试试。"),
    (.en, "The model returned an unexpected format. Try a different model."),
  ]
  for (language, message) in expected {
    AppLanguage.$scopedLanguage.withValue(language) {
      #expect(L10n.Settings.modelFailure("schema_mismatch", fallback: "Fallback") == message)
    }
  }
}

@Test func settingsEnglishLocalizesStatusWithoutTranslatingChatNames() {
  AppLanguage.$scopedLanguage.withValue(.en) {
    #expect(L10n.Settings.sourceStatus("“研发讨论”新增 1 条", source: "wechat", succeeded: true) == "1 new message in “研发讨论”")
    #expect(L10n.Settings.sourceStatus("“研发讨论”新增 12 条", source: "wechat", succeeded: true) == "12 new messages in “研发讨论”")
    #expect(L10n.Settings.recordCount(1) == "1 record")
    #expect(L10n.Settings.recordCount(1234) == "1,234 records")
  }
}

@Test func relaySettingsUseEnglishCountsAndKeepChineseFormatting() throws {
  let settings = try HubJSON.decoder().decode(RelaySettings.self, from: Data("""
    {
      "mode": "custom",
      "connected": false,
      "unprocessable": 0,
      "devices": [{"device": "phone-test", "pending": 1}],
      "retiring": [],
      "usage": {"day": "2026-11-26", "requests": 1234, "by_kind": {}}
    }
    """.utf8))

  AppLanguage.$scopedLanguage.withValue(.en) {
    #expect(L10n.Settings.relayPending(settings) == "1 item")
    #expect(L10n.Settings.relayUsage(settings)?.text == "1,234 requests")
    #expect(L10n.Settings.relayConnection(settings) == "Can't reach the mailbox. Check the address and your network.")
  }
  AppLanguage.$scopedLanguage.withValue(.zh) {
    #expect(L10n.Settings.relayPending(settings) == RelaySettingsText.pending(settings))
    #expect(L10n.Settings.relayUsage(settings)?.text == RelaySettingsText.usage(settings)?.text)
    #expect(L10n.Settings.relayConnection(settings) == RelaySettingsText.connection(settings))
  }
}
