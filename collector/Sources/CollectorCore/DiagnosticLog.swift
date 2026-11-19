import Foundation
import ObjectiveC
import Darwin

public struct DiagnosticBuild: Sendable {
  public let version: String
  public let build: String

  public init(bundle: Bundle = .main) {
    version = Self.identifier(bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString"))
    build = Self.identifier(bundle.object(forInfoDictionaryKey: "CFBundleVersion"))
  }

  private static func identifier(_ value: Any?) -> String {
    guard let text = value as? String, text.range(of: #"^[A-Za-z0-9._+-]{1,64}$"#, options: .regularExpression) != nil
    else { return "unknown" }
    return text
  }
}

public final class DiagnosticLog: @unchecked Sendable {
  public enum LaunchSource: String { case launchd, finder, unknown }
  public enum ExitReason: String { case exit, signal }
  public enum Event {
    case started(DiagnosticBuild, LaunchSource)
    case uncaughtException(NSExceptionName)
    case audioWorkerLaunchFailed
    case audioWorkerExit(status: Int32, reason: ExitReason)
    case collectorLogOpenFailed
    case statusWriteFailed
    case outboxDropped(total: Int)
    case outboxDegraded
    case setupStarted
    case setupLogOpenFailed
    case setupStatusWriteFailed
    case setupFinished(exitCode: Int32)

    fileprivate var fields: (component: String, code: String, values: [String: Any], limited: Bool) {
      switch self {
      case let .started(build, source):
        return ("collector", "started", ["version": build.version, "build": build.build, "launched_by": source.rawValue], false)
      case let .uncaughtException(name):
        return ("collector", "uncaught_exception", ["name": Self.exceptionName(name)], false)
      case .audioWorkerLaunchFailed: return ("audio-worker", "audio_worker_launch_failed", [:], true)
      case let .audioWorkerExit(status, reason):
        return ("audio-worker", "audio_worker_exit", ["status": status, "reason": reason.rawValue], true)
      case .collectorLogOpenFailed: return ("collector", "collector_log_open_failed", [:], false)
      case .statusWriteFailed: return ("collector", "status_write_failed", [:], true)
      case let .outboxDropped(total): return ("collector", "outbox_dropped", ["dropped": total], true)
      case .outboxDegraded: return ("collector", "outbox_degraded", [:], true)
      case .setupStarted: return ("setup", "setup_started", [:], false)
      case .setupLogOpenFailed: return ("setup", "setup_log_open_failed", [:], false)
      case .setupStatusWriteFailed: return ("setup", "setup_status_write_failed", [:], false)
      case let .setupFinished(code): return ("setup", "setup_finished", ["exit_code": code], false)
      }
    }

    private static func exceptionName(_ name: NSExceptionName) -> String {
      // 自定义异常也能把任意文本放在 name 里。只允许已知的系统名称。
      switch name {
      case .genericException, .rangeException, .invalidArgumentException, .internalInconsistencyException,
           .mallocException, NSExceptionName("com.apple.coreaudio.avfaudio"), NSExceptionName("AVFAudio"):
        return name.rawValue
      default: return "other"
      }
    }
  }

  public static let shared = DiagnosticLog()
  private let lock = NSLock()
  private struct Rate {
    var count = 0
    var lastWrite: TimeInterval?
  }
  private var rates: [String: Rate] = [:]
  private let interval: TimeInterval = 600
  public init() {}

  public func record(_ event: Event, to descriptor: Int32 = STDERR_FILENO, at: Date = Date(),
                     uptime: TimeInterval = ProcessInfo.processInfo.systemUptime) {
    let fields = event.fields
    if !fields.limited {
      // 未捕获异常可能发生在持锁线程上。该路径只做一次同步写入。
      Self.emit(fields, at: at, to: descriptor)
      return
    }
    lock.lock(); defer { lock.unlock() }
    var rate = rates[fields.code, default: Rate()]
    rate.count += 1
    defer { rates[fields.code] = rate }
    if let last = rate.lastWrite, uptime - last < interval { return }
    rate.lastWrite = uptime
    var line = fields
    line.values["count"] = rate.count
    Self.emit(line, at: at, to: descriptor)
  }

  private static func emit(_ fields: (component: String, code: String, values: [String: Any], limited: Bool),
                           at: Date, to descriptor: Int32) {
    var values = fields.values
    values["at"] = LocalTime.iso(at)
    values["component"] = fields.component
    values["code"] = fields.code
    guard var data = try? JSONSerialization.data(withJSONObject: values, options: [.sortedKeys]) else { return }
    data.append(0x0a)
    data.withUnsafeBytes { bytes in
      while Darwin.write(descriptor, bytes.baseAddress, bytes.count) < 0 && errno == EINTR {}
    }
  }

  public static func installUncaughtExceptionHandler() {
    NSSetUncaughtExceptionHandler { exception in
      DiagnosticLog.shared.record(.uncaughtException(exception.name))
    }
    // Foundation 会先把 reason 和堆栈写进 stderr，再调用登记的处理器。
    // 从 Objective-C 运行时直接调用该处理器，保留崩溃退出且防止原文落盘。
    _ = objc_setUncaughtExceptionHandler { value in
      if let exception = value as? NSException { NSGetUncaughtExceptionHandler()?(exception) }
      abort()
    }
  }

  /// 打开私有追加日志，保留当前文件 inode，兼容后台复制截断轮转。
  public static func openFile(_ url: URL) throws -> Int32 {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                            attributes: [.posixPermissions: 0o700])
    let fd = open(url.path, O_WRONLY | O_CREAT | O_APPEND | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC, 0o600)
    guard fd >= 0 else { throw CocoaError(.fileWriteUnknown) }
    var info = stat()
    guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, fchmod(fd, 0o600) == 0 else {
      close(fd)
      throw CocoaError(.fileWriteUnknown)
    }
    return fd
  }

  public static func isFile(_ url: URL, on descriptor: Int32) -> Bool {
    var current = stat(), target = stat()
    return fstat(descriptor, &current) == 0 && current.st_mode & S_IFMT == S_IFREG &&
      lstat(url.path, &target) == 0 && current.st_dev == target.st_dev && current.st_ino == target.st_ino
  }

  public static func redirectIfNeeded(to url: URL, descriptor: Int32 = STDERR_FILENO) throws {
    var info = stat()
    if fstat(descriptor, &info) == 0 {
      if info.st_mode & S_IFMT == S_IFREG {
        // launchd 已经打开此文件时，只修改这个 fd，不重定向用户自己的日志。
        if isFile(url, on: descriptor) {
          let flags = fcntl(descriptor, F_GETFL)
          guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_APPEND) == 0, fchmod(descriptor, 0o600) == 0
          else { throw CocoaError(.fileWriteUnknown) }
        }
        return
      }
      if isatty(descriptor) == 1 { return }
    }
    let fd = try openFile(url)
    defer { if fd != descriptor { close(fd) } }
    if fd == descriptor {
      guard fcntl(fd, F_SETFD, 0) == 0 else { throw CocoaError(.fileWriteUnknown) }
    } else if dup2(fd, descriptor) < 0 {
      throw CocoaError(.fileWriteUnknown)
    }
  }
}
