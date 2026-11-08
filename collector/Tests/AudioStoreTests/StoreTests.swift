import Foundation
import Testing
import CryptoKit
import CollectorCore
@testable import AudioStore

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
