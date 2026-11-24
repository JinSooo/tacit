import CollectorCore
import Foundation

struct HistoryImportProgress: Equatable, Sendable {
  struct Issue: Codable, Equatable, Sendable {
    let id: String
    let category: String
  }

  let confirmed: Int
  let total: Int?
  let alreadyPresent: Int
  let skipped: Int
  let issues: [Issue]
  let privateCount: Int?
  let lastReconciledAt: Date?
  var isPaused: Bool
  let isComplete: Bool
  let hasPendingReceipt: Bool
  let errorCategory: String?
  var needsAttention: Int { issues.filter { $0.category != "kept_in_backup" }.count }
}

struct HistoryBackupInfo: Equatable {
  enum Recovery: Equatable { case frozenLocalHistory, emptyLocalBackend }
  let frozenAt: Date
  let bytes: Int64
  let privateCount: Int?
  /// Counts the export-eligible records without a successful copy; other devices and excluded
  /// correction chains are also local-only and are described by the recovery range.
  let unuploadedCount: Int?
  let lastReconciledAt: Date?
  let recovery: Recovery
  var canDelete: Bool
  var recoveryAfterDeletion: Recovery { .emptyLocalBackend }
}

enum HistoryReconcileResult: Equatable {
  case reconciled, emptyLocalBackend, incomplete
}

struct HistoryExportPage: Decodable {
  let snapshot_id: String
  let identities: [DeviceJSON]
  let records: [DeviceJSON]
  let next_cursor: String?
  let total: Int
  let private_count: Int
}

struct HistoryWithdrawal: Codable, Equatable, Sendable {
  enum Kind: String, Codable, Sendable { case deleted, `private` }
  let id: String
  let kind: Kind
}

struct HistoryImportCounts: Codable, Equatable, Sendable {
  var added = 0
  var exists = 0
  var deleted = 0
  var conflict = 0
  var rejected = 0

  var total: Int { added + exists + deleted + conflict + rejected }

  func subtracting(_ older: Self, batchSize: Int) -> Self? {
    let pairs = [(added, older.added), (exists, older.exists), (deleted, older.deleted),
                 (conflict, older.conflict), (rejected, older.rejected)]
    guard pairs.allSatisfy({ current, previous in
      previous >= 0 && current >= previous && current - previous <= batchSize
    }) else { return nil }
    let delta = Self(added: added - older.added, exists: exists - older.exists, deleted: deleted - older.deleted,
                     conflict: conflict - older.conflict, rejected: rejected - older.rejected)
    return delta
  }

  mutating func add(_ other: Self) {
    added += other.added
    exists += other.exists
    deleted += other.deleted
    conflict += other.conflict
    rejected += other.rejected
  }
}

struct HistoryImportRemoteProgress: Decodable {
  let session_id: String
  let hub_id: String
  let snapshot_id: String
  let next_batch_number: Int
  let finished_at: String?
  let counts: HistoryImportCounts?
}

struct HistoryImportReceipt: Decodable {
  struct Item: Decodable {
    enum Status: String, Decodable { case added, exists, deleted, conflict, rejected }
    let id: String
    let status: Status
    let remote_id: String?
    let code: String?
  }

  let session_id: String
  let batch_number: Int
  let items: [Item]
  let counts: HistoryImportCounts

  func validate(session: String, batch: Int, ids: [String]) throws {
    guard session_id == session, batch_number == batch, items.map(\.id) == ids else {
      throw HistoryImporter.Failure.invalidReceipt
    }
    var computed = HistoryImportCounts()
    for item in items {
      switch item.status {
      case .added, .exists:
        guard let remoteID = item.remote_id, HistoryImporter.validID(remoteID) else {
          throw HistoryImporter.Failure.invalidReceipt
        }
        if item.status == .added { computed.added += 1 } else { computed.exists += 1 }
      case .deleted: computed.deleted += 1
      case .conflict: computed.conflict += 1
      case .rejected: computed.rejected += 1
      }
    }
    guard computed == counts else { throw HistoryImporter.Failure.invalidReceipt }
  }
}

struct HistoryImportJournal: Codable, Sendable {
  enum Backup: String, Codable, Sendable { case available, deleting, deleted }

  struct Session: Codable, Sendable {
    var cursor = 0
    var ids: [String] = []
    var locallyDeletedIDs: Set<String>?
    var withdrawalOnly: Bool?
  }

  struct Attempt: Codable, Sendable {
    let snapshot: String
    let total: Int
    let pageSize: Int
    var privateCount: Int
    var session: String?
    var cursor: String?
    var offset = 0
    var batch = 1
    var counts = HistoryImportCounts()
    var retried: HistoryImportCounts?
    var issues: [HistoryImportProgress.Issue] = []
    var pending: [String]?
    var pendingLimit: Int?
    var pendingSent: Bool?
    var reachedEnd = false
    var finished = false
  }

  struct Retry: Codable, Sendable {
    let id: String
    let snapshot: String
    let requestSnapshot: String
    var identities: [DeviceJSON]?
    var fencing: Bool?
    var session: String?
    var received = false
  }

  var retry: Retry?
  var legacyWriter: Attempt?
  var generation: Int
  var deviceID: String?
  var frozenAt: Date?
  var backup: Backup = .available
  var paused = false
  var lastReconciledAt: Date?
  var attempt: Attempt?
  var sourceCheckedGeneration: Int?
  var backupPrivateCount: Int?
  var sessions: [String: Session] = [:]
  // Re-pairing revokes old sessions. Keep only IDs that still need to be
  // matched by the new actor before this copy may be reopened locally.
  var unverifiedPreviousIDs: Set<String>?
}
