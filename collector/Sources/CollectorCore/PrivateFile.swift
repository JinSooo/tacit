import Foundation

/// 原子替换也保持仅当前用户可读写，避免每次状态更新恢复成 0644。
public enum PrivateFile {
  public static func write(_ data: Data, to url: URL) throws {
    let temporary = url.deletingLastPathComponent().appendingPathComponent(".private-\(UUID().uuidString)")
    let fm = FileManager.default
    guard fm.createFile(atPath: temporary.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
      throw CocoaError(.fileWriteUnknown)
    }
    defer { try? fm.removeItem(at: temporary) }
    try data.write(to: temporary)
    guard rename(temporary.path, url.path) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
  }
}
