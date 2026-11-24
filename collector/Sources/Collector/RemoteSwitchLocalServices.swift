import CollectorCore
import Darwin
import Foundation

struct DiskRemoteSwitchPersistence: RemoteSwitchPersistence {
  let directory: URL

  func binding() throws -> HubBinding { try HubBinding.read(from: directory) }
  func publish(_ next: HubBinding, replacing previous: HubBinding) throws {
    try next.write(to: directory, replacing: previous)
  }
  func checkpoint() throws -> RemoteSwitchCheckpoint? {
    try LocalServiceStartupPolicy.readCheckpoint(in: directory).map {
      try JSONDecoder().decode(RemoteSwitchCheckpoint.self, from: $0)
    }
  }
  func save(_ checkpoint: RemoteSwitchCheckpoint) throws {
    try LocalServiceStartupPolicy.writeCheckpoint(JSONEncoder().encode(checkpoint), in: directory)
  }
  func clearCheckpoint() throws { try LocalServiceStartupPolicy.removeCheckpoint(in: directory) }

  func hasAgentLink(for remote: HubBinding.Remote) -> Bool {
    let root = directory.appendingPathComponent(remote.dir, isDirectory: true)
    return (try? LocalDeviceLink.Files(directory: root).read(.agent)) != nil
  }

  func clearAgentContext(for route: HubBinding.Route) throws {
    let fs = FileManager.default
    let root = route.remote.map { directory.appendingPathComponent($0.dir) } ?? directory
    if route.remote != nil {
      do {
        let state = try root.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard state.isDirectory == true, state.isSymbolicLink != true else { throw LocalDeviceLink.Failure.unsafeFile }
      } catch CocoaError.fileReadNoSuchFile { return }
      catch CocoaError.fileNoSuchFile { return }
    }
    let cache = root.appendingPathComponent("agent-context-cache")
    func directories(_ root: URL) throws -> [URL] {
      do {
        let state = try root.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard state.isDirectory == true, state.isSymbolicLink != true else { throw LocalDeviceLink.Failure.unsafeFile }
        return try fs.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey])
      }
      catch CocoaError.fileReadNoSuchFile { return [] }
      catch CocoaError.fileNoSuchFile { return [] }
    }
    // Audit entries live inside each identity scope and must remain available to that identity.
    for scope in try directories(cache) {
      let state = try scope.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
      guard state.isDirectory == true, state.isSymbolicLink != true else { continue }
      for file in try directories(scope) where file.lastPathComponent != "audit" {
        do { try fs.removeItem(at: file) }
        catch CocoaError.fileNoSuchFile {}
      }
    }
  }
}

struct LocalHistoryPreview: Decodable, Equatable, Sendable {
  let total: Int
  let privateCount: Int

  enum Failure: LocalizedError {
    case unavailable
    var errorDescription: String? { "无法读取本机记录数量。" }
  }

  private enum CodingKeys: String, CodingKey { case total, privateCount = "private_count" }

  static func load(config: Config) async throws -> Self {
    let route = try config.hubRoute()
    guard route.remote == nil else { throw HubBinding.Failure.changed }
    guard let runtime = config.repo else { throw Failure.unavailable }
    let preview = try await Task.detached(priority: .utility) {
      let result = try LaunchdRemoteSwitchServices.runProcess(config.bun,
        [runtime + "/hub/src/cli.ts", "history-export", "--preview", "--data-dir", config.dataDir.path], 25)
      guard result.status == 0,
            let counts = try? JSONDecoder().decode(Self.self, from: Data(result.stdout.utf8)),
            counts.total >= 0, counts.privateCount >= 0 else { throw Failure.unavailable }
      return counts
    }.value
    guard try config.hubRoute() == route else { throw HubBinding.Failure.changed }
    return preview
  }
}

struct LaunchdRemoteSwitchServices: RemoteSwitchServices {
  typealias Failure = RemoteSwitch.Failure
  private let config: Config
  private let startup: LoginStartup
  private let fs = FileManager.default
  private let domain = "gui/\(getuid())"

  struct CommandResult {
    let status: Int32
    let stdout: String
  }

  typealias Command = (String, [String], TimeInterval) throws -> CommandResult
  typealias Probe = (URLRequest) async throws -> DeviceTransportResponse
  private let execute: Command
  private let probe: Probe
  private let pidIsRunning: (Int32) -> Bool
  private let verificationTimeout: TimeInterval
  private let processQueue = DispatchQueue(label: "record-anything.switch-process", qos: .utility)

  init(config: Config, startup: LoginStartup, execute: @escaping Command = LaunchdRemoteSwitchServices.runProcess,
       probe: @escaping Probe = { try await LocalDeviceLink.request($0) },
       pidIsRunning: @escaping (Int32) -> Bool = { kill($0, 0) == 0 || errno != ESRCH },
       verificationTimeout: TimeInterval = 25) {
    self.config = config
    self.startup = startup
    self.execute = execute
    self.probe = probe
    self.pidIsRunning = pidIsRunning
    self.verificationTimeout = verificationTimeout
  }

  private var database: URL { config.dataDir.appendingPathComponent("history.db") }
  private var stagedHub: URL { config.dataDir.appendingPathComponent(LocalSwitchJob.hub.label + ".switch-back.plist") }

  private struct SetupSelection: Decodable { let distill: Bool }

  func snapshot() async throws -> LocalSwitchSnapshot {
    func read(_ job: LocalSwitchJob) async throws -> LocalSwitchSnapshot.Definition? {
      let loaded = try await state(job) != nil
      var result: LocalSwitchSnapshot.Definition?
      for login in [true, false] {
        let path = startup.file(job.rawValue, enabled: login)
        guard try exists(path) else { continue }
        guard result == nil else { throw Failure.servicesUnavailable }
        let plist = try Data(contentsOf: path)
        try validate(plist, job: job)
        result = .init(plist: plist, login: login, loaded: loaded)
      }
      guard !loaded || result != nil else { throw Failure.servicesUnavailable }
      return result
    }
    guard let hub = try await read(.hub) else { throw Failure.servicesUnavailable }
    let distill = try await read(.distill)
    let stamp = try? Data(contentsOf: config.dataDir.appendingPathComponent("app-setup.json"))
    let setup = stamp.flatMap { try? JSONDecoder().decode(SetupSelection.self, from: $0) }
    return .init(hub: hub, distill: distill, loginEnabled: startup.enabled,
                 distillEnabled: distill != nil && setup?.distill != false,
                 audioRetentionDays: hub.loaded ? await readAudioRetention() : nil)
  }

  private struct AudioSettings: Decodable { let retention_days: Int }

  private func readAudioRetention() async -> Int? {
    guard let token = config.token, !token.isEmpty else { return nil }
    var request = URLRequest(url: config.hubURL.appendingPathComponent("v1/audio/settings"), timeoutInterval: 3)
    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    guard let reply = try? await probe(request), reply.statusCode == 200,
          let settings = try? JSONDecoder().decode(AudioSettings.self, from: reply.body),
          (0...365).contains(settings.retention_days) else { return nil }
    return settings.retention_days
  }

  func stop(_ job: LocalSwitchJob) async throws {
    guard let before = try await state(job) else { return }
    _ = try await command("/bin/launchctl", ["bootout", "\(domain)/\(job.label)"])
    let deadline = ProcessInfo.processInfo.systemUptime + 10
    repeat {
      let running = before.pid.map(pidIsRunning) ?? false
      if try await state(job) == nil, !running { return }
      try await Task.sleep(for: .milliseconds(100))
    } while ProcessInfo.processInfo.systemUptime < deadline
    throw Failure.servicesUnavailable
  }

  func verifyClosedDatabase() async throws {
    guard try exists(database), try await state(.hub) == nil, try await state(.distill) == nil else {
      throw Failure.databaseInUse
    }
    for suffix in ["-wal", "-journal", "-shm"] {
      if try exists(URL(fileURLWithPath: database.path + suffix)) { throw Failure.databaseInUse }
    }
    // Checking the database file itself also catches external readers/writers that leave no sidecar.
    let result = try await command("/usr/sbin/lsof", ["-w", "-t", "--", database.path])
    guard result.status == 1, result.stdout.isEmpty else { throw Failure.databaseInUse }
  }

  func withdrawDefinitions() async throws {
    for job in LocalSwitchJob.allCases {
      for login in [true, false] { try remove(startup.file(job.rawValue, enabled: login)) }
    }
  }

  func preflightReturn(_ local: LocalSwitchSnapshot) async throws {
    try validate(local.hub.plist, job: .hub)
    if local.distillEnabled, let distill = local.distill { try validate(distill.plist, job: .distill) }
    let token = config.dataDir.appendingPathComponent("token")
    if try exists(database) {
      guard fs.isReadableFile(atPath: database.path), fs.isWritableFile(atPath: database.path),
            let size = try database.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > 0 else {
        throw Failure.localHubUnverified
      }
    } else if local.allowEmptyHistory != true {
      throw Failure.localHubUnverified
    }
    guard fs.isWritableFile(atPath: config.dataDir.path), try exists(token),
          let credential = try? String(contentsOf: token, encoding: .utf8),
          !credential.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw Failure.localHubUnverified
    }
  }

  func discardStagedHub() async throws { try remove(stagedHub) }

  func startHubForVerification(_ local: LocalSwitchSnapshot) async throws {
    try await preflightReturn(local)
    // A restart before publication must not load this temporary definition at login.
    try PrivateFile.write(local.hub.plist, to: stagedHub)
    try await load(.hub, definition: stagedHub)
  }

  private struct BackendStatus: Decodable {
    struct Hub: Decodable { let pid: Int32 }
    struct Database: Decodable { let file: String }
    let hub: Hub
    let database: Database
  }

  private struct AudioWriteProbe: Encodable { let device: String; let deleted: [String] = [] }
  private struct AudioWriteAck: Decodable { let acknowledged: Bool }

  func verifyLocalHub() async throws {
    let token = try String(contentsOf: config.dataDir.appendingPathComponent("token"), encoding: .utf8)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !token.isEmpty else { throw Failure.localHubUnverified }
    let deadline = ProcessInfo.processInfo.systemUptime + verificationTimeout
    let probeDevice = "switch-probe-" + UUID().uuidString.lowercased()
    repeat {
      if let pid = try await state(.hub)?.pid, fs.isWritableFile(atPath: database.path) {
        // Require the launched job itself to hold the expected database open read/write.
        let opened = try await command("/usr/sbin/lsof", ["-w", "-a", "-p", String(pid), "-Fa", "--", database.path])
        if opened.status == 0, opened.stdout.split(separator: "\n").contains("au") {
          var status = URLRequest(url: config.hubURL.appendingPathComponent("v1/status"), timeoutInterval: 10)
          status.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
          if let reply = try? await probe(status), reply.statusCode == 200,
             let report = try? JSONDecoder().decode(BackendStatus.self, from: reply.body),
             report.hub.pid == pid, URL(fileURLWithPath: report.database.file).resolvingSymlinksInPath()
                == database.resolvingSymlinksInPath() {
            // An empty deletion acknowledgement takes an IMMEDIATE transaction. A unique synthetic
            // device forces a disk write without touching a real device's queue or creating History.
            var write = URLRequest(url: config.hubURL.appendingPathComponent("v1/audio/sync/ack"), timeoutInterval: 10)
            write.httpMethod = "POST"
            write.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            write.setValue("application/json", forHTTPHeaderField: "Content-Type")
            write.httpBody = try JSONEncoder().encode(AudioWriteProbe(device: probeDevice))
            if let reply = try? await probe(write), reply.statusCode == 200,
               (try? JSONDecoder().decode(AudioWriteAck.self, from: reply.body).acknowledged) == true { return }
          }
        }
      }
      if ProcessInfo.processInfo.systemUptime >= deadline { break }
      try await Task.sleep(for: .milliseconds(250))
    } while true
    throw Failure.localHubUnverified
  }

  func restore(_ local: LocalSwitchSnapshot, afterSwitchBack: Bool) async throws {
    for job in [LocalSwitchJob.hub, .distill] {
      if afterSwitchBack, job == .distill, !local.distillEnabled {
        for login in [true, false] { try remove(startup.file(job.rawValue, enabled: login)) }
        continue
      }
      guard let saved = local[job] else { continue }
      try validate(saved.plist, job: job)
      let path = startup.file(job.rawValue, enabled: afterSwitchBack ? local.loginEnabled : saved.login)
      let other = startup.file(job.rawValue, enabled: !(afterSwitchBack ? local.loginEnabled : saved.login))
      try fs.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
      try PrivateFile.write(saved.plist, to: path)
      try remove(other)
      if afterSwitchBack ? (job == .hub || local.distillEnabled) : saved.loaded {
        if afterSwitchBack, job == .hub, let registered = try await state(.hub), !Self.samePath(registered.path, path) {
          try await stop(.hub)
        }
        try await load(job, definition: path)
        if afterSwitchBack, job == .hub {
          guard Self.samePath(try await state(.hub)?.path, path) else { throw Failure.servicesUnavailable }
        }
      }
    }
    if afterSwitchBack {
      let from = startup.file("collector", enabled: !local.loginEnabled)
      let to = startup.file("collector", enabled: local.loginEnabled)
      if try exists(from) {
        guard try !exists(to) else { throw Failure.servicesUnavailable }
        try fs.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fs.moveItem(at: from, to: to)
      }
    }
    try remove(stagedHub)
  }

  private func validate(_ bytes: Data, job: LocalSwitchJob) throws {
    guard let plist = try PropertyListSerialization.propertyList(from: bytes, format: nil) as? [String: Any],
          plist["Label"] as? String == job.label else { throw Failure.servicesUnavailable }
  }

  private func exists(_ url: URL) throws -> Bool {
    var info = stat()
    if lstat(url.path, &info) == 0 {
      guard info.st_mode & S_IFMT == S_IFREG else { throw Failure.servicesUnavailable }
      return true
    }
    guard errno == ENOENT else { throw Failure.servicesUnavailable }
    return false
  }

  private func remove(_ url: URL) throws {
    if try exists(url) { try fs.removeItem(at: url) }
  }

  private struct JobState { let pid: Int32?; let path: String? }

  private func state(_ job: LocalSwitchJob) async throws -> JobState? {
    let result = try await command("/bin/launchctl", ["print", "\(domain)/\(job.label)"])
    guard result.status == 0 else {
      // Do not mistake an unavailable GUI launchd domain for an unloaded job.
      guard try await command("/bin/launchctl", ["print", domain]).status == 0 else { throw Failure.servicesUnavailable }
      return nil
    }
    var pid: Int32?, path: String?
    for line in result.stdout.split(separator: "\n") {
      let fields = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
      guard fields.count == 2 else { continue }
      if fields[0] == "pid", let value = Int32(fields[1]), value > 1 { pid = value }
      if fields[0] == "path", path == nil { path = fields[1] }
    }
    return JobState(pid: pid, path: path)
  }

  private func load(_ job: LocalSwitchJob, definition: URL) async throws {
    guard try await state(job) == nil else { return }
    let result = try await command("/bin/launchctl", ["bootstrap", domain, definition.path])
    if result.status != 0 {
      guard Self.samePath(try await state(job)?.path, definition) else { throw Failure.servicesUnavailable }
    }
  }

  private func command(_ executable: String, _ arguments: [String]) async throws -> CommandResult {
    let timeout: TimeInterval = arguments.first == "bootout" ? 30 : 5
    nonisolated(unsafe) let execute = self.execute
    return try await withCheckedThrowingContinuation { continuation in
      processQueue.async {
        continuation.resume(with: Result { try execute(executable, arguments, timeout) })
      }
    }
  }

  /// launchctl print 可能给出规范化后的路径；数据目录或 home 经符号链接访问时也算同一个文件。
  static func samePath(_ reported: String?, _ expected: URL) -> Bool {
    guard let reported else { return false }
    return reported == expected.path
      || URL(fileURLWithPath: reported).resolvingSymlinksInPath().path == expected.resolvingSymlinksInPath().path
  }

  static func runProcess(_ executable: String, _ arguments: [String], _ timeout: TimeInterval) throws -> CommandResult {
    let process = Process(), pipe = Pipe()
    let readEnd = pipe.fileHandleForReading
    let fd = readEnd.fileDescriptor
    guard fcntl(fd, F_SETFL, O_NONBLOCK) == 0 else { throw Failure.servicesUnavailable }
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    try process.run()
    try? pipe.fileHandleForWriting.close()
    defer { try? readEnd.close() }

    let deadline = ProcessInfo.processInfo.systemUptime + timeout
    var buffer = [UInt8](repeating: 0, count: 8192)
    var stdout = Data()
    while true {
      if ProcessInfo.processInfo.systemUptime >= deadline {
        guard process.isRunning else { break }
        kill(process.processIdentifier, SIGKILL)
        process.waitUntilExit()
        let label = URL(fileURLWithPath: executable).lastPathComponent
        let operation = label == "launchctl" ? " " + (arguments.first ?? "") : ""
        throw Failure.commandTimedOut(label + operation)
      }
      let count = read(fd, &buffer, buffer.count)
      if count > 0 {
        // Domain listings can be large. Drain them without retaining unlimited output.
        if stdout.count < 256 * 1024 { stdout.append(contentsOf: buffer.prefix(count)) }
        continue
      }
      if !process.isRunning {
        // 子进程可能在上一次 read 返回 EAGAIN 之后才写出最后的输出并退出：退出后再排空一次管道。
        while case let tail = read(fd, &buffer, buffer.count), tail > 0 {
          if stdout.count < 256 * 1024 { stdout.append(contentsOf: buffer.prefix(tail)) }
        }
        break
      }
      Thread.sleep(forTimeInterval: 0.01)
    }
    process.waitUntilExit()
    guard process.terminationReason == .exit else { throw Failure.servicesUnavailable }
    return CommandResult(status: process.terminationStatus, stdout: String(decoding: stdout, as: UTF8.self))
  }
}
