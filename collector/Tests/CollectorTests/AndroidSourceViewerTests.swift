import CollectorCore
import Foundation
import Testing
@testable import Collector

@Test func androidSourcesHaveDistinctNamesOrderAndPhosphorIcons() {
  #expect(SourceInfo.name("android.audio") == "手机录音")
  #expect(SourceInfo.name("android.notification") == "手机聊天")
  #expect(SourceInfo.name("android.usage") == "手机应用")

  for source in ["android.audio", "android.notification", "android.usage"] {
    #expect(SourceInfo.order.contains(source))
    let symbol = SourceInfo.symbol(source)
    #expect(symbol != "circle-dashed")
    #expect(!PhosphorGlyphs.character(symbol).isEmpty, "缺少 Phosphor 图标映射：\(symbol)")
  }

  #expect(SourceInfo.symbol("android.audio") != SourceInfo.symbol("mac.audio"))
  #expect(SourceInfo.symbol("android.notification") != SourceInfo.symbol("mac.wechat"))
  #expect(SourceInfo.symbol("android.usage") != SourceInfo.symbol("mac.app"))
}

@MainActor @Test func androidConversationAndSegmentPresentationMatchRules() throws {
  let titled = ConversationRef(id: "c1", recordIds: ["c1"], startMs: 0, endMs: 60_000, title: "苗圃交接")
  let untitled = ConversationRef(id: "c2", recordIds: ["c2"], startMs: 0, endMs: 60_000, title: nil)
  #expect(ConversationText.title(titled, source: "android.audio") == "手机录音：苗圃交接")
  #expect(ConversationText.title(untitled, source: "android.audio") == "手机录音")
  #expect(ConversationText.title(titled, source: "mac.audio") == "对话：苗圃交接")
  #expect(ConversationText.title(untitled, source: "mac.audio") == "对话")

  let phoneApp = HistorySegment.App(app: "org.example.garden", source: "android.usage", records: 1, seconds: 120)
  #expect(SegmentText.appName(phoneApp) == "手机应用")

  let decoder = HubJSON.decoder()
  let audio = try decoder.decode(HistoryRecord.self, from: Data("""
    {"id":"r1","device":"android-demo","source":"android.audio","kind":"span",
     "t_start":"2026-11-22T10:00:00+09:00","t_end":"2026-11-22T10:05:00+09:00","title":"对话记录"}
    """.utf8))
  let chat = try decoder.decode(HistoryRecord.self, from: Data("""
    {"id":"r2","device":"android-demo","source":"android.notification","kind":"event",
     "t_start":"2026-11-22T10:02:00+09:00","title":"温室值班群"}
    """.utf8))
  let segment = HistorySegment(id: "a:r1", kind: "app", startMs: 0, endMs: 300_000, thread: nil,
                               apps: [.init(app: nil, source: "android.audio", records: 1, seconds: 300)],
                               activeSeconds: 300, recordIds: ["r1", "r2"], privateCount: 0)
  let block = SegmentBlock(segment: segment, records: [audio, chat])
  #expect(SegmentText.title(block) == "手机录音")
  #expect(SegmentText.windows(block) == "温室值班群")
}
