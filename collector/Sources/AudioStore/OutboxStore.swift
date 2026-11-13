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
  private var ids = Set<String>()
  private var unreadable = Set<String>()
  private static let header = Data("RAO1".utf8)
  public enum Failure: Error { case unsafePath, invalidRecord, invalidFile, storage }
  public var count: Int { ids.count }
  public func contains(_ id: String) -> Bool { ids.contains(id) }

  public init(dataDirectory: URL, key: SymmetricKey? = nil) throws {
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
        if file.hasSuffix(".enc"), Self.validID(String(file.dropLast(4))) { ids.insert(String(file.dropLast(4))) }
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
    if ids.contains(record.id) {
      do { return try read(record.id) }
      catch { unreadable.insert(record.id); throw error }
    }
    let clean = RecordRedaction.record(record)
    let plain = try JSONEncoder().encode(clean)
    guard plain.count < 4 * 1024 * 1024 - 64 else { throw Failure.invalidRecord }
    let sealed = try AES.GCM.seal(plain, using: key, authenticating: Data(clean.id.utf8))
    guard let cipher = sealed.combined else { throw Failure.invalidFile }
    let name = ".pending-" + UUID().uuidString
    let fd = openat(directory, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
    guard fd >= 0 else { throw Failure.storage }
    defer { close(fd); _ = unlinkat(directory, name, 0) }
    let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
    try handle.write(contentsOf: Self.header + cipher)
    guard fsync(fd) == 0 else { throw Failure.storage }
    // linkat 不替换已经存在的文件（包括链接）；只有完整 fsync 后的密文才可见。
    guard linkat(directory, name, directory, clean.id + ".enc", 0) == 0 else { throw Failure.storage }
    ids.insert(clean.id)
    guard fsync(directory) == 0 else { throw Failure.storage }
    return clean
  }
  /// 损坏项留在原位、返回明确计数，其余记录仍可恢复；排除已在内存中的 id。
  public func restore(limit: Int, excluding: Set<String> = []) -> (records: [Record], unreadable: Int) {
    var records: [Record] = []
    for id in ids.subtracting(excluding).subtracting(unreadable).sorted() {
      guard records.count < max(0, limit) else { break }
      do { records.append(try read(id)) } catch { unreadable.insert(id) }
    }
    return (records, unreadable.count)
  }
  /// 只在中枢确认接收（或明确拒收）后调用。失败保留队列，重复发送由记录 id 去重。
  public func acknowledge(_ delivered: Set<String>) throws {
    for id in delivered {
      guard Self.validID(id) else { throw Failure.invalidRecord }
      guard ids.contains(id) else { continue }
      guard !unreadable.contains(id) else { throw Failure.invalidFile }
      // 不删除被外部替换成链接的文件，显示错误而非掩盖损坏。
      var info = stat()
      guard fstatat(directory, id + ".enc", &info, AT_SYMLINK_NOFOLLOW) == 0,
            (info.st_mode & S_IFMT) == S_IFREG else { throw Failure.unsafePath }
      guard unlinkat(directory, id + ".enc", 0) == 0 else { throw Failure.storage }
      ids.remove(id); unreadable.remove(id)
    }
    guard fsync(directory) == 0 else { throw Failure.storage }
  }
}
