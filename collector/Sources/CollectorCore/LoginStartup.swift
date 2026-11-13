import Foundation

/// 登录启动与当前运行分开：停用时移出 LaunchAgents，保留定义供手动打开时启动后台服务。
/// 不卸载当前任务，因此切换不会打断录音、丢掉内存队列或中断整理。
public struct LoginStartup {
  public static let jobs = ["hub", "distill", "collector"]
  public let agents: URL
  public let manual: URL
  private let fm = FileManager.default

  public init(home: URL, dataDir: URL) {
    agents = home.appendingPathComponent("Library/LaunchAgents")
    manual = dataDir.appendingPathComponent("launch-agents")
  }
  public func file(_ job: String, enabled: Bool) -> URL {
    (enabled ? agents : manual).appendingPathComponent("dev.record-anything.\(job).plist")
  }
  public var installed: Bool {
    ["hub", "collector"].allSatisfy { job in
      fm.fileExists(atPath: file(job, enabled: true).path) || fm.fileExists(atPath: file(job, enabled: false).path)
    }
  }
  public var enabled: Bool {
    installed && Self.jobs.allSatisfy { !fm.fileExists(atPath: file($0, enabled: false).path) }
  }
  public var mixed: Bool {
    Self.jobs.contains { fm.fileExists(atPath: file($0, enabled: true).path) }
      && Self.jobs.contains { fm.fileExists(atPath: file($0, enabled: false).path) }
  }

  public func setEnabled(_ enabled: Bool) throws {
    guard installed else { throw StartupError.notInstalled }
    let moves = Self.jobs.compactMap { job -> (URL, URL)? in
      let from = file(job, enabled: !enabled), to = file(job, enabled: enabled)
      guard fm.fileExists(atPath: from.path) else { return nil }
      return (from, to)
    }
    // 先检查冲突，失败时不改变任何一项。
    guard !moves.contains(where: { fm.fileExists(atPath: $0.1.path) }) else { throw StartupError.duplicate }
    try fm.createDirectory(at: enabled ? agents : manual, withIntermediateDirectories: true)
    var moved: [(URL, URL)] = []
    do {
      for (from, to) in moves { try fm.moveItem(at: from, to: to); moved.append((from, to)) }
    } catch {
      for (from, to) in moved.reversed() { try? fm.moveItem(at: to, to: from) }
      throw error
    }
  }

  /// Finder 手动启动时，即使登录自启关闭，也启动本次使用所需的两个后台任务。
  public func startServices() {
    let domain = "gui/\(getuid())"
    for job in ["hub", "distill"] {
      let definition = file(job, enabled: true)
      let url = fm.fileExists(atPath: definition.path) ? definition : file(job, enabled: false)
      guard fm.fileExists(atPath: url.path) else { continue }
      if launchctl(["print", "\(domain)/dev.record-anything.\(job)"]) != 0 {
        _ = launchctl(["bootstrap", domain, url.path])
      }
    }
  }

  private func launchctl(_ args: [String]) -> Int32 {
    let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/launchctl"); p.arguments = args
    p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
    do { try p.run(); p.waitUntilExit(); return p.terminationStatus } catch { return -1 }
  }

  enum StartupError: LocalizedError {
    case notInstalled, duplicate
    var errorDescription: String? {
      switch self {
      case .notInstalled: return "启动配置不完整，请重新安装应用后再试。"
      case .duplicate: return "发现重复的启动配置，未作更改。请重新安装应用后再试。"
      }
    }
  }
}
