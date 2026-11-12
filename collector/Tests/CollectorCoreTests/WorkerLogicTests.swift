import Testing
import Foundation
@testable import CollectorCore

@Test func meetingBleedRequiresTextCoverage() {
  func line(_ track: AudioTrack, _ start: String, _ end: String, _ text: String) -> TranscriptLine {
    TranscriptLine(segment: AudioSegment(file: "\(track.rawValue)-\(start).enc", track: track,
      start: AudioPolicy.date("2026-11-11T\(start)+08:00")!, end: AudioPolicy.date("2026-11-11T\(end)+08:00")!, dbfs: -20), local: "S1", text: text)
  }
  let question = line(.mic, "16:22:43", "16:22:55", "呃，这个chat指的是是图表是吗？图表对图表呃，那我们就先从phone开始，就先后开图表。")
  let questionSys = line(.sys, "16:22:45", "16:22:55", "那我们就先从洞开始，就先抛开口掉。")
  let analysis = line(.mic, "16:30:42", "16:30:57", "可能前期就是不管是项目还是产品，就是确认好，就是和客户去沟通，就是对确O我直接都说了嗯，就是需求分析对吧？嗯，呃总体设计")
  let analysisSys = line(.sys, "16:30:45", "16:30:55", "这些都说了，就是需求分析，对吧？")
  let echo = line(.mic, "16:34:30", "16:34:34", "有些我们可能需要在手机上进行操作。")
  // 系统声音早切段，末尾与 mic 相差一秒：仍在前后各三秒的范围内。
  let echoSys = line(.sys, "16:34:21", "16:34:29", "还有，有些我们可能需要在手机上进行操作。")
  for (mic, sys, hidden) in [(question, questionSys, false), (analysis, analysisSys, false), (echo, echoSys, true)] {
    let segments = [mic.segment, sys.segment]
    let candidates: Set<Int> = WorkerLogic.isBleed(mic: [1, 0.1], sys: [[1, 0]]) ? [0] : []
    #expect(candidates == [0])
    #expect(WorkerLogic.confirmedBleed(candidates, segments: segments, lines: [mic, sys], meeting: true).contains(0) == hidden)
    #expect(WorkerLogic.confirmedBleed(candidates, segments: segments, lines: [], meeting: false) == [0])
    // 会议不能因系统文字缺失而退回仅看声纹，也不能仅凭文字隐藏。
    #expect(WorkerLogic.confirmedBleed(candidates, segments: segments, lines: [mic], meeting: true).isEmpty)
    #expect(WorkerLogic.confirmedBleed([], segments: segments, lines: [mic, sys], meeting: true).isEmpty)
  }
  let before = line(.sys, "16:34:20", "16:34:28", "有些我们可能需要")
  let after = line(.sys, "16:34:36", "16:34:40", "在手机上进行操作。")
  #expect(WorkerLogic.confirmedBleed([0], segments: [echo.segment], lines: [after, echo, before], meeting: true) == [0])
  let distant = line(.sys, "16:33:00", "16:33:10", echo.text)
  #expect(WorkerLogic.confirmedBleed([0], segments: [echo.segment], lines: [echo, distant], meeting: true).isEmpty)
}

@Test func windowsAndAACPadding() {
  #expect(WorkerLogic.windows(count: 23999, segment: 0).isEmpty)
  #expect(WorkerLogic.windows(count: 72000, segment: 2).map(\.count) == [48000, 24000])
  #expect(WorkerLogic.windows(count: 71999, segment: 2).map(\.count) == [48000])
  #expect(WorkerLogic.trimPadding([Float](repeating: 0, count: 2112) + [1, 2, 3]) == [1, 2, 3])
}
// 用户报告：试听片段经常是远处、隔墙的细微声音，听不出是谁。
@Test func sampleClipPrefersLoudRunAndNormalizesVolume() {
  // 两段同样长：前一段轻声（0.01），后一段正常（0.3）。按最长选会选到前一段，按响度要选后一段。
  var samples = [Float](repeating: 0, count: 96000)
  for i in 0..<24000 { samples[i] = 0.01 }
  for i in 48000..<72000 { samples[i] = 0.3 }
  let runs = [0..<24000, 48000..<72000]
  let best = WorkerLogic.loudest(runs, in: samples, limit: 96000)
  #expect(best?.range == 48000..<72000)
  #expect((best?.dbfs ?? -100) > -20)

  // 响度相近时留更长的：1 dB 以内的差别不该让人声更短。
  var close = [Float](repeating: 0, count: 72000)
  for i in 0..<24000 { close[i] = 0.1 }
  for i in 48000..<72000 { close[i] = 0.105 }
  #expect(WorkerLogic.loudest([48_000..<72_000, 0..<24_000], in: close, limit: 96000)?.range == 48_000..<72_000)

  // 一段里前一半是静音时，滑窗要能找到后面有声的位置。
  var late = [Float](repeating: 0, count: 96000)
  for i in 64000..<80000 { late[i] = 0.2 }
  let found = WorkerLogic.loudest([0..<96000], in: late, limit: 32000)!.range
  #expect(found.lowerBound >= 48000 && found.upperBound >= 80000)

  #expect(WorkerLogic.runs([VoiceWindow(segment: 0, offset: 0, count: 48000), VoiceWindow(segment: 0, offset: 48000, count: 24000), VoiceWindow(segment: 0, offset: 96000, count: 24000)]) == [0..<72000, 96000..<120000])
  #expect(WorkerLogic.loudest([], in: samples, limit: 96000) == nil)
}

@Test func sampleClipNormalizationBoostsQuietSpeechWithoutClipping() {
  let quiet = WorkerLogic.normalize([0.02, -0.02, 0.01])
  // 峰值 0.02 要提到 0.7 需要 35 倍，超过 16 倍上限：放到 0.32 就停。
  #expect(abs(quiet[0] - 0.32) < 0.0001)
  #expect(quiet.allSatisfy { abs($0) <= 1 })
  // 最多放大 16 倍：极轻的声音不会被放大到爆音；已经够响的不动。
  let faint = WorkerLogic.normalize([0.001, -0.001])
  #expect(abs(faint[0] - 0.016) < 0.0001)
  #expect(WorkerLogic.normalize([0.8, -0.8]) == [0.8, -0.8])
  #expect(WorkerLogic.normalize([0, 0]) == [0, 0])
}

@Test func sampleNoteShowsWhenAndWhatWasSaid() {
  #expect(SampleNote.line(stamp: nil, said: "你好") == "")
  #expect(SampleNote.line(stamp: "11 月 9 日 02:00", said: nil) == "11 月 9 日 02:00 录到的")
  #expect(SampleNote.line(stamp: "11 月 9 日 02:00", said: "  这个方案下周再定 ") == "11 月 9 日 02:00，当时说：这个方案下周再定")
  #expect(SampleNote.line(stamp: "11 月 9 日 02:00", said: "   ") == "11 月 9 日 02:00 录到的")
}

@Test func clusteringAndMajorityAreStable() {
  var speakers: [LocalSpeaker] = []
  #expect(WorkerLogic.assign(vector: [2, 0], track: .mic, seconds: 3, speakers: &speakers) == "S1")
  #expect(WorkerLogic.assign(vector: [1, 1], track: .mic, seconds: 1.5, speakers: &speakers) == "S1")
  #expect(abs(speakers[0].seconds - 4.5) < 0.001)
  _ = WorkerLogic.assign(vector: [0.8, 0.6], track: .mic, seconds: 3, speakers: &speakers)
  let expected = WorkerLogic.unit([Float(3 + 1.5 / sqrt(2.0) + 2.4), Float(1.5 / sqrt(2.0) + 1.8)])
  #expect(WorkerLogic.cosine(speakers[0].centroid, expected) > 0.99999)
  #expect(WorkerLogic.assign(vector: [-1, 0], track: .mic, seconds: 3, speakers: &speakers) == "S2")
  #expect(WorkerLogic.assign(vector: [1, 0], track: .sys, seconds: 3, speakers: &speakers) == "S3")
  let votes = ["S2", "S1", "S2"].map { VoiceWindow(segment: 0, offset: 0, count: 48000, local: $0) }
  #expect(WorkerLogic.majority(votes) == "S2")
  #expect(WorkerLogic.majority(Array(votes.prefix(2))) == "S1")
}
@Test func gatingDoesNotTranscribeWithoutMeEvenInMeetings() {
  var speakers: [LocalSpeaker] = []
  _ = WorkerLogic.assign(vector: [1, 0], track: .mic, seconds: 3, speakers: &speakers)
  #expect(WorkerLogic.decision(speakers: speakers, voiceprint: nil, threshold: 0.49, meetings: ["meeting"]) == .waiting_me)
  #expect(WorkerLogic.decision(speakers: speakers, voiceprint: [1, 0], threshold: 0.49, meetings: []) == .done)
  #expect(WorkerLogic.decision(speakers: speakers, voiceprint: [0, 1], threshold: 0.49, meetings: ["meeting"]) == .done)
  #expect(WorkerLogic.decision(speakers: speakers, voiceprint: [0, 1], threshold: 0.49, meetings: []) == .skipped)
  speakers[0].track = .sys
  #expect(WorkerLogic.decision(speakers: speakers, voiceprint: [1, 0], threshold: 0.49, meetings: []) == .skipped)
}
@Test func echoRequiresBothOverlapAndSimilarText() {
  let start = Date(timeIntervalSince1970: 1794000000)
  func line(_ track: AudioTrack, _ offset: Double, _ text: String) -> TranscriptLine {
    TranscriptLine(segment: AudioSegment(file: "\(track.rawValue)-0001.enc", track: track, start: start.addingTimeInterval(offset), end: start.addingTimeInterval(offset + 2), dbfs: -20), local: "S1", text: text)
  }
  #expect(abs(WorkerLogic.similarity("你好世界啊", "你好世界呀") - 0.8) < 0.0001)
  #expect(WorkerLogic.similarity("", "") == 0)
  #expect(WorkerLogic.removeEcho([line(.mic, 0, "你好世界"), line(.sys, 1, "你好世界")]).count == 1)
  #expect(WorkerLogic.removeEcho([line(.mic, 0, "你好世界"), line(.sys, 2, "你好世界")]).count == 2)
  #expect(WorkerLogic.removeEcho([line(.mic, 0, "完全不同"), line(.sys, 1, "你好世界")]).count == 2)
}
@Test func historyShapeTitleBodyAndWav() throws {
  let start = Date(timeIntervalSince1970: 1794000000)
  var meta = AudioMetadata(start: start); meta.t_end = LocalTime.iso(start.addingTimeInterval(3))
  let segment = AudioSegment(file: "mic-0001.enc", track: .mic, start: start, end: start.addingTimeInterval(3), dbfs: -20)
  meta.segments = [segment]
  let record = WorkerLogic.record(meta: meta, device: "mac-test", lines: [TranscriptLine(segment: segment, local: "S1", text: "合成测试", confidence: 0.75)], labels: ["S1": String(repeating: "我", count: 300)], ids: ["S1": "speaker-test"], retention: 7)
  #expect((record["title"] as! String).unicodeScalars.count <= 200)
  #expect((record["body"] as! String).contains("：合成测试"))
  #expect((record["capture"] as! [String: Any])["confidence"] as? Double == 0.75)
  #expect(record["source_ref"] as? String == meta.id)
  #expect(record["people"] as? [String] == ["speaker-test"])
  #expect(AudioPolicy.validID(record["id"] as! String))
  #expect(throws: Never.self) { _ = try JSONSerialization.data(withJSONObject: record) }
  // 回归：同一人被拆成多个本地标签时，标题不重复列名字。
  let split = WorkerLogic.record(meta: meta, device: "mac-test", lines: ["S1", "S2", "S3"].map { TranscriptLine(segment: segment, local: $0, text: "合成") },
    labels: ["S1": "我", "S2": "同事", "S3": "我"], ids: [:], retention: 7)
  #expect((split["title"] as! String).hasSuffix(" · 我、同事"))
  let wav = WorkerLogic.wav([0, 1, -1]); #expect(wav.count == 50)
  #expect(String(data: wav.prefix(4), encoding: .utf8) == "RIFF")
}

// 回归：采集端每秒扫描全部对话的 meta.json，每个时间戳都新建格式器，音频队列被拖慢到丢帧停录（2026-11-10）。
@Test func audioPolicyDateParsingIsCheap() {
  let texts = ["2026-11-09T16:23:06+09:00", "2026-11-09T07:23:06.123Z"]
  let begin = Date()
  for i in 0..<20000 { #expect(AudioPolicy.date(texts[i % 2]) != nil) }
  #expect(Date().timeIntervalSince(begin) < 0.5)
  #expect(AudioPolicy.date("2026-11-09T07:23:06.123Z")!.timeIntervalSince1970.truncatingRemainder(dividingBy: 1) > 0.1)
  #expect(AudioPolicy.date("bad") == nil && AudioPolicy.date(nil) == nil && AudioPolicy.date("0001-01-01T09:18:59+09:18") != nil)
}

@Test func fastRFC3339MatchesFormatter() {
  let plain = ISO8601DateFormatter(), frac = ISO8601DateFormatter(); frac.formatOptions.insert(.withFractionalSeconds)
  for text in ["2026-11-09T16:23:06+09:00", "2026-11-09T07:23:06Z", "2026-11-09T07:23:06.123Z", "2024-02-29T23:59:59-05:30",
               "2000-03-01T00:00:00+00:00", "1970-01-01T00:00:00Z", "2100-12-31T12:00:00.5+14:00"] {
    let expected = plain.date(from: text) ?? frac.date(from: text)!
    #expect(abs(AudioPolicy.fastRFC3339(text)!.timeIntervalSince(expected)) < 0.001, "\(text)")
  }
  for text in ["2026-02-30T00:00:00Z", "2026-13-01T00:00:00Z", "2026-11-09 16:23:06Z", "2026-11-09T16:23:06", "2026-11-09T16:23:06+0900", "2026-11-09T16:23:06.Z", "2026-11-09T24:00:00Z", "0001-01-01T09:18:59+09:18"] {
    #expect(AudioPolicy.fastRFC3339(text) == nil, "\(text)")
  }
}

// 2026-11-11 实测：31 分钟两人对话被拆成 70 个"说话人"，界面上出现"对方 1""对方 2"……
@Test func consolidateMergesLongSpeakersAndAttachesShortOnes() {
  func s(_ local: String, _ v: [Float], _ seconds: Double, _ track: AudioTrack = .mic) -> LocalSpeaker {
    let u = WorkerLogic.unit(v)
    return LocalSpeaker(local: local, track: track, seconds: seconds, centroid: u, weightedSum: u.map { Double($0) * seconds })
  }
  var speakers = [
    s("S1", [1, 0, 0], 100), s("S2", [0.9, 0.3, 0], 40),      // 同一个人被拆成两个长的
    s("S3", [0, 1, 0], 80),                                    // 另一个人
    s("S4", [0.7, 0.5, 0], 3), s("S5", [0.1, 0.9, 0.3], 2),   // 短窗口，各像一个人
    s("S6", [0, 0, 1], 2),                                     // 谁都不像
    s("S7", [1, 0, 0], 50, .sys),                              // 别的一路不和 mic 合并
  ]
  let map = WorkerLogic.consolidate(speakers)
  #expect(map["S2"] == "S1" && map["S4"] == "S1" && map["S5"] == "S3" && map["S6"] == "S6" && map["S7"] == "S7")
  var windows = [VoiceWindow(segment: 0, offset: 0, count: 48000, local: "S2"), VoiceWindow(segment: 1, offset: 0, count: 48000, local: "S5")]
  WorkerLogic.apply(map, windows: &windows, speakers: &speakers)
  #expect(windows.map(\.local) == ["S1", "S3"])
  #expect(speakers.map(\.local) == ["S1", "S3", "S6", "S7"])
  #expect(abs(speakers[0].seconds - 143) < 0.001)
  // 全是短的（例如一段几秒的对话）时不动。
  #expect(WorkerLogic.consolidate([s("A", [1, 0], 2), s("B", [1, 0], 2)]) == ["A": "A", "B": "B"])
  #expect(WorkerLogic.nearest([0.2, 1, 0], track: .mic, speakers: speakers) == "S3")
  #expect(WorkerLogic.nearest([0, 0, -1], track: .mic, speakers: speakers) == nil)
}

// 2026-11-11 实测：放歌时麦克风录到的歌词进了对话记录。
@Test func bleedAndTextCoverageCatchSpeakerSound() {
  #expect(WorkerLogic.isBleed(mic: [1, 0.1], sys: [[0, 1], [1, 0]]))
  #expect(!WorkerLogic.isBleed(mic: [1, 0], sys: [[0.3, 1]]))
  #expect(!WorkerLogic.isBleed(mic: [1, 0], sys: []))
  #expect(WorkerLogic.coverage("走过了冬就到家", in: "走过了冬天，就到家了") == 1)
  #expect(WorkerLogic.coverage("完全不同的话", in: "走过了冬天") == 0)
  let start = Date(timeIntervalSince1970: 1794000000)
  func line(_ track: AudioTrack, _ offset: Double, _ length: Double, _ text: String) -> TranscriptLine {
    TranscriptLine(segment: AudioSegment(file: "\(track.rawValue)-\(Int(offset)).enc", track: track, start: start.addingTimeInterval(offset), end: start.addingTimeInterval(offset + length), dbfs: -20), local: "S1", text: text)
  }
  // 两路切段不同：mic 一句跨了 sys 两段，拼起来比。
  let kept = WorkerLogic.removeEcho([line(.mic, 0, 6, "走过了冬就到家"), line(.sys, 0, 3, "走过了冬天"), line(.sys, 3, 3, "就到家了"), line(.mic, 0, 1, "是")])
  #expect(kept.filter { $0.segment.track == .mic }.map(\.text) == ["是"])
}

// 2026-11-11 实测：放歌那段 78 句只去掉了 47 句，漏掉的都归在同一个说话人名下。
@Test func speakerMostlyFromLoudspeakerIsDroppedWhole() {
  let t = Date(timeIntervalSince1970: 1794000000)
  let segments = (0..<10).map { AudioSegment(file: "mic-\($0).enc", track: .mic, start: t.addingTimeInterval(Double($0) * 10), end: t.addingTimeInterval(Double($0) * 10 + 3), dbfs: -20) }
  // 0–5 是放歌的声音 S2，6–9 是我 S1。
  let windows = segments.indices.map { VoiceWindow(segment: $0, offset: 0, count: 48000, local: $0 < 6 ? "S2" : "S1") }
  #expect(WorkerLogic.expandBleed([0, 1, 2, 3], windows: windows, segments: segments) == Set(0...5))
  // 我的段里偶尔有一两句被误判，不会把我整个去掉。
  #expect(WorkerLogic.expandBleed([0, 1, 2, 3, 7], windows: windows, segments: segments) == Set(0...5).union([7]))
  // 只有两句命中，不够判断。
  #expect(WorkerLogic.expandBleed([0, 1], windows: windows, segments: segments) == [0, 1])
}
