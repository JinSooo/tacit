import Foundation
import Testing
@testable import CollectorCore

private let sourceTime = Date(timeIntervalSince1970: 1_800_000_000)
private let syntheticHome = "/Users/synthetic"

private func file(_ name: String = "报告.pdf", directory: String = "Downloads", offset: Double = 0,
                  inode: UInt64 = 42, created: Date = sourceTime, fromURL: String? = nil) -> FileAppearance {
  FileAppearance(path: syntheticHome + "/" + directory + "/" + name, inode: inode, created: created,
                 observed: sourceTime.addingTimeInterval(offset), size: 8192, directory: directory, fromURL: fromURL)
}

@Test func filePathFilteringCoversSubdirectoriesAndSensitiveDirectories() {
  func allowed(_ path: String, regular: Bool = true) -> String? {
    FileSourcePolicy.directory(path: syntheticHome + "/" + path, home: syntheticHome, isRegularFile: regular)
  }
  #expect(allowed("Downloads/子目录/报告.PDF") == "Downloads")
  #expect(allowed("Desktop/文件.txt") == "Desktop")
  #expect(allowed("Documents/文件.txt") == "Documents")
  for path in ["Downloads/.secret", "Downloads/.hidden/file", "Desktop/.git/config", "Documents/node_modules/pkg/file.js",
               "Documents/.build/debug/file", "Downloads/unfinished.crdownload", "Downloads/a.download/file",
               "Downloads/a.PART", "Downloads/a.tmp", "Downloads/a.partial", "Downloads/a.temp",
               "Documents/com.apple.Passwords/data", "Desktop/1Password.opvault/data", "Documents/Bitwarden/data",
               "Documents/me.proton.pass.electron/vault", "Documents/Proton Pass/data", "Documents/LastPass.app/data",
               "Documents/Dashlane/data", "Downloads-copy/file", "Pictures/file", "Downloads/../../elsewhere/file"] {
    #expect(allowed(path) == nil, "应跳过：\(path)")
  }
  #expect(allowed("Downloads/目录", regular: false) == nil)
  #expect(allowed("Downloads/报告密码.txt") == "Downloads")
  #expect(FileSourcePolicy.shouldDescend(path: syntheticHome + "/Downloads", home: syntheticHome))
  #expect(FileSourcePolicy.shouldDescend(path: syntheticHome + "/Downloads/移入的目录/子目录", home: syntheticHome))
  for path in ["Documents/1Password.opvault", "Downloads/未完成.download", "Desktop/node_modules", "Desktop/.git",
               "Documents/com.apple.Passwords", "Desktop/Bitwarden", "../elsewhere"] {
    #expect(!FileSourcePolicy.shouldDescend(path: syntheticHome + "/" + path, home: syntheticHome))
  }
}

@Test func fileChangesIgnoreModificationAndDeletion() {
  #expect(!FileSourcePolicy.acceptsChange(created: false, moved: false, removed: false))
  #expect(!FileSourcePolicy.acceptsChange(created: false, moved: false, removed: true))
  #expect(FileSourcePolicy.acceptsChange(created: true, moved: false, removed: false))
  #expect(FileSourcePolicy.acceptsChange(created: false, moved: true, removed: false))
  #expect(FileSourcePolicy.directory(path: syntheticHome + "/Downloads/report.pdf.crdownload", home: syntheticHome, isRegularFile: true) == nil)
  #expect(FileSourcePolicy.directory(path: syntheticHome + "/Downloads/report.pdf", home: syntheticHome, isRegularFile: true) == "Downloads")
}

@Test func downloadURLRemovesQueryFragmentAndCredentials() {
  #expect(FileSourcePolicy.cleanURL("https://user:pass@example.test/a.pdf?token=synthetic#secret") == "https://example.test/a.pdf")
  #expect(FileSourcePolicy.cleanURL("file:///private/file") == nil)
  #expect(FileSourcePolicy.cleanURL("not a URL") == nil)
}

@Test func fileRecordAndStableIdentity() throws {
  let f = file(fromURL: "https://example.test/report?key=synthetic")
  let r = f.record(device: "test-mac")
  #expect(r.source == "mac.file" && r.kind == "event" && r.capture.method == "file")
  #expect(r.title == "下载 · 报告.pdf" && r.body == f.path)
  #expect(r.context?.extra?["dir"] == .string("Downloads"))
  #expect(r.context?.extra?["ext"] == .string("pdf"))
  #expect(r.context?.extra?["size"] == .integer(8192))
  #expect(r.context?.extra?["from_url"] == .string("https://example.test/report"))
  #expect(r.source_ref?.count == 64)
  #expect(f.sourceRef == file(offset: 100).sourceRef)
  #expect(f.sourceRef != file(inode: 43).sourceRef)
  #expect(f.sourceRef != file(created: sourceTime.addingTimeInterval(1)).sourceRef)
  #expect(f.sourceRef != file("another.pdf").sourceRef)
  #expect(file(directory: "Desktop").record(device: "mac").title == "新文件 · 报告.pdf")
  #expect(file("带\n换行.txt").record(device: "mac").title == "下载 · 带 换行.txt")
  let encoded = try JSONEncoder().encode(r)
  let json = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
  let extra = (json["context"] as! [String: Any])["extra"] as! [String: Any]
  #expect(extra["size"] as? Int == 8192)
  #expect(extra["ext"] as? String == "pdf")
  #expect(json["source_ref"] as? String == f.sourceRef)
  #expect(try JSONDecoder().decode(Record.self, from: encoded) == r)
}

@Test func fileWindowThresholdDeduplicationAndPause() {
  var buffer = FileAppearanceBuffer()
  #expect(buffer.drain(now: sourceTime, device: "mac").isEmpty)
  for i in 0..<20 { buffer.append(file("\(i).txt")) }
  buffer.append(file("0.txt"))
  #expect(buffer.drain(now: sourceTime.addingTimeInterval(59), device: "mac").isEmpty)
  let twenty = buffer.drain(now: sourceTime.addingTimeInterval(60), device: "mac")
  #expect(twenty.count == 20)
  buffer.append(file("0.txt", offset: 61))
  #expect(buffer.drain(now: sourceTime.addingTimeInterval(122), device: "mac").isEmpty)
  buffer.append(file("暂停前.txt", offset: 123))
  buffer.discardPending()
  #expect(buffer.drain(now: sourceTime.addingTimeInterval(200), device: "mac").isEmpty)
}

@Test func fileBurstCombinesOnlySameParentAndKeepsFirstTwentyNames() {
  var buffer = FileAppearanceBuffer()
  for i in 0..<21 { buffer.append(file("nested/\(i).txt", offset: Double(i))) }
  buffer.append(file("different/a.txt"))
  buffer.append(file("desktop.txt", directory: "Desktop"))
  let records = buffer.drain(now: sourceTime.addingTimeInterval(60), device: "mac")
  #expect(records.count == 3)
  let summary = records.first { $0.title == "新文件 · 21 个（Downloads）" }!
  #expect(summary.body.split(separator: "\n").count == 20)
  #expect(summary.body.hasPrefix("0.txt\n1.txt") && summary.body.hasSuffix("19.txt"))
  #expect(summary.source_ref?.count == 64 && summary.capture.method == "file")
  #expect(buffer.drain(now: sourceTime.addingTimeInterval(120), device: "mac").isEmpty)
}

private func event() -> CalendarEventSnapshot {
  CalendarEventSnapshot(externalIdentifier: "synthetic-event", start: sourceTime.addingTimeInterval(-3600),
    end: sourceTime.addingTimeInterval(-60), title: "合成评审", calendar: "测试日历", organizer: "组织者甲",
    location: "测试会议室", attendees: ["测试甲", "测试乙"], notes: "合成备注")
}

@Test func calendarFiltersEndedWindowAllDayDeclinedAndCanceled() {
  #expect(event().record(now: sourceTime, device: "mac") != nil)
  var e = event(); e.end = sourceTime.addingTimeInterval(1)
  #expect(e.record(now: sourceTime, device: "mac") == nil)
  e = event(); e.end = sourceTime
  #expect(e.record(now: sourceTime, device: "mac") != nil)
  e = event(); e.end = sourceTime.addingTimeInterval(-36 * 3600); e.start = e.end.addingTimeInterval(-3600)
  #expect(e.record(now: sourceTime, device: "mac") != nil)
  e.end = e.end.addingTimeInterval(-1)
  #expect(e.record(now: sourceTime, device: "mac") == nil)
  e = event(); e.allDay = true
  #expect(e.record(now: sourceTime, device: "mac") == nil)
  e = event(); e.declined = true
  #expect(e.record(now: sourceTime, device: "mac") == nil)
  e = event(); e.canceled = true
  #expect(e.record(now: sourceTime, device: "mac") == nil)
  e = event(); e.end = e.start
  #expect(e.record(now: sourceTime, device: "mac") == nil)
  e = event(); e.externalIdentifier = ""
  #expect(e.record(now: sourceTime, device: "mac") == nil)
}

@Test func calendarRecordContainsPeopleMetadataAndBoundedNotes() throws {
  var e = event(); e.notes = String(repeating: "文", count: 2100)
  let r = e.record(now: sourceTime, device: "mac")!
  #expect(r.kind == "span" && r.source == "mac.calendar" && r.capture.method == "api")
  #expect(r.title == "日程 · 合成评审" && r.context?.app == "com.apple.iCal")
  #expect(r.t_start == LocalTime.iso(e.start) && r.t_end == LocalTime.iso(e.end))
  #expect(r.people == ["测试甲", "测试乙"])
  #expect(r.context?.extra?["calendar"] == .string("测试日历"))
  #expect(r.context?.extra?["organizer"] == .string("组织者甲"))
  #expect(r.body == "地点：测试会议室\n参会人：测试甲、测试乙\n备注：" + String(repeating: "文", count: 2000))
  #expect(r.source_ref == "synthetic-event|" + LocalTime.iso(e.start, timeZone: TimeZone(secondsFromGMT: 0)!))
  let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(r)) as! [String: Any]
  #expect(json["people"] as? [String] == r.people)
  #expect(json["t_end"] as? String == LocalTime.iso(e.end))
}

@Test func calendarDeduplicatesRereadsButKeepsRecurrencesAndUnfinishedEvents() {
  var buffer = CalendarRecordBuffer()
  let e = event()
  #expect(buffer.records([e, e], now: sourceTime, device: "mac").count == 1)
  var changed = e; changed.title = "改名不会重写"
  #expect(buffer.records([changed], now: sourceTime, device: "mac").isEmpty)
  var recurrence = e; recurrence.start = e.start.addingTimeInterval(-86400); recurrence.end = e.end.addingTimeInterval(-86400)
  #expect(buffer.records([recurrence], now: sourceTime, device: "mac").count == 1)
  var future = e; future.externalIdentifier = "later"; future.end = sourceTime.addingTimeInterval(60)
  #expect(buffer.records([future], now: sourceTime, device: "mac").isEmpty)
  #expect(buffer.records([future], now: sourceTime.addingTimeInterval(120), device: "mac").count == 1)
}
