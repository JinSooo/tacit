import Foundation

/// 标记跨进程保留；只有用户手动重试才解除上次启动崩溃后的暂停。
public final class RecordingStartGuard {
  public let marker: URL
  public private(set) var blocked: Bool
  private var depth = 0
  public init(dataDirectory: URL) {
    marker = dataDirectory.appendingPathComponent("collector-recording-starting")
    blocked = FileManager.default.fileExists(atPath: marker.path)
  }
  public func allowManualRetry() throws {
    try clear()
    blocked = false
  }
  /// 嵌套启动只由最外层清标记；普通错误也清理，进程崩溃则保留。
  public func attempt(_ operation: () throws -> Void) throws {
    if depth == 0 { try begin() }
    depth += 1
    do {
      try operation()
    } catch {
      depth -= 1
      if depth == 0 { try clear() }
      throw error
    }
    depth -= 1
    if depth == 0 { try clear() }
  }
  public func begin() throws {
    guard !blocked else { throw CocoaError(.userCancelled) }
    try FileManager.default.createDirectory(at: marker.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("starting\n".utf8).write(to: marker, options: .atomic)
  }
  public func clear() throws {
    if FileManager.default.fileExists(atPath: marker.path) { try FileManager.default.removeItem(at: marker) }
  }
}
