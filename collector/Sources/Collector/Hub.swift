import Foundation
import CollectorCore

struct Config {
  var dataDir: URL
  var device = "mac"
  /// 命令行或 collector.json 指定的端口；没指定时每次都现读中枢的 hub.json，
  /// 设置页改端口后中枢重启到新端口，采集端不用重启（重启会丢掉内存里还没发出的记录）。
  var fixedPort: String?
  var hubURL: URL { URL(string: "http://127.0.0.1:\(fixedPort ?? Config.hubPort(dataDir) ?? "47823")")! }
  var repo: String?
  var bun: String
  var pluginInterval: TimeInterval = 300

  /// 命令行参数优先，其次是数据目录下的 collector.json；端口再其次读中枢的 hub.json（设置页改端口写在这里），都没有用 47823。
  static func load() -> Config {
    let args = CommandLine.arguments
    func arg(_ name: String) -> String? {
      guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
      return args[i + 1]
    }
    let home = FileManager.default.homeDirectoryForCurrentUser
    let dataDir = URL(fileURLWithPath: arg("--data-dir") ?? home.appendingPathComponent("Library/Application Support/record-anything").path)
    var file: [String: Any] = [:]
    if let d = try? Data(contentsOf: dataDir.appendingPathComponent("collector.json")),
       let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] { file = j }
    var c = Config(dataDir: dataDir, fixedPort: arg("--port") ?? (file["port"] as? Int).map(String.init),
                   repo: arg("--repo") ?? file["repo"] as? String,
                   bun: arg("--bun") ?? file["bun"] as? String ?? home.appendingPathComponent(".bun/bin/bun").path)
    if let d = arg("--device") ?? file["device"] as? String { c.device = d }
    if let i = arg("--plugin-interval").flatMap(Double.init) { c.pluginInterval = i }
    return c
  }

  static func hubPort(_ dataDir: URL) -> String? {
    guard let d = try? Data(contentsOf: dataDir.appendingPathComponent("hub.json")),
          let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
          let p = j["port"] as? Int, (1024...65535).contains(p) else { return nil }
    return String(p)
  }

  var token: String? {
    (try? String(contentsOf: dataDir.appendingPathComponent("token"), encoding: .utf8))?
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }
}

/// 把记录经 POST /v1/ingest 发给 hub。发不出去就留在内存队列里重试。
final class HubClient {
  let config: Config
  let queue = OutboundQueue()
  private var inFlight = false
  private let lock = NSLock()
  private(set) var lastError: String?
  private(set) var sent = 0
  private(set) var rejected = 0
  private var deliveryMetrics = HubDeliveryMetrics()
  var hubBusy: Int { lock.lock(); defer { lock.unlock() }; return deliveryMetrics.hubBusy }

  init(config: Config) { self.config = config }

  func enqueue(_ records: [Record]) { if !records.isEmpty { queue.push(records) } }

  func flush() {
    lock.lock()
    if inFlight { lock.unlock(); return }
    let batch = queue.peek(200)
    if batch.isEmpty { lock.unlock(); return }
    inFlight = true
    lock.unlock()

    guard let token = config.token else { finish(error: "找不到 hub 的 token，hub 是否启动过？", done: nil); return }
    var req = URLRequest(url: config.hubURL.appendingPathComponent("v1/ingest"))
    req.httpMethod = "POST"
    req.timeoutInterval = 15
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    struct Body: Encodable { let device: String; let records: [Record] }
    let enc = JSONEncoder(); enc.outputFormatting = [.withoutEscapingSlashes]
    req.httpBody = try? enc.encode(Body(device: config.device, records: batch))

    URLSession.shared.dataTask(with: req) { [weak self] data, resp, err in
      guard let self else { return }
      let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
      if let err { self.finish(error: "hub 连不上：\(err.localizedDescription)", done: nil); return }
      // 503 是中枢撞上别的进程的写锁、不等锁直接返回：中枢是通的，记录留在队列里下一轮再发，不提示连不上。
      if status == 503 { self.finish(error: nil, done: nil, status: status); return }
      guard status == 200, let data,
            let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        self.finish(error: "hub 返回 \(status)", done: nil); return
      }
      // 被拒的记录重试也不会成功，记数后丢掉；其余视为已送达。
      let bad = (j["rejected"] as? [[String: Any]])?.count ?? 0
      if bad > 0 { NSLog("record-anything: hub 拒收 \(bad) 条：\(String(describing: j["rejected"]))") }
      self.finish(error: nil, done: (Set(batch.map(\.id)), batch.count - bad, bad))
    }.resume()
  }

  private func finish(error: String?, done: (Set<String>, Int, Int)?, status: Int? = nil) {
    lock.lock()
    if let status { deliveryMetrics.received(status: status) }
    inFlight = false
    lastError = error
    if let done { queue.remove(ids: done.0); sent += done.1; rejected += done.2 }
    let more = done != nil && queue.count > 0
    lock.unlock()
    if more { flush() }
  }
}

/// 定时运行外部插件。插件是采集端的子进程，继承采集端的系统权限（实验 0-C）；
/// runner 以 HTTP 模式把记录交给 hub，数据库只由 hub 打开。
/// 所有运行排在一个串行队列里：常规增量、单个"立即运行"和维护导入互不并发，同一插件不会同时跑两份。
final class PluginScheduler {
  struct Outcome { let ok: Bool; let accepted: Int; let text: String; let at: Date }
  let config: Config
  var plugins: [String] { DataSourceCatalog.plugins.map(\.id) + installedExtensions().map(\.id) }
  private var active = Set<String>()
  private var process: Process?
  func setActive(_ id: String, _ on: Bool) {
    lock.lock(); defer { lock.unlock() }
    if on { active.insert(id) } else { active.remove(id); if current == id, let process, process.isRunning { process.terminate() } }
  }
  private func canRun(_ id: String) -> Bool { lock.lock(); defer { lock.unlock() }; return active.contains(id) && isEnabled(id) }
  func installedExtensions() -> [ExtensionPlugin] {
    let root = config.dataDir.appendingPathComponent("extensions")
    return ((try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [])
      .filter { $0.lastPathComponent.hasPrefix("ext-") }
      .compactMap { url in guard let data = try? Data(contentsOf: url.appendingPathComponent("installed.json")) else { return nil }; return try? JSONDecoder().decode(ExtensionPlugin.self, from: data) }
      .sorted { $0.id < $1.id }
  }
  func manage(_ request: PluginRequest) async throws -> PluginResponse {
    let config = self.config
    let queue = ["install", "configure", "uninstall"].contains(request.action) ? jobs : DispatchQueue.global(qos: .utility)
    return try await withCheckedThrowingContinuation { continuation in
      queue.async {
        do {
          guard let repo = config.repo else { throw PluginFailure(message: "找不到安装目录，请重新安装应用。") }
          let p = Process(), output = Pipe(), input = Pipe()
          p.executableURL = URL(fileURLWithPath: config.bun)
          p.arguments = ["\(repo)/hub/src/cli.ts", "plugins"]
          var env = ProcessInfo.processInfo.environment; env["RA_DATA_DIR"] = config.dataDir.path; p.environment = env
          var command = request; command.hub = config.hubURL.absoluteString
          let data = try JSONEncoder().encode(command)
          p.standardOutput = output; p.standardInput = input; p.standardError = FileHandle.nullDevice
          try p.run()
          input.fileHandleForWriting.write(data); try? input.fileHandleForWriting.close()
          let response = output.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
          let result = try JSONDecoder().decode(PluginResponse.self, from: response)
          continuation.resume(returning: result)
        } catch { continuation.resume(throwing: error) }
      }
    }
  }
  /// 由注册表提供：停用的插件不运行。
  var isEnabled: (String) -> Bool = { _ in true }
  private var last: [String: Outcome] = [:]
  private var current: String?
  private var regularQueued = false
  private let lock = NSLock()
  private let jobs = DispatchQueue(label: "record-anything.plugins", qos: .utility)

  init(config: Config) { self.config = config }

  var available: Bool { config.repo != nil && FileManager.default.isExecutableFile(atPath: config.bun) }

  /// 常规增量：已有一轮在排队时不再重复排。
  func runAll() {
    guard available else { return }
    lock.lock(); if regularQueued { lock.unlock(); return }; regularQueued = true; lock.unlock()
    jobs.async {
      self.lock.lock(); self.regularQueued = false; self.lock.unlock()
      for p in self.plugins where self.canRun(p) { _ = self.run(p, since: nil) }
    }
  }

  /// 指定插件运行一次（立即运行、同步、导入）。完成回调在后台线程，参数是每个插件的结果。
  func run(_ names: [String], since: Date?, completion: (([String: Outcome]) -> Void)? = nil) {
    guard available else { completion?([:]); return }
    jobs.async {
      var results: [String: Outcome] = [:]
      for p in names where self.canRun(p) { results[p] = self.run(p, since: since) }
      completion?(results)
    }
  }

  private func run(_ name: String, since: Date?) -> Outcome {
    guard let repo = config.repo else { return Outcome(ok: false, accepted: 0, text: "未配置仓库", at: Date()) }
    lock.lock(); current = name; lock.unlock()
    defer { lock.lock(); current = nil; process = nil; lock.unlock() }
    let p = Process()
    p.executableURL = URL(fileURLWithPath: config.bun)
    if name.hasPrefix("ext-") {
      p.arguments = ["\(repo)/hub/src/cli.ts", "plugin-run", name, "--hub", config.hubURL.absoluteString] + PluginImport.arguments(plugin: name, since: since)
    } else {
      p.arguments = ["\(repo)/hub/src/cli.ts", "run-plugin", name, "--hub", config.hubURL.absoluteString,
                     "--", config.bun, "\(repo)/plugins/\(name)/main.ts"] + PluginImport.arguments(plugin: name, since: since)
    }
    var env = ProcessInfo.processInfo.environment
    env["RA_DATA_DIR"] = config.dataDir.path
    p.environment = env
    let out = Pipe(); p.standardOutput = out; p.standardError = FileHandle.nullDevice
    let started = Date()
    lock.lock()
    guard active.contains(name) && isEnabled(name) else { lock.unlock(); return Outcome(ok: true, accepted: 0, text: "已停用或暂停", at: Date()) }
    do { try p.run(); process = p; lock.unlock() } catch { lock.unlock(); return set(name, Outcome(ok: false, accepted: 0, text: "启动失败", at: Date())) }
    let timer = DispatchWorkItem { if p.isRunning { p.terminate() } }
    DispatchQueue.global().asyncAfter(deadline: .now() + PluginImport.timeout(since: since), execute: timer)
    let data = out.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit(); timer.cancel()
    let summary = String(data: data, encoding: .utf8)?.split(separator: "\n").last.map(String.init) ?? ""
    let ok = p.terminationStatus == 0
    var accepted: Int?
    if let d = summary.data(using: .utf8), let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
       let a = j["accepted"] as? Int { accepted = a }
    let text = PluginImport.outcomeText(ok: ok, exitStatus: p.terminationStatus, accepted: accepted, elapsed: Date().timeIntervalSince(started))
    return set(name, Outcome(ok: ok, accepted: accepted ?? 0, text: text, at: Date()))
  }

  private func set(_ name: String, _ v: Outcome) -> Outcome { lock.lock(); last[name] = v; lock.unlock(); return v }
  func outcome(_ name: String) -> Outcome? { lock.lock(); defer { lock.unlock() }; return last[name] }
  func isRunning(_ name: String) -> Bool { lock.lock(); defer { lock.unlock() }; return current == name }
  /// collector-status.json 用。
  func status() -> [String: String] { lock.lock(); defer { lock.unlock() }; return last.mapValues(\.text) }
}
