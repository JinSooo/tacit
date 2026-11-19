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
  fileprivate var readableCount: Int { count - unreadable.count }
  public func contains(_ id: String) -> Bool { sizes[id] != nil }

  public init(dataDirectory: URL, key: SymmetricKey? = nil, byteLimit: Int64 = OutboxStore.defaultByteLimit) throws {
    self.byteLimit = max(0, byteLimit)
    self.key = try key ?? AudioStore.loadKey()
    let fm = FileManager.default
    try Self.rejectLink(dataDirectory)
    try fm.createDirectory(at: dataDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let base = dataDirectory.resolvingSymlinksInPath()
    root = base.appendingPathComponent("outbox", isDirectory: true)
    try Self.rejectLink(root)
    guard mkdir(root.path, 0o700) == 0 || errno == EEXIST else { throw Failure.storage }
    directory = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard directory >= 0 else { throw Failure.unsafePath }
    guard fchmod(directory, 0o700) == 0 else { close(directory); throw Failure.storage }
    do {
      for file in try fm.contentsOfDirectory(atPath: root.path) {
        let id = String(file.dropLast(4))
        if file.hasSuffix(".enc"), Self.validID(id) {
          var info = stat()
          guard fstatat(directory, file, &info, AT_SYMLINK_NOFOLLOW) == 0 else {
            if errno == ENOENT { continue }
            throw Failure.storage
          }
          let regular = info.st_mode & S_IFMT == S_IFREG
          sizes[id] = regular ? info.st_size : 0
          if regular { bytes += info.st_size } else { unreadable.insert(id) }
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
    guard Self.validID(id) else { throw Failure.invalidRecord }
    let fd = openat(directory, id + ".enc", O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
    guard fd >= 0 else { throw Failure.unsafePath }; defer { close(fd) }
    var info = stat()
    guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
          info.st_size > 32, info.st_size < 4 * 1024 * 1024 else { throw Failure.invalidFile }
    let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
    let bytes = try handle.readToEnd() ?? Data()
    guard bytes.starts(with: Self.header) else { throw Failure.invalidFile }
    let sealed = try AES.GCM.SealedBox(combined: bytes.dropFirst(Self.header.count))
    let data = try AES.GCM.open(sealed, using: key, authenticating: Data(id.utf8))
    let record = try JSONDecoder().decode(Record.self, from: data)
    guard record.id == id else { throw Failure.invalidRecord }
    return record
  }
  /// 返回实际持久化版本。相同 id 永不覆盖，以便网络响应丢失时安全重放。
  public func append(_ record: Record) throws -> Record {
    guard Self.validID(record.id) else { throw Failure.invalidRecord }
    if contains(record.id) {
      do { return try read(record.id) }
      catch { unreadable.insert(record.id); throw Failure.invalidFile }
    }
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
  /// 损坏项留在原位、返回明确计数，其余记录仍可恢复；排除已在内存中的 id。
  public func restore(limit: Int, excluding: Set<String> = []) -> (records: [Record], unreadable: Int) {
    var records: [Record] = []
    for id in sizes.keys.filter({ !excluding.contains($0) && !unreadable.contains($0) }).sorted() {
      guard records.count < max(0, limit) else { break }
      do { records.append(try read(id)) } catch { unreadable.insert(id) }
    }
    return (records, unreadable.count)
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
      try remove(id)
      dropped += 1
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
  public private(set) var hasStorageError = false
  public private(set) var queuePeak = 0
  public var count: Int { diskCount + memory.count }
  public var status: OutboxStatus { .init(bytes: diskBytes, dropped: dropped, degraded: store == nil) }

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
      hasStorageError = false
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
    catch OutboxStore.Failure.invalidRecord { hasStorageError = true; return false }
    catch OutboxStore.Failure.invalidFile where store.contains(record.id) { hasStorageError = true; return true }
  }

  public func batch(limit: Int) -> [Record] {
    guard limit > 0 else { return [] }
    if let store {
      diskBatch.removeAll { !store.contains($0.id) }
      let needed = min(limit, store.readableCount) - diskBatch.count
      if needed > 0 {
        let restored = store.restore(limit: needed, excluding: Set(diskBatch.map(\.id)))
        diskBatch.append(contentsOf: restored.records)
      }
      if store.readableCount < store.count { hasStorageError = true }
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

  private func updateMetrics() {
    if let store {
      diskCount = store.count
      diskBytes = store.bytes
      dropped = priorDrops + store.dropped
    }
    queuePeak = max(queuePeak, min(count, memory.capacity))
  }

  private func degrade(at uptime: TimeInterval) {
    updateMetrics()
    priorDrops = dropped
    store = nil
    diskBatch.removeAll()
    hasStorageError = true
    nextAttempt = uptime + 60
  }
}
