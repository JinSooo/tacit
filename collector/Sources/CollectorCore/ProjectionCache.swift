import CryptoKit
import Foundation
import SQLite3

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// 下推缓存中实际落盘的五类实体（对应 docs/contracts.md 6.9.1）。
public enum ProjectionEntityKind: String, Codable, CaseIterable, Equatable, Hashable, Sendable {
  case day
  case project
  case thread
  case projectContext = "project_context"
  case now
}

/// 变更流中的全部 kind（含只广播不落盘的 `record_gone`）。
public enum ProjectionChangeKind: String, Codable, CaseIterable, Equatable, Hashable, Sendable {
  case day
  case project
  case thread
  case projectContext = "project_context"
  case now
  case recordGone = "record_gone"

  public var entityKind: ProjectionEntityKind? {
    switch self {
    case .day: return .day
    case .project: return .project
    case .thread: return .thread
    case .projectContext: return .projectContext
    case .now: return .now
    case .recordGone: return nil
    }
  }
}

public enum ProjectionChangeOp: String, Codable, Equatable, Sendable {
  case upsert
  case delete
}

/// 单条投影变更项（6.9.2）。
public struct ProjectionChange: Codable, Equatable, Sendable {
  public let seq: Int64
  public let op: ProjectionChangeOp
  public let kind: ProjectionChangeKind
  public let id: String
  public let rev: Int64
  public let data: DeviceJSON?
  public let truncated: Bool?

  public init(
    seq: Int64,
    op: ProjectionChangeOp,
    kind: ProjectionChangeKind,
    id: String,
    rev: Int64,
    data: DeviceJSON? = nil,
    truncated: Bool? = nil
  ) {
    self.seq = seq
    self.op = op
    self.kind = kind
    self.id = id
    self.rev = rev
    self.data = data
    self.truncated = truncated
  }
}

/// `projection.pull` 响应结构（6.9.2）。
public struct ProjectionPage: Codable, Equatable, Sendable {
  public let epoch: Int64
  public let reset: Bool
  public let changes: [ProjectionChange]
  public let cursor: Int64
  public let more: Bool
  public let serverTime: String

  private enum CodingKeys: String, CodingKey {
    case epoch, reset, changes, cursor, more
    case serverTime = "server_time"
  }

  public init(
    epoch: Int64,
    reset: Bool,
    changes: [ProjectionChange],
    cursor: Int64,
    more: Bool,
    serverTime: String
  ) {
    self.epoch = epoch
    self.reset = reset
    self.changes = changes
    self.cursor = cursor
    self.more = more
    self.serverTime = serverTime
  }
}

/// `projection.invalidate` 中的单个失效项（6.9.5）。
public struct ProjectionInvalidateItem: Codable, Equatable, Hashable, Sendable {
  public let kind: ProjectionChangeKind
  public let id: String

  public init(kind: ProjectionChangeKind, id: String) {
    self.kind = kind
    self.id = id
  }
}

/// 本地持久化游标 `(epoch, seq)`。
public struct ProjectionCursor: Equatable, Sendable {
  public let epoch: Int64
  public let seq: Int64

  public static let zero = ProjectionCursor(epoch: 0, seq: 0)

  public init(epoch: Int64, seq: Int64) {
    self.epoch = epoch
    self.seq = seq
  }
}

/// 缓存中读取出的一条实体记录。
public struct ProjectionEntityRecord: Equatable, Sendable {
  public let kind: ProjectionEntityKind
  public let id: String
  public let rev: Int64
  public let truncated: Bool
  public let payloadData: Data
  public let updatedAtMs: Int64

  public init(
    kind: ProjectionEntityKind,
    id: String,
    rev: Int64,
    truncated: Bool,
    payloadData: Data,
    updatedAtMs: Int64
  ) {
    self.kind = kind
    self.id = id
    self.rev = rev
    self.truncated = truncated
    self.payloadData = payloadData
    self.updatedAtMs = updatedAtMs
  }

  public func decodeJSON() throws -> DeviceJSON {
    try JSONDecoder().decode(DeviceJSON.self, from: payloadData)
  }

  public func decode<T: Decodable>(_ type: T.Type, decoder: JSONDecoder = JSONDecoder()) throws -> T {
    try decoder.decode(type, from: payloadData)
  }
}

/// 应用一批变更或失效后的统计结果。
public struct ProjectionApplyResult: Equatable, Sendable {
  public let wasReset: Bool
  public let cursor: ProjectionCursor
  public let upsertedCount: Int
  public let deletedCount: Int
  public let goneRecordIDs: [String]
  public let invalidatedWidget: Bool

  public init(
    wasReset: Bool,
    cursor: ProjectionCursor,
    upsertedCount: Int,
    deletedCount: Int,
    goneRecordIDs: [String],
    invalidatedWidget: Bool
  ) {
    self.wasReset = wasReset
    self.cursor = cursor
    self.upsertedCount = upsertedCount
    self.deletedCount = deletedCount
    self.goneRecordIDs = goneRecordIDs
    self.invalidatedWidget = invalidatedWidget
  }
}

/// 保留策略与磁盘上限清理的结果统计。
public struct ProjectionPruneResult: Equatable, Sendable {
  public let expiredDaysDeleted: Int
  public let expiredArchivedThreadsDeleted: Int
  public let diskTrimDaysDeleted: Int
  public let finalDatabaseBytes: Int64

  public init(
    expiredDaysDeleted: Int,
    expiredArchivedThreadsDeleted: Int,
    diskTrimDaysDeleted: Int,
    finalDatabaseBytes: Int64
  ) {
    self.expiredDaysDeleted = expiredDaysDeleted
    self.expiredArchivedThreadsDeleted = expiredArchivedThreadsDeleted
    self.diskTrimDaysDeleted = diskTrimDaysDeleted
    self.finalDatabaseBytes = finalDatabaseBytes
  }
}

/// 下推缓存保留与空间上限配置（默认按 docs/contracts.md 6.9.6）。
public struct ProjectionCachePolicy: Equatable, Sendable {
  /// `day` 保留天数（默认 90 天）。
  public let dayRetentionDays: Int
  /// `archived` 事项保留天数（默认 30 天）。
  public let archivedThreadRetentionDays: Int
  /// 数据库文件磁盘硬上限（默认 128 MiB）。
  public let maxDiskBytes: Int64
  /// 超出磁盘上限时优先清理早于此天数的 `day`（默认 30 天）。
  public let diskTrimDayAgeDays: Int

  public static let `default` = ProjectionCachePolicy()

  public init(
    dayRetentionDays: Int = 90,
    archivedThreadRetentionDays: Int = 30,
    maxDiskBytes: Int64 = 128 * 1024 * 1024,
    diskTrimDayAgeDays: Int = 30
  ) {
    self.dayRetentionDays = max(1, dayRetentionDays)
    self.archivedThreadRetentionDays = max(1, archivedThreadRetentionDays)
    self.maxDiskBytes = max(4096, maxDiskBytes)
    self.diskTrimDayAgeDays = max(1, diskTrimDayAgeDays)
  }
}

/// 下推缓存错误。
public enum ProjectionCacheError: Error, Equatable, Sendable {
  case invalidPath(String)
  case symlinkRejected(String)
  case keychainFailure(Int32)
  case invalidKey
  case cryptoFailure(String)
  case sqliteError(code: Int32, message: String)
  case corruptedEntity(kind: String, id: String)
}

/// 下推缓存 32 字节对称密钥提供者（可注入内存实现，避免单测触碰真实钥匙串）。
public protocol ProjectionCacheKeyProvider: Sendable {
  func loadOrCreateKey() throws -> SymmetricKey
}

/// 内存密钥提供者（单测和临时缓存用，不碰钥匙串）。
public final class InMemoryProjectionCacheKeyProvider: ProjectionCacheKeyProvider, @unchecked Sendable {
  private let lock = NSLock()
  private var key: SymmetricKey

  public init(key: SymmetricKey = SymmetricKey(size: .bits256)) {
    self.key = key
  }

  public init(rawKey: Data) throws {
    guard rawKey.count == 32 else { throw ProjectionCacheError.invalidKey }
    self.key = SymmetricKey(data: rawKey)
  }

  public func loadOrCreateKey() throws -> SymmetricKey {
    lock.lock(); defer { lock.unlock() }
    return key
  }
}

/// 钥匙串密钥提供者：service `record-anything`、account `viewer-cache-key`，仅经 `/usr/bin/security` 读写。
public struct KeychainProjectionCacheKeyProvider: ProjectionCacheKeyProvider, Sendable {
  public static let service = "record-anything"
  public static let account = "viewer-cache-key"

  /// 参数和可选标准输入；写入经 `security -i` 走标准输入，密钥不进进程参数。
  public typealias SecurityRunner = @Sendable ([String], Data?) throws -> (status: Int32, text: String)

  private let service: String
  private let account: String
  private let runSecurity: SecurityRunner

  public init(
    service: String = KeychainProjectionCacheKeyProvider.service,
    account: String = KeychainProjectionCacheKeyProvider.account,
    runSecurity: @escaping SecurityRunner = { try KeychainProjectionCacheKeyProvider.systemSecurity($0, stdin: $1) }
  ) {
    self.service = service
    self.account = account
    self.runSecurity = runSecurity
  }

  public func loadOrCreateKey() throws -> SymmetricKey {
    if let existing = try readKey() { return existing }
    let created = SymmetricKey(size: .bits256)
    let hex = created.withUnsafeBytes { bytes in
      bytes.map { String(format: "%02x", $0) }.joined()
    }
    let command = try SecurityCLI.addGenericPasswordCommand(service: service, account: account, hexValue: hex)
    let added = try runSecurity(["-i"], command).status
    guard let stored = try readKey() else {
      throw ProjectionCacheError.keychainFailure(added == 0 ? -3 : added)
    }
    return stored
  }

  private func readKey() throws -> SymmetricKey? {
    let (status, text) = try runSecurity(["find-generic-password", "-s", service, "-a", account, "-w"], nil)
    if status == 44 { return nil }
    guard status == 0,
          text.count == 64,
          let raw = DeviceProtocol.hexDecode(text),
          raw.count == 32 else {
      throw ProjectionCacheError.keychainFailure(status == 0 ? -2 : status)
    }
    return SymmetricKey(data: raw)
  }

  /// 仅调用 `/usr/bin/security`，10 秒超时防止无限挂起。
  public static func systemSecurity(_ arguments: [String], stdin: Data? = nil) throws -> (status: Int32, text: String) {
    do { return try SecurityCLI.run(arguments, stdin: stdin) }
    catch let failure as SecurityCLI.Failure { throw ProjectionCacheError.keychainFailure(failure.status) }
  }
}

/// 逐行 AES-256-GCM 加密工具，AAD 绑定 `kind` + `entity_id` 防止整行调换。
public enum ProjectionCacheCrypto {
  /// 构造与实体身份绑定的 AAD：`"<kind>\0<entity_id>"`（kind 为固定枚举，不含 NUL，拼接无歧义）。
  public static func aad(kind: ProjectionEntityKind, entityID: String) -> Data {
    Data("\(kind.rawValue)\0\(entityID)".utf8)
  }

  public static func seal(
    _ plaintext: Data,
    kind: ProjectionEntityKind,
    entityID: String,
    using key: SymmetricKey
  ) throws -> Data {
    try seal(plaintext, aad: aad(kind: kind, entityID: entityID), using: key)
  }

  public static func seal(
    _ plaintext: Data,
    aad: Data,
    using key: SymmetricKey
  ) throws -> Data {
    do {
      let box = try AES.GCM.seal(plaintext, using: key, authenticating: aad)
      guard let combined = box.combined else {
        throw ProjectionCacheError.cryptoFailure("AES-GCM 密文组合失败")
      }
      return combined
    } catch let error as ProjectionCacheError {
      throw error
    } catch {
      throw ProjectionCacheError.cryptoFailure("AES-GCM 加密失败")
    }
  }

  public static func open(
    _ combined: Data,
    kind: ProjectionEntityKind,
    entityID: String,
    using key: SymmetricKey
  ) throws -> Data {
    try open(combined, aad: aad(kind: kind, entityID: entityID), using: key)
  }

  public static func open(
    _ combined: Data,
    aad: Data,
    using key: SymmetricKey
  ) throws -> Data {
    do {
      let box = try AES.GCM.SealedBox(combined: combined)
      return try AES.GCM.open(box, using: key, authenticating: aad)
    } catch {
      throw ProjectionCacheError.cryptoFailure("AES-GCM 解密或认证失败")
    }
  }
}

/// Mac 查看端下推结果的本地加密缓存（系统 SQLite3 + 逐行 AES-GCM）。
public final class ProjectionCache: @unchecked Sendable {
  public static let databaseFileName = "viewer-cache.db"

  public let dataDirectory: URL
  public let databaseURL: URL
  public let widgetSnapshotURL: URL?
  public let policy: ProjectionCachePolicy

  private let keyProvider: any ProjectionCacheKeyProvider
  private let clock: @Sendable () -> Date
  private let calendar: Calendar
  private let lock = NSLock()
  private var db: OpaquePointer?
  private var cachedKey: SymmetricKey?

  public init(
    dataDirectory: URL,
    widgetSnapshotURL: URL? = nil,
    keyProvider: any ProjectionCacheKeyProvider = KeychainProjectionCacheKeyProvider(),
    policy: ProjectionCachePolicy = .default,
    clock: @escaping @Sendable () -> Date = { Date() },
    calendar: Calendar = .current
  ) throws {
    self.dataDirectory = dataDirectory
    self.databaseURL = dataDirectory.appendingPathComponent(Self.databaseFileName)
    self.widgetSnapshotURL = widgetSnapshotURL
    self.keyProvider = keyProvider
    self.policy = policy
    self.clock = clock
    self.calendar = calendar
    try lock.withLock {
      _ = try openDatabaseLocked()
    }
  }

  deinit {
    lock.lock()
    closeLocked()
    lock.unlock()
  }

  // MARK: - 游标与中枢身份

  public func cursor() throws -> ProjectionCursor {
    try lock.withLock {
      guard db != nil || FileManager.default.fileExists(atPath: databaseURL.path) else {
        return .zero
      }
      let handle = try openDatabaseLocked()
      return try readCursorLocked(handle)
    }
  }

  public func storedHubID() throws -> String? {
    try lock.withLock {
      guard db != nil || FileManager.default.fileExists(atPath: databaseURL.path) else {
        return nil
      }
      let handle = try openDatabaseLocked()
      return try readMetaLocked(handle, key: "hub_id")
    }
  }

  public func lastSyncAt() throws -> String? {
    try lock.withLock {
      guard db != nil || FileManager.default.fileExists(atPath: databaseURL.path) else {
        return nil
      }
      let handle = try openDatabaseLocked()
      return try readMetaLocked(handle, key: "last_sync_at")
    }
  }

  /// 核对并绑定 `hub_id`：若已存有不同的 `hub_id`，立即整库 `wipe()` 并返回 `true`。
  @discardableResult
  public func ensureHubID(_ hubID: String) throws -> Bool {
    try lock.withLock {
      guard db != nil || FileManager.default.fileExists(atPath: databaseURL.path) else {
        let handle = try openDatabaseLocked()
        try writeMetaLocked(handle, key: "hub_id", value: hubID)
        return false
      }
      let handle = try openDatabaseLocked()
      if let existing = try readMetaLocked(handle, key: "hub_id"), existing != hubID {
        try wipeLocked()
        let fresh = try openDatabaseLocked()
        try writeMetaLocked(fresh, key: "hub_id", value: hubID)
        return true
      }
      try writeMetaLocked(handle, key: "hub_id", value: hubID)
      return false
    }
  }

  // MARK: - 读取实体

  public func get(kind: ProjectionEntityKind, id: String) throws -> ProjectionEntityRecord? {
    try lock.withLock {
      guard db != nil || FileManager.default.fileExists(atPath: databaseURL.path) else {
        return nil
      }
      let handle = try openDatabaseLocked()
      let key = try resolveKeyLocked()
      let sql = "SELECT rev, truncated, payload, updated_at_ms FROM projection_entities WHERE kind = ? AND entity_id = ? LIMIT 1;"
      var stmt: OpaquePointer?
      try check(sqlite3_prepare_v2(handle, sql, -1, &stmt, nil), handle: handle)
      defer { sqlite3_finalize(stmt) }
      try bindText(stmt, index: 1, value: kind.rawValue, handle: handle)
      try bindText(stmt, index: 2, value: id, handle: handle)
      let step = sqlite3_step(stmt)
      if step == SQLITE_DONE { return nil }
      guard step == SQLITE_ROW else { throw sqliteError(step, handle: handle) }
      let rev = sqlite3_column_int64(stmt, 0)
      let truncated = sqlite3_column_int(stmt, 1) != 0
      let blob = readBlob(stmt, column: 2)
      let updatedAtMs = sqlite3_column_int64(stmt, 3)
      let plaintext = try ProjectionCacheCrypto.open(blob, kind: kind, entityID: id, using: key)
      return ProjectionEntityRecord(
        kind: kind,
        id: id,
        rev: rev,
        truncated: truncated,
        payloadData: plaintext,
        updatedAtMs: updatedAtMs
      )
    }
  }

  public func list(kind: ProjectionEntityKind) throws -> [ProjectionEntityRecord] {
    try lock.withLock {
      guard db != nil || FileManager.default.fileExists(atPath: databaseURL.path) else {
        return []
      }
      let handle = try openDatabaseLocked()
      let key = try resolveKeyLocked()
      let sql = "SELECT entity_id, rev, truncated, payload, updated_at_ms FROM projection_entities WHERE kind = ? ORDER BY entity_id ASC;"
      var stmt: OpaquePointer?
      try check(sqlite3_prepare_v2(handle, sql, -1, &stmt, nil), handle: handle)
      defer { sqlite3_finalize(stmt) }
      try bindText(stmt, index: 1, value: kind.rawValue, handle: handle)
      var results: [ProjectionEntityRecord] = []
      while true {
        let step = sqlite3_step(stmt)
        if step == SQLITE_DONE { break }
        guard step == SQLITE_ROW else { throw sqliteError(step, handle: handle) }
        let id = readText(stmt, column: 0)
        let rev = sqlite3_column_int64(stmt, 1)
        let truncated = sqlite3_column_int(stmt, 2) != 0
        let blob = readBlob(stmt, column: 3)
        let updatedAtMs = sqlite3_column_int64(stmt, 4)
        let plaintext = try ProjectionCacheCrypto.open(blob, kind: kind, entityID: id, using: key)
        results.append(ProjectionEntityRecord(
          kind: kind,
          id: id,
          rev: rev,
          truncated: truncated,
          payloadData: plaintext,
          updatedAtMs: updatedAtMs
        ))
      }
      return results
    }
  }

  public func count(kind: ProjectionEntityKind? = nil) throws -> Int {
    try lock.withLock {
      guard db != nil || FileManager.default.fileExists(atPath: databaseURL.path) else {
        return 0
      }
      let handle = try openDatabaseLocked()
      let sql = kind == nil
        ? "SELECT COUNT(*) FROM projection_entities;"
        : "SELECT COUNT(*) FROM projection_entities WHERE kind = ?;"
      var stmt: OpaquePointer?
      try check(sqlite3_prepare_v2(handle, sql, -1, &stmt, nil), handle: handle)
      defer { sqlite3_finalize(stmt) }
      if let kind {
        try bindText(stmt, index: 1, value: kind.rawValue, handle: handle)
      }
      let step = sqlite3_step(stmt)
      guard step == SQLITE_ROW else { throw sqliteError(step, handle: handle) }
      return Int(sqlite3_column_int64(stmt, 0))
    }
  }

  // MARK: - 应用变更、失效、重置与清空

  /// 应用 `projection.pull` 返回的一页结果。若 `reset == true` 或 `epoch` 变化，先清空本地缓存并复位游标到 `(epoch, 0)`。
  public func applyPage(
    _ page: ProjectionPage,
    hubID: String? = nil,
    now: Date? = nil
  ) throws -> ProjectionApplyResult {
    try lock.withLock {
      let handle = try openDatabaseLocked()
      let current = try readCursorLocked(handle)
      if page.reset || (current.epoch != 0 && page.epoch != current.epoch) {
        try clearAllEntitiesLocked(handle, newEpoch: page.epoch, hubID: hubID)
        let widgetRemoved = removeWidgetSnapshotLocked()
        return ProjectionApplyResult(
          wasReset: true,
          cursor: ProjectionCursor(epoch: page.epoch, seq: 0),
          upsertedCount: 0,
          deletedCount: 0,
          goneRecordIDs: [],
          invalidatedWidget: widgetRemoved
        )
      }
      return try applyChangesLocked(
        handle,
        changes: page.changes,
        epoch: page.epoch,
        cursorSeq: page.cursor,
        serverTime: page.serverTime,
        hubID: hubID,
        now: now ?? clock()
      )
    }
  }

  /// 应用增量变更（如信箱 `projection.delta`）。若 `epoch` 变化则先清空缓存并复位游标，不推进到跳过缺口的序号。
  public func applyChanges(
    _ changes: [ProjectionChange],
    epoch: Int64,
    cursorSeq: Int64,
    serverTime: String? = nil,
    hubID: String? = nil,
    now: Date? = nil
  ) throws -> ProjectionApplyResult {
    try lock.withLock {
      let handle = try openDatabaseLocked()
      let current = try readCursorLocked(handle)
      if current.epoch != 0 && epoch != current.epoch {
        try clearAllEntitiesLocked(handle, newEpoch: epoch, hubID: hubID)
        let widgetRemoved = removeWidgetSnapshotLocked()
        return ProjectionApplyResult(
          wasReset: true,
          cursor: ProjectionCursor(epoch: epoch, seq: 0),
          upsertedCount: 0,
          deletedCount: 0,
          goneRecordIDs: [],
          invalidatedWidget: widgetRemoved
        )
      }
      return try applyChangesLocked(
        handle,
        changes: changes,
        epoch: epoch,
        cursorSeq: cursorSeq,
        serverTime: serverTime,
        hubID: hubID,
        now: now ?? clock()
      )
    }
  }

  /// 应用紧急失效通知（`projection.invalidate`）：立即删除对应缓存实体但不推进拉取游标，返回需要从内存 LRU 清除的 `record_gone` ID。
  public func applyInvalidate(
    epoch: Int64,
    items: [ProjectionInvalidateItem],
    now: Date? = nil
  ) throws -> ProjectionApplyResult {
    try lock.withLock {
      let handle = try openDatabaseLocked()
      let current = try readCursorLocked(handle)
      if current.epoch != 0 && epoch != current.epoch {
        try clearAllEntitiesLocked(handle, newEpoch: epoch, hubID: nil)
        let widgetRemoved = removeWidgetSnapshotLocked()
        return ProjectionApplyResult(
          wasReset: true,
          cursor: ProjectionCursor(epoch: epoch, seq: 0),
          upsertedCount: 0,
          deletedCount: 0,
          goneRecordIDs: [],
          invalidatedWidget: widgetRemoved
        )
      }
      let today = TimelineDay.key(now ?? clock(), calendar: calendar)
      var deletedCount = 0
      var goneIDs: [String] = []
      var shouldInvalidateWidget = false
      try transactionLocked(handle) {
        for item in items {
          if let entityKind = item.kind.entityKind {
            deletedCount += try deleteEntityLocked(handle, kind: entityKind, id: item.id)
            if entityKind == .day && item.id == today || entityKind == .now {
              shouldInvalidateWidget = true
            }
          } else {
            goneIDs.append(item.id)
          }
        }
      }
      let widgetRemoved = shouldInvalidateWidget ? removeWidgetSnapshotLocked() : false
      return ProjectionApplyResult(
        wasReset: false,
        cursor: current,
        upsertedCount: 0,
        deletedCount: deletedCount,
        goneRecordIDs: goneIDs,
        invalidatedWidget: widgetRemoved
      )
    }
  }

  /// 清空实体并将游标重置为 `(newEpoch, 0)`（收到 `reset` 或 `epoch` 切换时调用）。
  public func reset(toEpoch newEpoch: Int64, hubID: String? = nil) throws {
    try lock.withLock {
      let handle = try openDatabaseLocked()
      try clearAllEntitiesLocked(handle, newEpoch: newEpoch, hubID: hubID)
      _ = removeWidgetSnapshotLocked()
    }
  }

  /// 按 6.9.6 清理过期 `day`（90 天）、过期 `archived` 事项（30 天）及超过 128 MiB 上限的旧 `day`（30 天前）并执行 `incremental_vacuum`。
  @discardableResult
  public func prune(now: Date? = nil) throws -> ProjectionPruneResult {
    try lock.withLock {
      guard db != nil || FileManager.default.fileExists(atPath: databaseURL.path) else {
        return ProjectionPruneResult(
          expiredDaysDeleted: 0,
          expiredArchivedThreadsDeleted: 0,
          diskTrimDaysDeleted: 0,
          finalDatabaseBytes: 0
        )
      }
      let handle = try openDatabaseLocked()
      let key = try resolveKeyLocked()
      let referenceDate = now ?? clock()

      // 1. `day` 保留最近 dayRetentionDays 天（含今天，与中枢 window_days 语义一致）。
      let dayCutoffDate = calendar.date(byAdding: .day, value: -(policy.dayRetentionDays - 1), to: referenceDate) ?? referenceDate
      let dayCutoffKey = TimelineDay.key(dayCutoffDate, calendar: calendar)

      // 2. `thread` 保留全部 active / paused，以及近 archivedThreadRetentionDays 天更新的 archived。
      let archivedCutoff = referenceDate.addingTimeInterval(-Double(policy.archivedThreadRetentionDays) * 86_400)
      let expiredThreadIDs = try findExpiredArchivedThreadsLocked(handle, key: key, cutoff: archivedCutoff)

      var expiredDaysDeleted = 0
      var expiredThreadsDeleted = 0
      try transactionLocked(handle) {
        expiredDaysDeleted = try deleteDaysBeforeLocked(handle, cutoffKey: dayCutoffKey)
        for threadID in expiredThreadIDs {
          expiredThreadsDeleted += try deleteEntityLocked(handle, kind: .thread, id: threadID)
        }
      }
      if expiredDaysDeleted > 0 || expiredThreadsDeleted > 0 {
        try execLocked(handle, "PRAGMA incremental_vacuum;")
      }

      // 3. 磁盘硬上限（默认 128 MiB）：超出时先回收空闲页，仍超出则删除早于 30 天的 day，再 incremental_vacuum。
      var diskTrimDaysDeleted = 0
      var currentBytes = databaseFileSizeLocked()
      if currentBytes > policy.maxDiskBytes {
        try execLocked(handle, "PRAGMA incremental_vacuum;")
        currentBytes = databaseFileSizeLocked()
      }
      if currentBytes > policy.maxDiskBytes {
        let trimDate = calendar.date(byAdding: .day, value: -policy.diskTrimDayAgeDays, to: referenceDate) ?? referenceDate
        let trimCutoffKey = TimelineDay.key(trimDate, calendar: calendar)
        let candidateDays = try listDayIDsBeforeLocked(handle, cutoffKey: trimCutoffKey)
        let batchSize = max(1, min(8, candidateDays.count))
        var index = 0
        while currentBytes > policy.maxDiskBytes && index < candidateDays.count {
          let end = min(index + batchSize, candidateDays.count)
          try transactionLocked(handle) {
            for dayID in candidateDays[index..<end] {
              diskTrimDaysDeleted += try deleteEntityLocked(handle, kind: .day, id: dayID)
            }
          }
          try execLocked(handle, "PRAGMA incremental_vacuum;")
          currentBytes = databaseFileSizeLocked()
          index = end
        }
      }

      return ProjectionPruneResult(
        expiredDaysDeleted: expiredDaysDeleted,
        expiredArchivedThreadsDeleted: expiredThreadsDeleted,
        diskTrimDaysDeleted: diskTrimDaysDeleted,
        finalDatabaseBytes: currentBytes
      )
    }
  }

  /// 整库清空入口：关闭 SQLite，删除数据库文件及附属文件，同时删除注入的小组件快照。
  public func wipe() throws {
    try lock.withLock {
      try wipeLocked()
    }
  }

  /// 返回当前数据库文件字节数（文件不存在时为 0）。
  public func databaseFileSize() -> Int64 {
    lock.withLock { databaseFileSizeLocked() }
  }

  /// 读取整数 PRAGMA（供核对 `secure_delete`、`auto_vacuum` 等配置）。
  public func pragmaInt(_ name: String) throws -> Int64 {
    try lock.withLock {
      let handle = try openDatabaseLocked()
      return try readPragmaIntLocked(handle, name: name)
    }
  }

  // MARK: - 内部实现

  private func resolveKeyLocked() throws -> SymmetricKey {
    if let cachedKey { return cachedKey }
    let loaded = try keyProvider.loadOrCreateKey()
    let byteCount = loaded.withUnsafeBytes { $0.count }
    guard byteCount == 32 else { throw ProjectionCacheError.invalidKey }
    cachedKey = loaded
    return loaded
  }

  private func openDatabaseLocked() throws -> OpaquePointer {
    if let db { return db }
    let fm = FileManager.default
    try rejectSymlink(dataDirectory)
    try fm.createDirectory(at: dataDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    try rejectSymlink(dataDirectory)
    try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dataDirectory.path)

    // 拒绝数据库及其附属文件的符号链接。
    let sidecars = ["", "-journal", "-wal", "-shm"].map { URL(fileURLWithPath: databaseURL.path + $0) }
    for url in sidecars {
      try rejectSymlink(url)
    }

    // 用 O_NOFOLLOW + 0600 创建或核验常规文件，杜绝符号链接竞争和过宽权限。
    let fd = open(databaseURL.path, O_RDWR | O_CREAT | O_NOFOLLOW, 0o600)
    if fd < 0 {
      if errno == ELOOP {
        throw ProjectionCacheError.symlinkRejected(databaseURL.path)
      }
      throw ProjectionCacheError.invalidPath("无法创建或打开缓存文件（errno=\(errno)）")
    }
    defer { close(fd) }
    var st = stat()
    guard fstat(fd, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else {
      throw ProjectionCacheError.invalidPath("缓存路径不是常规文件")
    }
    guard fchmod(fd, 0o600) == 0 else {
      throw ProjectionCacheError.invalidPath("无法设置缓存文件 0600 权限")
    }
    let isBrandNew = st.st_size == 0

    var handle: OpaquePointer?
    let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
    let rc = sqlite3_open_v2(databaseURL.path, &handle, flags, nil)
    guard rc == SQLITE_OK, let opened = handle else {
      let message = handle.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "sqlite3_open_v2 失败"
      if let handle { sqlite3_close(handle) }
      throw ProjectionCacheError.sqliteError(code: rc, message: message)
    }

    do {
      try execLocked(opened, "PRAGMA busy_timeout = 5000;")
      try execLocked(opened, "PRAGMA secure_delete = ON;")
      try execLocked(opened, "PRAGMA journal_mode = DELETE;")
      if isBrandNew {
        // auto_vacuum 必须在建表前设置为 INCREMENTAL（2）才能生效。
        try execLocked(opened, "PRAGMA auto_vacuum = INCREMENTAL;")
      } else if try readPragmaIntLocked(opened, name: "auto_vacuum") != 2 {
        try execLocked(opened, "PRAGMA auto_vacuum = INCREMENTAL;")
        try execLocked(opened, "VACUUM;")
      }
      try execLocked(opened, """
        CREATE TABLE IF NOT EXISTS projection_meta (
          k TEXT PRIMARY KEY,
          v TEXT NOT NULL
        );
        CREATE TABLE IF NOT EXISTS projection_entities (
          kind TEXT NOT NULL CHECK(kind IN ('day','project','thread','project_context','now')),
          entity_id TEXT NOT NULL,
          rev INTEGER NOT NULL,
          truncated INTEGER NOT NULL DEFAULT 0,
          payload BLOB NOT NULL,
          updated_at_ms INTEGER NOT NULL,
          PRIMARY KEY (kind, entity_id)
        );
        CREATE INDEX IF NOT EXISTS projection_entities_kind ON projection_entities(kind, entity_id);
        """)
      db = opened
      return opened
    } catch {
      sqlite3_close(opened)
      throw error
    }
  }

  private func closeLocked() {
    if let db {
      sqlite3_close(db)
      self.db = nil
    }
  }

  private func wipeLocked() throws {
    closeLocked()
    let suffixes = ["", "-journal", "-wal", "-shm"]
    for suffix in suffixes {
      let path = databaseURL.path + suffix
      try unlinkIfExists(path)
    }
    _ = removeWidgetSnapshotLocked()
  }

  @discardableResult
  private func removeWidgetSnapshotLocked() -> Bool {
    guard let snapshot = widgetSnapshotURL else { return false }
    if unlink(snapshot.path) == 0 {
      return true
    }
    return false
  }

  private func unlinkIfExists(_ path: String) throws {
    if unlink(path) == 0 { return }
    if errno == ENOENT { return }
    throw ProjectionCacheError.invalidPath("无法删除文件：\(path)（errno=\(errno)）")
  }

  private func rejectSymlink(_ url: URL) throws {
    var st = stat()
    if lstat(url.path, &st) == 0 {
      if (st.st_mode & S_IFMT) == S_IFLNK {
        throw ProjectionCacheError.symlinkRejected(url.path)
      }
    }
  }

  private func databaseFileSizeLocked() -> Int64 {
    var st = stat()
    guard lstat(databaseURL.path, &st) == 0 else { return 0 }
    return Int64(st.st_size)
  }

  private func applyChangesLocked(
    _ handle: OpaquePointer,
    changes: [ProjectionChange],
    epoch: Int64,
    cursorSeq: Int64,
    serverTime: String?,
    hubID: String?,
    now: Date
  ) throws -> ProjectionApplyResult {
    let key = try resolveKeyLocked()
    let nowMs = Int64(now.timeIntervalSince1970 * 1000)
    let today = TimelineDay.key(now, calendar: calendar)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.withoutEscapingSlashes]

    var upsertedCount = 0
    var deletedCount = 0
    var goneIDs: [String] = []
    var shouldInvalidateWidget = false

    try transactionLocked(handle) {
      for change in changes {
        guard let entityKind = change.kind.entityKind else {
          // record_gone 只用于通知内存 LRU 清理，不落盘为缓存实体。
          goneIDs.append(change.id)
          continue
        }
        switch change.op {
        case .upsert:
          guard let dataObj = change.data else {
            // 无正文的 upsert 按删除处理，避免写入空占位。
            deletedCount += try deleteEntityLocked(handle, kind: entityKind, id: change.id)
            if (entityKind == .day && change.id == today) || entityKind == .now {
              shouldInvalidateWidget = true
            }
            continue
          }
          let plaintext = try encoder.encode(dataObj)
          let ciphertext = try ProjectionCacheCrypto.seal(
            plaintext,
            kind: entityKind,
            entityID: change.id,
            using: key
          )
          try upsertEntityLocked(
            handle,
            kind: entityKind,
            id: change.id,
            rev: change.rev,
            truncated: change.truncated ?? false,
            ciphertext: ciphertext,
            updatedAtMs: nowMs
          )
          upsertedCount += 1
        case .delete:
          deletedCount += try deleteEntityLocked(handle, kind: entityKind, id: change.id)
          if (entityKind == .day && change.id == today) || entityKind == .now {
            shouldInvalidateWidget = true
          }
        }
      }
      try writeMetaLocked(handle, key: "epoch", value: String(epoch))
      try writeMetaLocked(handle, key: "seq", value: String(cursorSeq))
      if let serverTime {
        try writeMetaLocked(handle, key: "last_sync_at", value: serverTime)
      }
      if let hubID {
        try writeMetaLocked(handle, key: "hub_id", value: hubID)
      }
    }

    let widgetRemoved = shouldInvalidateWidget ? removeWidgetSnapshotLocked() : false
    return ProjectionApplyResult(
      wasReset: false,
      cursor: ProjectionCursor(epoch: epoch, seq: cursorSeq),
      upsertedCount: upsertedCount,
      deletedCount: deletedCount,
      goneRecordIDs: goneIDs,
      invalidatedWidget: widgetRemoved
    )
  }

  private func clearAllEntitiesLocked(_ handle: OpaquePointer, newEpoch: Int64, hubID: String?) throws {
    try transactionLocked(handle) {
      try execLocked(handle, "DELETE FROM projection_entities;")
      try writeMetaLocked(handle, key: "epoch", value: String(newEpoch))
      try writeMetaLocked(handle, key: "seq", value: "0")
      if let hubID {
        try writeMetaLocked(handle, key: "hub_id", value: hubID)
      }
    }
    try execLocked(handle, "PRAGMA incremental_vacuum;")
  }

  private func upsertEntityLocked(
    _ handle: OpaquePointer,
    kind: ProjectionEntityKind,
    id: String,
    rev: Int64,
    truncated: Bool,
    ciphertext: Data,
    updatedAtMs: Int64
  ) throws {
    let sql = """
      INSERT INTO projection_entities(kind, entity_id, rev, truncated, payload, updated_at_ms)
      VALUES (?, ?, ?, ?, ?, ?)
      ON CONFLICT(kind, entity_id) DO UPDATE SET
        rev = excluded.rev,
        truncated = excluded.truncated,
        payload = excluded.payload,
        updated_at_ms = excluded.updated_at_ms;
      """
    var stmt: OpaquePointer?
    try check(sqlite3_prepare_v2(handle, sql, -1, &stmt, nil), handle: handle)
    defer { sqlite3_finalize(stmt) }
    try bindText(stmt, index: 1, value: kind.rawValue, handle: handle)
    try bindText(stmt, index: 2, value: id, handle: handle)
    try check(sqlite3_bind_int64(stmt, 3, rev), handle: handle)
    try check(sqlite3_bind_int(stmt, 4, truncated ? 1 : 0), handle: handle)
    try bindBlob(stmt, index: 5, data: ciphertext, handle: handle)
    try check(sqlite3_bind_int64(stmt, 6, updatedAtMs), handle: handle)
    let step = sqlite3_step(stmt)
    guard step == SQLITE_DONE else { throw sqliteError(step, handle: handle) }
  }

  @discardableResult
  private func deleteEntityLocked(_ handle: OpaquePointer, kind: ProjectionEntityKind, id: String) throws -> Int {
    let sql = "DELETE FROM projection_entities WHERE kind = ? AND entity_id = ?;"
    var stmt: OpaquePointer?
    try check(sqlite3_prepare_v2(handle, sql, -1, &stmt, nil), handle: handle)
    defer { sqlite3_finalize(stmt) }
    try bindText(stmt, index: 1, value: kind.rawValue, handle: handle)
    try bindText(stmt, index: 2, value: id, handle: handle)
    let step = sqlite3_step(stmt)
    guard step == SQLITE_DONE else { throw sqliteError(step, handle: handle) }
    return Int(sqlite3_changes(handle))
  }

  private func deleteDaysBeforeLocked(_ handle: OpaquePointer, cutoffKey: String) throws -> Int {
    let sql = "DELETE FROM projection_entities WHERE kind = 'day' AND entity_id < ?;"
    var stmt: OpaquePointer?
    try check(sqlite3_prepare_v2(handle, sql, -1, &stmt, nil), handle: handle)
    defer { sqlite3_finalize(stmt) }
    try bindText(stmt, index: 1, value: cutoffKey, handle: handle)
    let step = sqlite3_step(stmt)
    guard step == SQLITE_DONE else { throw sqliteError(step, handle: handle) }
    return Int(sqlite3_changes(handle))
  }

  private func listDayIDsBeforeLocked(_ handle: OpaquePointer, cutoffKey: String) throws -> [String] {
    let sql = "SELECT entity_id FROM projection_entities WHERE kind = 'day' AND entity_id < ? ORDER BY entity_id ASC;"
    var stmt: OpaquePointer?
    try check(sqlite3_prepare_v2(handle, sql, -1, &stmt, nil), handle: handle)
    defer { sqlite3_finalize(stmt) }
    try bindText(stmt, index: 1, value: cutoffKey, handle: handle)
    var ids: [String] = []
    while true {
      let step = sqlite3_step(stmt)
      if step == SQLITE_DONE { break }
      guard step == SQLITE_ROW else { throw sqliteError(step, handle: handle) }
      ids.append(readText(stmt, column: 0))
    }
    return ids
  }

  private struct ThreadRetentionProbe: Decodable {
    let status: String?
    let updated_at: String?
    let last_ms: Int64?
  }

  private func findExpiredArchivedThreadsLocked(
    _ handle: OpaquePointer,
    key: SymmetricKey,
    cutoff: Date
  ) throws -> [String] {
    let sql = "SELECT entity_id, payload FROM projection_entities WHERE kind = 'thread';"
    var stmt: OpaquePointer?
    try check(sqlite3_prepare_v2(handle, sql, -1, &stmt, nil), handle: handle)
    defer { sqlite3_finalize(stmt) }
    let decoder = JSONDecoder()
    var expired: [String] = []
    while true {
      let step = sqlite3_step(stmt)
      if step == SQLITE_DONE { break }
      guard step == SQLITE_ROW else { throw sqliteError(step, handle: handle) }
      let id = readText(stmt, column: 0)
      let blob = readBlob(stmt, column: 1)
      guard let plaintext = try? ProjectionCacheCrypto.open(blob, kind: .thread, entityID: id, using: key),
            let probe = try? decoder.decode(ThreadRetentionProbe.self, from: plaintext),
            probe.status == "archived" else {
        continue
      }
      let updatedAt: Date?
      if let raw = probe.updated_at, let parsed = DeviceProtocol.parseRFC3339(raw) {
        updatedAt = parsed
      } else if let lastMs = probe.last_ms {
        updatedAt = Date(timeIntervalSince1970: Double(lastMs) / 1000.0)
      } else {
        updatedAt = nil
      }
      if let updatedAt, updatedAt < cutoff {
        expired.append(id)
      }
    }
    return expired
  }

  private func readCursorLocked(_ handle: OpaquePointer) throws -> ProjectionCursor {
    let epoch = (try readMetaLocked(handle, key: "epoch")).flatMap(Int64.init) ?? 0
    let seq = (try readMetaLocked(handle, key: "seq")).flatMap(Int64.init) ?? 0
    return ProjectionCursor(epoch: epoch, seq: seq)
  }

  private func readMetaLocked(_ handle: OpaquePointer, key: String) throws -> String? {
    let sql = "SELECT v FROM projection_meta WHERE k = ? LIMIT 1;"
    var stmt: OpaquePointer?
    try check(sqlite3_prepare_v2(handle, sql, -1, &stmt, nil), handle: handle)
    defer { sqlite3_finalize(stmt) }
    try bindText(stmt, index: 1, value: key, handle: handle)
    let step = sqlite3_step(stmt)
    if step == SQLITE_DONE { return nil }
    guard step == SQLITE_ROW else { throw sqliteError(step, handle: handle) }
    return readText(stmt, column: 0)
  }

  private func writeMetaLocked(_ handle: OpaquePointer, key: String, value: String) throws {
    let sql = "INSERT INTO projection_meta(k, v) VALUES (?, ?) ON CONFLICT(k) DO UPDATE SET v = excluded.v;"
    var stmt: OpaquePointer?
    try check(sqlite3_prepare_v2(handle, sql, -1, &stmt, nil), handle: handle)
    defer { sqlite3_finalize(stmt) }
    try bindText(stmt, index: 1, value: key, handle: handle)
    try bindText(stmt, index: 2, value: value, handle: handle)
    let step = sqlite3_step(stmt)
    guard step == SQLITE_DONE else { throw sqliteError(step, handle: handle) }
  }

  private func readPragmaIntLocked(_ handle: OpaquePointer, name: String) throws -> Int64 {
    var stmt: OpaquePointer?
    try check(sqlite3_prepare_v2(handle, "PRAGMA \(name);", -1, &stmt, nil), handle: handle)
    defer { sqlite3_finalize(stmt) }
    let step = sqlite3_step(stmt)
    guard step == SQLITE_ROW else { throw sqliteError(step, handle: handle) }
    return sqlite3_column_int64(stmt, 0)
  }

  private func transactionLocked(_ handle: OpaquePointer, _ body: () throws -> Void) throws {
    try execLocked(handle, "BEGIN IMMEDIATE;")
    do {
      try body()
      try execLocked(handle, "COMMIT;")
    } catch {
      _ = try? execLocked(handle, "ROLLBACK;")
      throw error
    }
  }

  private func execLocked(_ handle: OpaquePointer, _ sql: String) throws {
    var errPtr: UnsafeMutablePointer<CChar>?
    let rc = sqlite3_exec(handle, sql, nil, nil, &errPtr)
    if rc != SQLITE_OK {
      let msg = errPtr.map { String(cString: $0) } ?? String(cString: sqlite3_errmsg(handle))
      if let errPtr { sqlite3_free(errPtr) }
      throw ProjectionCacheError.sqliteError(code: rc, message: msg)
    }
  }

  private func check(_ rc: Int32, handle: OpaquePointer) throws {
    guard rc == SQLITE_OK else { throw sqliteError(rc, handle: handle) }
  }

  private func sqliteError(_ rc: Int32, handle: OpaquePointer) -> ProjectionCacheError {
    let msg = String(cString: sqlite3_errmsg(handle))
    return .sqliteError(code: rc, message: msg)
  }

  private func bindText(_ stmt: OpaquePointer?, index: Int32, value: String, handle: OpaquePointer) throws {
    let rc = value.withCString { cstr in
      sqlite3_bind_text(stmt, index, cstr, -1, sqliteTransient)
    }
    try check(rc, handle: handle)
  }

  private func bindBlob(_ stmt: OpaquePointer?, index: Int32, data: Data, handle: OpaquePointer) throws {
    let rc: Int32
    if data.isEmpty {
      rc = sqlite3_bind_blob(stmt, index, nil, 0, sqliteTransient)
    } else {
      rc = data.withUnsafeBytes { ptr in
        sqlite3_bind_blob(stmt, index, ptr.baseAddress, Int32(ptr.count), sqliteTransient)
      }
    }
    try check(rc, handle: handle)
  }

  private func readText(_ stmt: OpaquePointer?, column: Int32) -> String {
    guard let ptr = sqlite3_column_text(stmt, column) else { return "" }
    return String(cString: ptr)
  }

  private func readBlob(_ stmt: OpaquePointer?, column: Int32) -> Data {
    let count = Int(sqlite3_column_bytes(stmt, column))
    guard count > 0, let ptr = sqlite3_column_blob(stmt, column) else { return Data() }
    return Data(bytes: ptr, count: count)
  }
}

private extension NSLock {
  func withLock<T>(_ body: () throws -> T) rethrows -> T {
    lock()
    defer { unlock() }
    return try body()
  }
}
