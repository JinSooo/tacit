import AppKit
import CryptoKit
import CollectorCore
import AudioStore

/// 音频状态只在 queue 上修改；菜单通过快照读取，不阻塞录音。
final class AudioCoordinator {
  let config: Config
  private let queue = DispatchQueue(label: "record-anything.audio", qos: .utility)
  // 每个 IOProc 缓冲约 10ms；留约 4 秒余量，偶尔的磁盘或设备操作不会让整路录音停掉，又能限制真跟不上时的内存。
  private let slots = DispatchSemaphore(value: 400)
  private let snapshotLock = NSLock()
  private var snapshot: [String] = []
  private var store: AudioStore?
  private var mic: Microphone?
  private var micGeneration = UUID()
  private var micSetting = UserDefaults.standard.string(forKey: "micDevice") ?? "builtin"
  private var inputDevices: [InputAudioDevice] = []
  private var defaultInput: UInt32?
  private var micStatus = "麦克风未录音"
  private var micFailure: String?
  private var lastMicStart = Date.distantPast
  private lazy var deviceObserver = MicrophoneDeviceObserver(queue: queue) { [weak self] in
    self?.devicesChanged()
  }
  private var tapStop: (() -> Void)?
  private var pipelines: [AudioTrack: AudioPipeline] = [:]
  private var current: AudioMetadata?
  private var boundary = ConversationBoundary()
  private var health = MicrophoneHealth()
  private var enabled = false
  private var generation = UUID()
  private var lastStart = Date.distantPast
  private var lastSync = Date.distantPast
  private var syncing = false
  private var worker: Process?
  private var lastWorker = Date.distantPast
  private var voiceHash: String?
  private var voiceChanged = false
  private var samplesRequested = false
  private var workerFailureAt = Date.distantPast
  private var retentionDays = 7
  private var retentionKnown = false
  private var meetingHistory = MeetingMicrophoneHistory()
  private let calendarMeetings = CalendarMeetingQuery()
  private var failure: String?
  private lazy var models = AudioModelDownload(config: config)
  private var lastMaintenance = Date.distantPast
  private var lastCleanup = Date.distantPast
  private var lastInitialize = Date.distantPast
  private let maintenance = BackgroundMaintenance()
  private var inventory: [AudioMetadata] = []
  private var inventoryRevision = 0
  private var maintenanceFailure: String?
  private var shuttingDown = false
  private var initialized = false
  private var sessionStarted = Date.distantPast

  private let startGuard: RecordingStartGuard
  let initiallyBlocked: Bool
  init(config: Config) {
    self.config = config
    startGuard = RecordingStartGuard(dataDirectory: config.dataDir)
    initiallyBlocked = startGuard.blocked
    if initiallyBlocked {
      let notice = "上次开启录音时崩溃，已暂停录音"
      failure = notice; snapshot = [notice]
    }
  }
  func allowManualStart() {
    queue.async { [self] in
      do { try startGuard.allowManualRetry(); failure = nil; lastStart = .distantPast; lastMicStart = .distantPast }
      catch { failure = "无法解除录音启动保护：\(error)" }
      publish()
    }
  }
  private var transcription = TranscriptionStatus(pending: 0, failed: 0)
  func transcriptionStatus() -> TranscriptionStatus {
    snapshotLock.lock(); defer { snapshotLock.unlock() }
    return transcription
  }
  func status() -> [String] { snapshotLock.lock(); defer { snapshotLock.unlock() }; return snapshot }
  func update(enabled: Bool) {
    queue.async { [self] in
      guard !shuttingDown else { return }
      let now = Date()
      if !enabled {
        // 先用已采到的会议上下文结束当前对话，再清空探针历史；停用不能继续读取新的系统输入。
        self.enabled = false; stop()
      }
      // 逐个读系统里所有音频进程的属性很贵（空闲时占采集端一半以上 CPU）。会议判定只看有人说话的那段时间里
      // 会议软件是否在用麦克风：有人说话时每秒查，没人说话时每 10 秒查一次，够刷新 90 秒窗口。
      let speaking = pipelines.values.contains { $0.speechActive }
      meetingHistory.sample(enabled: enabled && !startGuard.blocked, speaking: speaking, at: now, read: microphoneInputBundles)
      if !initialized {
        // 从未开启过录音时不读钥匙串、不扫描音频目录；已初始化的历史维护仍按原节奏继续。
        guard enabled, !startGuard.blocked else { publish(); return }
        guard now.timeIntervalSince(lastInitialize) >= 60 else { return }
        lastInitialize = now
        do {
          store = try AudioStore(dataDirectory: config.dataDir); try store?.recoverInterrupted()
          let state = try? Data(contentsOf: config.dataDir.appendingPathComponent("collector-audio-state.json"))
          if let state, let json = try? JSONSerialization.jsonObject(with: state) as? [String: Any] {
            voiceHash = json["voice_hash"] as? String
            voiceChanged = json["voice_changed"] as? Bool ?? false
            if let days = json["retention_days"] as? Int, (0...365).contains(days) {
              retentionDays = days; retentionKnown = true
            }
            lastWorker = AudioPolicy.date(json["last_worker"] as? String) ?? .distantPast
          }
          initialized = true
        } catch { failure = "音频存储不可用：\(error)"; publish(); return }
      }
      if startGuard.blocked {
        self.enabled = false; stop()
        failure = "上次开启录音时崩溃，已暂停录音"; publish(); return
      }
      self.enabled = enabled
      if enabled && tapStop == nil && now.timeIntervalSince(lastStart) >= 60 { start() }
      else if enabled && tapStop != nil && mic == nil && now.timeIntervalSince(lastMicStart) >= 60 { rebuildMicrophone() }
      if current != nil {
        // 给 VAD 的最短人声/静音窗口留 1 秒判定时间，避免第 60 秒附近的人声被提前切断。
        if boundary.shouldClose(at: now.addingTimeInterval(-1)), !pipelines.values.contains(where: { $0.speechActive }) { tryOperation { try close() } }
      }
      // 没收到回调也视作持续静音，覆盖权限被拒绝却没有错误的系统行为。
      if mic != nil, now.timeIntervalSince(sessionStarted) >= 600, healthLastFrame.map({ now.timeIntervalSince($0) >= 600 }) ?? true {
        health.observe(dbfs: -160, start: healthLastFrame ?? sessionStarted, end: now, enabled: true)
      }
      if now.timeIntervalSince(lastSync) >= 300 || shouldRunWorker(now) { sync() }
      if now.timeIntervalSince(lastMaintenance) >= 30 {
        lastMaintenance = now
        // 保留期按天计，过期清理 10 分钟一次足够；盘点仍每 30 秒一次。
        let cleanup = worker == nil && retentionKnown && now.timeIntervalSince(lastCleanup) >= 600
        if cleanup { lastCleanup = now }
        refreshInventory(cleanup: cleanup)
        publish()
      }
    }
  }
  private var healthLastFrame: Date?
  func shutdown() {
    queue.sync {
      shuttingDown = true; enabled = false; deviceObserver.stop(); stop()
      if let worker, worker.isRunning {
        worker.terminate()
        let deadline = Date().addingTimeInterval(3)
        while worker.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
        if worker.isRunning { kill(worker.processIdentifier, SIGKILL) }
      }
    }
    maintenance.drain()
    queue.sync {}
  }
  private func start() {
    lastStart = Date()
    let model = config.dataDir.appendingPathComponent("models/silero_vad.onnx").path
    guard models.ready else {
      // 第一次开启录音才下载；下载完让下一轮状态检查立即开始录音，失败则 60 秒后随下一次启动重试。
      failure = "正在下载语音模型（约 270MB），完成后自动开始录音"
      models.start { [weak self] ok in
        guard let self else { return }
        self.queue.async {
          if ok { self.failure = nil; self.lastStart = .distantPast } else { self.failure = self.models.lastFailure }
          self.publish()
        }
      }
      publish(); return
    }
    guard #available(macOS 14.2, *) else { failure = "系统声音录音需要 macOS 14.2 或更新版本"; publish(); return }
    do {
      try startGuard.attempt {
        generation = UUID(); let session = generation
        pipelines[.sys] = try AudioPipeline(modelPath: model, emit: { [weak self] samples, start, end in
          try self?.save(samples, track: .sys, start: start, end: end)
        }, level: { _, _, _ in })
        rebuildMicrophone()
        let tap = SystemTap(buffer: captureBuffer(.sys, session: session)); tapStop = { tap.stop() }
        try tap.start()
        failure = nil
      }
    } catch { failure = "录音启动失败：\(error)"; stop() }
    publish()
  }
  /// 每路分别标记代次，设备切换后丢弃旧麦克风排队中的帧，不影响系统声音。
  private func captureBuffer(_ track: AudioTrack, session: UUID) -> CaptureBuffer {
    CaptureBuffer(receive: { [weak self] samples, rate, host in
      guard let self else { return }
      guard self.slots.wait(timeout: .now()) == .success else {
        self.inputFailure("音频处理跟不上，已停止该路录音", track: track, session: session); return
      }
      self.queue.async {
        defer { self.slots.signal() }
        guard self.enabled, self.isCurrent(track, session: session) else { return }
        do { try self.pipelines[track]?.accept(samples, rate: rate, host: host) }
        catch {
          if track == .mic { self.micFailure = "麦克风处理失败：\(error)"; self.stopMicrophone() }
          else { self.failure = "音频处理失败：\(error)"; self.stop() }
          self.publish()
        }
      }
    }, failure: { [weak self] text in self?.inputFailure(text, track: track, session: session) })
  }
  private func isCurrent(_ track: AudioTrack, session: UUID) -> Bool {
    (track == .mic ? micGeneration : generation) == session
  }
  private func inputFailure(_ text: String, track: AudioTrack, session: UUID) {
    queue.async { [weak self] in
      guard let self, self.isCurrent(track, session: session) else { return }
      if track == .mic { self.micFailure = text; self.stopMicrophone() }
      else { self.failure = text; self.stop() }
      self.publish()
    }
  }
  func selectMicrophone(_ setting: String) {
    queue.async { [self] in
      UserDefaults.standard.set(setting, forKey: "micDevice")
      micSetting = setting
      if enabled && tapStop != nil { rebuildMicrophone() }
      else {
        do { try deviceObserver.observe(systemDefault: micSetting == "system") }
        catch { micFailure = "监听麦克风设备失败：\(error)" }
      }
      publish()
    }
  }
  private func devicesChanged() {
    do {
      let devices = try MicrophoneDevices.inputs()
      let defaultDevice = micSetting == "system" ? MicrophoneDevices.defaultInput() : nil
      // process tap 的 aggregate device 也会触发设备列表事件；输入列表没变就不重建。
      guard devices != inputDevices || defaultDevice != defaultInput else { return }
      inputDevices = devices; defaultInput = defaultDevice
      if enabled && tapStop != nil { rebuildMicrophone() }
      publish()
    } catch { micFailure = "读取麦克风设备失败：\(error)"; publish() }
  }
  private func stopMicrophone() {
    micGeneration = UUID(); mic?.stop(); mic = nil
    if let pipeline = pipelines.removeValue(forKey: .mic) { tryOperation { try pipeline.flush() } }
    health.reset(); healthLastFrame = nil; micStatus = "麦克风未录音"
  }
  private func rebuildMicrophone() {
    stopMicrophone(); lastMicStart = Date(); micFailure = nil
    do {
      try deviceObserver.observe(systemDefault: micSetting == "system")
      inputDevices = try MicrophoneDevices.inputs()
      defaultInput = micSetting == "system" ? MicrophoneDevices.defaultInput() : nil
      let selection = MicrophoneSelection.resolve(devices: inputDevices.map(\.descriptor), setting: micSetting)
      guard let device = selection.inputID(devices: inputDevices.reduce(into: [:]) { $0[$1.uid] = $1.id },
                                          defaultInput: { self.defaultInput }) else {
        throw AudioCaptureError(selection.notice ?? "没有可用的系统默认输入")
      }
      try startGuard.attempt {
        let model = config.dataDir.appendingPathComponent("models/silero_vad.onnx").path
        pipelines[.mic] = try AudioPipeline(modelPath: model, emit: { [weak self] samples, start, end in
          try self?.save(samples, track: .mic, start: start, end: end)
        }, level: { [weak self] dbfs, start, end in
          self?.health.observe(dbfs: dbfs, start: start, end: end, enabled: true); self?.healthLastFrame = end
        })
        sessionStarted = Date()
        let microphone = Microphone(buffer: captureBuffer(.mic, session: micGeneration), device: device)
        mic = microphone
        try microphone.start()
        let actualName = inputDevices.first { $0.id == microphone.actualDevice }?.name ?? "系统默认输入"
        micStatus = "麦克风：\(actualName)"
        if let notice = selection.notice { micStatus += " · \(notice)" }
      }
    } catch {
      stopMicrophone(); micFailure = "麦克风启动失败：\(error)"
    }
    publish()
  }
  private func stop() {
    guard mic != nil || !pipelines.isEmpty else { return }
    generation = UUID(); stopMicrophone(); tapStop?(); tapStop = nil
    for pipeline in pipelines.values { tryOperation { try pipeline.flush() } }
    tryOperation { try close() }
    pipelines = [:]; health.reset(); healthLastFrame = nil
    publish()
  }
  private func save(_ samples: [Float], track: AudioTrack, start: Date, end: Date) throws {
    guard let store else { return }
    if boundary.shouldClose(at: start) { try close() }
    if current == nil { current = AudioMetadata(start: start); try store.writeMetadata(current!) }
    var meta = current!
    if start < AudioPolicy.date(meta.t_start)! {
      let old = meta
      meta.t_start = LocalTime.iso(start)
      try store.moveOpenConversation(from: old, to: meta)
      current = meta
    }
    let file = String(format: "%@-%04d.enc", track.rawValue, meta.segments.filter { $0.track == track }.count + 1)
    try store.writeSegment(AudioCodec.encode(samples), file: file, meta: meta)
    meta.segments.append(AudioSegment(file: file, track: track, start: start, end: end, dbfs: AudioPipeline.dbfs(samples)))
    let since = boundary.lastSpeechEnd ?? start
    let apps = meetingHistory.apps(since: since, through: end)
    meta.meeting_apps = Array(Set(meta.meeting_apps).union(apps)).sorted(); meta.updated_at = LocalTime.iso(Date())
    try store.writeMetadata(meta); current = meta
    _ = boundary.observe(start: start, end: end)
  }
  private func close() throws {
    guard var meta = current else { return }
    let end = meta.segments.compactMap { AudioPolicy.date($0.t_end) }.max() ?? AudioPolicy.date(meta.t_start)!
    meta.meeting_apps = calendarMeetings.meetingApps(meta.meeting_apps, start: AudioPolicy.date(meta.t_start)!, end: end)
    meta.t_end = LocalTime.iso(end); try meta.transition(to: .closed, at: Date())
    try store?.writeMetadata(meta); current = nil; boundary.reset()
    inventory.removeAll { $0.id == meta.id }; inventory.append(meta)
    inventoryRevision += 1; lastMaintenance = .distantPast
    closedScan.invalidate()
  }
  private func tryOperation(_ operation: () throws -> Void) {
    do { try operation() } catch { failure = "音频存储操作失败：\(error)" }
  }
  private func shouldRunWorker(_ now: Date) -> Bool {
    guard !shuttingDown, !maintenance.isRunning, worker == nil, now.timeIntervalSince(workerFailureAt) >= 60, FileManager.default.isExecutableFile(atPath: workerURL.path) else { return false }
    if voiceChanged { return true }
    // 本函数每秒被调用，扫描全部 meta.json 会拖慢音频队列导致丢帧停录；磁盘扫描最多每分钟一次，其间沿用上次结论。
    // 对话一结束就转写，不再等上次启动满 10 分钟（2026-11-12：处理半小时对话只要 40 秒，延迟几乎全是这段等待）。
    // 转写进程异常退出后仍隔 10 分钟，免得卡在同一段对话上反复启动。
    if now.timeIntervalSince(workerCrashedAt) >= 600,
       closedScan.check(at: now, scan: { inventory.contains { $0.status == .closed } }) { return true }
    guard now.timeIntervalSince(lastWorker) >= 600 else { return false }
    // hub 要试听样本时也要跑一次，否则新声音要等下一段对话录完才有样本。
    if samplesRequested { return true }
    return pendingScan.check(at: now) {
      // 旧对话还没按当前规则重认完（转写进程做完会留下标记文件）时也要启动。
      if let root = store?.root, !FileManager.default.fileExists(atPath: root.appendingPathComponent(WorkerLogic.relabelMarker).path) { return true }
      return inventory.contains { $0.status == .failed && ($0.attempts ?? 0) < 3 }
    }
  }
  private var closedScan = PendingWorkScan()
  private var pendingScan = PendingWorkScan()
  private var workerCrashedAt = Date.distantPast
  private static let workerLaunchFailure = "转写进程启动失败"
  private var workerURL: URL { Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/ra-audio-worker") }
  private func request(path: String, body: [String: Any]? = nil, completion: @escaping (Data?) -> Void) {
    guard let token = config.token else { completion(nil); return }
    var components = URLComponents(url: config.hubURL, resolvingAgainstBaseURL: false)!
    components.path = path
    if body == nil { components.queryItems = [URLQueryItem(name: "device", value: config.device)] }
    var request = URLRequest(url: components.url!); request.timeoutInterval = 20
    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    if let body { request.httpMethod = "POST"; request.setValue("application/json", forHTTPHeaderField: "Content-Type"); request.httpBody = try? JSONSerialization.data(withJSONObject: body) }
    URLSession.shared.dataTask(with: request) { data, response, error in
      completion(error == nil && (response as? HTTPURLResponse)?.statusCode == 200 ? data : nil)
    }.resume()
  }
  private func sync() {
    guard !shuttingDown, !syncing else { return }
    syncing = true; lastSync = Date()
    request(path: "/v1/audio/sync") { [weak self] data in
      guard let self else { return }
      self.queue.async {
        defer { self.syncing = false; self.publish() }
        guard let data, let reply = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let days = reply["retention_days"] as? Int, (0...365).contains(days),
              let deleting = reply["delete_conversations"] as? [String] else { return }
        do {
          self.retentionDays = days; self.retentionKnown = true
          if let voice = reply["voiceprint"] as? [String: Any] {
            let canonical = try JSONSerialization.data(withJSONObject: voice, options: .sortedKeys)
            let hash = SHA256.hash(data: canonical).map { String(format: "%02x", $0) }.joined()
            if hash != self.voiceHash { self.voiceChanged = true; self.voiceHash = hash }
          } else { self.voiceHash = nil }
          self.samplesRequested = !((reply["sample_requests"] as? [Any]) ?? []).isEmpty
          // worker 持有 closed 对话期间不删除，待它退出后再执行并 ack。
          guard self.worker == nil else { return }
          let purgeText = reply["purge_before"] as? String
          let purge = AudioPolicy.date(purgeText)
          if purgeText != nil && purge == nil { throw AudioError.invalidMetadata }
          guard !self.maintenance.isRunning, let store = self.store else { self.lastSync = .distantPast; return }
          let revision = self.inventoryRevision
          self.maintenance.perform(returningTo: self.queue, operation: {
            let deleted = try store.cleanup(now: Date(), retentionDays: days, purgeBefore: purge, deleting: deleting)
            return (deleted, try store.conversations(readOnly: true))
          }, completion: { result in
            do {
              let (deleted, all) = try result.get()
              self.maintenanceFailure = nil; self.acceptInventory(all, revision: revision)
              var ack: [String: Any] = ["device": self.config.device, "deleted": deleting.filter { deleted.contains($0) }]
              if let purgeText { ack["purged_at"] = purgeText }
              if !self.shuttingDown && (purgeText != nil || !deleting.isEmpty) { self.request(path: "/v1/audio/sync/ack", body: ack) { _ in } }
              if self.shouldRunWorker(Date()) { self.launchWorker() }
              self.persistState(); self.publish()
            } catch { self.maintenanceFailure = "音频同步清理失败"; self.lastSync = .distantPast }
          })
        } catch { self.failure = "音频同步清理失败：\(error)" }
      }
    }
  }
  private func launchWorker() {
    let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/sbin/taskpolicy")
    process.arguments = ["-b", workerURL.path, "--data-dir", config.dataDir.path, "--device", config.device, "--hub", config.hubURL.absoluteString]
    var env = ProcessInfo.processInfo.environment; env["RA_DATA_DIR"] = config.dataDir.path; process.environment = env
    // 系统库也能往这个流输出，转写退出原因和积压量通过诊断日志及状态文件记录。
    process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
    process.terminationHandler = { [weak self] p in
      let crashed = p.terminationReason == .uncaughtSignal
      if p.terminationStatus != 0 {
        DiagnosticLog.shared.record(.audioWorkerExit(status: p.terminationStatus, reason: crashed ? .signal : .exit))
      }
      self?.queue.async { [weak self] in
        guard let self else { return }
        self.worker = nil; self.inventoryRevision += 1; self.lastMaintenance = .distantPast; self.lastSync = .distantPast; self.closedScan.invalidate(); self.pendingScan.invalidate()
        if crashed { self.workerCrashedAt = Date() }
      }
    }
    do {
      try process.run(); worker = process; lastWorker = Date(); voiceChanged = false
      if failure?.hasPrefix(Self.workerLaunchFailure) == true { failure = nil }
    } catch {
      DiagnosticLog.shared.record(.audioWorkerLaunchFailed)
      failure = "\(Self.workerLaunchFailure)：\(error.localizedDescription)"
      workerFailureAt = Date()
    }
  }
  private func persistState() {
    var state: [String: Any] = ["retention_days": retentionDays, "last_worker": LocalTime.iso(lastWorker), "voice_changed": voiceChanged]
    if let voiceHash { state["voice_hash"] = voiceHash }
    tryOperation { try JSONSerialization.data(withJSONObject: state).write(to: config.dataDir.appendingPathComponent("collector-audio-state.json"), options: .atomic) }
  }
  private func acceptInventory(_ all: [AudioMetadata], revision: Int) {
    if revision == inventoryRevision { inventory = all; closedScan.invalidate(); pendingScan.invalidate() }
    else { lastMaintenance = .distantPast }
  }
  private func refreshInventory(cleanup: Bool) {
    guard let store else { return }
    let days = retentionDays, revision = inventoryRevision
    maintenance.perform(returningTo: queue, operation: {
      if cleanup { _ = try store.cleanup(now: Date(), retentionDays: days) }
      return try store.conversations(readOnly: true)
    }, completion: { result in
      switch result {
      case .success(let all): self.maintenanceFailure = nil; self.acceptInventory(all, revision: revision)
      case .failure: self.maintenanceFailure = "音频目录检查失败"
      }
      self.publish()
    })
  }
  private func publish() {
    let all = inventory.filter { $0.id != current?.id } + (current.map { [$0] } ?? [])
    let today = all.filter { AudioPolicy.date($0.t_start).map { Calendar.current.isDateInToday($0) } ?? false }.count
    let pending = all.filter { [.closed, .waiting_me, .failed].contains($0.status) }.count
    var lines = ["今天 \(today) 段对话，待转写 \(pending) 段"]
    lines.append(micStatus)
    if let micFailure { lines.append(micFailure) }
    if health.warning { lines.append("麦克风可能没有权限") }
    if let failure { lines.append(failure) }
    if let maintenanceFailure { lines.append(maintenanceFailure) }
    let failed = all.filter { $0.status == .failed }.count
    snapshotLock.lock()
    snapshot = lines
    transcription = .init(pending: pending, failed: failed)
    snapshotLock.unlock()
  }
}
