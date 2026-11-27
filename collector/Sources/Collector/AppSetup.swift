import AppKit
import CollectorCore

/// 应用包自带的后台运行目录和运行时 Contents/Helpers/Tacit（即 Bun，安装包和 install.sh 构建的应用都有）。
struct Bundled {
  let runtime: String
  let bun: String
  static let current: Bundled? = {
    guard let resources = Bundle.main.resourceURL, let executable = Bundle.main.executableURL else { return nil }
    let runtime = resources.appendingPathComponent("runtime").path
    let bun = executable.deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("Helpers/Tacit").path
    guard FileManager.default.fileExists(atPath: runtime + "/hub/src/cli.ts"),
          FileManager.default.isExecutableFile(atPath: bun) else { return nil }
    return Bundled(runtime: runtime, bun: bun)
  }()
}

/// 启动时的安装准备：首次打开或升级后初始化数据与密钥、写后台服务配置并启动；之后每次打开只核对有无变化。
enum AppSetup {
  @MainActor static func checkPlacement() -> Bool {
    let placement = AppPlacement.of(bundlePath: Bundle.main.bundlePath,
                                    home: FileManager.default.homeDirectoryForCurrentUser.path)
    guard placement == .mustMove else { return true }
    askToMove()
    return false
  }

  enum Activity: Equatable {
    case idle, running, finished(SetupStatus.Reason?)

    var failure: SetupStatus.Reason? {
      if case .finished(let reason) = self { return reason }
      return nil
    }
  }

  private static let lock = NSLock()
  private static var currentActivity = Activity.idle
  static var activity: Activity { lock.withLock { currentActivity } }

  enum ChecklistStep: Equatable {
    case preparing
    case failed(String)
  }

  /// The ordinary viewer requests wait through startup. The checklist needs a single short probe
  /// so a known failure can be shown immediately and offline port settings stay available.
  static func isReachable(_ base: URL) async -> Bool {
    struct Health: Decodable { let ok: Bool }
    let request = URLRequest(url: base.appendingPathComponent("v1/health"),
                             cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 2)
    guard let reply = try? await LocalDeviceLink.request(request, session: .shared), reply.statusCode == 200,
          let health = try? JSONDecoder().decode(Health.self, from: reply.body) else { return false }
    return health.ok
  }

  static func checklistStep(in dataDir: URL, reachable: Bool) -> ChecklistStep? {
    checklistStep(activity: activity, reachable: reachable, inStartupGrace: HubAPI.inStartupGrace(),
                  startupMessage: DiagnosticSummary.startupMessage(in: dataDir))
  }

  static func checklistStep(activity: Activity, reachable: Bool, inStartupGrace: Bool,
                            startupMessage: @autoclosure () -> String?) -> ChecklistStep? {
    if let reason = activity.failure {
      return .failed(L10n.Settings.setupFailure(reason))
    }
    if reachable { return nil }
    if activity == .running || inStartupGrace { return .preparing }
    return .failed(startupMessage() ?? L10n.Settings.setupFailure(.unknown))
  }

  /// 用户手动打开时，准备完成后让 launchd 起一份待命实例；launchd 拉起的自己就是那份。
  static func start(config: Config, startup: LoginStartup, writeGate: RemoteSwitchWriteGate? = nil, standby: Bool = false,
                    retry: Bool = false, port: Int? = nil, completion: ((Result<Void, Error>) -> Void)? = nil) {
    guard lock.withLock({
      guard currentActivity != .running, retry || currentActivity == .idle else { return false }
      currentActivity = .running
      return true
    }) else {
      completion?(.failure(HubError(message: L10n.Settings.preparingBackend, status: 0)))
      return
    }

    DispatchQueue.global(qos: .utility).async {
      var reason: SetupStatus.Reason?
      var result: Result<Void, Error> = .success(())
      defer {
        lock.withLock { currentActivity = .finished(reason) }
        completion?(result)
      }
      do {
        try writeGate?.begin()
        defer { writeGate?.end() }
        guard shouldRunBundledSetup(in: config.dataDir), !retry || config.allowsLocalHub else {
          throw HubError.invalidBinding
        }
        if let port {
          do { try config.writeHubPort(port) }
          catch { throw HubError(message: L10n.Settings.offlinePortSaveFailed, status: 0) }
        }
        let bundle = Bundle.main.bundlePath
        if AppPlacement.of(bundlePath: bundle, home: FileManager.default.homeDirectoryForCurrentUser.path) == .installed {
          if let bundled = Bundled.current {
            reason = run(config: config, app: bundle, bundled: bundled, retry: retry).reason
          } else {
            reason = .bundleIncomplete
          }
          if let reason {
            throw HubError(message: L10n.Settings.setupFailure(reason), status: 0)
          }
          if standby { startup.ensureCollectorStandby() }
        } else {
          startup.startServices()
        }
      } catch {
        result = .failure(error)
      }
    }
  }

  /// Remote-aware setup still refreshes the installed collector and AI launch configuration.
  /// A local recovery must restore its definitions before the bundled installer can touch the DB.
  static func shouldRunBundledSetup(in directory: URL) -> Bool {
    guard let binding = try? HubBinding.read(from: directory) else { return false }
    return binding.phase == .committed || LocalServiceStartupPolicy.allowsBackground(in: directory)
  }

  private static func run(config: Config, app: String, bundled: Bundled, retry: Bool) -> SetupStatus {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: bundled.bun)
    p.arguments = [bundled.runtime + "/hub/src/cli.ts", "setup", "--app", app] + (retry ? ["--retry"] : [])
    p.currentDirectoryURL = URL(fileURLWithPath: bundled.runtime)
    var environment = ProcessInfo.processInfo.environment
    environment["RA_DATA_DIR"] = config.dataDir.path
    p.environment = environment
    return SetupStatus.run(p, dataDirectory: config.dataDir)
  }

  @MainActor private static func askToMove() {
    NSApp.setActivationPolicy(.regular)
    NSApp.activate(ignoringOtherApps: true)
    let alert = NSAlert()
    if Bundle.main.bundlePath.contains("/AppTranslocation/") {
      // 已经在“应用程序”里，但不是用访达拖进去的（例如命令行复制），macOS 会挪到临时位置运行（2026-11-25 虚拟机实测）。
      alert.messageText = L10n.Settings.temporaryAppLocation
      alert.informativeText = L10n.Settings.moveAppAndBack
    } else {
      alert.messageText = L10n.Settings.moveAppToApplications
      alert.informativeText = L10n.Settings.launchFromApplications
    }
    alert.addButton(withTitle: L10n.Settings.openApplications)
    alert.addButton(withTitle: L10n.Settings.quit)
    if alert.runModal() == .alertFirstButtonReturn {
      NSWorkspace.shared.open(URL(fileURLWithPath: "/Applications"))
    }
    NSApp.terminate(nil)
  }
}

/// 第一次开启录音时下载本机语音模型（约 270MB），由后台运行时下载并校验。
final class AudioModelDownload {
  private let config: Config
  private let lock = NSLock()
  private var running = false
  private(set) var lastFailure: String?

  init(config: Config) { self.config = config }

  static let files = ["silero_vad.onnx", "3dspeaker_speech_eres2net_base_sv_zh-cn_3dspeaker_16k.onnx",
                      "sense-voice/model.int8.onnx", "sense-voice/tokens.txt"]
  var ready: Bool {
    let models = config.dataDir.appendingPathComponent("models")
    return Self.files.allSatisfy { FileManager.default.fileExists(atPath: models.appendingPathComponent($0).path) }
  }
  var inProgress: Bool { lock.lock(); defer { lock.unlock() }; return running }

  /// 已在下载时不重复启动；完成后回调在后台线程。
  func start(completion: @escaping (Bool) -> Void) {
    lock.lock()
    if running { lock.unlock(); return }
    guard let repo = config.repo, FileManager.default.isExecutableFile(atPath: config.bun) else {
      lastFailure = L10n.Settings.speechModelInstallationMissing(); lock.unlock(); completion(false); return
    }
    running = true; lastFailure = nil; lock.unlock()
    DispatchQueue.global(qos: .utility).async { [self] in
      let p = Process(), err = Pipe()
      p.executableURL = URL(fileURLWithPath: config.bun)
      p.arguments = [repo + "/hub/src/cli.ts", "audio-models"]
      var env = ProcessInfo.processInfo.environment; env["RA_DATA_DIR"] = config.dataDir.path; p.environment = env
      p.standardOutput = FileHandle.nullDevice; p.standardError = err; p.standardInput = FileHandle.nullDevice
      var ok = false, reason = ""
      do {
        try p.run()
        let data = err.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
        ok = p.terminationStatus == 0
        reason = String(decoding: data, as: UTF8.self)
      } catch { /* No category was emitted. */ }
      lock.lock(); running = false
      if !ok { lastFailure = L10n.Settings.speechModelDownloadMessage(stderr: reason) }
      lock.unlock()
      completion(ok)
    }
  }
}
