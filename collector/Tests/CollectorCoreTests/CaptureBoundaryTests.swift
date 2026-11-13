import Foundation
import Testing
@testable import CollectorCore

@Test func textAreaTailDoesNotRetainCredentialTails() {
  #expect(Text.captureSuffix("说明 AKIA1234567890ABCDEF 后续内容", limit: 12) == " 后续内容")
  let key = "-----BEGIN PRIVATE KEY-----\n" + String(repeating: "AbCd0123\n", count: 100) + "-----END PRIVATE KEY-----\n后续内容"
  #expect(Text.captureSuffix(key, limit: 100) == "\n后续内容")
}

@Test func clipboardDoesNotKeepCredentialsCutAtBodyOrTitleBoundary() {
  let secret = "AKIA" + "A1B2C3D4E5F6G7H8"
  let body = String(repeating: "文", count: 19_990) + " " + secret
  let record = ClipboardPolicy.record(text: body, types: [], app: nil, time: Date(), device: "mac")!
  #expect(!record.body.contains(String(secret.prefix(9))))
  let title = String(repeating: "文", count: 70) + " " + secret
  let titled = ClipboardPolicy.record(text: title, types: [], app: nil, time: Date(), device: "mac")!
  #expect(!titled.title.contains(String(secret.prefix(8))))
  // 未截断的完整值继续交给入库拦截；不能误删整段正常文字。
  #expect(titled.body == title)
}

@Test func clipboardDropsPrivateKeyBlockWhenItsEndingIsPastTheLimit() {
  let text = "说明\n-----BEGIN PRIVATE KEY-----\n" + String(repeating: "AbCd0123456789+/\n", count: 1500) + "-----END PRIVATE KEY-----"
  let record = ClipboardPolicy.record(text: text, types: [], app: nil, time: Date(), device: "mac")!
  #expect(record.body.hasPrefix("说明\n"))
  #expect(!record.body.contains("AbCd0123456789"))
  #expect(record.body.count <= 20_010)
}


@Test func calendarNotesAndDisplayTitlesDoNotRetainPartialCredentials() {
  let secret = "AKIA" + "A1B2C3D4E5F6G7H8"
  let event = CalendarEventSnapshot(externalIdentifier: "synthetic", start: Date().addingTimeInterval(-20), end: Date().addingTimeInterval(-1), title: "会议", calendar: "合成", notes: String(repeating: "文", count: 1990) + " " + secret)
  #expect(!event.record(now: Date(), device: "mac")!.body.contains("AKIA"))
  #expect(!Text.clamp(String(repeating: "文", count: 190) + " " + secret, 200).contains("AKIA"))
  #expect(PluginImport.outcomeText(ok: false, exitStatus: 1, accepted: nil, elapsed: 0, failure: "permission").contains("无权读取"))
  #expect(!PluginImport.outcomeText(ok: false, exitStatus: 1, accepted: nil, elapsed: 0, failure: "synthetic-secret").contains("synthetic-secret"))
}
