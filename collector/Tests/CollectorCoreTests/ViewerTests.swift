import Foundation
import CoreText
import Testing
@testable import CollectorCore

private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
  try HubJSON.decoder().decode(T.self, from: Data(json.utf8))
}

private func record(_ id: String, _ source: String, _ title: String, _ start: String, _ end: String? = nil) throws -> HistoryRecord {
  let endField = end.map { #","t_end":"\#($0)""# } ?? ""
  return try decode(HistoryRecord.self, #"{"id":"\#(id)","device":"mac","source":"\#(source)","kind":"\#(end == nil ? "event" : "span")","t_start":"\#(start)"\#(endField),"title":"\#(title)"}"#)
}

@Test func parsesBothHubTimeFormats() {
  // 记录用带时区偏移的秒级时间，审计和更新时间用带毫秒的 UTC。
  let a = ViewerTime.parse("2026-11-09T12:20:55+09:00")
  let b = ViewerTime.parse("2026-11-09T03:20:55.000Z")
  #expect(a != nil && a == b)
  #expect(ViewerTime.parse("昨天") == nil)
}

@Test func dayQueryCoversWholeLocalDayInclusive() {
  var cal = Calendar(identifier: .gregorian)
  cal.timeZone = TimeZone(identifier: "Asia/Tokyo")!
  let day = cal.date(from: DateComponents(year: 2026, month: 11, day: 9, hour: 15))!
  let q = ViewerTime.dayQuery(day, calendar: cal)
  #expect(q.from == "2026-11-09T00:00:00.000+09:00")
  // hub 的 to 是闭区间，必须停在次日零点之前。
  #expect(q.to == "2026-11-09T23:59:59.999+09:00")
}

@Test func decodesHubRecordWithNestedContextAndMixedBooleans() throws {
  let r = try decode(HistoryRecord.self, """
    {"id":"01M6Z55ER9BPCTVCYA6ZANFBVM","schema":1,"device":"mac","source":"mac.git","kind":"event",
     "t_start":"2026-11-09T12:20:55+09:00","t_end":null,"title":"commit","capture":{"method":"db"},
     "context":{"repo":"/r","extra":{"hash":"aa1d4b8","files":5,"merged":true}},"redactions":0}
    """)
  #expect(r.contextText("repo") == "/r")
  guard case .object(let extra)? = r.context?["extra"] else { Issue.record("extra 不是对象"); return }
  #expect(extra["files"]?.text == "5")
  #expect(extra["merged"]?.text == "是")
  #expect(!r.isSpan && r.end == nil)

  // hub 的 confirmed 有时是 1，有时是 true。
  let p = try decode([Project].self, #"[{"id":"a","name":"x","confirmed":1,"thread_count":2},{"id":"b","name":"y","confirmed":false}]"#)
  #expect(p[0].confirmed.value && !p[1].confirmed.value)
  #expect(p[0].threadCount == 2)
}

@Test func recordDetailShowsLatestCorrection() throws {
  let d = try decode(RecordDetail.self, """
    {"id":"A","device":"mac","source":"mac.screen","kind":"event","t_start":"2026-11-09T10:00:00+09:00","title":"t","body":"原文",
     "corrections":[
       {"id":"B","device":"mac","source":"manual.correction","kind":"event","t_start":"2026-11-09T11:00:00+09:00","title":"t","body":"一改"},
       {"id":"C","device":"mac","source":"manual.correction","kind":"event","t_start":"2026-11-09T12:00:00+09:00","title":"t","body":"二改"}]}
    """)
  #expect(d.record.body == "原文")
  #expect(d.current.body == "二改")
}

@Test func collapsesOnlyAdjacentSameTitleWithinGap() throws {
  // 新的在前：两段相同标题、间隔 2 分钟合并；隔 10 分钟的同标题不并；换了标题就断开。
  let rows = try [
    record("4", "mac.screen", "WeChat", "2026-11-09T12:20:00+09:00", "2026-11-09T12:21:00+09:00"),
    record("3", "mac.screen", "WeChat", "2026-11-09T12:16:00+09:00", "2026-11-09T12:18:00+09:00"),
    record("2", "mac.screen", "WeChat", "2026-11-09T12:00:00+09:00", "2026-11-09T12:06:00+09:00"),
    record("1", "mac.browser", "WeChat", "2026-11-09T11:59:00+09:00"),
  ]
  let runs = RecordRuns.collapse(rows)
  #expect(runs.map { $0.records.map(\.id) } == [["4", "3"], ["2"], ["1"]])
  #expect(runs[0].seconds == 180)
  #expect(runs[0].start == rows[1].start)
}

// 用户报告：一场面试被静音切成五条"对话：未知说话人、我、说话人 OK…"，中间还夹着别的记录。
@Test func conversationRecordsCollapseIntoOneRowEvenWhenInterleaved() throws {
  let rows = try [
    record("a3", "mac.audio", "对话 · 11:22–11:44 · 说话人 MY、我", "2026-11-11T11:22:00+09:00", "2026-11-11T11:44:00+09:00"),
    record("s2", "mac.screen", "ChatGPT", "2026-11-11T11:18:00+09:00", "2026-11-11T11:20:00+09:00"),
    record("a2", "mac.audio", "对话 · 10:41–11:10 · 我", "2026-11-11T10:41:00+09:00", "2026-11-11T11:10:00+09:00"),
    record("a1", "mac.audio", "对话 · 10:26–10:34 · 我", "2026-11-11T10:26:00+09:00", "2026-11-11T10:34:00+09:00"),
    record("x1", "mac.audio", "对话 · 09:00–09:05 · 我", "2026-11-11T09:00:00+09:00", "2026-11-11T09:05:00+09:00"),
  ]
  let c = ConversationRef(id: "a1", recordIds: ["a1", "a2", "a3"], startMs: 0, endMs: 0, title: "中铁二十三局三公司线上面试")
  let runs = RecordRuns.collapse(rows, conversations: [c])
  #expect(runs.map { $0.records.map(\.id) } == [["a3", "a2", "a1"], ["s2"], ["x1"]])
  #expect(runs[0].conversation == c && runs[1].conversation == nil)
  #expect(runs[0].start == rows[3].start && runs[0].end == rows[0].end)
}

// 用户报告：标题用"·"连接（"Zen · Google Search""C童文科 · C童文科"），对话标题里一串说话人编号。
@Test func recordTitlesUseColonsInsteadOfMiddleDots() {
  #expect(RecordTitles.display("Zen · Google Search", source: "mac.screen") == "Zen：Google Search")
  #expect(RecordTitles.display("Zen · Google Search", source: "mac.screen", appShown: true) == "Google Search")
  #expect(RecordTitles.display("Claude · Claude", source: "mac.screen") == "Claude")
  #expect(RecordTitles.display("微信 · C童文科 · 我", source: "mac.wechat") == "C童文科：我")
  #expect(RecordTitles.display("复制 · 部门定位与规划", source: "mac.clipboard") == "复制：部门定位与规划")
  #expect(RecordTitles.display("对话 · 16:46–17:17 · 未知说话人、说话人 OK", source: "mac.audio") == "对话")
  #expect(RecordTitles.display("   ", source: "mac.screen") == nil)
}

@Test func lanesGroupSources() {
  #expect(Lane.of("codex.session") == .agent)
  #expect(Lane.of("mac.git") == .terminal)
  #expect(Lane.of("mac.clipboard") == .other)
}

/// 回归：日记章节时间有交叉（真实数据 10:07–10:49、10:25–11:22、11:01–12:01），条带上的章节文字叠在一起。
/// 每段只能占到下一段开始为止；太窄的只画色块不写字，比 1pt 还窄的不画。
@Test func chapterStripNeverOverlaps() {
  // 一像素一分钟，从 10:00 起算。
  let spans: [(lo: Double, hi: Double)] = [(25, 82), (7, 49), (61, 121), (120, 121), (121, 122), (200, 260), (200, 230)]
  let slots = ChapterStrip.layout(spans)
  for (a, b) in zip(slots, slots.dropFirst()) { #expect(a.hi <= b.lo) }
  #expect(slots.map(\.index) == [1, 0, 2, 3, 4, 5])
  #expect(slots[0] == ChapterStrip.Slot(index: 1, lo: 7, hi: 25, label: nil))  // 被后一段截到 10:25，放不下字
  #expect(slots[2] == ChapterStrip.Slot(index: 2, lo: 61, hi: 120, label: 47))
  // 相邻的一分钟章节只剩色块。
  #expect(slots[3].label == nil && slots[4].label == nil && slots[4].lo == 121)
  // 同一时刻开始的两段，短的让位给长的。
  #expect(slots[5] == ChapterStrip.Slot(index: 5, lo: 200, hi: 260, label: 48))
  // 一天 10 段、每段 6pt 宽：都画得出色块，没有一段写字。
  let tight = (0..<10).map { i in (lo: Double(i * 6), hi: Double(i * 6 + 6)) }
  #expect(ChapterStrip.layout(tight).count == 10)
  #expect(ChapterStrip.layout(tight).allSatisfy { $0.label == nil })
}

@Test func waveformPeaksFromWav() {
  // 16 位单声道：前半段静音，后半段满幅。
  var pcm = Data()
  for i in 0..<1600 { var v = Int16(i < 800 ? 0 : 16000).littleEndian; pcm.append(Data(bytes: &v, count: 2)) }
  func le32(_ v: Int) -> Data { var x = UInt32(v).littleEndian; return Data(bytes: &x, count: 4) }
  func le16(_ v: Int) -> Data { var x = UInt16(v).littleEndian; return Data(bytes: &x, count: 2) }
  var wav = Data("RIFF".utf8) + le32(36 + pcm.count) + Data("WAVEfmt ".utf8)
  wav += le32(16) + le16(1) + le16(1) + le32(16000) + le32(32000) + le16(2) + le16(16)
  wav += Data("data".utf8) + le32(pcm.count) + pcm
  let peaks = Waveform.peaks(wav: wav, buckets: 4)
  #expect(peaks == [0, 0, 1, 1])
  #expect(Waveform.peaks(wav: Data("not a wav file at all, definitely not".utf8), buckets: 4).isEmpty)
}

@Test func formatsDurations() {
  #expect(ViewerFormat.compact(5 * 3600 + 28 * 60) == "5 小时 28 分")
  #expect(ViewerFormat.compact(2 * 3600) == "2 小时")
  #expect(ViewerFormat.compact(42 * 60 + 5) == "42 分")
  #expect(ViewerFormat.compact(30) == "30 秒")
  #expect(ViewerFormat.duration(59) == "59 秒")
  #expect(ViewerFormat.duration(3600) == "1 小时")
}

@Test func searchSnippetCentersOnMatch() {
  let body = "第一行\n" + String(repeating: "甲", count: 50) + "梦诚大屏接口" + String(repeating: "乙", count: 50)
  let s = SearchSnippet.make(body, query: "梦诚", radius: 4)
  #expect(s == SearchSnippet(before: "…甲甲甲甲", match: "梦诚", after: "大屏接口…"))
  // 不区分大小写，保留原文写法；换行压成空格；没命中返回 nil。
  #expect(SearchSnippet.make("Open\nCodex now", query: "codex", radius: 20) == SearchSnippet(before: "Open ", match: "Codex", after: " now"))
  #expect(SearchSnippet.make("abc", query: "z") == nil)
}

@Test func segmentsJoinRecordsAndKeepStragglers() throws {
  // hub 的活动段：线程段带项目名，"private" 字段映射到 privateCount。
  let json = #"""
  {"segments":[
    {"id":"a:3","kind":"app","start_ms":1794106920000,"end_ms":1794107040000,"thread":null,
     "apps":[{"app":"com.synthetic.chat","source":"mac.screen","records":1,"seconds":120}],"active_seconds":120,"record_ids":["3"],"private":1},
    {"id":"t:1","kind":"thread","start_ms":1794106800000,"end_ms":1794108600000,
     "thread":{"id":"ta","title":"合成线程","brief":"在写合成功能","status":"active","domain":null,"project_id":"p","project_name":"合成项目"},
     "apps":[{"app":null,"source":"codex.session","records":2,"seconds":1500}],"active_seconds":1500,"record_ids":["1","2"],"private":0}
  ]}
  """#
  struct R: Decodable { let segments: [HistorySegment] }
  let segments = try HubJSON.decoder().decode(R.self, from: Data(json.utf8)).segments
  #expect(segments[0].privateCount == 1)
  #expect(segments[1].thread?.projectName == "合成项目")
  #expect(segments[1].apps[0].app == nil)
  #expect(segments[1].start == Date(timeIntervalSince1970: 1_794_106_800))

  let rows = [
    try record("1", "codex.session", "合成会话", "2026-11-08T11:00:00+08:00", "2026-11-08T11:20:00+08:00"),
    try record("2", "codex.session", "合成会话", "2026-11-08T11:25:00+08:00", "2026-11-08T11:30:00+08:00"),
    try record("3", "mac.screen", "Chat · 合成群", "2026-11-08T11:02:00+08:00", "2026-11-08T11:04:00+08:00"),
    // 两次读取之间新到的记录，不在任何段里。
    try record("4", "mac.shell", "合成命令", "2026-11-08T12:00:00+08:00"),
  ]
  let blocks = SegmentBlocks.join(segments, records: rows)
  #expect(blocks.map(\.id) == ["r:4", "a:3", "t:1"])
  #expect(blocks[2].records.map(\.id) == ["2", "1"])
  #expect(blocks[0].segment.kind == "app" && blocks[0].segment.recordIds == ["4"])
  // 筛选后段里只剩可见记录，一条不剩的段不显示。
  let filtered = SegmentBlocks.join(segments, records: rows, visible: ["1", "3"])
  #expect(filtered.map(\.id) == ["a:3", "t:1"])
  #expect(filtered[1].records.map(\.id) == ["1"])
}

@Test func minorSegmentsFoldOnlyInRunsOfThree() {
  func block(_ id: String, thread: Bool = false, records: Int = 1, seconds: Double = 10) -> SegmentBlock {
    let t = thread ? try! HubJSON.decoder().decode(HistorySegment.ThreadRef.self, from: Data(#"{"id":"t","title":"合成线程"}"#.utf8)) : nil
    let s = HistorySegment(id: id, kind: thread ? "thread" : "app", startMs: 0, endMs: 0, thread: t, apps: [], activeSeconds: seconds, recordIds: [], privateCount: 0)
    let rs = (0..<records).map { i in try! record("\(id)-\(i)", "mac.screen", "合成", "2026-11-08T11:00:00+08:00") }
    return SegmentBlock(segment: s, records: rs)
  }
  // 线程段、记录多或时长长的都不算零碎。
  #expect(!SegmentFold.isMinor(block("t", thread: true)))
  #expect(!SegmentFold.isMinor(block("many", records: 3)))
  #expect(!SegmentFold.isMinor(block("long", seconds: 300)))
  let items = SegmentFold.fold([block("a"), block("b"), block("c"), block("T", thread: true), block("d"), block("e"), block("U", thread: true)])
  #expect(items.map(\.id) == ["minor:a", "T", "d", "e", "U"])
}

/// 回归：界面声明 zh-Hans 后，FileManager.displayName 把 WeChat 显示成"微信"，和记录标题、搜索词对不上。
/// 显示名必须按用户的系统语言取。
@Test func appNameFollowsSystemLanguageNotViewerLanguage() throws {
  let app = FileManager.default.temporaryDirectory.appendingPathComponent("ra-appname-\(UUID().uuidString)/WeChat.app")
  let res = app.appendingPathComponent("Contents/Resources")
  for (lang, name) in [("en", "WeChat"), ("zh-Hans", "微信")] {
    let dir = res.appendingPathComponent("\(lang).lproj")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try "\"CFBundleDisplayName\" = \"\(name)\";\n".write(to: dir.appendingPathComponent("InfoPlist.strings"), atomically: true, encoding: .utf8)
  }
  let plist = #"<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict><key>CFBundleIdentifier</key><string>dev.test.wechat</string><key>CFBundleName</key><string>Weixin</string></dict></plist>"#
  try plist.write(to: app.appendingPathComponent("Contents/Info.plist"), atomically: true, encoding: .utf8)
  defer { try? FileManager.default.removeItem(at: app.deletingLastPathComponent()) }

  #expect(AppNames.systemLanguageName(app, preferences: ["en-US"]) == "WeChat")
  #expect(AppNames.systemLanguageName(app, preferences: ["zh-Hans-CN", "en"]) == "微信")
  #expect(AppNames.systemLanguageName(app.deletingLastPathComponent().appendingPathComponent("Missing.app"), preferences: ["en"]) == "Missing")
}

/// 回归：较新的系统应用（查找、语音备忘录）的名字只在 InfoPlist.loctable 里，Info.plist 里是 "FindMy"。
@Test func appNameReadsLoctable() throws {
  let app = FileManager.default.temporaryDirectory.appendingPathComponent("ra-appname-\(UUID().uuidString)/FindMy.app")
  let res = app.appendingPathComponent("Contents/Resources")
  try FileManager.default.createDirectory(at: res, withIntermediateDirectories: true)
  let table: NSDictionary = ["en": ["CFBundleDisplayName": "Find My"], "zh_CN": ["CFBundleDisplayName": "查找"]]
  try PropertyListSerialization.data(fromPropertyList: table, format: .binary, options: 0).write(to: res.appendingPathComponent("InfoPlist.loctable"))
  let plist = #"<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict><key>CFBundleIdentifier</key><string>dev.test.findmy</string><key>CFBundleName</key><string>FindMy</string></dict></plist>"#
  try plist.write(to: app.appendingPathComponent("Contents/Info.plist"), atomically: true, encoding: .utf8)
  defer { try? FileManager.default.removeItem(at: app.deletingLastPathComponent()) }

  #expect(AppNames.systemLanguageName(app, preferences: ["en-US"]) == "Find My")
  #expect(AppNames.systemLanguageName(app, preferences: ["zh-Hans-CN"]) == "查找")
}

@Test func phosphorTableHasUniqueNamesInPrivateUseArea() {
  let names = PhosphorGlyphs.table.map(\.name)
  #expect(Set(names).count == names.count)
  for g in PhosphorGlyphs.table { #expect((0xE000...0xF8FF).contains(g.code), "\(g.name)") }
  #expect(PhosphorGlyphs.character("check").unicodeScalars.first?.value == 0xE182)
  #expect(PhosphorGlyphs.character("no-such-icon").isEmpty)
}

// 回归：图标不居中（2026-11-10 用户报告）。PhIcon 曾把字形下移 0.06em；图标现在画成 size × size 的图片，
// 路径来自 PhosphorGlyphs.path，正圆的 record 墨迹必须正好在方框中心。
// 工具栏里整体偏上的另一半原因是构建记错 SDK 版本，由 build.sh 的检查兜住。
@Test func phosphorGlyphPathIsCenteredInItsBox() throws {
  let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../Resources/Phosphor").standardized
  for file in ["Phosphor.ttf", "Phosphor-Fill.ttf"] {
    let data = try Data(contentsOf: dir.appendingPathComponent(file))
    let descriptor = try #require(CTFontManagerCreateFontDescriptorFromData(data as CFData))
    let font = CTFontCreateWithFontDescriptor(descriptor, 100, nil)
    let ink = try #require(PhosphorGlyphs.path("record", font: font)).boundingBoxOfPath
    #expect(abs(ink.midY - 50) < 0.5, "\(file)：墨迹中心 y=\(ink.midY)")
    #expect(abs(ink.midX - 50) < 0.5, "\(file)：墨迹中心 x=\(ink.midX)")
    #expect(PhosphorGlyphs.path("no-such-icon", font: font) == nil)
  }
}

// 回归：launchd 拉起采集端的同时又从访达打开，出现两个采集端同时录音（2026-11-10 实测发现）。
@Test func secondCollectorInstanceSeesLockHeld() throws {
  let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ra-lock-\(UUID().uuidString)")
  try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: dir) }
  let path = dir.appendingPathComponent("collector.lock").path
  var first: InstanceLock?
  if case .acquired(let l) = InstanceLock.acquire(path: path) { first = l }
  #expect(first != nil)
  if case .held = InstanceLock.acquire(path: path) {} else { Issue.record("第二次获取应当返回 held") }
  first = nil
  if case .acquired = InstanceLock.acquire(path: path) {} else { Issue.record("释放后应当能再次获取") }
  #expect(InstanceLockUnavailableCheck.ok(dir.appendingPathComponent("missing/collector.lock").path))
}

private enum InstanceLockUnavailableCheck {
  static func ok(_ path: String) -> Bool { if case .unavailable = InstanceLock.acquire(path: path) { return true }; return false }
}
