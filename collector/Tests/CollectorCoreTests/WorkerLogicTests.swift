import Testing
import Foundation
@testable import CollectorCore

@Test func windowsAndAACPadding() {
  #expect(WorkerLogic.windows(count: 23999, segment: 0).isEmpty)
  #expect(WorkerLogic.windows(count: 72000, segment: 2).map(\.count) == [48000, 24000])
  #expect(WorkerLogic.windows(count: 71999, segment: 2).map(\.count) == [48000])
  #expect(WorkerLogic.trimPadding([Float](repeating: 0, count: 2112) + [1, 2, 3]) == [1, 2, 3])
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
