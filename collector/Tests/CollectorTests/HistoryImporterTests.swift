import CollectorCore
import CryptoKit
import Darwin
import Foundation
import Testing
@testable import Collector

@MainActor private final class ImportFixture {
  enum Fault: Error { case disconnected, crash, unexpected }
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent("tacit-import-unit-" + UUID().uuidString)
  let gate = RemoteSwitchWriteGate()
  let remote: HubBinding.Remote
  var binding: HubBinding
  var now = Date()
  var snapshot = String(repeating: "a", count: 64)
  var privateCount = 1
  var records: [DeviceJSON]
  var sendBudget: Int?
  var budget = 4 * 1024 * 1024
  var newCapture = false
  var failAfter: String?
  var beforeSend: ((String) async -> Void)?
  var offline = false
  var invalidateCursor = false
  var unknownVerification = false
  var failApply = false
  var applyChangesSnapshot = false
  var deviceID: String? = "mac-original"
  var requested: [String] = []
  var events: [HistoryWithdrawal] = []
  var applied: [HistoryWithdrawal] = []
  var outcomes: [String: String] = [:]
  var receipts: [String: [Int: Data]] = [:]
  var sessions: [String: String] = [:]
  var sessionSnapshots: [String: String] = [:]
  var sessionOwners: [String: String] = [:]
  var beginCalls = 0
  var finishCalls = 0
  var expiredSessions: Set<String> = []
  var progress: HistoryImportProgress?
  var backup: HistoryBackupInfo?

  init(_ count: Int = 4) throws {
    let key = Curve25519.KeyAgreement.PrivateKey()
    let text = DeviceEnvelope.publicKeyBase64URL(key.publicKey)
    remote = try HubBinding.Remote(hubID: DeviceProtocol.hubID(forPublicKey: key.publicKey.rawRepresentation), hubPublicKey: text)
    binding = HubBinding(generation: 1, target: .remote, phase: .committed, remote: remote)
    records = (0..<count).map { _ in .object(["id": .string(ULID.make()), "body": .string("synthetic record")]) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    try Data("dummy db".utf8).write(to: directory.appendingPathComponent("history.db"))
  }

  func clean() { try? FileManager.default.removeItem(at: directory) }

  func make() -> HistoryImporter {
    let app = HistoryImporter(directory: directory, gate: gate, pageSize: 2, operations: .init(
      binding: { self.binding },
      budget: { _ in self.budget },
      send: { _, operation, body in
        await self.beforeSend?(operation)
        return try self.send(operation, body)
      },
      export: { try self.export(after: $0, limit: $1) },
      apply: { changes in
        if self.failApply { throw Fault.crash }
        self.applied.append(contentsOf: changes)
        if self.applyChangesSnapshot { self.snapshot = String(repeating: "c", count: 64) }
      },
      mayImport: { _ in !self.newCapture },
      now: { self.now },
      deviceID: { _ in self.deviceID }
    ))
    app.onChange = { self.progress = $0; self.backup = $1 }
    return app
  }

  func journal() throws -> HistoryImportJournal {
    let bytes = try #require(try HistoryImportJournalFile.read(in: directory, for: remote))
    return try JSONDecoder().decode(HistoryImportJournal.self, from: bytes)
  }

  func store(_ value: HistoryImportJournal) throws {
    try HistoryImportJournalFile.write(JSONEncoder().encode(value), in: directory, for: remote)
  }

  private func export(after cursor: String?, limit: Int) throws -> HistoryExportPage {
    let start: Int
    if let cursor {
      let fields = cursor.split(separator: ":")
      guard fields.first == Substring(snapshot) else { throw FrozenHistoryCommands.Failure.snapshotChanged }
      start = Int(fields.last!)!
    } else { start = 0 }
    let end = min(start + limit, records.count)
    return try decode(["snapshot_id": snapshot, "identities": [], "records": records[start..<end].map { node in
      var record = ["id": node["id"]!.stringValue!, "body": node["body"]!.stringValue!]
      record["corrects"] = node["corrects"]?.stringValue
      return record
    }, "next_cursor": end < records.count ? "\(snapshot):\(end)" as Any : NSNull(), "total": records.count, "private_count": privateCount])
  }

  private func decode<T: Decodable>(_ value: Any) throws -> T {
    try JSONDecoder().decode(T.self, from: JSONSerialization.data(withJSONObject: value))
  }

  func send(_ operation: String, _ body: [String: DeviceJSON]) throws -> Data {
    guard !offline else { throw Fault.disconnected }
    let op = operation.replacingOccurrences(of: "history.import.", with: "")
    requested.append(op)
    let requestedSnapshot = body["snapshot_id"]?.stringValue ?? snapshot
    let session = body["session_id"]?.stringValue ?? sessions[requestedSnapshot] ?? UUID().uuidString
    func progress(_ finished: Bool = false) throws -> Data {
      let confirmed = receipts[session] ?? [:]
      var counts = HistoryImportCounts()
      for bytes in confirmed.values {
        counts.add(try JSONDecoder().decode(HistoryImportReceipt.self, from: bytes).counts)
      }
      let totals = try JSONSerialization.jsonObject(with: JSONEncoder().encode(counts))
      return try JSONSerialization.data(withJSONObject: ["session_id": session, "hub_id": remote.hub_id, "snapshot_id": sessionSnapshots[session] ?? requestedSnapshot,
        "next_batch_number": confirmed.count + 1, "counts": totals, "finished_at": finished ? "finished" as Any : NSNull()])
    }
    func reply(_ value: Any) throws -> Data { try JSONSerialization.data(withJSONObject: value) }
    let data: Data
    switch op {
    case "begin":
      expiredSessions.remove(session)
      sessions[requestedSnapshot] = session
      sessionSnapshots[session] = requestedSnapshot
      sessionOwners[session] = deviceID
      beginCalls += 1
      data = try progress()
    case "batch":
      guard case .int(let number) = body["batch_number"], let content = body["records"]?.arrayValue else { throw Fault.unexpected }
      if let sendBudget, try HistoryImporter.batchIDs(content[...], budget: sendBudget).count != content.count {
        throw DeviceClientError.envelopeTooLarge(message: nil)
      }
      let batch = Int(number)
      if let cached = receipts[session]?[batch] {
        let original = try JSONDecoder().decode(HistoryImportReceipt.self, from: cached)
        guard original.items.map(\.id) == content.compactMap({ $0["id"]?.stringValue }) else {
          throw DeviceClientError.operationError(op: operation, status: 409, message: "batch_changed")
        }
        data = cached
      }
      else {
        var counts = ["added": 0, "exists": 0, "deleted": 0, "conflict": 0, "rejected": 0]
        let items = content.map { record in
          let id = record["id"]!.stringValue!, outcome = outcomes[id] ?? "added"
          counts[outcome, default: 0] += 1
          return ["id": id, "status": outcome, "remote_id": id,
            "code": outcome == "conflict" ? "record_conflict" : "invalid_record"]
        }
        data = try reply(["session_id": session, "batch_number": batch, "items": items, "counts": counts])
        receipts[session, default: [:]][batch] = data
      }
    case "status":
      guard sessionOwners[session] == deviceID else {
        throw DeviceClientError.operationError(op: operation, status: 404, message: "session_unknown")
      }
      data = try progress()
    case "finish":
      if expiredSessions.contains(session) {
        throw DeviceClientError.operationError(op: operation, status: 403, message: "authorization_expired")
      }
      finishCalls += 1
      data = try progress(true)
    case "changes":
      guard case .int(let after) = body["after"] else { throw Fault.unexpected }
      if (invalidateCursor && after > 0) || Int(after) > events.count { throw DeviceClientError.operationError(op: operation, status: 409, message: "cursor_unknown") }
      guard sessionOwners[session] == deviceID || body["withdrawal_only"] == .bool(true) else {
        throw DeviceClientError.operationError(op: operation, status: 404, message: "session_unknown")
      }
      let ids = try (receipts[session]?.values.map { try JSONDecoder().decode(HistoryImportReceipt.self, from: $0) } ?? [])
        .flatMap { $0.items.filter { [.added, .exists, .deleted].contains($0.status) }.map(\.id) }
      let changes = events.filter { ids.contains($0.id) }
      guard Int(after) <= changes.count else {
        throw DeviceClientError.operationError(op: operation, status: 409, message: "cursor_unknown")
      }
      data = try reply(["changes": changes.dropFirst(Int(after)).map { ["id": $0.id, "kind": $0.kind.rawValue] },
        "cursor": changes.count, "more": false])
    case "verify":
      guard let ids = body["ids"]?.arrayValue?.compactMap(\.stringValue) else { throw Fault.unexpected }
      data = try reply(["items": ids.map { id in
        let rejected = ["conflict", "rejected"].contains(outcomes[id] ?? "")
        return ["id": id, "status": unknownVerification || rejected ? "unknown" :
          events.first(where: { $0.id == id })?.kind.rawValue ?? "present"]
      }])
    case "status.get": data = try reply([String: String]())
    default: throw Fault.unexpected
    }
    if failAfter == op {
      failAfter = nil
      throw Fault.crash
    }
    return data
  }

  func run(_ app: HistoryImporter, until stop: () -> Bool, max: Int = 25) async {
    for _ in 0..<max where !stop() { await app.tick() }
    #expect(stop())
  }
}

@Test @MainActor func historyImportResumesEveryDurableStep() async throws {
  let f = try ImportFixture()
  defer { f.clean() }
  var app = f.make()
  f.newCapture = true
  await app.tick()
  #expect(f.requested.isEmpty)
  f.newCapture = false
  await app.tick() // Save snapshot, before begin.
  app = f.make()
  f.failAfter = "begin"
  await app.tick()
  #expect(try f.journal().attempt?.session == nil)
  app = f.make()
  await app.tick()
  #expect(f.beginCalls == 2 && f.sessions.count == 1)
  f.failAfter = "batch"
  await f.run(app, until: { f.progress?.hasPendingReceipt == true })
  #expect(try f.journal().attempt?.counts.total == 0)
  app = f.make()
  await app.tick()
  #expect(try f.journal().attempt?.counts.total == 2)
  app = f.make()
  f.failAfter = "finish"
  await f.run(app, until: { f.finishCalls == 1 })
  #expect(f.progress?.isComplete == false)
  app = f.make()
  await f.run(app, until: { f.progress?.isComplete == true })
  #expect(f.progress?.confirmed == 4)
  #expect(f.receipts.values.first?.count == 2)
  #expect(f.finishCalls == 2)
}

@Test @MainActor func historyImportShrinksAndKeepsIssueIDs() async throws {
  let f = try ImportFixture(4)
  defer { f.clean() }
  let ids = f.records.map { $0["id"]!.stringValue! }
  f.budget = 110
  f.records[0] = .object(["id": .string(ids[0]), "body": .string(String(repeating: "x", count: 300))])
  f.outcomes[ids[1]] = "conflict"
  f.outcomes[ids[2]] = "rejected"
  let app = f.make()
  await f.run(app, until: { f.progress?.isComplete == true })
  #expect(f.receipts.values.first?.count == 3)
  #expect(f.progress?.confirmed == 1)
  #expect(f.progress?.total == 4)
  #expect(f.progress?.needsAttention == 3)
  #expect(f.progress?.issues == [
    .init(id: ids[0], category: "batch_too_large"), .init(id: ids[1], category: "record_conflict"),
    .init(id: ids[2], category: "invalid_record"),
  ])
}

@Test @MainActor func historyImportVerifiesExpiredCursorAndAdvancesOnlyAfterApply() async throws {
  let f = try ImportFixture(2)
  defer { f.clean() }
  let app = f.make()
  await f.run(app, until: { f.progress?.isComplete == true })
  let session = try #require(f.sessions[f.snapshot])
  let ids = try #require(f.journal().sessions[session]?.ids)
  var reset = try f.journal()
  reset.sessions[session]?.cursor = 999
  try f.store(reset)
  f.invalidateCursor = true
  f.events = [.init(id: ids[0], kind: .private), .init(id: ids[1], kind: .deleted)]
  f.failApply = true
  #expect(await app.reconcileForReturn(on: f.binding.route) == .incomplete)
  #expect(try f.journal().sessions[session]?.cursor == 999)
  f.failApply = false
  f.unknownVerification = true
  #expect(await app.reconcileForReturn(on: f.binding.route) == .incomplete)
  f.unknownVerification = false
  #expect(await app.reconcileForReturn(on: f.binding.route) == .reconciled)
  #expect(try f.journal().sessions[session]?.cursor == 2)
  #expect(Set(f.applied.map(\.id)) == Set(ids))
  f.offline = true
  #expect(await app.reconcileForReturn(on: f.binding.route) == .incomplete)
}

@Test @MainActor func historyBackupDeletionRequiresFinishedImportAndExplicitEmptyReturn() async throws {
  let f = try ImportFixture(1)
  defer { f.clean() }
  let app = f.make()
  await #expect(throws: HistoryImporter.Failure.deletionBlocked) { try await app.deleteBackup() }
  f.failAfter = "batch"
  await f.run(app, until: { f.progress?.hasPendingReceipt == true })
  try await app.setPaused(true)
  await #expect(throws: HistoryImporter.Failure.deletionBlocked) { try await app.deleteBackup() }
  await app.tick()
  #expect(f.progress?.hasPendingReceipt == false && f.progress?.isPaused == true)
  try await app.setPaused(false)
  await f.run(app, until: { f.progress?.isComplete == true })
  f.gate.setPaused(true)
  await #expect(throws: HistoryImporter.Failure.deletionBlocked) { try await app.deleteBackup() }
  f.gate.setPaused(false)
  for name in ["history.db-journal", "history.db.migration-v18.bak", "audio.enc"] {
    try Data("fixture".utf8).write(to: f.directory.appendingPathComponent(name))
  }
  let pendingAudit = f.directory.appendingPathComponent("history.db.audit-pending")
  try FileManager.default.createDirectory(at: pendingAudit, withIntermediateDirectories: false)
  try Data("encrypted audit fixture".utf8).write(to: pendingAudit.appendingPathComponent("fixture.enc"))
  try await app.deleteBackup()
  #expect(!FileManager.default.fileExists(atPath: pendingAudit.path))
  #expect(try app.backupInfo().recovery == .emptyLocalBackend)
  #expect(!FileManager.default.fileExists(atPath: f.directory.appendingPathComponent("history.db").path))
  #expect(!FileManager.default.fileExists(atPath: f.directory.appendingPathComponent("history.db-journal").path))
  #expect(!FileManager.default.fileExists(atPath: f.directory.appendingPathComponent("history.db.migration-v18.bak").path))
  #expect(FileManager.default.fileExists(atPath: f.directory.appendingPathComponent("audio.enc").path))
  #expect(await f.make().reconcileForReturn(on: f.binding.route) == .emptyLocalBackend)
}

@Test @MainActor func historyImportStartsNewSessionAfterSourceReopens() async throws {
  let f = try ImportFixture(1)
  defer { f.clean() }
  let app = f.make()
  await f.run(app, until: { f.progress?.isComplete == true })
  f.binding = HubBinding(generation: 3, target: .remote, phase: .committed, remote: f.remote)
  f.snapshot = String(repeating: "b", count: 64)
  f.records.append(.object(["id": .string(ULID.make()), "body": .string("new local write")]))
  let restarted = f.make()
  f.newCapture = true
  await restarted.tick()
  #expect(f.progress?.isComplete == false)
  #expect(f.progress?.confirmed == 0 && f.progress?.total == nil)
  f.newCapture = false
  for _ in 0..<8 { await restarted.tick() }
  #expect(f.sessions.count == 2)
  #expect(f.progress?.confirmed == 2 && f.progress?.isComplete == true)
  #expect(try f.journal().sourceCheckedGeneration == 3)
}

@Test @MainActor func historyImportResizesDurableBatchAfterTransportLimitShrinks() async throws {
  let f = try ImportFixture(2)
  defer { f.clean() }
  let app = f.make()
  await f.run(app, until: { f.beginCalls == 1 })
  // Simulate interruption after persisting a batch on the direct route and before its PUT.
  var saved = try f.journal()
  saved.attempt?.pending = f.records.compactMap { $0["id"]?.stringValue }
  try f.store(saved)
  f.sendBudget = 110
  f.budget = 110
  let restarted = f.make()
  await f.run(restarted, until: { f.progress?.isComplete == true }, max: 10)
  #expect(f.requested.contains("status"))
  #expect(f.progress?.confirmed == 2)
  #expect(try f.journal().attempt?.pending == nil)
  #expect(f.backup?.canDelete == true)
}

@Test @MainActor func historyImportRecoversCommittedOversizeBatchWithoutChangingItsNumber() async throws {
  let f = try ImportFixture(2)
  defer { f.clean() }
  let ids = f.records.compactMap { $0["id"]?.stringValue }
  f.outcomes[ids[1]] = "conflict"
  f.failAfter = "batch"
  let app = f.make()
  await f.run(app, until: { f.progress?.hasPendingReceipt == true })
  let session = try #require(f.sessions[f.snapshot])
  f.sendBudget = 110
  f.budget = 110
  let restarted = f.make()
  await f.run(restarted, until: { f.progress?.isComplete == true })
  #expect(f.requested.contains("status") && f.requested.contains("verify"))
  #expect(f.receipts[session]?.count == 1)
  #expect(try f.journal().sessions[session]?.ids == [ids[0]])
  #expect(f.progress?.confirmed == 1 && f.progress?.needsAttention == 1)
}

@Test @MainActor func historyImportBlocksReturnWhileOversizeBatchMayStillCommit() async throws {
  let f = try ImportFixture(2)
  defer { f.clean() }
  let app = f.make()
  await f.run(app, until: { f.beginCalls == 1 })
  var saved = try f.journal()
  saved.attempt?.pending = f.records.compactMap { $0["id"]?.stringValue }
  try f.store(saved)
  f.budget = 110
  f.gate.setPaused(true)
  #expect(await app.reconcileForReturn(on: f.binding.route) == .incomplete)
  #expect(try f.journal().attempt?.pending == saved.attempt?.pending)
  #expect(f.requested.contains("status") && !f.requested.contains("batch"))
}

@Test @MainActor func historyImportDefersBackupWritesUntilFinishEvenWhenPaused() async throws {
  let f = try ImportFixture(4)
  defer { f.clean() }
  let app = f.make()
  await f.run(app, until: { f.progress?.confirmed == 2 })
  let id = try #require(f.records[0]["id"]?.stringValue)
  f.events = [.init(id: id, kind: .deleted)]
  f.applyChangesSnapshot = true
  f.now.addTimeInterval(60)
  try await app.setPaused(true)
  await app.tick()
  #expect(f.applied.isEmpty)
  try await app.setPaused(false)
  await f.run(app, until: { f.progress?.isComplete == true })
  #expect(f.applied.isEmpty)
  await app.tick()
  #expect(f.applied == f.events)
  #expect(f.sessions.count == 1 && f.finishCalls == 1)
}

@Test(arguments: [false, true])
@MainActor func historyImportResetsRevokedIdentityCheckpoint(legacy: Bool) async throws {
  let f = try ImportFixture(2)
  defer { f.clean() }
  let app = f.make()
  f.failAfter = "batch"
  await f.run(app, until: { f.progress?.hasPendingReceipt == true })
  var saved = try f.journal()
  let old = try #require(saved.attempt?.session)
  saved.sessions[old]?.cursor = 42
  if legacy { saved.deviceID = nil }
  try f.store(saved)
  let ids = f.records.compactMap { $0["id"]?.stringValue }
  f.outcomes = Dictionary(uniqueKeysWithValues: ids.map { ($0, "exists") })
  f.sessions = [:] // begin is scoped to the authenticated actor on the hub.
  f.requested = []
  f.deviceID = "mac-replacement"
  f.binding = HubBinding(generation: legacy ? 3 : 2, target: .remote, phase: .committed, remote: f.remote)
  let restarted = f.make()
  #expect(await restarted.reconcileForReturn(on: f.binding.route) == .incomplete)
  await f.run(restarted, until: { f.progress?.isComplete == true })
  let new = try #require(f.sessions[f.snapshot])
  #expect(new != old)
  #expect(Set(try f.journal().sessions.keys) == [old, new])
  #expect(try f.journal().sessions[old]?.withdrawalOnly == true)
  #expect(try f.journal().sessions[new]?.cursor == 0)
  #expect(f.requested.first == (legacy ? "status" : "begin"))
  #expect(f.progress?.confirmed == 2 && f.progress?.alreadyPresent == 2)
  #expect(await restarted.reconcileForReturn(on: f.binding.route) == .reconciled)
}

@Test func frozenHistoryHandlesClosedSubprocessInputPipe() throws {
  let input = Pipe()
  try input.fileHandleForReading.close()
  #expect(!FrozenHistoryCommands.writeInput(Data([0x61]), to: input.fileHandleForWriting.fileDescriptor))
}

@Test @MainActor func historyBackupRejectsSymlinkedPendingAudit() throws {
  let f = try ImportFixture(0)
  defer { f.clean() }
  let sentinel = f.directory.appendingPathComponent("unrelated")
  try Data([42]).write(to: sentinel)
  let sidecar = f.directory.appendingPathComponent("history.db.audit-pending")
  try FileManager.default.createSymbolicLink(at: sidecar, withDestinationURL: sentinel)
  #expect(throws: HistoryImporter.Failure.backupUnavailable) {
    try HistoryBackupFiles(directory: f.directory).remove()
  }
  #expect(try Data(contentsOf: sentinel) == Data([42]))
  #expect(FileManager.default.fileExists(atPath: f.directory.appendingPathComponent("history.db").path))
}

@Test @MainActor func historyImportKeepsOldMappingAfterRePairingConflict() async throws {
  let f = try ImportFixture(1)
  defer { f.clean() }
  let app = f.make()
  await f.run(app, until: { f.progress?.isComplete == true })
  let id = try #require(f.records[0]["id"]?.stringValue)
  f.outcomes[id] = "conflict" // The previous copy could have become private on the hub.
  f.sessions = [:]
  f.deviceID = "mac-replacement"
  f.binding = HubBinding(generation: 2, target: .remote, phase: .committed, remote: f.remote)
  let restarted = f.make()
  await f.run(restarted, until: { f.progress?.isComplete == true && f.progress?.needsAttention == 1 })
  f.events = [.init(id: id, kind: .deleted)]
  #expect(await restarted.reconcileForReturn(on: f.binding.route) == .reconciled)
  #expect(f.applied == f.events)
  #expect(try f.journal().unverifiedPreviousIDs == nil)
}

@Test @MainActor func lateLargerHistoryBatchWinsBeforeResizedRetry() async throws {
  let f = try ImportFixture(2)
  defer { f.clean() }
  let app = f.make()
  await f.run(app, until: { f.beginCalls == 1 })
  var saved = try f.journal()
  let ids = f.records.compactMap { $0["id"]?.stringValue }
  let session = try #require(saved.attempt?.session)
  saved.attempt?.pending = ids
  saved.attempt?.pendingSent = true
  try f.store(saved)
  f.sendBudget = 110
  f.budget = 110
  await app.tick()
  #expect(try f.journal().attempt?.pendingLimit == 1)
  f.sendBudget = nil
  _ = try f.send("history.import.batch", ["session_id": .string(session), "batch_number": .int(1), "records": .array(f.records)])
  await f.run(app, until: { f.progress?.isComplete == true })
  #expect(try f.journal().sessions[session]?.ids == ids)
  #expect(f.receipts[session]?.count == 1)
}

@Test @MainActor func finalReceiptFinishesPausedImportAndWithdrawalsStillRun() async throws {
  let f = try ImportFixture(1)
  defer { f.clean() }
  let app = f.make()
  f.failAfter = "batch"
  await f.run(app, until: { f.progress?.hasPendingReceipt == true })
  try await app.setPaused(true)
  await f.run(app, until: { f.progress?.isComplete == true })
  #expect(f.progress?.isPaused == false)
  f.events = [.init(id: try #require(f.records[0]["id"]?.stringValue), kind: .deleted)]
  await app.tick()
  #expect(f.applied == f.events)
}

@Test @MainActor func historyIssuesCanBeKeptAndRetriedIndividuallyAfterRestart() async throws {
  let f = try ImportFixture(2)
  defer { f.clean() }
  let ids = f.records.compactMap { $0["id"]?.stringValue }
  f.outcomes = [ids[0]: "conflict", ids[1]: "rejected"]
  let app = f.make()
  await f.run(app, until: { f.progress?.isComplete == true })
  try await app.abandonIssue(id: ids[1])
  #expect(f.progress?.issues.contains(.init(id: ids[1], category: "kept_in_backup")) == true)
  f.outcomes[ids[0]] = "added"
  try await app.retryIssue(id: ids[0])
  f.failAfter = "batch"
  await app.tick()
  #expect(f.backup?.canDelete == false)
  let restarted = f.make()
  await f.run(restarted, until: { f.progress?.hasPendingReceipt == false })
  #expect(f.progress?.needsAttention == 0)
  #expect(f.backup?.unuploadedCount == 1)
  #expect(f.progress?.confirmed == 1)
  #expect(f.receipts.values.map(\.count).sorted() == [1, 1])
}

@Test @MainActor func historyBackupDoesNotPublishOldPrivateCountOnReconnect() async throws {
  let f = try ImportFixture(1)
  defer { f.clean() }
  let app = f.make()
  await f.run(app, until: { f.progress?.isComplete == true })
  #expect(f.backup?.privateCount == 1)
  f.binding = HubBinding(generation: 3, target: .remote, phase: .committed, remote: f.remote)
  f.privateCount = 9
  f.newCapture = true
  await app.tick()
  #expect(f.backup?.privateCount == nil)
  f.newCapture = false
  await app.tick()
  #expect(f.backup?.privateCount == 9)
}

@Test @MainActor func privateChainAbsentFromReExportCanStillBeDeletedUsingOldMapping() async throws {
  let f = try ImportFixture(1)
  defer { f.clean() }
  let id = try #require(f.records[0]["id"]?.stringValue)
  let app = f.make()
  await f.run(app, until: { f.progress?.isComplete == true })
  f.events = [.init(id: id, kind: .private)]
  await app.tick()
  #expect(f.applied == f.events)

  f.records = []
  f.snapshot = String(repeating: "b", count: 64)
  f.deviceID = "mac-new"
  f.binding = HubBinding(generation: 2, target: .remote, phase: .committed, remote: f.remote)
  let repaired = f.make()
  await repaired.tick()
  f.events.append(.init(id: id, kind: .deleted))
  #expect(await repaired.reconcileForReturn(on: f.binding.route) == .reconciled)
  #expect(f.applied == f.events)
}

// 2026-11-24 终审回归：重试收据已保存，重新上线时续期同一会话。
@Test @MainActor func finalReviewRetryRenewsExpiredFinish() async throws {
  let f = try ImportFixture(1)
  defer { f.clean() }
  let id = try #require(f.records.first?["id"]?.stringValue)
  f.outcomes[id] = "conflict"
  let app = f.make()
  await f.run(app, until: { f.progress?.isComplete == true })
  f.outcomes[id] = "added"
  try await app.retryIssue(id: id)
  f.failAfter = "finish"
  await app.tick()
  let retry = try #require(f.journal().retry)
  #expect(retry.received)
  let session = try #require(retry.session)
  f.expiredSessions.insert(session)
  await f.make().tick()
  #expect(try f.journal().retry == nil)
  #expect(f.receipts[session]?.count == 1)
}

// 2026-11-24 终审回归：换身份后补删备份，落盘的代次与新身份一致。
@Test @MainActor func finalReviewBackupDeletionKeepsNewGeneration() async throws {
  let f = try ImportFixture()
  defer { f.clean() }
  let app = f.make()
  await f.run(app, until: { f.progress?.isComplete == true })
  var journal = try f.journal()
  journal.backup = .deleting
  try f.store(journal)
  f.deviceID = "mac-replacement"
  f.binding = HubBinding(generation: 2, target: .remote, phase: .committed, remote: f.remote)
  await app.tick()
  #expect(try f.journal().generation == 2)
  #expect(f.backup?.recovery == .emptyLocalBackend)
}

// 2026-11-24 终审回归：旧日志标记已删，切回后新封存的历史仍会同步。
@Test @MainActor func finalReviewLegacyDeletedBackupDoesNotHideNewHistory() async throws {
  let f = try ImportFixture(1)
  defer { f.clean() }
  var journal = HistoryImportJournal(generation: 1, deviceID: nil)
  journal.backup = .deleted
  try f.store(journal)
  f.binding = HubBinding(generation: 3, target: .remote, phase: .committed, remote: f.remote)
  await f.run(f.make(), until: { f.progress?.confirmed == 1 })
  #expect(f.backup?.recovery == .frozenLocalHistory)
}

// 2026-11-24 虚拟机联调回归：切回本机后用新身份再切出，备份日期是这次封存的时间，不沿用第一次的。
@Test @MainActor func refrozenBackupWithNewIdentityShowsNewFreezeDate() async throws {
  let f = try ImportFixture(1)
  defer { f.clean() }
  let first = Date(timeIntervalSince1970: 1_795_480_000), second = Date(timeIntervalSince1970: 1_795_490_000)
  f.binding = HubBinding(generation: 1, target: .remote, phase: .committed, remote: f.remote, updatedAt: first)
  await f.run(f.make(), until: { f.progress?.isComplete == true })
  #expect(f.backup?.frozenAt == first)
  f.deviceID = "mac-replaced"
  f.binding = HubBinding(generation: 3, target: .remote, phase: .committed, remote: f.remote, updatedAt: second)
  f.backup = nil
  await f.run(f.make(), until: { f.backup != nil })
  #expect(f.backup?.frozenAt == second)
}

// 2026-11-24 终审回归：直连断开后的超限重试用空批收尾，原记录仍可处理。
@Test @MainActor func finalReviewOversizeRetryCanFinishThroughSmallerChannel() async throws {
  let f = try ImportFixture(2)
  defer { f.clean() }
  let ids = f.records.compactMap { $0["id"]?.stringValue }
  f.records[1] = .object(["id": .string(ids[1]), "body": .string("correction"), "corrects": .string(ids[0])])
  f.outcomes[ids[1]] = "conflict"
  let app = f.make()
  await f.run(app, until: { f.progress?.isComplete == true })
  try await app.retryIssue(id: ids[1])
  f.beforeSend = { op in
    if op == "history.import.batch" { f.sendBudget = 110 }
  }
  await app.tick()
  #expect(try f.journal().retry?.fencing == true)
  f.beforeSend = nil
  await f.run(f.make(), until: { f.progress?.hasPendingReceipt == false })
  #expect(f.progress?.issues == [.init(id: ids[1], category: "batch_too_large")])
  #expect(f.backup?.canDelete == true)
}

// 2026-11-24 终审回归：在途批次还在等回执时，暂停立即发布。
@Test @MainActor func finalReviewPausePublishesWhileReceiptIsInFlight() async throws {
  let f = try ImportFixture(2)
  defer { f.clean() }
  let app = f.make()
  await app.tick()
  await app.tick()
  var receipt: CheckedContinuation<Void, Never>?
  f.beforeSend = { op in
    if op == "history.import.batch" {
      await withCheckedContinuation { receipt = $0 }
    }
  }
  let tick = Task { await app.tick() }
  for _ in 0..<100 where receipt == nil { try await Task.sleep(for: .milliseconds(5)) }
  let pending = try #require(receipt)
  do {
    defer { pending.resume() }
    try await app.setPaused(true)
    #expect(f.progress?.isPaused == true)
  }
  await tick.value
}
