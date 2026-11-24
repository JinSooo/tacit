import Foundation
import CryptoKit
import Security
import CollectorCore

/// 采集端和 worker 共用；不会把解密后的音频写到临时文件。
public final class AudioStore {
  public let root: URL
  private let key: SymmetricKey
  private let fm = FileManager.default
  public init(dataDirectory: URL, key: SymmetricKey? = nil) throws {
    root = dataDirectory.appendingPathComponent("audio", isDirectory: true)
    self.key = try key ?? Self.loadKey()
    try fm.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    try rejectLink(root)
  }
  private static let service = "record-anything", account = "audio-key-hex", legacyAccount = "audio-key"
  /// 用系统 security 命令读写（和 hub 的数据库密钥一样）：钥匙串只认 /usr/bin/security，
  /// 自签名的 app 重新构建后不用再授权，也不会因为授权框没人点而卡住录音线程。（2026-11-09 确认）
  public static func loadKey() throws -> SymmetricKey {
    if let key = try readKey() { return key }
    // 旧版用 SecItem 存二进制密钥，只认具体构建：迁移一次（这次会弹授权框），之后只用 security。
    let legacy = try readLegacy()
    let key = legacy.map { SymmetricKey(data: $0) } ?? SymmetricKey(size: .bits256)
    let hex = key.withUnsafeBytes { $0.map { String(format: "%02x", $0) }.joined() }
    // 经 `security -i` 从标准输入写入，密钥不进进程参数；退出码不可靠，以读回为准。
    let added = try security(["-i"], stdin: SecurityCLI.addGenericPasswordCommand(service: service, account: account, hexValue: hex)).status
    guard let stored = try readKey() else { throw AudioError.keychain(added == 0 ? -3 : added) }
    let same = stored.withUnsafeBytes { a in key.withUnsafeBytes { b in a.elementsEqual(b) } }
    if legacy != nil && same {
      SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: legacyAccount] as CFDictionary)
    }
    return stored
  }
  private static func readKey() throws -> SymmetricKey? {
    let (status, text) = try security(["find-generic-password", "-s", service, "-a", account, "-w"])
    if status == 44 { return nil }
    guard status == 0, text.count == 64, text.allSatisfy(\.isHexDigit) else { throw AudioError.keychain(status) }
    var bytes: [UInt8] = []; var i = text.startIndex
    while i < text.endIndex { let j = text.index(i, offsetBy: 2); bytes.append(UInt8(text[i..<j], radix: 16)!); i = j }
    return SymmetricKey(data: bytes)
  }
  private static func readLegacy() throws -> Data? {
    let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
      kSecAttrAccount as String: legacyAccount, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
    var result: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    if status == errSecItemNotFound { return nil }
    guard status == errSecSuccess, let data = result as? Data, data.count == 32 else { throw AudioError.keychain(status) }
    return data
  }
  /// 10 秒没返回就放弃，交给调用方报错并稍后重试，不无限等待。
  private static func security(_ arguments: [String], stdin: Data? = nil) throws -> (status: Int32, text: String) {
    do { return try SecurityCLI.run(arguments, stdin: stdin) }
    catch let failure as SecurityCLI.Failure { throw AudioError.keychain(failure.status) }
  }

  public func directory(for meta: AudioMetadata) throws -> URL {
    try meta.validate()
    let day = String(meta.t_start.prefix(10))
    guard day.range(of: "^[0-9]{4}-[0-9]{2}-[0-9]{2}$", options: .regularExpression) != nil else { throw AudioError.invalidPath }
    let parent = root.appendingPathComponent(day, isDirectory: true)
    let dir = parent.appendingPathComponent(meta.id, isDirectory: true)
    try rejectLink(parent); try rejectLink(dir)
    return dir
  }
  /// 两路的首个人声段可能乱序返回；跨午夜时保持同一 ULID，移动整个 open 目录。
  public func moveOpenConversation(from old: AudioMetadata, to new: AudioMetadata) throws {
    guard old.status == .open, new.status == .open, old.id == new.id else { throw AudioError.invalidTransition }
    let source = try directory(for: old), target = try directory(for: new)
    guard source != target else { return }
    try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    try fm.moveItem(at: source, to: target)
    do { try writeMetadata(new) }
    catch { try? fm.moveItem(at: target, to: source); throw error }
  }
  public func writeMetadata(_ meta: AudioMetadata) throws {
    let dir = try directory(for: meta)
    try fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    try writePrivateData(try meta.encoded(), to: dir.appendingPathComponent("meta.json"))
  }
  public func readMetadata(at directory: URL, readOnly: Bool = false) throws -> AudioMetadata {
    try rejectLink(directory); try rejectLink(directory.appendingPathComponent("meta.json"))
    let meta = try AudioMetadata.decode(readPrivateData(at: directory.appendingPathComponent("meta.json"), migrate: !readOnly))
    guard try self.directory(for: meta).standardizedFileURL == directory.standardizedFileURL else { throw AudioError.invalidPath }
    let cache = directory.appendingPathComponent("speakers.json")
    if !readOnly && fm.fileExists(atPath: cache.path) { _ = try readPrivateData(at: cache) }
    return meta
  }
  public func conversations(readOnly: Bool = false) throws -> [AudioMetadata] {
    var result: [AudioMetadata] = [], seen: Set<String> = []
    for day in try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]) {
      try rejectLink(day)
      guard try day.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else { continue }
      for dir in try fm.contentsOfDirectory(at: day, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]) {
        try rejectLink(dir)
        guard try dir.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else { continue }
        guard readOnly else { result.append(try readMetadata(at: dir, readOnly: false)); continue }
        result.append(try cachedMetadata(at: dir)); seen.insert(dir.standardizedFileURL.path)
      }
    }
    if readOnly { cacheLock.lock(); metaCache = metaCache.filter { seen.contains($0.key) }; cacheLock.unlock() }
    return result
  }
  /// 采集端每 30 秒盘点一次全部对话。逐个解密上千份 meta.json 是空闲时的主要 CPU 开销（2026-11-18 实测），
  /// 文件没换（inode、大小、修改时间都相同）就沿用上次解密校验过的结果；任何写入都是原子替换，会换 inode。
  private struct FileStamp: Equatable { let inode: UInt64; let size: UInt64; let modified: Date }
  private var metaCache: [String: (stamp: FileStamp, meta: AudioMetadata)] = [:]
  private let cacheLock = NSLock()
  private func stamp(_ url: URL) throws -> FileStamp {
    let attributes = try fm.attributesOfItem(atPath: url.path)
    if attributes[.type] as? FileAttributeType == .typeSymbolicLink { throw AudioError.invalidPath }
    return FileStamp(inode: (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0,
                     size: (attributes[.size] as? NSNumber)?.uint64Value ?? 0,
                     modified: attributes[.modificationDate] as? Date ?? .distantPast)
  }
  private func cachedMetadata(at dir: URL) throws -> AudioMetadata {
    let key = dir.standardizedFileURL.path, file = dir.appendingPathComponent("meta.json")
    let before = try stamp(file)
    cacheLock.lock(); let hit = metaCache[key]; cacheLock.unlock()
    if let hit, hit.stamp == before { return hit.meta }
    let meta = try readMetadata(at: dir, readOnly: true)
    // 读的同时被替换时不缓存，下次重读。
    if (try? stamp(file)) == before { cacheLock.lock(); metaCache[key] = (before, meta); cacheLock.unlock() }
    return meta
  }
  public func writeSegment(_ aac: Data, file: String, meta: AudioMetadata) throws {
    try validateFile(file)
    let dir = try directory(for: meta)
    try fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let sealed = try AES.GCM.seal(aac, using: key)
    guard let data = sealed.combined else { throw AudioError.invalidMetadata }
    try atomic(data, to: dir.appendingPathComponent(file))
  }
  public func readSegment(_ file: String, meta: AudioMetadata) throws -> Data {
    try validateFile(file)
    let url = try directory(for: meta).appendingPathComponent(file); try rejectLink(url)
    return try AES.GCM.open(AES.GCM.SealedBox(combined: Data(contentsOf: url)), using: key)
  }
  /// 调用者必须确保 worker 没在处理这些目录；open 对话始终保留。
  @discardableResult public func cleanup(now: Date, retentionDays: Int, purgeBefore: Date? = nil, deleting: [String] = [],
                                         preservingPending: Bool = false) throws -> [String] {
    guard (0...365).contains(retentionDays), deleting.allSatisfy(AudioPolicy.validID) else { throw AudioError.invalidMetadata }
    let all = try conversations(readOnly: true)
    var deleted: [String] = []
    for meta in all where meta.status != .open {
      if deleting.contains(meta.id) || AudioPolicy.shouldDelete(meta, now: now, retentionDays: retentionDays,
        purgeBefore: purgeBefore, preservingPending: preservingPending) {
        try fm.removeItem(at: directory(for: meta)); deleted.append(meta.id)
      }
    }
    // 已不在本机的目录也可以确认删除，仍在录的不能 ack。
    return Array(Set(deleted + deleting.filter { id in !all.contains { $0.id == id && $0.status == .open } }))
  }
  public func recoverInterrupted() throws {
    for var meta in try conversations() where meta.status == .open {
      guard let end = meta.segments.compactMap({ AudioPolicy.date($0.t_end) }).max() else {
        try fm.removeItem(at: directory(for: meta)); continue
      }
      meta.t_end = LocalTime.iso(end); try meta.transition(to: .closed, at: Date()); try writeMetadata(meta)
    }
  }
  private static let documentHeader = Data("RAAE1".utf8)
  private func validateDocument(_ url: URL) throws {
    let base = root.standardizedFileURL.pathComponents, parts = url.standardizedFileURL.pathComponents
    guard ["meta.json", "speakers.json"].contains(url.lastPathComponent), parts.count > base.count,
          Array(parts.prefix(base.count)) == base else { throw AudioError.invalidPath }
    // contentsOfDirectory 返回的 URL 可能带 baseURL；按绝对路径组件检查，不能靠相对 URL 循环退父级。
    for length in stride(from: parts.count, through: base.count, by: -1) {
      try rejectLink(URL(fileURLWithPath: NSString.path(withComponents: Array(parts.prefix(length)))))
    }
  }
  /// 旧 JSON 首次读取时原位加密，任何解密/JSON 校验失败均保留原文件并报错。
  public func readPrivateData(at url: URL, migrate: Bool = true) throws -> Data {
    try validateDocument(url)
    let data = try Data(contentsOf: url)
    if data.starts(with: Self.documentHeader) {
      return try AES.GCM.open(AES.GCM.SealedBox(combined: data.dropFirst(Self.documentHeader.count)), using: key,
                              authenticating: Data(url.lastPathComponent.utf8))
    }
    _ = try JSONSerialization.jsonObject(with: data)
    if migrate { try writePrivateData(data, to: url) }
    return data
  }
  public func writePrivateData(_ data: Data, to url: URL) throws {
    try validateDocument(url)
    let box = try AES.GCM.seal(data, using: key, authenticating: Data(url.lastPathComponent.utf8))
    guard let encrypted = box.combined else { throw AudioError.invalidMetadata }
    try atomic(Self.documentHeader + encrypted, to: url)
  }
  private func validateFile(_ file: String) throws {
    guard file.range(of: "^(mic|sys)-[0-9]{4,}\\.enc$", options: .regularExpression) != nil else { throw AudioError.invalidPath }
  }
  private func rejectLink(_ url: URL) throws {
    if (try? fm.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType) == .typeSymbolicLink { throw AudioError.invalidPath }
  }
  private func atomic(_ data: Data, to url: URL) throws {
    try rejectLink(url)
    try data.write(to: url, options: .atomic)
    try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
  }
}
