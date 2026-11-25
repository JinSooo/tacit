import Foundation
import CollectorCore
import AudioStore

struct Config {
  var dataDir: URL
  var device = "mac"
  /// 命令行或 collector.json 指定的端口；没指定时每次都现读中枢的 hub.json，
  /// 设置页改端口后中枢重启到新端口，采集端继续重试待发送记录。
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
    // 应用包自带运行目录和 bun 时始终用自带的，首次打开还没写 collector.json 也能运行。
    let bundled = Bundled.current
    var c = Config(dataDir: dataDir, fixedPort: arg("--port") ?? (file["port"] as? Int).map(String.init),
                   repo: arg("--repo") ?? bundled?.runtime ?? file["repo"] as? String,
                   bun: arg("--bun") ?? bundled?.bun ?? file["bun"] as? String ?? home.appendingPathComponent(".bun/bin/bun").path)
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

  func hubRoute() throws -> HubBinding.Route { try HubBinding.read(from: dataDir).route }

  var allowsLocalHub: Bool {
    guard let route = try? hubRoute() else { return false }
    return route.remote == nil
  }

  var token: String? {
    guard allowsLocalHub else { return nil }
    return (try? String(contentsOf: dataDir.appendingPathComponent("token"), encoding: .utf8))?
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }
}

/// 先在独立 I/O 队列脱敏、加密保存，再发送；成功确认后删除本机待发送副本。
final class HubClient: @unchecked Sendable {
  let config: Config
  let queue: OutboundQueue
  private var buffers: [HubBinding.Route?: OutboxBuffer] = [:]
  private var retiredStatus: [HubBinding.Route?: OutboxStatus] = [:]
  private let writeGate: RemoteSwitchWriteGate?
  private let upload: CollectorUpload
  private let openOutbox: (URL) throws -> OutboxStore
  private var inFlight = false
  private let lock = NSLock()
  private var networkError: String?
  private var networkRoute: HubBinding.Route?
  private var storageError: String?
  private var storedCount = 0
  private var peak = 0
  private var diskStatus = OutboxStatus()
  var outboxStatus: OutboxStatus { lock.lock(); defer { lock.unlock() }; return diskStatus }
  var queuePeak: Int { lock.lock(); defer { lock.unlock() }; return peak }
  private var pendingWrites = 0
  private let io = DispatchQueue(label: "record-anything.outbox", qos: .utility)
  var lastError: String? { lock.lock(); defer { lock.unlock() }; return storageError ?? networkError }
  var pendingCount: Int { lock.lock(); defer { lock.unlock() }; return storedCount + pendingWrites }
  private var sentCount = 0
  private var rejectedCount = 0
  private var remoteSent: (route: HubBinding.Route, count: Int)?
  var sent: Int {
    let route = try? config.hubRoute()
    return lock.withLock {
      guard let route, route.remote != nil else { return sentCount }
      return remoteSent?.route == route ? remoteSent?.count ?? 0 : 0
    }
  }
  var rejected: Int { lock.withLock { rejectedCount } }
  private var deliveryMetrics = HubDeliveryMetrics()
  var hubBusy: Int { lock.lock(); defer { lock.unlock() }; return deliveryMetrics.hubBusy }
  private let onHealthEvent: (@Sendable () -> Void)?

  init(config: Config, deviceSession: HostDeviceSession? = nil,
       writeGate: RemoteSwitchWriteGate? = nil, onHealthEvent: (@Sendable () -> Void)? = nil,
       openOutbox: @escaping (URL) throws -> OutboxStore = {
         // 远端代次的待发目录给信箱 journal 预留空间，二者合计不超过 1 GiB。
         let reserve = $0.lastPathComponent.hasPrefix("outbox-") && !$0.lastPathComponent.hasSuffix("-local")
           && $0.lastPathComponent != "outbox-unassigned" ? Int64(RemoteRelayJournal.reservedBytes) : 0
         return try OutboxStore(dataDirectory: $0, byteLimit: OutboxStore.defaultByteLimit - reserve)
       },
       onLinked: (@Sendable (LocalDeviceLink) -> Void)? = nil) {
    self.config = config
    self.onHealthEvent = onHealthEvent
    self.writeGate = writeGate
    self.openOutbox = openOutbox
    upload = CollectorUpload(config: config, deviceSession: deviceSession, onLinked: onLinked)
    queue = OutboundQueue()
    io.async { [self] in retryOutbox() }
  }

  private func buffer(for route: HubBinding.Route?) -> OutboxBuffer {
    if let buffer = buffers[route] { return buffer }
    let directory = Self.outboxDirectory(in: config.dataDir, for: route)
    let buffer = OutboxBuffer(memory: route == .local ? queue : OutboundQueue()) { [openOutbox] in
      try openOutbox(directory)
    }
    buffers[route] = buffer
    return buffer
  }

  static func outboxDirectory(in root: URL, for route: HubBinding.Route?) -> URL {
    switch route {
    case .some(.local): root
    case .some(let route):
      root.appendingPathComponent("outbox-\(route.generation)-\(route.remote?.hub_id ?? "local")", isDirectory: true)
    case .none: root.appendingPathComponent("outbox-unassigned", isDirectory: true)
    }
  }

  private func retryOutbox() {
    _ = buffer(for: try? config.hubRoute())
    for buffer in buffers.values { buffer.retry(at: ProcessInfo.processInfo.systemUptime) }
    publishOutbox()
  }

  private func publishOutbox(writesCompleted: Int = 0) {
    let route = try? config.hubRoute()
    for (retired, buffer) in buffers where retired != route && buffer.count == 0 && !buffer.status.degraded {
      let status = buffer.status
      if status.dropped > 0 || status.quarantined > 0 { retiredStatus[retired] = status }
      buffers.removeValue(forKey: retired)
    }
    var statuses = retiredStatus
    for (route, buffer) in buffers { statuses[route] = buffer.status }
    let status = statuses.values.reduce(into: OutboxStatus(degraded: false)) { total, status in
      total = OutboxStatus(bytes: total.bytes + status.bytes, dropped: total.dropped + status.dropped,
                            degraded: total.degraded || status.degraded, quarantined: total.quarantined + status.quarantined)
    }
    lock.lock()
    let newDrops = status.dropped > diskStatus.dropped
    let newQuarantine = status.quarantined > diskStatus.quarantined
    let becameDegraded = status.degraded && !diskStatus.degraded
    diskStatus = status
    storedCount = buffers[route]?.count ?? 0
    peak = max(peak, buffers.values.map(\.queuePeak).max() ?? 0)
    pendingWrites -= writesCompleted
    if status.degraded {
      storageError = "待发送记录无法安全保存，请检查磁盘空间和数据目录；暂时只在内存中重试。"
    } else if buffers.values.contains(where: \.hasStorageError) {
      storageError = "有待发送记录无法安全保存或恢复。"
    } else {
      storageError = status.quarantined > 0 ? "已隔离 \(status.quarantined) 条损坏的待发送记录。" : nil
    }
    lock.unlock()
    if newDrops { DiagnosticLog.shared.record(.outboxDropped(total: status.dropped)) }
    if status.degraded { DiagnosticLog.shared.record(.outboxDegraded) }
    if newDrops || newQuarantine || becameDegraded { onHealthEvent?() }
  }

  func enqueue(_ records: [Record]) {
    guard !records.isEmpty else { return }
    lock.lock(); pendingWrites += records.count; lock.unlock()
    io.async { [self] in
      let buffer = buffer(for: try? config.hubRoute())
      buffer.retry(at: ProcessInfo.processInfo.systemUptime)
      buffer.enqueue(records, at: ProcessInfo.processInfo.systemUptime)
      publishOutbox(writesCompleted: records.count)
    }
  }

  func flush() {
    Task {
      do { try writeGate?.begin() } catch { return }
      defer { writeGate?.end() }
      await upload.prepare()
    }
    io.async { [self] in
      retryOutbox()
      sendNext()
    }
  }

  private func sendNext() {
    let observed = try? config.hubRoute()
    if observed != networkRoute {
      networkRoute = observed
      lock.withLock { networkError = nil }
    }
    guard let route = observed else {
      lock.withLock { networkError = "后台连接配置无法读取，待发送记录已保留。" }
      return
    }
    guard !inFlight else { return }
    if route.remote != nil {
      let queued = buffer(for: route).count
      if queued > 0 || RemoteDeviceSession.hasJournal(in: config.dataDir, for: route) {
        sendRemote(on: route, queued: queued)
      }
      return
    }
    let batch = buffer(for: route).batch(limit: CollectorUpload.batchLimit)
    publishOutbox()
    guard !batch.isEmpty else { return }
    do { try writeGate?.begin() } catch { return }
    inFlight = true

    Task { [weak self, writeGate] in
      guard let self else { writeGate?.end(); return }
      do {
        let delivery = try await upload.send(batch, on: route) { ids in
          try await self.onIO { try self.buffer(for: route).markSubmitted(ids) }
        }
        let records = delivery.records
        guard let receipt = DeliveryReceipt.decode(delivery.body, batchCount: records.count) else {
          finish(on: route, error: "后台未确认完整接收，待发送记录已保留。", done: nil)
          return
        }
        // 明确拒收只记数量，不把中枢返回的正文写入日志。
        let bad = receipt.rejected.count
        if bad > 0 { NSLog("record-anything: hub 拒收 %d 条", bad) }
        finish(on: route, error: nil, done: (delivery.route, Set(records.map(\.id)), records.count - bad, bad))
      } catch DeviceClientError.hubBusy, DeviceClientError.operationError(_, 503, _), DeviceClientError.plaintextError(503, _) {
        finish(on: route, error: nil, done: nil, status: 503)
      } catch DeviceClientError.operationError(_, let status, _), DeviceClientError.plaintextError(let status, _) {
        finish(on: route, error: "后台服务拒绝了记录（\(status)）", done: nil)
      } catch RemoteDeviceAccess.Failure.frozen, DeviceClientError.deviceRemoved, DeviceClientError.invalidKey, DeviceClientError.keyStoreError, LocalDeviceLink.Failure.keyUnavailable {
        let backend = route.remote == nil ? "本机后台" : "远端后台"
        finish(on: route, error: "\(backend)连接凭据不可用，待发送记录已保留。", done: nil)
      } catch CollectorUpload.Failure.noToken {
        finish(on: route, error: "找不到后台服务的访问凭证，请重启 Tacit", done: nil)
      } catch CollectorUpload.Failure.batchTooLarge, DeviceClientError.envelopeTooLarge {
        finish(on: route, error: "待发送记录超过上传大小限制。", done: nil)
      } catch {
        finish(on: route, error: "连不上后台服务", done: nil)
      }
    }
  }

  private func sendRemote(on route: HubBinding.Route, queued: Int) {
    // 与本机路径一致：切换进行中不发；finish() 负责 end()。
    do { try writeGate?.begin() } catch { return }
    inFlight = true
    Task { [weak self, writeGate] in
      guard let self else { writeGate?.end(); return }
      do {
        guard let session = try await upload.remoteSession(for: route) else { throw RemoteDeviceSession.Failure.unavailable }
        let delivery: RemoteDeviceSession.CaptureDelivery
        if let completed = try await session.completedCapture() {
          delivery = completed
        } else {
          let excluding = try await session.reservedCaptureIDs()
          let unresolved = try await session.unknownCaptureOutcomes()
          let unresolvedMessage = unresolved == 0 ? nil : "有 \(unresolved) 条已移出待发队列的记录发送结局未知。"
          guard queued > 0 else {
            finish(on: route, error: unresolvedMessage, done: nil)
            return
          }
          let limits = try await session.captureBatchLimits()
          let (batch, queued) = await withCheckedContinuation { continuation in
            self.io.async {
              let buffer = self.buffer(for: route)
              let batch = buffer.eligibleBatch(limit: limits.count, excluding: excluding.union(limits.requiresDirect)) {
                session.captureRecordFits($0, budget: limits.bytes)
              }
              continuation.resume(returning: (batch, buffer.count))
            }
          }
          guard !batch.isEmpty else {
            var message: String?
            if queued > excluding.count { message = "待发送队列中有记录需要直连上传。" }
            finish(on: route, error: unresolvedMessage ?? message, done: nil)
            return
          }
          // “已交给传输”标记由 sendCapture 按实际打包的记录 ID 在任何网络 I/O 前写入。
          delivery = try await session.sendCapture(batch)
        }
        if let status = delivery.rejectedStatus {
          if let nonce = delivery.nonce { try await session.releaseRejectedCapture(nonce: nonce, status: status) }
          finish(on: route, error: "后台服务拒绝了记录（\(status)）", done: nil)
          return
        }
        guard let receipt = DeliveryReceipt.decode(delivery.body, batchCount: delivery.ids.count) else {
          finish(on: route, error: "后台未确认完整接收，待发送记录已保留。", done: nil)
          return
        }
        let rejected = receipt.rejected.count
        let done = (route, Set(delivery.ids), delivery.ids.count - rejected, rejected)
        finish(on: route, error: nil, done: done, relay: delivery.nonce.map { (session, $0) })
      } catch RemoteDeviceSession.Failure.awaitingReceipt, is RemoteSwitchWriteGate.Paused {
        finish(on: route, error: nil, done: nil)
      } catch DeviceClientError.operationError(_, let status, _), DeviceClientError.plaintextError(let status, _) {
        finish(on: route, error: "后台服务拒绝了记录（\(status)）", done: nil)
      } catch {
        finish(on: route, error: "远端后台暂不可用，待发送记录已保留。", done: nil)
      }
    }
  }

  private func finish(on route: HubBinding.Route, error: String?, done: (HubBinding.Route, Set<String>, Int, Int)?, status: Int? = nil,
                      relay: (RemoteDeviceSession, String)? = nil) {
    io.async { [self] in
      var acknowledged = done
      if let done {
        do { try buffer(for: done.0).acknowledge(done.1, at: ProcessInfo.processInfo.systemUptime) }
        catch { acknowledged = nil }
      }
      let current = (try? config.hubRoute()) == route
      lock.lock()
      let previousError = networkError
      if current, let status { deliveryMetrics.received(status: status) }
      inFlight = false
      if current { networkError = error }
      if let done = acknowledged {
        if done.0.remote == nil { sentCount += done.2 }
        else if current { remoteSent = (done.0, (remoteSent?.route == done.0 ? remoteSent?.count ?? 0 : 0) + done.2) }
        rejectedCount += done.3
      }
      lock.unlock()
      publishOutbox()
      if current && ((error != nil && previousError == nil) || status == 503) { onHealthEvent?() }
      if acknowledged != nil, let (session, nonce) = relay {
        // The journal's durable receipt remains recoverable even if this last
        // confirmation or the later mailbox DELETE fails.
        inFlight = true
        Task {
          let confirmed = (try? await session.confirmCapture(nonce: nonce)) != nil
          self.io.async {
            self.inFlight = false
            self.writeGate?.end()
            if confirmed || !current { self.sendNext() }
          }
        }
      } else {
        writeGate?.end()
        if acknowledged != nil || !current { sendNext() }
      }
    }
  }
  private func onIO<T>(_ action: @escaping () throws -> T) async throws -> T {
    try await withCheckedThrowingContinuation { continuation in
      io.async { continuation.resume(with: Result(catching: action)) }
    }
  }

  func mayImportHistory(on route: HubBinding.Route) async -> Bool {
    guard let session = try? await upload.remoteSession(for: route),
          let limits = try? await session.captureBatchLimits(),
          let reserved = try? await session.reservedCaptureIDs(), reserved.isEmpty,
          (try? await session.completedCapture()) == nil else { return false }
    return (try? await onIO { [self] in
      guard try config.hubRoute() == route, !inFlight else { return false }
      let active = buffer(for: route)
      if active.count == 0 { return true }
      return active.eligibleBatch(limit: 1, excluding: limits.requiresDirect) {
        session.captureRecordFits($0, budget: limits.bytes)
      }.isEmpty
    }) ?? false
  }

  func settleForSwitch() async throws -> Bool {
    try await onIO { [self] in
      retryOutbox()
      let active = buffer(for: try config.hubRoute())
      guard active.isPersisted else { throw RemoteSwitch.Failure.outboxNotPersisted }
      return !inFlight
    }
  }

  func switchBackPendingCount(on route: HubBinding.Route) async throws -> Int {
    try await onIO { [self] in
      guard route.remote != nil, try config.hubRoute() == route else { throw HubBinding.Failure.changed }
      let active = buffer(for: route)
      guard active.isPersisted else { throw RemoteSwitch.Failure.outboxNotPersisted }
      return try active.switchableCount(onlyUnsubmitted: true)
    }
  }

  func publishSwitch(previousLocal: HubBinding.Route?, from: HubBinding.Route, to: HubBinding.Route,
                     commit: @escaping () throws -> Void) async throws {
    try await onIO { [self] in
      guard try config.hubRoute() == from, from != to else { throw HubBinding.Failure.changed }
      retryOutbox()
      let source = buffer(for: from)
      guard source.isPersisted else { throw RemoteSwitch.Failure.outboxNotPersisted }
      let target = buffer(for: to)
      let now = ProcessInfo.processInfo.systemUptime
      target.retry(at: now)
      defer { publishOutbox() }
      try target.discardSwitchCopies()
      if let previousLocal {
        let oldLocal = buffer(for: previousLocal)
        oldLocal.retry(at: now)
        try oldLocal.copyForSwitch(to: target, onlyUnsubmitted: false)
      }
      try source.copyForSwitch(to: target, onlyUnsubmitted: previousLocal != nil)
      // Capture enqueues already scheduled on this queue were copied above. Later enqueues
      // run after commit and read the published generation before choosing their buffer.
      do { try commit() } catch {
        // 没发布成功：撤掉刚复制到目标代次的硬链副本，免得重复计入容量、密文滞留。
        try? target.discardSwitchCopies()
        throw error
      }
    }
  }

  func finishSwitchToRemote(from local: HubBinding.Route, to remote: HubBinding.Route) async throws {
    try await onIO { [self] in
      guard try config.hubRoute() == remote else { throw HubBinding.Failure.changed }
      let now = ProcessInfo.processInfo.systemUptime
      let source = buffer(for: local), target = buffer(for: remote)
      for item in [source, target] { item.retry(at: now) }
      defer { publishOutbox() }
      try source.removeSwitchCopies(in: target, onlyUnsubmitted: false)
    }
  }

  func finishSwitchBack(previousLocal: HubBinding.Route, remote: HubBinding.Route,
                        local: HubBinding.Route) async throws {
    try await onIO { [self] in
      let target = buffer(for: local)
      let oldLocal = buffer(for: previousLocal)
      let oldRemote = buffer(for: remote)
      let now = ProcessInfo.processInfo.systemUptime
      for item in [target, oldLocal, oldRemote] { item.retry(at: now) }
      defer { publishOutbox() }
      try oldLocal.removeSwitchCopies(in: target, onlyUnsubmitted: false)
      try oldRemote.removeSwitchCopies(in: target, onlyUnsubmitted: true)
    }
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
    guard config.allowsLocalHub else { throw PluginFailure(message: "需要连接这台 Mac 的后台") }
    let writeGate = self.writeGate
    let queue = ["install", "configure", "uninstall"].contains(request.action) ? jobs : DispatchQueue.global(qos: .utility)
    return try await withCheckedThrowingContinuation { continuation in
      queue.async {
        do {
          try writeGate?.begin()
          defer { writeGate?.end() }
          guard config.allowsLocalHub else { throw PluginFailure(message: "需要连接这台 Mac 的后台") }
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
  private let deviceSession: HostDeviceSession?
  private let writeGate: RemoteSwitchWriteGate?

  init(config: Config, deviceSession: HostDeviceSession? = nil, writeGate: RemoteSwitchWriteGate? = nil) {
    self.config = config
    self.deviceSession = deviceSession
    self.writeGate = writeGate
  }

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

  private func resolveConnection(on route: HubBinding.Route) throws -> HostDeviceSession.Connection? {
    guard let deviceSession else {
      if route.remote != nil { throw RemoteDeviceAccess.Failure.unavailable }
      return nil
    }
    let done = DispatchSemaphore(value: 0)
    var resolved: Result<HostDeviceSession.Connection?, Error>?
    Task {
      do { resolved = .success(try await deviceSession.connection(for: route)) }
      catch { resolved = .failure(error) }
      done.signal()
    }
    done.wait()
    return try resolved?.get()
  }

  private func run(_ name: String, since: Date?) -> Outcome {
    do { try writeGate?.begin() }
    catch { return Outcome(ok: false, accepted: 0, text: "正在切换后台", at: Date()) }
    defer { writeGate?.end() }
    guard let repo = config.repo else { return Outcome(ok: false, accepted: 0, text: "未配置仓库", at: Date()) }
    lock.lock(); current = name; lock.unlock()
    defer { lock.lock(); current = nil; process = nil; lock.unlock() }
    let route: HubBinding.Route
    let connection: HostDeviceSession.Connection?
    do {
      route = try config.hubRoute()
      connection = try resolveConnection(on: route)
    } catch {
      return set(name, Outcome(ok: false, accepted: 0, text: "后台设备连接不可用", at: Date()))
    }
    let p = Process()
    p.executableURL = URL(fileURLWithPath: config.bun)
    if let connection {
      if name.hasPrefix("ext-") {
        p.arguments = ["\(repo)/hub/src/cli.ts", "plugin-run", name, "--transport", "stdio", "--device", connection.deviceID] + PluginImport.arguments(plugin: name, since: since)
      } else {
        p.arguments = ["\(repo)/hub/src/cli.ts", "run-plugin", name, "--transport", "stdio", "--device", connection.deviceID,
                       "--", config.bun, "\(repo)/plugins/\(name)/main.ts"] + PluginImport.arguments(plugin: name, since: since)
      }
    } else if name.hasPrefix("ext-") {
      p.arguments = ["\(repo)/hub/src/cli.ts", "plugin-run", name, "--hub", config.hubURL.absoluteString] + PluginImport.arguments(plugin: name, since: since)
    } else {
      p.arguments = ["\(repo)/hub/src/cli.ts", "run-plugin", name, "--hub", config.hubURL.absoluteString,
                     "--", config.bun, "\(repo)/plugins/\(name)/main.ts"] + PluginImport.arguments(plugin: name, since: since)
    }
    var env = ProcessInfo.processInfo.environment
    env["RA_DATA_DIR"] = config.dataDir.path
    p.environment = env
    let out = Pipe()
    let input = connection == nil ? nil : Pipe()
    if let input { p.standardInput = input }
    p.standardOutput = out; p.standardError = FileHandle.nullDevice
    let started = Date()
    lock.lock()
    guard active.contains(name) && isEnabled(name) else { lock.unlock(); return Outcome(ok: true, accepted: 0, text: "已停用或暂停", at: Date()) }
    do { try p.run(); process = p; lock.unlock() } catch { lock.unlock(); return set(name, Outcome(ok: false, accepted: 0, text: "启动失败", at: Date())) }
    let timer = DispatchWorkItem { if p.isRunning { p.terminate() } }
    DispatchQueue.global().asyncAfter(deadline: .now() + PluginImport.timeout(since: since), execute: timer)
    let summary: String
    if let connection, let deviceSession, let input {
      try? input.fileHandleForReading.close()
      try? out.fileHandleForWriting.close()
      let readHandle = out.fileHandleForReading
      let writeHandle = input.fileHandleForWriting
      let channel = StdioLineChannel(readFD: readHandle.fileDescriptor, writeFD: writeHandle.fileDescriptor)
      let proxyDone = DispatchSemaphore(value: 0)
      var lastLine = ""
      Task.detached(priority: .utility) {
        defer {
          try? readHandle.close()
          try? writeHandle.close()
          proxyDone.signal()
        }
        lastLine = await PluginProxy.serve(
          channel: channel,
          deviceID: connection.deviceID,
          allowedSources: PluginProxy.allowedSources(for: name)
        ) { op, body in
          guard let reply = try await deviceSession.send(op: op, body: body, on: connection.route) else {
            throw DeviceClientError.deviceRemoved(message: nil)
          }
          return reply
        }
      }
      proxyDone.wait()
      p.waitUntilExit(); timer.cancel()
      summary = lastLine
    } else {
      let data = out.fileHandleForReading.readDataToEndOfFile()
      p.waitUntilExit(); timer.cancel()
      summary = String(data: data, encoding: .utf8)?.split(separator: "\n").last.map(String.init) ?? ""
    }
    let ok = p.terminationStatus == 0
    var accepted: Int?, failure: String?, warnings: [String] = []
    if let d = summary.data(using: .utf8), let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
      accepted = j["accepted"] as? Int; failure = j["failure"] as? String
      warnings = j["warnings"] as? [String] ?? []
    }
    let text = PluginImport.outcomeText(ok: ok, exitStatus: p.terminationStatus, accepted: accepted, elapsed: Date().timeIntervalSince(started), failure: failure, warnings: warnings)
    return set(name, Outcome(ok: ok, accepted: accepted ?? 0, text: text, at: Date()))
  }

  private func set(_ name: String, _ v: Outcome) -> Outcome { lock.lock(); last[name] = v; lock.unlock(); return v }
  func outcome(_ name: String) -> Outcome? { lock.lock(); defer { lock.unlock() }; return last[name] }
  func isRunning(_ name: String) -> Bool { lock.lock(); defer { lock.unlock() }; return current == name }
  /// collector-status.json 用。
  func status() -> [String: String] { lock.lock(); defer { lock.unlock() }; return last.mapValues(\.text) }
}
