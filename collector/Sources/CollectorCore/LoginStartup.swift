import Foundation

/// 登录启动与当前运行分开：停用时移出 LaunchAgents，保留定义供手动打开时启动后台服务。
/// 不卸载当前任务，因此切换不会打断录音、丢掉内存队列或中断整理。
public struct LoginStartup {
  public static let jobs = ["hub", "distill", "collector"]
  public let agents: URL
  public let manual: URL
  private let dataDir: URL
  private let fm = FileManager.default
  private let beginWrite: () throws -> Void
  private let endWrite: () -> Void

  public init(home: URL, dataDir: URL, beginWrite: @escaping () throws -> Void = {},
              endWrite: @escaping () -> Void = {}) {
    self.dataDir = dataDir
    self.beginWrite = beginWrite
    self.endWrite = endWrite
    agents = home.appendingPathComponent("Library/LaunchAgents")
    manual = dataDir.appendingPathComponent("launch-agents")
  }
  public func file(_ job: String, enabled: Bool) -> URL {
    (enabled ? agents : manual).appendingPathComponent("dev.record-anything.\(job).plist")
  }
  private var relevantJobs: [String] {
    (try? HubBinding.read(from: dataDir).route.remote) != nil ? ["collector"] : Self.jobs
  }
  public var installed: Bool {
    relevantJobs.filter { $0 != "distill" }.allSatisfy { job in
      fm.fileExists(atPath: file(job, enabled: true).path) || fm.fileExists(atPath: file(job, enabled: false).path)
    }
  }
  public var enabled: Bool {
    installed && relevantJobs.allSatisfy { !fm.fileExists(atPath: file($0, enabled: false).path) }
  }
  public var mixed: Bool {
    relevantJobs.contains { fm.fileExists(atPath: file($0, enabled: true).path) }
      && relevantJobs.contains { fm.fileExists(atPath: file($0, enabled: false).path) }
  }

  public func setEnabled(_ enabled: Bool) throws {
    do { try beginWrite() } catch { throw StartupError.switching }
    defer { endWrite() }
    guard let binding = try? HubBinding.read(from: dataDir),
          binding.phase == .committed || LocalServiceStartupPolicy.allowsBackground(in: dataDir) else {
      throw StartupError.switching
    }
    guard installed else { throw StartupError.notInstalled }
    let moves = relevantJobs.compactMap { job -> (URL, URL)? in
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
  public func startServices(launchctl override: (([String]) -> Int32)? = nil) {
    guard LocalServiceStartupPolicy.allowsBackground(in: dataDir) else { return }
    let launchctl = override ?? self.launchctl
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

  /// 用户手动打开时，让 launchd 也起一份待命的采集端：这份崩溃时它立刻接手（见 main.swift 的单实例锁）。
  /// 安装包首次打开只写好登录启动定义、要到下次登录才由 launchd 接管，期间崩溃就没人拉起（2026-11-25 虚拟机实测）。
  /// 只在开着登录启动时做；关了登录启动就只管本次使用。
  public func ensureCollectorStandby(launchctl override: (([String]) -> (Int32, String))? = nil) {
    let definition = file("collector", enabled: true)
    guard fm.fileExists(atPath: definition.path) else { return }
    let launchctl = override ?? self.launchctlOutput
    let target = "gui/\(getuid())/dev.record-anything.collector"
    let (status, description) = launchctl(["print", target])
    if status != 0 {
      _ = launchctl(["bootstrap", "gui/\(getuid())", definition.path])
    } else if !description.contains("state = running") {
      _ = launchctl(["kickstart", target])
    }
  }

  private func launchctlOutput(_ args: [String]) -> (Int32, String) {
    let p = Process(), out = Pipe()
    p.executableURL = URL(fileURLWithPath: "/bin/launchctl"); p.arguments = args
    p.standardOutput = out; p.standardError = FileHandle.nullDevice
    do {
      try p.run()
      let data = out.fileHandleForReading.readDataToEndOfFile()
      p.waitUntilExit()
      return (p.terminationStatus, String(decoding: data, as: UTF8.self))
    } catch { return (-1, "") }
  }

  private func launchctl(_ args: [String]) -> Int32 {
    let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/launchctl"); p.arguments = args
    p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
    do { try p.run(); p.waitUntilExit(); return p.terminationStatus } catch { return -1 }
  }

  enum StartupError: LocalizedError {
    case notInstalled, duplicate, switching
    var errorDescription: String? {
      switch self {
      case .switching: return L10n.text(zh: "后台正在切换，登录启动暂时无法更改。", en: "Wait for the background service to finish switching before changing login startup.")
      case .notInstalled: return L10n.text(zh: "启动配置不完整，请重新安装应用后再试。", en: "Startup settings are incomplete. Reinstall Tacit and try again.")
      case .duplicate: return L10n.text(zh: "发现重复的启动配置，未作更改。请重新安装应用后再试。", en: "Duplicate startup settings were found, so the change was skipped. Reinstall Tacit and try again.")
      }
    }
  }
}
