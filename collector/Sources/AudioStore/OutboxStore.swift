import Foundation
import CryptoKit
import CollectorCore
import Darwin

/// 串行 I/O 队列使用。每条记录独立持久化，内存只恢复一个有界批次。
/// 文件名绑定 AES-GCM 的认证数据；目录与文件均拒绝符号链接。
public final class OutboxStore {
  public let root: URL
  private let key: SymmetricKey
  private let directory: Int32
  private var sizes: [String: Int64] = [:]
  private let byteLimit: Int64
  public private(set) var bytes: Int64 = 0
  public private(set) var dropped = 0
  public static let defaultByteLimit: Int64 = 1 << 30
  private var unreadable = Set<String>()
  private static let header = Data("RAO1".utf8)
  public enum Failure: Error { case unsafePath, invalidRecord, invalidFile, storage, tooLarge }
  public var count: Int { sizes.count }
  public private(set) var quarantined = 0
  private static let quarantineName = "quarantine"
  fileprivate var hasUnreadableFiles: Bool { !unreadable.isEmpty }
  public func contains(_ id: String) -> Bool { sizes[id] != nil }

  public init(dataDirectory: URL, key: SymmetricKey? = nil, byteLimit: Int64 = OutboxStore.defaultByteLimit) throws {
    self.byteLimit = max(0, byteLimit)
    self.key = try key ?? AudioStore.loadKey()
    let fm = FileManager.default
    try Self.rejectLink(dataDirectory)
    try fm.createDirectory(at: dataDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let base = dataDirectory.resolvingSymlinksInPath()
    let parent = open(base.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard parent >= 0 else { throw Failure.unsafePath }
    defer { close(parent) }
    root = base.appendingPathComponent("outbox", isDirectory: true)
    try Self.rejectLink(root)
    guard mkdirat(parent, "outbox", 0o700) == 0 || errno == EEXIST else { throw Failure.storage }
    guard fsync(parent) == 0 else { throw Failure.storage }
    directory = openat(parent, "outbox", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard directory >= 0 else { throw Failure.unsafePath }
    guard fchmod(directory, 0o700) == 0 else { close(directory); throw Failure.storage }
    do {
      for file in try fm.contentsOfDirectory(atPath: root.path) {
        if file == Self.quarantineName {
          let quarantine = root.appendingPathComponent(file, isDirectory: true)
          try Self.rejectLink(quarantine)
          quarantined = try fm.contentsOfDirectory(atPath: quarantine.path).filter { $0.hasSuffix(".enc") }.count
          continue
        }
        let id = String(file.dropLast(4))
        if file.hasSuffix(".enc"), Self.validID(id) {
          var info = stat()
          guard fstatat(directory, file, &info, AT_SYMLINK_NOFOLLOW) == 0 else {
            if errno == ENOENT { continue }
            throw Failure.storage
          }
          let regular = info.st_mode & S_IFMT == S_IFREG
          sizes[id] = regular ? info.st_size : 0
          if regular { bytes += info.st_size }
        }
        // 原子替换前崩溃的临时文件里也只有密文；未提交的文件不作为记录恢复。
        else if file.hasPrefix(".pending-") { _ = unlinkat(directory, file, 0) }
      }
    } catch { close(directory); throw error }
  }
  deinit { close(directory) }
  private static func validID(_ id: String) -> Bool { id.range(of: "^[0-9A-HJKMNP-TV-Z]{26}$", options: .regularExpression) != nil }
  private static func rejectLink(_ url: URL) throws {
    var info = stat()
    if lstat(url.path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFLNK { throw Failure.unsafePath }
  }
  private func read(_ id: String) throws -> Record {
    let fd = openat(directory, id + ".enc", O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
    guard fd >= 0 else {
      if errno == ELOOP || errno == EACCES || errno == EPERM { throw Failure.invalidFile }
      throw Failure.storage
    }
    defer { close(fd) }
    var info = stat()
    guard fstat(fd, &info) == 0 else { throw Failure.storage }
    guard (info.st_mode & S_IFMT) == S_IFREG, info.st_size > 32, info.st_size < 4 * 1024 * 1024 else {
      throw Failure.invalidFile
    }
    let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
    let bytes = try handle.read(upToCount: 4 * 1024 * 1024) ?? Data()
    guard bytes.starts(with: Self.header) else { throw Failure.invalidFile }
    do {
      let sealed = try AES.GCM.SealedBox(combined: bytes.dropFirst(Self.header.count))
      let data = try AES.GCM.open(sealed, using: key, authenticating: Data(id.utf8))
      let record = try JSONDecoder().decode(Record.self, from: data)
      guard record.id == id else { throw Failure.invalidFile }
      return record
    } catch { throw Failure.invalidFile }
  }

  private func readOrQuarantine(_ id: String) throws -> Record? {
    do {
      let record = try read(id)
      unreadable.remove(id)
      return record
    } catch Failure.invalidFile {
      unreadable.insert(id)
      try quarantine(id)
      return nil
    }
  }

  private func quarantine(_ id: String) throws {
    let name = Self.quarantineName
    guard mkdirat(directory, name, 0o700) == 0 || errno == EEXIST else { throw Failure.storage }
    let target = openat(directory, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard target >= 0 else { throw Failure.unsafePath }
    defer { close(target) }
    let isolated = id + "-" + UUID().uuidString + ".enc"
    guard renameat(directory, id + ".enc", target, isolated) == 0 else { throw Failure.storage }
    quarantined += 1
    bytes -= sizes.removeValue(forKey: id) ?? 0
    unreadable.remove(id)
    _ = unlinkat(directory, ".submitted-" + id, 0)
    guard fsync(target) == 0, fsync(directory) == 0 else { throw Failure.storage }
  }

  /// 返回实际持久化版本。相同 id 永不覆盖，以便网络响应丢失时安全重放。
  public func append(_ record: Record) throws -> Record {
    guard Self.validID(record.id) else { throw Failure.invalidRecord }
    if contains(record.id), let saved = try readOrQuarantine(record.id) { return saved }
    let clean = RecordRedaction.record(record)
    let plain = try JSONEncoder().encode(clean)
    guard plain.count < 4 * 1024 * 1024 - 64 else { throw Failure.invalidRecord }
    let sealed = try AES.GCM.seal(plain, using: key, authenticating: Data(clean.id.utf8))
    guard let cipher = sealed.combined else { throw Failure.invalidFile }
    let contents = Self.header + cipher
    guard contents.count <= byteLimit else { dropped += 1; throw Failure.tooLarge }
    let name = ".pending-" + UUID().uuidString
    let fd = openat(directory, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
    guard fd >= 0 else { throw Failure.storage }
    defer { close(fd); _ = unlinkat(directory, name, 0) }
    let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
    try trim(reserving: Int64(contents.count))
    try handle.write(contentsOf: contents)
    guard fsync(fd) == 0 else { throw Failure.storage }
    // linkat 不替换已经存在的文件（包括链接）；只有完整 fsync 后的密文才可见。
    guard linkat(directory, name, directory, clean.id + ".enc", 0) == 0 else { throw Failure.storage }
    sizes[clean.id] = Int64(contents.count)
    bytes += Int64(contents.count)
    guard fsync(directory) == 0 else { throw Failure.storage }
    return clean
  }
  /// Preserve unreadable ciphertext in quarantine and continue restoring healthy records.
  /// `accepting` lets the sender skip records it routes elsewhere (for example pending mailbox deliveries).
  public func restore(limit: Int, excluding: Set<String> = [],
                      accepting: (Record) -> Bool = { _ in true }) -> (records: [Record], unreadable: Int) {
    var records: [Record] = []
    for id in sizes.keys.filter({ !excluding.contains($0) }).sorted() {
      guard records.count < max(0, limit) else { break }
      do {
        if let record = try readOrQuarantine(id), accepting(record) { records.append(record) }
      } catch {
        if contains(id) { unreadable.insert(id) }
      }
    }
    return (records, quarantined + unreadable.count)
  }
  /// A missing marker proves the current sender never handed this record to transport.
  /// Persist all markers before network I/O, including a mailbox PUT whose reply may be lost.
  public func markSubmitted(_ ids: [String]) throws {
    for id in ids {
      guard Self.validID(id), contains(id) else { throw Failure.invalidRecord }
      let fd = openat(directory, ".submitted-" + id, O_WRONLY | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
      guard fd >= 0 else { throw Failure.storage }
      close(fd)
    }
    guard fsync(directory) == 0 else { throw Failure.storage }
  }

  private func wasSubmitted(_ id: String) throws -> Bool {
    var info = stat()
    if fstatat(directory, ".submitted-" + id, &info, AT_SYMLINK_NOFOLLOW) == 0 { return true }
    guard errno == ENOENT else { throw Failure.storage }
    return false
  }

  public func switchableCount(onlyUnsubmitted: Bool) throws -> Int {
    try sizes.keys.reduce(into: 0) { count, id in
      // Preview must not quarantine or otherwise change a queue the sender is using.
      do {
        if try switchableRecord(id, onlyUnsubmitted: onlyUnsubmitted, readRecord: { try read($0) }) != nil {
          count += 1
        }
      } catch Failure.invalidFile { }
    }
  }

  /// Both destinations use the device's same encryption key. Link the existing ciphertext,
  /// leave both directory entries until publication, and never evict entries during migration.
  public func copyForSwitch(to destination: OutboxStore, onlyUnsubmitted: Bool) throws {
    for id in sizes.keys.sorted() {
      guard let source = try switchableRecord(id, onlyUnsubmitted: onlyUnsubmitted, readRecord: readOrQuarantine) else { continue }
      let submitted = try wasSubmitted(id)
      if destination.contains(id), let existing = try destination.readOrQuarantine(id) {
        guard existing == source else { throw Failure.invalidRecord }
        if submitted { try destination.markSubmitted([id]) }
        continue
      }
      let size = sizes[id] ?? 0
      guard size <= destination.byteLimit - destination.bytes else { throw Failure.tooLarge }
      let name = id + ".enc"
      guard linkat(directory, name, destination.directory, name, 0) == 0 else { throw Failure.storage }
      destination.sizes[id] = size
      destination.bytes += size
      if submitted { try destination.markSubmitted([id]) }
    }
    guard fsync(destination.directory) == 0 else { throw Failure.storage }
  }

  public func removeSwitchCopies(in destination: OutboxStore, onlyUnsubmitted: Bool) throws {
    let ids = try sizes.keys.sorted().filter { id in
      guard destination.contains(id),
            let source = try switchableRecord(id, onlyUnsubmitted: onlyUnsubmitted, readRecord: readOrQuarantine),
            let saved = try destination.readOrQuarantine(id) else { return false }
      guard saved == source else { throw Failure.invalidRecord }
      return true
    }
    try acknowledge(Set(ids))
  }

  private func switchableRecord(_ id: String, onlyUnsubmitted: Bool,
                                readRecord: (String) throws -> Record?) throws -> Record? {
    guard let record = try readRecord(id) else { return nil }
    guard onlyUnsubmitted else { return record }
    // A correction may reference an item that only exists on the server.
    return try wasSubmitted(id) || record.source == "manual.correction" ? nil : record
  }

  fileprivate func discardSwitchCopies() throws {
    for id in sizes.keys.sorted() {
      if try readOrQuarantine(id) != nil { try remove(id) }
    }
    guard fsync(directory) == 0 else { throw Failure.storage }
  }

  /// 只在中枢确认接收（或明确拒收）后调用。失败保留队列，重复发送由记录 id 去重。
  public func acknowledge(_ delivered: Set<String>) throws {
    for id in delivered {
      guard Self.validID(id) else { throw Failure.invalidRecord }
      guard contains(id) else { continue }
      guard !unreadable.contains(id) else { throw Failure.invalidFile }
      try remove(id)
    }
    guard fsync(directory) == 0 else { throw Failure.storage }
  }

  /// ULID 的字典序即记录时间序。只在超过预算时遍历旧项。
  func trim(reserving incoming: Int64 = 0) throws {
    guard bytes > byteLimit - incoming else { return }
    for id in sizes.keys.sorted() where (sizes[id] ?? 0) > 0 {
      if try readOrQuarantine(id) != nil {
        try remove(id)
        dropped += 1
      }
      if bytes <= byteLimit - incoming { break }
    }
    guard fsync(directory) == 0 else { throw Failure.storage }
  }

  private func remove(_ id: String) throws {
    // 不删除被外部替换成链接的文件。
    var info = stat()
    guard fstatat(directory, id + ".enc", &info, AT_SYMLINK_NOFOLLOW) == 0,
          info.st_mode & S_IFMT == S_IFREG else { throw Failure.unsafePath }
    guard unlinkat(directory, id + ".enc", 0) == 0 else { throw Failure.storage }
    _ = unlinkat(directory, ".submitted-" + id, 0)
    bytes -= sizes.removeValue(forKey: id) ?? 0
    unreadable.remove(id)
  }
}

/// 由发送端的串行 I/O 队列调用。磁盘失效时仅保留有界的内存退路。
public final class OutboxBuffer {
  public let memory: OutboundQueue
  private let openStore: () throws -> OutboxStore
  private var store: OutboxStore?
  private var diskBatch: [Record] = []
  private var nextAttempt: TimeInterval = 0
  private var diskCount = 0
  private var diskBytes: Int64 = 0
  private var dropped = 0
  private var priorDrops = 0
  private var saveError = false
  public var hasStorageError: Bool { saveError || store?.hasUnreadableFiles == true }
  public private(set) var queuePeak = 0
  public var count: Int { diskCount + memory.count }
  private var quarantined = 0
  public var status: OutboxStatus {
    .init(bytes: diskBytes, dropped: dropped, degraded: store == nil, quarantined: quarantined)
  }

  public init(memory: OutboundQueue = OutboundQueue(), open: @escaping () throws -> OutboxStore) {
    self.memory = memory
    openStore = open
  }

  public func retry(at uptime: TimeInterval) {
    guard store == nil, uptime >= nextAttempt else { return }
    nextAttempt = uptime + 60
    do {
      let opened = try openStore()
      store = opened
      saveError = false
      try opened.trim()
      // 已成功移入磁盘的项一次性移出内存。失败项留给下一次重试。
      var settled = Set<String>()
      defer { memory.remove(ids: settled) }
      for record in memory.peek(memory.capacity) {
        if try save(record, to: opened) { settled.insert(record.id) }
      }
    } catch {
      degrade(at: uptime)
    }
    updateMetrics()
  }

  public func enqueue(_ records: [Record], at uptime: TimeInterval) {
    for record in records {
      if let store {
        do { if try save(record, to: store) { continue } }
        catch {
          let alreadyStored = store.contains(record.id)
          degrade(at: uptime)
          if alreadyStored { continue }
        }
      }
      memory.push([RecordRedaction.record(record)])
    }
    updateMetrics()
  }

  /// true 表示已保存，或同 ID/超限策略已决定不保留内存副本。
  private func save(_ record: Record, to store: OutboxStore) throws -> Bool {
    do { _ = try store.append(record); return true }
    catch OutboxStore.Failure.tooLarge { return true }
    catch OutboxStore.Failure.invalidRecord { saveError = true; return false }

  }

  public func batch(limit: Int) -> [Record] {
    guard limit > 0 else { return [] }
    if let store {
      diskBatch.removeAll { !store.contains($0.id) }
      let needed = min(limit, store.count) - diskBatch.count
      if needed > 0 {
        let restored = store.restore(limit: needed, excluding: Set(diskBatch.map(\.id)))
        diskBatch.append(contentsOf: restored.records)
      }
      updateMetrics()
    }
    if diskBatch.count >= limit { return Array(diskBatch.prefix(limit)) }
    var seen = Set(diskBatch.map(\.id))
    var batch = diskBatch
    for record in memory.peek(memory.capacity) where store?.contains(record.id) != true && seen.insert(record.id).inserted {
      batch.append(record)
      if batch.count == limit { break }
    }
    return batch
  }

  /// Skips in-flight and relay-oversized records without changing their durable queue entries.
  public func eligibleBatch(limit: Int, excluding: Set<String>, accepting: (Record) -> Bool) -> [Record] {
    let records = store?.restore(limit: limit, excluding: excluding, accepting: accepting).records ?? []
    updateMetrics()
    if records.count == limit { return records }
    var seen = Set(records.map(\.id)).union(excluding)
    var batch = records
    for record in memory.peek(memory.capacity) where store?.contains(record.id) != true
      && seen.insert(record.id).inserted && accepting(record) {
      batch.append(record)
      if batch.count == limit { break }
    }
    return batch
  }

  public func acknowledge(_ ids: Set<String>, at uptime: TimeInterval) throws {
    if let store {
      let persisted = ids.filter { store.contains($0) }
      if !persisted.isEmpty {
        do { try store.acknowledge(persisted) }
        catch { degrade(at: uptime); throw error }
      }
    }
    memory.remove(ids: ids)
    updateMetrics()
  }

  public var isPersisted: Bool { store != nil && !hasStorageError && memory.count == 0 }

  public func switchableCount(onlyUnsubmitted: Bool) throws -> Int {
    guard isPersisted, let store else { throw OutboxStore.Failure.storage }
    return try store.switchableCount(onlyUnsubmitted: onlyUnsubmitted)
  }

  /// A prospective generation can contain copies from an interrupted publication. Rebuild it
  /// from the active queues so records acknowledged since that attempt do not move again.
  public func discardSwitchCopies() throws {
    guard isPersisted, let store else { throw OutboxStore.Failure.storage }
    defer { updateMetrics() }
    try store.discardSwitchCopies()
  }

  public func markSubmitted(_ ids: [String]) throws {
    guard let store else { throw OutboxStore.Failure.storage }
    try store.markSubmitted(ids)
  }

  public func copyForSwitch(to destination: OutboxBuffer, onlyUnsubmitted: Bool) throws {
    guard isPersisted, destination.isPersisted, let store, let target = destination.store else {
      throw OutboxStore.Failure.storage
    }
    defer { updateMetrics(); destination.updateMetrics() }
    try store.copyForSwitch(to: target, onlyUnsubmitted: onlyUnsubmitted)
  }

  public func removeSwitchCopies(in destination: OutboxBuffer, onlyUnsubmitted: Bool) throws {
    guard let store, let target = destination.store else { throw OutboxStore.Failure.storage }
    defer { updateMetrics(); destination.updateMetrics() }
    try store.removeSwitchCopies(in: target, onlyUnsubmitted: onlyUnsubmitted)
  }

  private func updateMetrics() {
    if let store {
      diskCount = store.count
      diskBytes = store.bytes
      dropped = priorDrops + store.dropped
      quarantined = store.quarantined
    }
    queuePeak = max(queuePeak, min(count, memory.capacity))
  }

  private func degrade(at uptime: TimeInterval) {
    updateMetrics()
    priorDrops = dropped
    store = nil
    diskBatch.removeAll()
    saveError = true
    nextAttempt = uptime + 60
  }
}
