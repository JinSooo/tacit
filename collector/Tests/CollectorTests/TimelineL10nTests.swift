import Foundation
import XCTest
@testable import Collector
@testable import CollectorCore

final class TimelineL10nTests: XCTestCase {
  func testTimelineGlossaryAndCounts() {
    AppLanguage.$scopedLanguage.withValue(.en) {
      XCTAssertEqual(L10n.activityCount(1), "1 activity")
      XCTAssertEqual(L10n.activityCount(1_234), "1,234 activities")
      XCTAssertEqual(L10n.basedOnRecordCount(1), "Based on 1 record")
      XCTAssertEqual(L10n.timelineCutoff("12:45 PM", hasDrafts: true, failed: false), "Summarized up to 12:45 PM")
    }
    AppLanguage.$scopedLanguage.withValue(.zh) {
      XCTAssertEqual(L10n.activityCount(1_234), "1,234 段活动")
      XCTAssertEqual(L10n.timelineCutoff("12:45", hasDrafts: false, failed: true), "内容截至 12:45，最近一次整理失败")
    }
  }

  func testConversationDraftMarkerAndLegacyTitle() throws {
    let data = Data("""
      {"date":"2026-11-26","drafts":[
        {"id":"a","title":"Generic title","title_kind":"conversation","excerpt":"Hello","t_start":"12:00","t_end":"12:01","active_seconds":60,"sources":[],"apps":[],"record_ids":[]},
        {"id":"b","title":"一场对话","excerpt":"你好","t_start":"12:00","t_end":"12:01","active_seconds":60,"sources":[],"apps":[],"record_ids":[]},
        {"id":"c","title":"Team check-in","excerpt":"Notes","t_start":"12:00","t_end":"12:01","active_seconds":60,"sources":[],"apps":[],"record_ids":[]}
      ]}
      """.utf8)
    let drafts = try XCTUnwrap(HubAPI.decodeDiary(data).drafts)
    XCTAssertEqual(drafts.map { L10n.draftTitle($0.title, lang: .en) }, ["Conversation", "Conversation", "Team check-in"])
    XCTAssertEqual(drafts.map { L10n.draftTitle($0.title, lang: .zh) }, ["一场对话", "一场对话", "Team check-in"])
  }

  func testTranscriptLocalizesOnlyCanonicalSpeakerPrefixes() {
    let original = """
      [12:45:00] 我：原话中的“对方 1”不变
      [12:45:01] 对方 2：😀 内容
      [12:45:02] 小明：你好
      对方3: Hi
      其他人：继续
      [我] 字幕
      [AI] 回复
      正文里的 [我] 不变
      """
    XCTAssertEqual(L10n.transcript(original, lang: .zh), original)
    XCTAssertEqual(L10n.transcript(original, lang: .en), """
      [12:45:00] Me：原话中的“对方 1”不变
      [12:45:01] Speaker 2：😀 内容
      [12:45:02] 小明：你好
      Speaker 3: Hi
      Others：继续
      [Me] 字幕
      [AI] 回复
      正文里的 [我] 不变
      """)
  }

  @MainActor func testOriginalConversationCopyKeepsStoredSpeakerTokens() throws {
    let data = Data("""
      {"id":"conversation","record_ids":["a","b"],"start":"2026-11-26T12:45:00+08:00","end":"2026-11-26T12:46:00+08:00",
       "state":"ready","points":[],"turns":[{"at":"2026-11-26T12:45:00+08:00","speaker":"Me","text":"Edited display"}],
       "records":[{"id":"a","t_start":"2026-11-26T12:45:00+08:00","body":"[12:45:00] 我：原话"},{"id":"b","t_start":"2026-11-26T12:45:01+08:00","body":"对方 1：原话"}]}
      """.utf8)
    let conversation = try HubJSON.decoder().decode(ConversationDetail.self, from: data)
    XCTAssertEqual(ConversationBody.originalTranscript(conversation), "[12:45:00] 我：原话\n对方 1：原话")
  }

}
