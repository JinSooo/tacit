import Foundation
import Testing
import CryptoKit
import Darwin
import CollectorCore
@testable import AudioStore

private func outboxRecord(_ body: String = "合成待发送记录") -> Record {
  Record(device: "test", source: "mac.screen", kind: "text", start: Date(), context: nil, title: "合成", body: body, capture: .init(method: "test"))
}
@Test func outboxStoresOnlyEncryptedRedactedDataAndAcknowledges() throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  let key = SymmetricKey(size: .bits256), store = try OutboxStore(dataDirectory: root, key: key)
  let fake = "ghp_" + String(repeating: "aB3", count: 12), record = outboxRecord(fake)
  let clean = try store.append(record)
  let file = store.root.appendingPathComponent(record.id + ".enc"), bytes = try Data(contentsOf: file)
  #expect(!bytes.contains(Data(fake.utf8))); #expect(!bytes.contains(Data(clean.body.utf8)))
  #expect(clean.body == "[已脱敏:GitHub]"); #expect(clean.redactions == 1)
  #expect((try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int) == 0o600)
  let reopened = try OutboxStore(dataDirectory: root, key: key)
  #expect(reopened.restore(limit: 1).records == [clean])
  var changed = record; changed.body = "同 id 不应覆盖"
  #expect(try reopened.append(changed) == clean); #expect(reopened.count == 1)
  try reopened.acknowledge([record.id])
  #expect(!FileManager.default.fileExists(atPath: file.path))
  #expect(try OutboxStore(dataDirectory: root, key: key).restore(limit: 10).records.isEmpty)
}
@Test func outboxCorruptionAndWrongKeyPreserveFilesAndOtherRecords() throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  let key = SymmetricKey(size: .bits256), store = try OutboxStore(dataDirectory: root, key: key)
  let a = try store.append(outboxRecord()), b = try store.append(outboxRecord())
  let file = store.root.appendingPathComponent(a.id + ".enc")
  var bytes = try Data(contentsOf: file); bytes[bytes.count - 1] ^= 1; try bytes.write(to: file)
  let recovered = try OutboxStore(dataDirectory: root, key: key)
  #expect(recovered.restore(limit: 10).records == [b]); #expect(recovered.restore(limit: 10).unreadable == 1)
  #expect(!FileManager.default.fileExists(atPath: file.path))
  #expect(recovered.count == 1 && recovered.quarantined == 1)
  let quarantine = store.root.appendingPathComponent("quarantine")
  let isolated = try #require(FileManager.default.contentsOfDirectory(at: quarantine, includingPropertiesForKeys: nil).first)
  #expect(try Data(contentsOf: isolated) == bytes)
  #expect(try recovered.append(a) == a)
  let wrong = try OutboxStore(dataDirectory: root, key: SymmetricKey(size: .bits256))
  #expect(wrong.restore(limit: 10).unreadable == 3)
  #expect(wrong.count == 0 && wrong.quarantined == 3)
  #expect(try Data(contentsOf: isolated) == bytes)
}
@Test func outboxRestoreIsBoundedAndKeepsOverflowUntilAcknowledged() throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  let key = SymmetricKey(size: .bits256), store = try OutboxStore(dataDirectory: root, key: key)
  for _ in 0..<8 { _ = try store.append(outboxRecord()) }
  let first = store.restore(limit: 3).records
  #expect(first.count == 3); #expect(store.count == 8)
  let second = store.restore(limit: 3, excluding: Set(first.map(\.id))).records
  #expect(Set(first.map(\.id)).isDisjoint(with: second.map(\.id)))
  try store.acknowledge(Set(first.map(\.id)))
  let restarted = try OutboxStore(dataDirectory: root, key: key)
  #expect(restarted.count == 5); #expect(restarted.restore(limit: 10).records.count == 5)
}
@Test func outboxRejectsRootAndRecordSymlinks() throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  let outside = root.appendingPathComponent("outside")
  try Data("合成外部文件".utf8).write(to: outside)
  let link = root.appendingPathComponent("outbox")
  try FileManager.default.createSymbolicLink(at: link, withDestinationURL: root)
  let key = SymmetricKey(size: .bits256)
  #expect(throws: (any Error).self) { try OutboxStore(dataDirectory: root, key: key) }
  try FileManager.default.removeItem(at: link)
  let store = try OutboxStore(dataDirectory: root, key: key), r = outboxRecord()
  try FileManager.default.createSymbolicLink(at: store.root.appendingPathComponent(r.id + ".enc"), withDestinationURL: outside)
  #expect(throws: (any Error).self) { try store.append(r) }
  #expect(try String(contentsOf: outside, encoding: .utf8) == "合成外部文件")
}

@Test func outboxEnforcesEncryptedByteLimitAndEvictsOldestAcrossRestart() throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  let key = SymmetricKey(size: .bits256)
  let oldest = outboxRecord(), middle = outboxRecord(), newest = outboxRecord()
  let original = try OutboxStore(dataDirectory: root, key: key)
  // 反序写入，淘汰按记录时间而非遍历顺序。
  _ = try original.append(middle)
  _ = try original.append(oldest)
  let initialBytes = original.bytes
  let limited = try OutboxStore(dataDirectory: root, key: key, byteLimit: initialBytes)
  #expect(limited.bytes == initialBytes)
  _ = try limited.append(newest)
  #expect(limited.dropped == 1)
  #expect(limited.bytes <= initialBytes)
  #expect(limited.restore(limit: 3).records == [middle, newest].map(RecordRedaction.record))
  let reopened = try OutboxStore(dataDirectory: root, key: key)
  #expect(reopened.restore(limit: 3).records == [middle, newest].map(RecordRedaction.record))
  try reopened.acknowledge([middle.id, newest.id])
  #expect(reopened.bytes == 0)
}

@Test func degradedOutboxRetriesAtSixtySecondsAndPersistsMemoryRecords() throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  let blockedPath = root.appendingPathComponent("outbox")
  try Data().write(to: blockedPath)
  let key = SymmetricKey(size: .bits256)
  var opens = 0
  let buffer = OutboxBuffer {
    opens += 1
    return try OutboxStore(dataDirectory: root, key: key)
  }
  let record = outboxRecord()
  buffer.retry(at: 10)
  buffer.enqueue([record], at: 11)
  #expect(buffer.status.degraded)
  #expect(buffer.batch(limit: 10) == [RecordRedaction.record(record)])
  try FileManager.default.removeItem(at: blockedPath)
  buffer.retry(at: 69)
  #expect(opens == 1)
  buffer.retry(at: 70)
  #expect(opens == 2)
  #expect(!buffer.status.degraded)
  #expect(buffer.status.bytes > 0)
  #expect(buffer.memory.count == 0)
  #expect(buffer.count == 1)
  let reopened = try OutboxStore(dataDirectory: root, key: key)
  #expect(reopened.restore(limit: 10).records == [RecordRedaction.record(record)])
  try buffer.acknowledge([record.id], at: 71)
  #expect(buffer.status.bytes == 0)
}

@Test func outboxRecoversAfterAnActiveStoreFailsToPersist() throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  let key = SymmetricKey(size: .bits256)
  let buffer = OutboxBuffer { try OutboxStore(dataDirectory: root, key: key) }
  let disk = outboxRecord(), fallback = outboxRecord()
  buffer.retry(at: 0)
  buffer.enqueue([disk], at: 1)
  let blockedPath = root.appendingPathComponent("outbox/\(fallback.id).enc")
  try FileManager.default.createDirectory(at: blockedPath, withIntermediateDirectories: false)
  buffer.enqueue([fallback], at: 2)
  #expect(buffer.status.degraded)
  #expect(buffer.batch(limit: 1).map(\.id) == [fallback.id])
  #expect(buffer.count == 2)
  try FileManager.default.removeItem(at: blockedPath)
  buffer.retry(at: 62)
  #expect(!buffer.status.degraded)
  #expect(buffer.batch(limit: 2).map(\.id) == [disk.id, fallback.id])
  try buffer.acknowledge([disk.id], at: 63)
  #expect(buffer.batch(limit: 2).map(\.id) == [fallback.id])
}

@Test func eligibleBatchPublishesCorruptFileQuarantineImmediately() throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  let store = try OutboxStore(dataDirectory: root, key: SymmetricKey(size: .bits256))
  let buffer = OutboxBuffer { store }
  let record = outboxRecord()
  buffer.retry(at: 0)
  buffer.enqueue([record], at: 1)
  try Data("invalid ciphertext".utf8).write(to: store.root.appendingPathComponent(record.id + ".enc"))
  #expect(buffer.count == 1)
  #expect(buffer.eligibleBatch(limit: 10, excluding: []) { _ in true }.isEmpty)
  #expect(buffer.count == 0)
  #expect(buffer.status.quarantined == 1)
}
