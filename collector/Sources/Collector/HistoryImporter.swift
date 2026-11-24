import CollectorCore
import CryptoKit
import Foundation

@MainActor final class HistoryImporter {
  enum Failure: Error { case busy, backupUnavailable, deletionBlocked, invalidReceipt, changedSnapshot, offline, unreconciled, issueUnavailable }

  struct Operations {
    var binding: () throws -> HubBinding
    var budget: (HubBinding.Route) async throws -> Int
    var send: (HubBinding.Route, String, [String: DeviceJSON]) async throws -> Data
    var export: (String?, Int) async throws -> HistoryExportPage
    var apply: ([HistoryWithdrawal]) async throws -> Void
    var mayImport: (HubBinding.Route) async -> Bool = { _ in true }
    var now: () -> Date = Date.init
    var deviceID: (HubBinding.Remote) throws -> String? = { _ in nil }
  }

  let operations: Operations
  private let directory: URL
  private let files: HistoryBackupFiles
  private let pageSize: Int
  private let gate: RemoteSwitchWriteGate
  private var active = false
  private var updatingPause = false
  private var lastError: String?
  private var nextCheck: Date = .distantPast
  private var lastRoute: HubBinding.Route?
  private var lastPresentation: (route: HubBinding.Route, progress: HistoryImportProgress, backup: HistoryBackupInfo?)?
  var onChange: ((HistoryImportProgress?, HistoryBackupInfo?) -> Void)?

  init(directory: URL, gate: RemoteSwitchWriteGate, pageSize: Int = 40, operations: Operations) {
    self.directory = directory
    self.files = HistoryBackupFiles(directory: directory)
    self.gate = gate
    self.pageSize = pageSize
    self.operations = operations
  }

  nonisolated static func validID(_ id: String) -> Bool {
    id.utf8.count == 26 && id.utf8.allSatisfy { "0123456789ABCDEFGHJKMNPQRSTVWXYZ".utf8.contains($0) }
  }

  func tick() async {
    guard !active, !gate.isPaused else { return }
    do {
      let binding = try operations.binding()
      guard binding.phase == .committed, binding.route.remote != nil else {
        lastRoute = nil
        onChange?(nil, nil)
        return
      }
      if lastRoute != binding.route {
        lastRoute = binding.route
        nextCheck = .distantPast
        lastError = nil
      }
      try gate.begin()
      active = true
      if var presentation = lastPresentation, presentation.route == binding.route, presentation.backup?.canDelete == true {
        presentation.backup?.canDelete = false
        onChange?(presentation.progress, presentation.backup)
      }
      defer { active = false; gate.end(); publish() }
      try await step(on: binding.route)
      lastError = nil
    } catch {
      lastError = Self.category(error)
      publish()
    }
  }

  private func step(on route: HubBinding.Route) async throws {
    var state = try load(on: route)
    if let legacy = state.legacyWriter, let session = legacy.session {
      do {
        let status: HistoryImportRemoteProgress = try await send("status", ["session_id": .string(session)], on: route)
        guard status.session_id == session, status.snapshot_id == legacy.snapshot,
              status.hub_id == route.remote?.hub_id else { throw Failure.invalidReceipt }
        state.attempt = legacy
        state.sessions[session]?.withdrawalOnly = nil
        state.unverifiedPreviousIDs?.subtract(legacy.pending ?? [])
        if legacy.pending != nil { state.sourceCheckedGeneration = route.generation }
      } catch DeviceClientError.operationError(_, 404, "session_unknown") {
        // This identity cannot upload into the old writer's session.
      }
      state.legacyWriter = nil
      try save(state, on: route)
    }
    if state.backup == .deleting {
      guard let remote = route.remote else { throw Failure.backupUnavailable }
      let saved = state
      _ = try await Task.detached(priority: .utility) { [files] in
        try Self.finishDeleting(saved, files: files, remote: remote, generation: route.generation)
      }.value
      return
    }
    guard state.backup == .available else { return }
    let attempt = state.attempt
    if state.sourceCheckedGeneration != route.generation || attempt == nil {
      guard !state.paused, await operations.mayImport(route), !gate.isPaused else { return }
      let first = try await operations.export(nil, pageSize)
      if attempt?.snapshot != first.snapshot_id {
        state.attempt = try newAttempt(first)
      }
      state.backupPrivateCount = first.private_count
      state.sourceCheckedGeneration = route.generation
      try save(state, on: route)
      return
    }
    if attempt?.pending != nil {
      guard await operations.mayImport(route), !gate.isPaused else { return }
      // Pausing cannot abandon a receipt in flight.
      try await uploadPending(&state, on: route)
      return
    }
    if let attempt, attempt.reachedEnd, !attempt.finished {
      guard !gate.isPaused else { return }
      try await finish(attempt, state: &state, on: route)
      return
    }
    if attempt?.finished == true {
      if state.retry != nil {
        guard await operations.mayImport(route), !gate.isPaused else { return }
        try await processRetry(&state, on: route)
        return
      }
      // Withdrawals change the frozen file's snapshot fingerprint. Wait until
      // the active export has finished before applying them to the backup.
      if !state.sessions.isEmpty, operations.now() >= nextCheck {
        nextCheck = operations.now().addingTimeInterval(60)
        try await reconcileSessions(&state, on: route)
      }
      return
    }
    guard !state.paused, await operations.mayImport(route), !gate.isPaused else { return }
    guard let attempt else { return }
    let page: HistoryExportPage
    do { page = try await readPage(attempt) }
    catch FrozenHistoryCommands.Failure.snapshotChanged, Failure.changedSnapshot {
      let first = try await operations.export(nil, pageSize)
      state.attempt = try newAttempt(first)
      state.backupPrivateCount = first.private_count
      try save(state, on: route)
      return
    }
    if attempt.session == nil {
      try await begin(page, state: &state, on: route)
      return
    }
    if attempt.offset == page.records.count {
      try advance(page, by: 0, state: &state, on: route)
      return
    }
    let budget = try await operations.budget(route)
    guard await operations.mayImport(route), !gate.isPaused, try !load(on: route).paused else { return }
    let ids = try Self.batchIDs(page.records.dropFirst(attempt.offset), budget: budget)
    if ids.isEmpty {
      guard let id = page.records[attempt.offset]["id"]?.stringValue else { throw Failure.invalidReceipt }
      state.attempt?.issues.append(.init(id: id, category: "batch_too_large"))
      try advance(page, by: 1, state: &state, on: route)
    } else {
      state.attempt?.pending = ids
      state.attempt?.pendingSent = false
      try save(state, on: route)
      try await uploadPending(&state, on: route, page: page)
    }
  }

  private func newAttempt(_ page: HistoryExportPage) throws -> HistoryImportJournal.Attempt {
    guard page.total >= 0, page.private_count >= 0 else { throw Failure.invalidReceipt }
    return .init(snapshot: page.snapshot_id, total: page.total, pageSize: pageSize, privateCount: page.private_count)
  }

  private func readPage(_ attempt: HistoryImportJournal.Attempt) async throws -> HistoryExportPage {
    let page = try await operations.export(attempt.cursor, attempt.pageSize)
    guard page.snapshot_id == attempt.snapshot else { throw Failure.changedSnapshot }
    guard page.total == attempt.total, page.records.count <= attempt.pageSize,
          (0...page.records.count).contains(attempt.offset), page.next_cursor == nil || !page.records.isEmpty,
          page.next_cursor == nil || page.next_cursor != attempt.cursor else { throw Failure.invalidReceipt }
    return page
  }

  private func begin(_ page: HistoryExportPage, state: inout HistoryImportJournal, on route: HubBinding.Route) async throws {
    let reply: HistoryImportRemoteProgress = try await send("begin", beginBody(page, route: route), on: route)
    guard reply.hub_id == route.remote?.hub_id, reply.snapshot_id == page.snapshot_id,
          UUID(uuidString: reply.session_id) != nil, reply.next_batch_number == 1, reply.finished_at == nil else {
      throw Failure.invalidReceipt
    }
    state.attempt?.session = reply.session_id
    state.sessions[reply.session_id] = .init()
    try save(state, on: route)
  }

  private func beginBody(_ page: HistoryExportPage, route: HubBinding.Route) -> [String: DeviceJSON] {
    ["hub_id": .string(route.remote?.hub_id ?? ""), "snapshot_id": .string(page.snapshot_id), "identities": .array(page.identities)]
  }

  private func uploadPending(_ state: inout HistoryImportJournal, on route: HubBinding.Route, page: HistoryExportPage? = nil) async throws {
    guard let attempt = state.attempt, let ids = attempt.pending, let session = attempt.session else { throw Failure.invalidReceipt }
    let source: HistoryExportPage
    if let page { source = page } else { source = try await readPage(attempt) }
    let batch = Array(source.records.dropFirst(attempt.offset).prefix(ids.count))
    guard batch.compactMap({ $0["id"]?.stringValue }) == ids else { throw Failure.changedSnapshot }
    if gate.isPaused {
      try await resolvePending(&state, attempt: attempt, source: source, ids: ids, session: session, on: route)
      return
    }
    let sending = Array(batch.prefix(attempt.pendingLimit ?? batch.count))
    let sendingIDs = Array(ids.prefix(sending.count))
    var body: [String: DeviceJSON] = ["session_id": .string(session), "batch_number": .int(Int64(attempt.batch)), "records": .array(sending)]
    if sending.isEmpty { body["seal_empty"] = .bool(true) }
    let definitelyUnsent = attempt.pendingSent == false
    state.attempt?.pendingSent = true
    try save(state, on: route)
    let reply: HistoryImportReceipt
    do {
      reply = try await sendBatch(body, session: session, source: source, on: route)
    } catch DeviceClientError.envelopeTooLarge(let message) {
      try await resolvePending(&state, attempt: attempt, source: source, ids: ids, session: session, on: route,
                               definitivelyRejected: definitelyUnsent && message != "响应体超过限制")
      return
    } catch DeviceClientError.operationError(_, 413, _),
            DeviceClientError.operationError(_, _, "batch_too_large") {
      try await resolvePending(&state, attempt: attempt, source: source, ids: ids, session: session, on: route,
                               definitivelyRejected: definitelyUnsent)
      return
    } catch DeviceClientError.operationError(_, 409, "batch_changed") {
      try await resolvePending(&state, attempt: attempt, source: source, ids: ids, session: session, on: route)
      return
    }
    try reply.validate(session: session, batch: attempt.batch, ids: sendingIDs)
    if sending.isEmpty {
      try recordFencedOversize(&state, id: ids[0], source: source, on: route)
      return
    }
    let mapped = reply.items.filter { [.added, .exists, .deleted].contains($0.status) }.map(\.id)
    let issues = reply.items.filter { [.rejected, .conflict].contains($0.status) }
      .map { HistoryImportProgress.Issue(id: $0.id, category: Self.issueCategory($0)) }
    try acceptBatch(counts: reply.counts, mapped: mapped, issues: issues, state: &state,
                    source: source, session: session, on: route)
  }

  private func sendBatch(_ body: [String: DeviceJSON], session: String, source: HistoryExportPage,
                         on route: HubBinding.Route) async throws -> HistoryImportReceipt {
    do { return try await send("batch", body, on: route) }
    catch DeviceClientError.operationError(_, _, "authorization_expired") {
      guard !gate.isPaused else { throw Failure.busy }
      let renewal: HistoryImportRemoteProgress = try await send("begin", beginBody(source, route: route), on: route)
      guard renewal.session_id == session, renewal.snapshot_id == source.snapshot_id, renewal.hub_id == route.remote?.hub_id else {
        throw Failure.invalidReceipt
      }
      guard !gate.isPaused else { throw Failure.busy }
      return try await send("batch", body, on: route)
    }
  }

  private func resolvePending(_ state: inout HistoryImportJournal, attempt: HistoryImportJournal.Attempt,
                              source: HistoryExportPage, ids: [String], session: String,
                              on route: HubBinding.Route, definitivelyRejected: Bool = false) async throws {
    let body: [String: DeviceJSON] = ["session_id": .string(session), "read_nonce": .string(UUID().uuidString)]
    let remote: HistoryImportRemoteProgress = try await send("status", body, on: route)
    guard remote.session_id == session, remote.snapshot_id == attempt.snapshot,
          remote.hub_id == route.remote?.hub_id else { throw Failure.invalidReceipt }
    if remote.next_batch_number == attempt.batch + 1 {
      // The previous transport committed the full batch. Reconcile it through
      // small read-only requests rather than replaying a now-oversized body.
      guard let totals = remote.counts,
            let counts = totals.subtracting(attempt.counts, batchSize: ids.count) else { throw Failure.invalidReceipt }
      if counts.total == 0 {
        guard attempt.pendingLimit == 0 else { throw Failure.invalidReceipt }
        try recordFencedOversize(&state, id: ids[0], source: source, on: route)
        return
      }
      let verification = try await verification(Array(ids.prefix(counts.total)), session: session, route: route)
      let mapped = verification.filter { $0.status != .unknown }.map(\.id)
      let issues = verification.filter { $0.status == .unknown }
        .map { HistoryImportProgress.Issue(id: $0.id, category: "batch_item_not_imported") }
      guard issues.count == counts.conflict + counts.rejected else { throw Failure.unreconciled }
      try acceptBatch(counts: counts, mapped: mapped, issues: issues, state: &state,
                      source: source, session: session, on: route)
      return
    }
    guard remote.next_batch_number == attempt.batch, remote.finished_at == nil else { throw Failure.invalidReceipt }
    if gate.isPaused {
      // A read of the next batch number does not fence earlier deliveries.
      guard attempt.pendingSent == false else { throw Failure.unreconciled }
      state.attempt?.pending = nil
      state.attempt?.pendingLimit = nil
      try save(state, on: route)
      return
    }
    let budget = try await operations.budget(route)
    let sendingCount = attempt.pendingLimit ?? ids.count
    let records = source.records.dropFirst(attempt.offset).prefix(sendingCount)
    let fitting = try Self.batchIDs(records, budget: budget)
    let reducedCount = min(fitting.count, sendingCount / 2)
    if reducedCount == 0, definitivelyRejected {
      state.attempt?.pending = nil
      state.attempt?.pendingLimit = nil
      state.attempt?.pendingSent = nil
      state.attempt?.issues.append(.init(id: ids[0], category: "batch_too_large"))
      try advance(source, by: 1, state: &state, on: route)
    } else {
      // A prefix (or the empty fence) competes for the existing batch number.
      // Preserve the original IDs until one fingerprint is durably confirmed.
      guard sendingCount > 0 else { throw Failure.unreconciled }
      state.attempt?.pendingLimit = reducedCount
      state.attempt?.pendingSent = !definitivelyRejected
      try save(state, on: route)
    }
  }

  private func recordFencedOversize(_ state: inout HistoryImportJournal, id: String,
                                     source: HistoryExportPage, on route: HubBinding.Route) throws {
    state.attempt?.pending = nil
    state.attempt?.pendingLimit = nil
    state.attempt?.pendingSent = nil
    state.attempt?.batch += 1
    state.attempt?.issues.append(.init(id: id, category: "batch_too_large"))
    try advance(source, by: 1, state: &state, on: route)
  }

  private func acceptBatch(counts: HistoryImportCounts, mapped: [String], issues: [HistoryImportProgress.Issue],
                           state: inout HistoryImportJournal, source: HistoryExportPage, session: String,
                           on route: HubBinding.Route) throws {
    guard var updated = state.attempt, var mapping = state.sessions[session] else { throw Failure.invalidReceipt }
    mapping.ids.append(contentsOf: mapped)
    state.unverifiedPreviousIDs?.subtract(mapped)
    if state.unverifiedPreviousIDs?.isEmpty == true { state.unverifiedPreviousIDs = nil }
    updated.issues.append(contentsOf: issues)
    updated.counts.add(counts)
    updated.pending = nil
    updated.pendingLimit = nil
    updated.pendingSent = nil
    updated.batch += 1
    state.attempt = updated
    state.sessions[session] = mapping
    try advance(source, by: counts.total, state: &state, on: route)
  }

  private func advance(_ page: HistoryExportPage, by count: Int, state: inout HistoryImportJournal, on route: HubBinding.Route) throws {
    guard var attempt = state.attempt, attempt.offset + count <= page.records.count else { throw Failure.invalidReceipt }
    attempt.offset += count
    if attempt.offset == page.records.count {
      attempt.cursor = page.next_cursor
      attempt.offset = 0
      attempt.reachedEnd = page.next_cursor == nil
    }
    state.attempt = attempt
    try save(state, on: route)
  }

  private func finish(_ attempt: HistoryImportJournal.Attempt, state: inout HistoryImportJournal, on route: HubBinding.Route) async throws {
    guard let session = attempt.session else { throw Failure.invalidReceipt }
    let body: [String: DeviceJSON] = ["session_id": .string(session)]
    let reply: HistoryImportRemoteProgress
    do { reply = try await send("finish", body, on: route) }
    catch DeviceClientError.operationError(_, _, "authorization_expired") {
      let page = try await operations.export(nil, attempt.pageSize)
      guard page.snapshot_id == attempt.snapshot else {
        state.attempt = try newAttempt(page)
        state.backupPrivateCount = page.private_count
        try save(state, on: route)
        return
      }
      let renewal: HistoryImportRemoteProgress = try await send("begin", beginBody(page, route: route), on: route)
      guard renewal.session_id == session else { throw Failure.invalidReceipt }
      reply = try await send("finish", body, on: route)
    }
    guard reply.session_id == session, reply.snapshot_id == attempt.snapshot, reply.finished_at != nil,
          reply.hub_id == route.remote?.hub_id, reply.next_batch_number == attempt.batch else { throw Failure.invalidReceipt }
    state.attempt?.finished = true
    state.paused = false
    try save(state, on: route, preservePause: false)
  }

  static func batchIDs(_ records: ArraySlice<DeviceJSON>, budget: Int) throws -> [String] {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.withoutEscapingSlashes]
    var ids: [String] = []
    var size = 0
    for record in records.prefix(200) {
      guard let id = record["id"]?.stringValue, validID(id) else { throw Failure.invalidReceipt }
      size += try encoder.encode(record).count + 1
      if size > budget { break }
      ids.append(id)
    }
    return ids
  }

  private static func issueCategory(_ item: HistoryImportReceipt.Item) -> String {
    let approved = ["record_conflict", "invalid_record", "out_of_scope", "private_record", "media_not_allowed", "device_collision",
                    "correction_target", "unsafe_source_ref"]
    return item.code.flatMap { approved.contains($0) ? $0 : nil } ?? item.status.rawValue
  }

  private func send<T: Decodable>(_ operation: String, _ body: [String: DeviceJSON], on route: HubBinding.Route) async throws -> T {
    guard try operations.binding().route == route else { throw HubBinding.Failure.changed }
    if gate.isPaused, !["status", "verify", "changes"].contains(operation) { throw Failure.busy }
    let bytes = try await operations.send(route, "history.import." + operation, body)
    guard try operations.binding().route == route else { throw HubBinding.Failure.changed }
    return try JSONDecoder().decode(T.self, from: bytes)
  }

  private func load(on route: HubBinding.Route) throws -> HistoryImportJournal {
    guard let remote = route.remote else { throw Failure.backupUnavailable }
    let deviceID = try operations.deviceID(remote)
    return try Self.readJournal(in: directory, route: route, remote: remote, deviceID: deviceID)
  }

  private nonisolated static func readJournal(in directory: URL, route: HubBinding.Route,
                                              remote: HubBinding.Remote, deviceID: String?) throws -> HistoryImportJournal {
    let bytes = try HistoryImportJournalFile.read(in: directory, for: remote)
    let saved = try bytes.map { try JSONDecoder().decode(HistoryImportJournal.self, from: $0) }
      ?? .init(generation: route.generation, deviceID: deviceID)
    return try Self.normalize(saved, on: route, deviceID: deviceID, directory: directory)
  }

  private nonisolated static func normalize(_ saved: HistoryImportJournal, on route: HubBinding.Route,
                                             deviceID: String?, directory: URL) throws -> HistoryImportJournal {
    var state = saved
    if state.generation != route.generation {
      // A legacy journal may have missed several generations of re-pairing.
      let replacedIdentity = state.deviceID.map { $0 != deviceID } ?? (deviceID != nil)
      // 切回本机再切出至少跨两代；新封存的库不能继承旧备份的删除状态。
      let refrozen = route.generation - state.generation >= 2 &&
        state.backup != .deleting && FileManager.default.fileExists(atPath: HistoryBackupFiles(directory: directory).database.path)
      // 备份日期只用于展示：换了新身份也是这次重新封存的库（2026-11-24 虚拟机联调发现仍显示第一次切换的时间）。
      if refrozen { state.frozenAt = nil }
      let newLocalBackup = refrozen && state.attempt == nil
      if newLocalBackup {
        state.backup = .available
        state.paused = false
        state.frozenAt = nil
        state.sourceCheckedGeneration = nil
        state.backupPrivateCount = nil
      }
      if replacedIdentity {
        // Write authority belongs to the old actor. Keep its read mappings for
        // withdrawals, and account separately for IDs without a receipt.
        var unverified = state.unverifiedPreviousIDs ?? []
        unverified.formUnion(state.attempt?.pending ?? [])
        state.unverifiedPreviousIDs = unverified.isEmpty ? nil : unverified
        if state.deviceID == nil && state.legacyWriter == nil { state.legacyWriter = state.attempt }
        state.attempt = nil
        state.retry = nil
        for key in state.sessions.keys { state.sessions[key]?.withdrawalOnly = true }
        state.sourceCheckedGeneration = nil
        if state.backup == .available { state.backupPrivateCount = nil }
      } else {
        guard state.attempt?.pending == nil, state.backup != .deleting else { throw Failure.unreconciled }
        state.paused = false
        state.backup = .available
        state.frozenAt = nil
      }
      state.lastReconciledAt = nil
    }
    state.deviceID = deviceID
    if let paused = try HistoryImportJournalFile.pause(in: directory, for: route) { state.paused = paused }
    if state.attempt?.finished == true { state.paused = false }
    return state
  }

  private func save(_ state: HistoryImportJournal, on route: HubBinding.Route, preservePause: Bool = true) throws {
    let binding = try operations.binding()
    guard binding.route == route, let remote = route.remote else { throw HubBinding.Failure.changed }
    var state = state
    if preservePause { state.paused = try load(on: route).paused }
    state.generation = route.generation
    if state.frozenAt == nil { state.frozenAt = DeviceProtocol.parseRFC3339(binding.updated_at) }
    try HistoryImportJournalFile.write(JSONEncoder().encode(state), in: directory, for: remote)
  }

  private struct Changes: Decodable {
    let changes: [HistoryWithdrawal]
    let cursor: Int
    let more: Bool
  }

  private struct Verification: Decodable {
    struct Item: Decodable {
      enum Status: String, Decodable { case present, deleted, `private`, unknown }
      let id: String
      let status: Status
    }
    let items: [Item]
  }

  private func reconcileSessions(_ state: inout HistoryImportJournal, on route: HubBinding.Route) async throws {
    var appliedChanges = false
    for session in state.sessions.keys.sorted() {
      guard let known = state.sessions[session] else { throw Failure.invalidReceipt }
      if known.ids.isEmpty { continue }
      let ids = Set(known.ids)
      var body: [String: DeviceJSON] = ["session_id": .string(session)]
      if known.withdrawalOnly == true { body["withdrawal_only"] = .bool(true) }
      var cursor = known.cursor
      var verified = false
      while true {
        try Task.checkCancellation()
        let reply: Changes
        do {
          reply = try await send("changes", body.merging(["after": .int(Int64(cursor))]) { _, after in after }, on: route)
        } catch DeviceClientError.operationError(_, _, "cursor_unknown") where !verified {
          appliedChanges = try await verify(known.ids, session: session, state: &state, route: route) || appliedChanges
          cursor = 0
          verified = true
          continue
        }
        guard reply.cursor >= cursor, reply.changes.count <= 200,
              reply.changes.allSatisfy({ ids.contains($0.id) }),
              reply.changes.isEmpty == (reply.cursor == cursor),
              !reply.more || !reply.changes.isEmpty else { throw Failure.invalidReceipt }
        if !reply.changes.isEmpty {
          try await applyWithdrawals(reply.changes, session: session, state: &state)
          appliedChanges = true
        }
        state.sessions[session]?.cursor = reply.cursor
        try save(state, on: route)
        if !reply.more { break }
        cursor = reply.cursor
      }
    }
    if appliedChanges {
      // Keep the import denominator tied to its original snapshot, while showing the
      // current private count in the backup after withdrawals.
      state.backupPrivateCount = try await operations.export(nil, 1).private_count
    }
    state.lastReconciledAt = operations.now()
    try save(state, on: route)
  }

  private func verify(_ ids: [String], session: String, state: inout HistoryImportJournal,
                      route: HubBinding.Route) async throws -> Bool {
    var appliedChanges = false
    for start in stride(from: 0, to: ids.count, by: 200) {
      let page = Array(ids[start..<min(start + 200, ids.count)])
      let items = try await verification(page, session: session, route: route, withdrawalOnly: state.sessions[session]?.withdrawalOnly == true)
      var withdrawals: [HistoryWithdrawal] = []
      for item in items {
        switch item.status {
        case .present: break
        case .unknown: throw Failure.unreconciled
        case .deleted: withdrawals.append(.init(id: item.id, kind: .deleted))
        case .private: withdrawals.append(.init(id: item.id, kind: .private))
        }
      }
      if !withdrawals.isEmpty {
        try await applyWithdrawals(withdrawals, session: session, state: &state)
        appliedChanges = true
      }
    }
    return appliedChanges
  }

  private func applyWithdrawals(_ withdrawals: [HistoryWithdrawal], session: String,
                                state: inout HistoryImportJournal) async throws {
    let alreadyDeleted = state.sessions.values.reduce(into: Set<String>()) {
      $0.formUnion($1.locallyDeletedIDs ?? [])
    }
    let applicable = withdrawals.filter { !alreadyDeleted.contains($0.id) }
    if !applicable.isEmpty { try await operations.apply(applicable) }
    let deleted = applicable.filter { $0.kind == .deleted }.map(\.id)
    if !deleted.isEmpty, var mapping = state.sessions[session] {
      mapping.locallyDeletedIDs = (mapping.locallyDeletedIDs ?? []).union(deleted)
      state.sessions[session] = mapping
    }
    if state.attempt?.finished == false { state.attempt = nil }
  }

  private func verification(_ ids: [String], session: String, route: HubBinding.Route,
                            withdrawalOnly: Bool = false) async throws -> [Verification.Item] {
    var body: [String: DeviceJSON] = ["session_id": .string(session), "ids": .array(ids.map(DeviceJSON.string))]
    if withdrawalOnly { body["withdrawal_only"] = .bool(true) }
    let reply: Verification = try await send("verify", body, on: route)
    guard reply.items.map(\.id) == ids else { throw Failure.invalidReceipt }
    return reply.items
  }

  /// Call while the switch coordinator holds its write pause.
  func reconcileForReturn(on route: HubBinding.Route) async -> HistoryReconcileResult {
    guard !active else { return .incomplete }
    active = true
    defer { active = false; publish() }
    do {
      var state = try load(on: route)
      if state.backup == .deleted { return .emptyLocalBackend }
      guard state.backup == .available, FileManager.default.fileExists(atPath: files.database.path) else { return .incomplete }
      guard state.retry == nil else { throw Failure.unreconciled }
      if state.attempt?.pending != nil { try await uploadPending(&state, on: route) }
      // A previously imported ID that conflicts under the new actor may be
      // private on the hub. Without a mapping we cannot safely reopen it.
      guard state.unverifiedPreviousIDs?.isEmpty != false else { throw Failure.unreconciled }
      if state.sessions.isEmpty {
        // A return still checks that the active destination is reachable, even if no
        // backup records were sent on this binding.
        _ = try await operations.send(route, "status.get", [:])
      }
      try await reconcileSessions(&state, on: route)
      lastError = nil
      return .reconciled
    } catch {
      lastError = Self.category(error)
      return .incomplete
    }
  }

  func retryIssue(id: String) async throws {
    try await changeIssue(id: id, retry: true)
  }

  func abandonIssue(id: String) async throws {
    try await changeIssue(id: id, retry: false)
  }

  private func changeIssue(id: String, retry: Bool) async throws {
    guard !active, !gate.isReturning, Self.validID(id) else { throw Failure.busy }
    let route = try committedRoute()
    let binding = try operations.binding()
    guard let remote = route.remote else { throw Failure.backupUnavailable }
    let deviceID = try operations.deviceID(remote)
    try gate.begin()
    active = true
    defer { active = false; gate.end() }
    let (loaded, backupSize) = try await Task.detached(priority: .utility) { [directory, files] in
      let state = try Self.readJournal(in: directory, route: route, remote: remote, deviceID: deviceID)
      return (state, try files.size())
    }.value
    var state = loaded
    guard Self.canDelete(state, generation: route.generation),
          let index = state.attempt?.issues.firstIndex(where: { $0.id == id }) else { throw Failure.issueUnavailable }
    if retry {
      let page = try await operations.export(nil, 1)
      let scope = SHA256.hash(data: Data((page.snapshot_id + UUID().uuidString).utf8))
        .map { String(format: "%02x", $0) }.joined()
      state.retry = .init(id: id, snapshot: page.snapshot_id, requestSnapshot: scope, identities: page.identities)
    } else {
      state.attempt?.issues[index] = .init(id: id, category: "kept_in_backup")
    }
    guard try operations.binding().route == route else { throw HubBinding.Failure.changed }
    let saved = state
    try await Task.detached(priority: .utility) { [directory] in
      try HistoryImportJournalFile.write(JSONEncoder().encode(saved), in: directory, for: remote)
    }.value
    lastError = nil
    active = false
    publish(binding, state: state, backupSize: backupSize)
  }

  private func findRetryRecord(_ id: String, snapshot: String, first: HistoryExportPage) async throws -> DeviceJSON? {
    var page = first
    while true {
      try Task.checkCancellation()
      guard page.snapshot_id == snapshot else { throw Failure.changedSnapshot }
      if let record = page.records.first(where: { $0["id"]?.stringValue == id }) { return record }
      guard let cursor = page.next_cursor else { return nil }
      page = try await operations.export(cursor, pageSize)
    }
  }

  private func processRetry(_ state: inout HistoryImportJournal, on route: HubBinding.Route) async throws {
    guard var retry = state.retry, let identity = route.remote else { return }
    if !retry.received {
      var fencedEmpty = false
      let first = try await operations.export(nil, pageSize)
      guard let record = try await findRetryRecord(retry.id, snapshot: retry.snapshot, first: first) else {
        state.retry = nil
        try save(state, on: route)
        throw Failure.issueUnavailable
      }
      var batch = [record]
      if let corrects = record["corrects"]?.stringValue {
        guard let original = try await findRetryRecord(corrects, snapshot: retry.snapshot, first: first) else {
          state.retry = nil
          try save(state, on: route)
          throw Failure.issueUnavailable
        }
        batch.insert(original, at: 0)
      }
      let ids = batch.compactMap { $0["id"]?.stringValue }
      if retry.session == nil {
        guard try await Self.batchIDs(batch[...], budget: operations.budget(route)).count == ids.count else {
          state.retry = nil
          try save(state, on: route)
          throw DeviceClientError.envelopeTooLarge(message: nil)
        }
      }
      let identities = retry.identities ?? first.identities
      let remote = try await renewRetry(retry, identities: identities, on: route)
      retry.session = remote.session_id
      retry.identities = identities
      state.retry = retry
      try save(state, on: route)
      var items: [HistoryImportReceipt.Item] = []
      var mapped: [String] = []
      let body: [String: DeviceJSON] = ["session_id": .string(remote.session_id), "batch_number": .int(1)]
      do {
        var request = body
        if retry.fencing == true {
          request["records"] = .array([])
          request["seal_empty"] = .bool(true)
        } else {
          request["records"] = .array(batch)
        }
        let receipt: HistoryImportReceipt = try await send("batch", request, on: route)
        try receipt.validate(session: remote.session_id, batch: 1, ids: retry.fencing == true ? [] : ids)
        items = receipt.items
        fencedEmpty = items.isEmpty
        mapped = items.filter { [.added, .exists, .deleted].contains($0.status) }.map(\.id)
      } catch DeviceClientError.envelopeTooLarge where retry.fencing != true,
              DeviceClientError.operationError(_, 413, _) where retry.fencing != true,
              DeviceClientError.operationError(_, _, "batch_too_large") where retry.fencing != true {
        // 用同一批次号的空批封口，防止直连上的旧请求稍后落库。
        state.retry?.fencing = true
        try save(state, on: route)
        return
      } catch DeviceClientError.operationError(_, 409, "batch_changed") where retry.fencing == true {
        let status: HistoryImportRemoteProgress = try await send("status", [
          "session_id": .string(remote.session_id), "read_nonce": .string(UUID().uuidString),
        ], on: route)
        guard status.session_id == remote.session_id, status.snapshot_id == retry.requestSnapshot,
              status.hub_id == identity.hub_id, status.next_batch_number == 2,
              let count = status.counts?.total, count == 0 || count == ids.count else { throw Failure.invalidReceipt }
        fencedEmpty = count == 0
        if count > 0 {
          let verified = try await verification(ids, session: remote.session_id, route: route)
          mapped = verified.filter { $0.status != .unknown }.map(\.id)
          guard mapped.count == (status.counts?.added ?? 0) + (status.counts?.exists ?? 0) + (status.counts?.deleted ?? 0)
          else { throw Failure.unreconciled }
          if let item = verified.first(where: { $0.id == retry.id }), mapped.contains(retry.id) {
            items = [.init(id: retry.id, status: item.status == .deleted ? .deleted : .exists, remote_id: nil, code: nil)]
          }
        }
      }
      state.sessions[remote.session_id] = .init(ids: mapped)
      if let last = items.last, mapped.contains(retry.id) {
        state.attempt?.issues.removeAll { $0.id == retry.id }
        state.unverifiedPreviousIDs?.remove(retry.id)
        var retried = state.attempt?.retried ?? .init()
        if last.status == .deleted { retried.deleted += 1 }
        else if last.status == .exists { retried.exists += 1 }
        else { retried.added += 1 }
        state.attempt?.retried = retried
      } else if let index = state.attempt?.issues.firstIndex(where: { $0.id == retry.id }) {
        let category = items.last.map(Self.issueCategory) ?? (fencedEmpty ? "batch_too_large" : "batch_item_not_imported")
        state.attempt?.issues[index] = .init(id: retry.id, category: category)
      }
      retry.received = true
      state.retry = retry
      try save(state, on: route)
    }
    guard let session = retry.session else { throw Failure.invalidReceipt }
    let body: [String: DeviceJSON] = ["session_id": .string(session)]
    let reply: HistoryImportRemoteProgress
    do { reply = try await send("finish", body, on: route) }
    catch DeviceClientError.operationError(_, _, "authorization_expired") {
      let identities: [DeviceJSON]
      if let saved = retry.identities { identities = saved }
      else { identities = try await operations.export(nil, 1).identities }
      _ = try await renewRetry(retry, identities: identities, on: route)
      reply = try await send("finish", body, on: route)
    }
    guard reply.session_id == session, reply.hub_id == identity.hub_id, reply.snapshot_id == retry.requestSnapshot,
          reply.next_batch_number == 2, reply.finished_at != nil else { throw Failure.invalidReceipt }
    state.retry = nil
    try save(state, on: route)
  }

  private func renewRetry(_ retry: HistoryImportJournal.Retry, identities: [DeviceJSON],
                          on route: HubBinding.Route) async throws -> HistoryImportRemoteProgress {
    let reply: HistoryImportRemoteProgress = try await send("begin", [
      "hub_id": .string(route.remote?.hub_id ?? ""), "snapshot_id": .string(retry.requestSnapshot), "identities": .array(identities),
    ], on: route)
    guard reply.hub_id == route.remote?.hub_id, reply.snapshot_id == retry.requestSnapshot,
          UUID(uuidString: reply.session_id) != nil, retry.session == nil || retry.session == reply.session_id else {
      throw Failure.invalidReceipt
    }
    return reply
  }

  func setPaused(_ paused: Bool) async throws {
    guard !updatingPause else { throw Failure.busy }
    try gate.begin()
    updatingPause = true
    defer { updatingPause = false; gate.end() }
    let route = try committedRoute()
    try await Task.detached(priority: .utility) { [directory] in
      try HistoryImportJournalFile.setPause(paused, in: directory, for: route)
    }.value
    // 在途批次仍会结算，用上次发布的状态立即反馈暂停。
    if try operations.binding().route == route, var presentation = lastPresentation, presentation.route == route {
      presentation.progress.isPaused = paused && !presentation.progress.isComplete
      lastPresentation = presentation
      if active { presentation.backup?.canDelete = false }
      onChange?(presentation.progress, presentation.backup)
    }
  }

  func backupInfo() throws -> HistoryBackupInfo {
    let binding = try operations.binding()
    guard binding.phase == .committed, binding.route.remote != nil else { throw Failure.backupUnavailable }
    return try backupInfo(binding, state: load(on: binding.route))
  }

  func deleteBackup() async throws {
    guard !active, !gate.isPaused, !gate.isReturning else { throw Failure.deletionBlocked }
    let route = try committedRoute()
    let binding = try operations.binding()
    guard let remote = route.remote else { throw Failure.backupUnavailable }
    try gate.begin()
    active = true
    defer { active = false; gate.end() }
    let deviceID = try operations.deviceID(remote)
    let state = try await Task.detached(priority: .utility) { [directory, files] in
      guard let bytes = try HistoryImportJournalFile.read(in: directory, for: remote) else { throw Failure.deletionBlocked }
      let saved = try JSONDecoder().decode(HistoryImportJournal.self, from: bytes)
      var state = try Self.normalize(saved, on: route, deviceID: deviceID, directory: directory)
      if state.backup == .deleted { return state }
      if state.backup == .available {
        guard Self.canDelete(state, generation: route.generation),
              FileManager.default.fileExists(atPath: files.database.path) else { throw Failure.deletionBlocked }
        state.backup = .deleting
        try HistoryImportJournalFile.write(JSONEncoder().encode(state), in: directory, for: remote)
      }
      return try Self.finishDeleting(state, files: files, remote: remote, generation: route.generation)
    }.value
    active = false
    publish(binding, state: state)
  }

  private nonisolated static func finishDeleting(_ saved: HistoryImportJournal, files: HistoryBackupFiles,
                                                  remote: HubBinding.Remote, generation: Int) throws -> HistoryImportJournal {
    try files.remove()
    var state = saved
    state.generation = generation
    state.backup = .deleted
    state.attempt = nil
    state.legacyWriter = nil
    state.sessions.removeAll()
    state.unverifiedPreviousIDs = nil
    state.backupPrivateCount = nil
    try HistoryImportJournalFile.write(JSONEncoder().encode(state), in: files.directory, for: remote)
    return state
  }

  func refreshPresentation(operationError: Error? = nil) async {
    if let operationError { lastError = Self.category(operationError) }
    guard !active, let binding = try? operations.binding(), binding.phase == .committed,
          let remote = binding.remote else { return }
    let route = binding.route
    let deviceID = try? operations.deviceID(remote)
    let state = try? await Task.detached(priority: .utility) { [directory] in
      try Self.readJournal(in: directory, route: route, remote: remote, deviceID: deviceID)
    }.value
    guard !active, let state, (try? operations.binding()) == binding else { return }
    publish(binding, state: state)
  }

  private func committedRoute() throws -> HubBinding.Route {
    let binding = try operations.binding()
    guard binding.phase == .committed, binding.route.remote != nil else { throw Failure.backupUnavailable }
    return binding.route
  }

  private nonisolated static func canDelete(_ state: HistoryImportJournal, generation: Int) -> Bool {
    state.backup == .available && state.sourceCheckedGeneration == generation &&
      state.attempt?.finished == true && state.attempt?.pending == nil && state.retry == nil
  }

  private func backupInfo(_ binding: HubBinding, state: HistoryImportJournal, size: Int64? = nil) throws -> HistoryBackupInfo {
    let attempt = state.sourceCheckedGeneration == binding.generation ? state.attempt : nil
    return .init(frozenAt: state.frozenAt ?? DeviceProtocol.parseRFC3339(binding.updated_at) ?? operations.now(),
      bytes: state.backup == .deleted ? 0 : try size ?? files.size(),
      privateCount: state.sourceCheckedGeneration == binding.generation ? state.backupPrivateCount ?? attempt?.privateCount : nil,
      unuploadedCount: attempt.map { max(0, $0.total - Self.confirmed($0)) },
      lastReconciledAt: state.lastReconciledAt,
      recovery: state.backup == .deleted ? .emptyLocalBackend : .frozenLocalHistory,
      canDelete: !active && !gate.isPaused && !gate.isReturning && Self.canDelete(state, generation: binding.generation))
  }

  private func publish() {
    guard let binding = try? operations.binding(), binding.phase == .committed,
          binding.route.remote != nil, let state = try? load(on: binding.route) else {
      onChange?(nil, nil)
      return
    }
    publish(binding, state: state)
  }

  private func publish(_ binding: HubBinding, state: HistoryImportJournal, backupSize: Int64? = nil) {
    let sourceChecked = state.sourceCheckedGeneration == binding.generation
    let attempt = sourceChecked ? state.attempt : nil
    let progress = HistoryImportProgress(confirmed: attempt.map(Self.confirmed) ?? 0, total: attempt?.total,
      alreadyPresent: (attempt?.counts.exists ?? 0) + (attempt?.retried?.exists ?? 0),
      skipped: (attempt?.counts.deleted ?? 0) + (attempt?.retried?.deleted ?? 0),
      issues: attempt?.issues ?? [], privateCount: sourceChecked ? state.backupPrivateCount ?? attempt?.privateCount : nil,
      lastReconciledAt: state.lastReconciledAt, isPaused: state.paused,
      isComplete: state.backup == .deleted || attempt?.finished == true,
      hasPendingReceipt: attempt?.pending != nil || state.retry != nil, errorCategory: lastError)
    let backup = try? backupInfo(binding, state: state, size: backupSize)
    lastPresentation = (binding.route, progress, backup)
    onChange?(progress, backup)
  }

  private static func confirmed(_ attempt: HistoryImportJournal.Attempt) -> Int {
    min(attempt.total, attempt.counts.added + attempt.counts.exists + attempt.counts.deleted + (attempt.retried?.total ?? 0))
  }

  private static func category(_ error: Error) -> String {
    switch error {
    case Failure.invalidReceipt, is DecodingError: return "receipt_invalid"
    case Failure.changedSnapshot, FrozenHistoryCommands.Failure.snapshotChanged: return "snapshot_changed"
    case Failure.backupUnavailable: return "backup_unavailable"
    case Failure.issueUnavailable: return "history_issue_unavailable"
    case FrozenHistoryCommands.Failure.subprocess: return "local_history_command_failed"
    case Failure.unreconciled: return "reconciliation_incomplete"
    case DeviceClientError.envelopeTooLarge: return "batch_requires_connection_with_more_capacity"
    case DeviceClientError.operationError(_, _, let category):
      let known = ["session_unknown", "scope_changed", "batch_changed", "batch_out_of_order", "hub_mismatch",
                   "authorization_expired", "device_collision", "batch_too_large", "invalid_scope"]
      return category.flatMap { known.contains($0) ? $0 : nil } ?? "remote_rejected"
    default: return "connection_or_storage_unavailable"
    }
  }
}
