import Foundation
import Testing
import CryptoKit
import CollectorCore
@testable import AudioStore

@Test func metadataAndSpeakerCacheMigrateInPlaceAndAuthenticate() throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  let store = try AudioStore(dataDirectory: root, key: SymmetricKey(size: .bits256))
  let meta = AudioMetadata(start: Date())
  try store.writeMetadata(meta)
  let dir = try store.directory(for: meta), file = dir.appendingPathComponent("meta.json")
  #expect(try !Data(contentsOf: file).contains(Data(meta.id.utf8)))
  // 模拟升级前两份明文，读回正确后确认磁盘已没有原文。
  try meta.encoded().write(to: file)
  let speaker = dir.appendingPathComponent("speakers.json")
  let legacy = Data("{\"name\":\"合成姓名\",\"embedding\":[1,2,3]}".utf8)
  try legacy.write(to: speaker)
  #expect(try store.readMetadata(at: dir).id == meta.id)
  #expect(try store.readPrivateData(at: speaker) == legacy)
  #expect(try Data(contentsOf: speaker) != legacy)
  #expect(try !Data(contentsOf: file).contains(Data(meta.id.utf8)))
  var bytes = try Data(contentsOf: speaker); bytes[bytes.count - 1] ^= 1; try bytes.write(to: speaker)
  #expect(throws: (any Error).self) { try store.readPrivateData(at: speaker) }
}

@Test func encryptedAudioRoundTripRejectsTamperingAndUnsafePaths() throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  let store = try AudioStore(dataDirectory: root, key: SymmetricKey(size: .bits256))
  let start = Date(timeIntervalSince1970: 1_794_000_000)
  var meta = AudioMetadata(start: start)
  try store.writeMetadata(meta)
  // 合成的编码负载，不依赖权限或系统音频服务；认证与清理必须真实执行。
  let aac = Data([0xff, 0xf1, 0x60, 0x40, 0x01, 0x7f, 0xfc, 1, 2, 3])
  try store.writeSegment(aac, file: "mic-0001.enc", meta: meta)
  #expect(try store.readSegment("mic-0001.enc", meta: meta) == aac)
  let path = try store.directory(for: meta).appendingPathComponent("mic-0001.enc")
  var encrypted = try Data(contentsOf: path); #expect(encrypted != aac)
  encrypted[encrypted.count - 1] ^= 1; try encrypted.write(to: path)
  #expect(throws: (any Error).self) { try store.readSegment("mic-0001.enc", meta: meta) }
  #expect(throws: (any Error).self) { try store.readSegment("../token", meta: meta) }
  meta.segments = [AudioSegment(file: "mic-0001.enc", track: .mic, start: start, end: start.addingTimeInterval(1), dbfs: -15)]
  try store.writeMetadata(meta)
  try store.recoverInterrupted()
  #expect(try store.conversations().first?.status == .closed)
  let deleted = try store.cleanup(now: start.addingTimeInterval(2), retentionDays: 7, purgeBefore: start.addingTimeInterval(2))
  #expect(deleted == [meta.id]); #expect(try store.conversations().isEmpty)
}

@Test func cleanupDoesNotFollowSymlinksOrDeleteOpenConversation() throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  let store = try AudioStore(dataDirectory: root, key: SymmetricKey(size: .bits256))
  let meta = AudioMetadata(start: Date())
  try store.writeMetadata(meta)
  #expect(try store.cleanup(now: Date(), retentionDays: 7, purgeBefore: .distantFuture, deleting: [meta.id]).isEmpty)
  let outside = root.appendingPathComponent("sentinel")
  try Data("合成内容".utf8).write(to: outside)
  let link = try store.directory(for: meta).appendingPathComponent("mic-0001.enc")
  try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
  #expect(throws: (any Error).self) { try store.readSegment("mic-0001.enc", meta: meta) }
  #expect(try String(contentsOf: outside, encoding: .utf8) == "合成内容")
}

@Test(.enabled(if: AudioCodec.encoderAvailable, "当前运行环境未提供 AAC 编码器，需真机运行此用例"))
func aacCodecRoundTripInMemory() throws {
  let samples = (0..<16000).map { Float(sin(Double($0) * 2 * .pi * 440 / 16000) * 0.25) }
  let aac = try AudioCodec.encode(samples)
  #expect(!aac.isEmpty)
  let decoded = try AudioCodec.decode(aac)
  #expect(abs(decoded.count - samples.count) <= 4096)
  #expect(decoded.contains { abs($0) > 0.1 })
  #expect(decoded.allSatisfy { $0.isFinite })
}

// 回归：段时间戳只精确到秒，不足 1 秒的段首尾相同；去空白不能依赖时间戳，否则短段被截空、长段段首丢人声。
@Test func aacPrimingTrimKeepsOnsetForShortSegments() throws {
  for n in [3000, 16500, 48123] {
    var samples = [Float](repeating: 0, count: n)
    for i in 0..<200 { samples[1000 + i] = Float(sin(Double(i) * 0.5) * 0.5) }
    let trimmed = WorkerLogic.trimPadding(try AudioCodec.decode(AudioCodec.encode(samples)))
    #expect(trimmed.count >= n && trimmed.count < n + 1024)
    let onset = trimmed.firstIndex { abs($0) > 0.05 }
    #expect(onset.map { abs($0 - 1000) <= 2 } == true)
  }
}

@Test func earlierTrackAcrossMidnightKeepsConversationAndEncryptedSegments() throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  let store = try AudioStore(dataDirectory: root, key: SymmetricKey(size: .bits256))
  let start = AudioPolicy.date("2026-11-09T00:00:05Z")!
  var meta = AudioMetadata(start: start)
  // 固定 UTC 日期，避免依赖测试机时区。
  meta.t_start = "2026-11-09T00:00:05Z"
  try store.writeMetadata(meta)
  let audio = Data([1, 2, 3, 4]); try store.writeSegment(audio, file: "sys-0001.enc", meta: meta)
  let old = meta; meta.t_start = "2026-11-08T23:59:59Z"
  try store.moveOpenConversation(from: old, to: meta)
  #expect(try store.readSegment("sys-0001.enc", meta: meta) == audio)
  #expect(try store.conversations() == [meta])
}

@Test func inventoryReadDoesNotRewriteLegacyMetadataOrInspectSpeakerCache() throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  let store = try AudioStore(dataDirectory: root, key: SymmetricKey(size: .bits256))
  let meta = AudioMetadata(start: Date()); try store.writeMetadata(meta)
  let dir = try store.directory(for: meta), file = dir.appendingPathComponent("meta.json")
  let original = try meta.encoded();try original.write(to:file)
  try Data("deliberately invalid speaker cache".utf8).write(to:dir.appendingPathComponent("speakers.json"))
  #expect(try store.conversations(readOnly:true).map(\.id) == [meta.id])
  #expect(try Data(contentsOf:file) == original)
}


@Test func unlimitedRetentionKeepsEncryptedFilesUntilExplicitPurge() throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  let store = try AudioStore(dataDirectory: root, key: SymmetricKey(size: .bits256))
  let start = Date(timeIntervalSince1970: 1_794_000_000)
  var meta = AudioMetadata(start: start)
  meta.t_end = LocalTime.iso(start.addingTimeInterval(1))
  try meta.transition(to: .closed, at: start.addingTimeInterval(1))
  try store.writeMetadata(meta)
  let bytes = Data([1, 2, 3])
  try store.writeSegment(bytes, file: "mic-0001.enc", meta: meta)
  let future = start.addingTimeInterval(1000 * 86400)
  #expect(try store.cleanup(now: future, retentionDays: 0).isEmpty)
  #expect(try store.readSegment("mic-0001.enc", meta: meta) == bytes)
  #expect(try store.cleanup(now: future, retentionDays: 0, purgeBefore: future) == [meta.id])
  #expect(try store.conversations().isEmpty)
  #expect(!FileManager.default.fileExists(atPath: try store.directory(for: meta).appendingPathComponent("mic-0001.enc").path))
}
