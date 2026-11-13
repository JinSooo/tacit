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
  #expect(throws: (any Error).self) { try recovered.append(a) }
  #expect(throws: (any Error).self) { try recovered.acknowledge([a.id]) }
  #expect(try Data(contentsOf: file) == bytes)
  let wrong = try OutboxStore(dataDirectory: root, key: SymmetricKey(size: .bits256))
  #expect(wrong.restore(limit: 10).unreadable == 2); #expect(wrong.count == 2)
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
