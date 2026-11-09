import Foundation
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

@Test func lanesGroupSources() {
  #expect(Lane.of("codex.session") == .agent)
  #expect(Lane.of("mac.git") == .terminal)
  #expect(Lane.of("mac.clipboard") == .other)
}

@Test func warmthHalvesEverySixHours() {
  let now = Date()
  #expect(abs(Warmth.of(now.addingTimeInterval(-6 * 3600), now: now) - 0.5) < 1e-9)
  #expect(Warmth.of(nil, now: now) == 0)
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
  #expect(ViewerFormat.compact(5 * 3600 + 28 * 60) == "5h 28m")
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
