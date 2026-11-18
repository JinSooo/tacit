import AppKit
import CollectorCore

/// 应用包自带的后台运行目录和 bun（安装包和 install.sh 构建的应用都有）。
struct Bundled {
  let runtime: String
  let bun: String
  static let current: Bundled? = {
    guard let resources = Bundle.main.resourceURL, let executable = Bundle.main.executableURL else { return nil }
    let runtime = resources.appendingPathComponent("runtime").path
    let bun = executable.deletingLastPathComponent().appendingPathComponent("bun").path
    guard FileManager.default.fileExists(atPath: runtime + "/hub/src/cli.ts"),
          FileManager.default.isExecutableFile(atPath: bun) else { return nil }
    return Bundled(runtime: runtime, bun: bun)
  }()
}

/// 启动时的安装准备：首次打开或升级后初始化数据与密钥、写后台服务配置并启动；之后每次打开只核对有无变化。
enum AppSetup {
  /// 返回 false 表示应用不在可运行的位置，已提示用户并即将退出。
  static func start(config: Config, startup: LoginStartup) -> Bool {
    let bundle = Bundle.main.bundlePath
    switch AppPlacement.of(bundlePath: bundle, home: FileManager.default.homeDirectoryForCurrentUser.path) {
    case .mustMove:
      MainActor.assumeIsolated { askToMove() }
      return false
    case .installed where Bundled.current != nil:
      DispatchQueue.global(qos: .utility).async { run(config: config, app: bundle) }
    default:
      DispatchQueue.global(qos: .utility).async { startup.startServices() }
    }
    return true
  }

  private static func run(config: Config, app: String) {
    guard let bundled = Bundled.current else { return }
    let logs = config.dataDir.appendingPathComponent("logs")
    try? FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
    let file = logs.appendingPathComponent("setup.log")
    if !FileManager.default.fileExists(atPath: file.path) { FileManager.default.createFile(atPath: file.path, contents: nil) }
    let log = try? FileHandle(forWritingTo: file)
    _ = try? log?.seekToEnd()
    log?.write(Data("\n== \(ISO8601DateFormatter().string(from: Date())) \(app)\n".utf8))
    let p = Process()
    p.executableURL = URL(fileURLWithPath: bundled.bun)
    p.arguments = [bundled.runtime + "/hub/src/cli.ts", "setup", "--app", app]
    p.currentDirectoryURL = URL(fileURLWithPath: bundled.runtime)
    p.standardOutput = log ?? FileHandle.nullDevice
    p.standardError = log ?? FileHandle.nullDevice
    p.standardInput = FileHandle.nullDevice
    do { try p.run(); p.waitUntilExit() } catch { log?.write(Data("无法启动准备流程：\(error.localizedDescription)\n".utf8)) }
    try? log?.close()
  }

  @MainActor private static func askToMove() {
    NSApp.setActivationPolicy(.regular)
    NSApp.activate(ignoringOtherApps: true)
    let alert = NSAlert()
    alert.messageText = "请先把 Tacit 拖到“应用程序”文件夹"
    alert.informativeText = "从“应用程序”文件夹打开后，Tacit 才能在后台持续记录，并在登录时自动启动。"
    alert.addButton(withTitle: "打开“应用程序”文件夹")
    alert.addButton(withTitle: "退出")
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
      lastFailure = "安装不完整，无法下载语音模型，请重新安装 Tacit"; lock.unlock(); completion(false); return
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
        reason = String(decoding: data, as: UTF8.self).split(separator: "\n").last.map(String.init) ?? ""
      } catch { reason = error.localizedDescription }
      lock.lock(); running = false
      if !ok { lastFailure = "语音模型下载失败" + (reason.isEmpty ? "" : "：\(reason)") + "。请检查网络，稍后会自动重试" }
      lock.unlock()
      completion(ok)
    }
  }
}
