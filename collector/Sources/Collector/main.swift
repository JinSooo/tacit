import AppKit
import ApplicationServices
import Carbon.HIToolbox
import CollectorCore

/// 菜单栏采集端。所有读取都在这里做，hub 只接收数据。
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
  /// 第二个实例启动时发这个通知，请已在运行的采集端打开窗口。
  static let showWindowNotification = "dev.record-anything.collector.show-window"
  let config = Config.load()
  let toggles = SourceToggles(store: UserDefaults.standard)
  lazy var sources = DataSourceRegistry(toggles: toggles)
  lazy var hub = HubClient(config: config)
  lazy var api = HubAPI(base: { [config] in config.hubURL }, token: { [config] in config.token })
  lazy var files = FileCollector(device: config.device, isPaused: { [weak self] in self.map { $0.paused || !$0.enabled("files") } ?? true },
                                send: { [weak self] in self?.hub.enqueue($0) })
  lazy var calendar = CalendarCollector(device: config.device, isPaused: { [weak self] in self.map { $0.paused || !$0.enabled("calendar") } ?? true },
                                       send: { [weak self] in self?.hub.enqueue($0) })
  lazy var audio = AudioCoordinator(config: config)
  lazy var plugins = PluginScheduler(config: config)
  lazy var viewer: ViewerWindow = MainActor.assumeIsolated {
    ViewerWindow(store: ViewerStore(api: api, device: config.device, controls: self))
  }
  lazy var segmenter = Segmenter(device: config.device)
  let ax = AXReader()
  let ocr = OCRReader()
  let captureQueue = DispatchQueue(label: "record-anything.capture", qos: .utility)

  var statusItem: NSStatusItem!
  var timers: [Timer] = []
  var pausedUntil: Date?
  var lastOCR: [String: Date] = [:]
  var clipboardCount = NSPasteboard.general.changeCount
  // 以下只在主线程读写，给"上次运行"用。
  var lastScreen: Date?
  var lastOCRRun: Date?
  var lastClipboard: Date?
  /// 维护任务（同步、导入）的进行状态，只在主线程读写。
  var jobs: [MaintenanceTask: CaptureSnapshot.Job] = [:]

  // 只计数，不含任何内容；写到 collector-status.json 便于排查和验收。
  var stats: [String: Int] = ["ticks": 0, "scanMsTotal": 0, "scanMsMax": 0, "truncated": 0,
                              "ocrRuns": 0, "ocrMsTotal": 0, "ocrLines": 0, "screenRecords": 0,
                              "clipboardRecords": 0, "skippedPolicy": 0, "skippedSecureInput": 0]

  func enabled(_ id: String) -> Bool { toggles.isEnabled(id) }

  func applicationDidFinishLaunching(_ n: Notification) {
    statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    let menu = NSMenu(); menu.delegate = self
    statusItem.menu = menu
    registerSources()
    // 上次开启录音时崩溃：先关掉录音开关，再启动各数据源。
    if audio.initiallyBlocked { toggles.setEnabled("audio", false) }
    sources.launch(paused: paused)
    updateIcon()

    timers = [
      Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in self?.tick() },
      Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.pollClipboard() },
      Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in self?.hub.flush() },
      Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in self?.writeStatus() },
      Timer.scheduledTimer(withTimeInterval: config.pluginInterval, repeats: true) { [weak self] _ in self?.plugins.runAll() },
      Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.updateFiles() },
      Timer.scheduledTimer(withTimeInterval: 15 * 60, repeats: true) { [weak self] _ in self?.calendar.poll() },
    ]
    DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in self?.plugins.runAll() }

    let ws = NSWorkspace.shared.notificationCenter
    ws.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { [weak self] _ in self?.updateAudio() }
    ws.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in self?.tick() }
    for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
      ws.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.closeSegment() }
    }
    DistributedNotificationCenter.default().addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
      self?.closeSegment()
    }
    DistributedNotificationCenter.default().addObserver(forName: .init(Self.showWindowNotification), object: nil, queue: .main) { [weak self] _ in
      self?.openHistory()
    }
  }

  /// 把各采集器接到统一的数据源接口上。顺序以 DataSourceCatalog 为准。
  func registerSources() {
    let ocr = ocr, files = files, calendar = calendar
    sources.register(BlockSource("screen") { s in
      s.permissionName = "辅助功能"
      s.permissionCheck = { AXIsProcessTrusted() ? .granted : .denied }
      s.request = { [weak self] in self?.requestAX() }
      s.onEnable = { [weak self] _ in if !AXIsProcessTrusted() { self?.requestAX() } }
      s.onApply = { [weak self] active in if !active { self?.closeSegment() }; self?.updateIcon() }
      s.last = { [weak self] in self?.lastScreen }
    })
    sources.register(BlockSource("ocr") { s in
      s.permissionName = "录屏"
      s.permissionCheck = { ocr.granted ? .granted : .denied }
      s.request = { ocr.requestAccess(); if !ocr.granted { SystemPermissions.openPrivacyPane("Privacy_ScreenCapture") } }
      s.onEnable = { _ in if !ocr.granted { ocr.requestAccess() } }
      s.last = { [weak self] in self?.lastOCRRun }
      s.describe = { [weak self] in self?.enabled("screen") == false ? ("屏幕文字停用时不运行", false) : ("", true) }
    })
    sources.register(BlockSource("clipboard") { s in
      s.last = { [weak self] in self?.lastClipboard }
    })
    sources.register(BlockSource("audio") { s in
      s.permissionName = "麦克风"
      s.permissionCheck = SystemPermissions.microphone
      s.request = SystemPermissions.requestMicrophone
      // 用户手动打开录音时解除"上次启动崩溃"的保护（与原来的菜单开关一致）；启动时不解除。
      s.onEnable = { [weak self] user in if user { self?.audio.allowManualStart() } }
      s.onApply = { [weak self] _ in self?.updateAudio() }
      s.describe = { [weak self] in
        let line = self?.audio.status().first ?? ""
        return (line, !["失败", "崩溃", "不可用", "缺少", "跟不上"].contains { line.contains($0) })
      }
    })
    sources.register(BlockSource("files") { s in
      s.onApply = { active in if active { files.start() } else { files.stop() } }
      s.last = { files.last }
      s.describe = {
        files.unavailable ? ("监听异常", false)
          : (files.recoveredFromDrop ? "曾丢失事件，已恢复" : "监听 \(FileDirectories(store: UserDefaults.standard).list.count) 个目录", true)
      }
    })
    sources.register(BlockSource("calendar") { s in
      s.permissionName = "日历"
      s.permissionCheck = SystemPermissions.calendar
      s.request = { calendar.requestAccess() }
      s.onEnable = { _ in calendar.start() }
      s.last = { calendar.last }
      s.run = { calendar.poll() }
    })
    plugins.isEnabled = { [toggles] in toggles.isEnabled($0) }
    for name in plugins.plugins { sources.register(PluginSource(name, scheduler: plugins)) }
  }

  /// 从 Finder、Spotlight 或 Dock 再次打开 App 时弹出主窗口。
  func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
    MainActor.assumeIsolated { viewer.show() }; return true
  }

  func applicationWillTerminate(_ n: Notification) {
    files.flush(force: true)
    files.stop()
    audio.shutdown()
    closeSegment()
    let deadline = Date().addingTimeInterval(3)
    hub.flush()
    while hub.queue.count > 0 && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.1)) }
  }

  // MARK: 屏幕

  var paused: Bool {
    if let p = pausedUntil, p > Date() { return true }
    pausedUntil = nil
    return false
  }

  func tick() {
    guard !paused, enabled("screen"), AXIsProcessTrusted() else { closeSegment(); updateIcon(); return }
    let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: UInt32.max)!)
    if idle > segmenter.config.idleLimit { closeSegment(); return }
    // 有密码框处于输入状态（安全输入）时什么都不读。
    if IsSecureEventInputEnabled() {
      captureQueue.async { [self] in stats["skippedSecureInput", default: 0] += 1; emit(segmenter.flush()) }
      return
    }
    guard let app = NSWorkspace.shared.frontmostApplication, app.processIdentifier != getpid() else { return }
    let pid = app.processIdentifier
    let bundle = app.bundleIdentifier ?? "unknown"
    let name = app.localizedName ?? bundle
    let now = Date()
    lastScreen = now
    let ocrOn = enabled("ocr")

    captureQueue.async { [self] in
      let snap = ax.snapshot(pid: pid)
      let window = snap?.window ?? ""
      if CapturePolicy.shouldSkip(bundleID: bundle, window: window) {
        stats["skippedPolicy", default: 0] += 1
        emit(segmenter.flush()); return
      }
      let o = Observation(time: now, bundleID: bundle, appName: name, window: window, url: snap?.url,
                          lines: snap?.lines ?? [], method: snap == nil ? "none" : "ax")
      stats["ticks", default: 0] += 1
      if let s = snap {
        stats["scanMsTotal", default: 0] += s.ms
        stats["scanMsMax"] = max(stats["scanMsMax"] ?? 0, s.ms)
        if s.truncated { stats["truncated", default: 0] += 1 }
      }
      emit(segmenter.observe(o))

      // 辅助功能几乎读不到正文时用 OCR 兜底，同一段至少隔 15 秒才再识别一次。
      let key = o.key
      if ocrOn, (snap?.chars ?? 0) < 80, now.timeIntervalSince(lastOCR[key] ?? .distantPast) > 15, ocr.granted {
        lastOCR[key] = now
        if lastOCR.count > 500 { lastOCR = lastOCR.filter { now.timeIntervalSince($0.value) < 600 } }
        ocr.recognize(pid: pid, frame: snap?.frame) { [self] lines, ms in
          DispatchQueue.main.async { [self] in lastOCRRun = Date() }
          captureQueue.async { [self] in
            stats["ocrRuns", default: 0] += 1
            stats["ocrMsTotal", default: 0] += ms
            stats["ocrMsMax"] = max(stats["ocrMsMax"] ?? 0, ms)
            stats["ocrLines", default: 0] += lines.count
            emit(segmenter.appendIfCurrent(key: key, lines: lines, method: "ocr", time: Date()))
          }
        }
      }
    }
  }

  func closeSegment() { captureQueue.async { [self] in emit(segmenter.flush()) } }

  /// 只在 captureQueue 上调用。
  func emit(_ records: [Record]) {
    guard !records.isEmpty else { return }
    stats["screenRecords", default: 0] += records.count
    hub.enqueue(records)
  }

  // MARK: 剪贴板

  func updateAudio() {
    audio.update(enabled: enabled("audio") && !paused)
  }

  func pollClipboard() {
    updateAudio()
    let pb = NSPasteboard.general
    guard pb.changeCount != clipboardCount else { return }
    clipboardCount = pb.changeCount
    guard !paused, enabled("clipboard") else { return }
    let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
    if let front, CapturePolicy.shouldSkip(bundleID: front, window: "") { return }
    let types = pb.types?.map(\.rawValue) ?? []
    if let r = ClipboardPolicy.record(text: pb.string(forType: .string), types: types, app: front,
                                       time: Date(), device: config.device) {
      lastClipboard = Date()
      captureQueue.async { [self] in stats["clipboardRecords", default: 0] += 1 }
      hub.enqueue([r])
    }
  }

  // MARK: 菜单

  func updateFiles() {
    if paused || !enabled("files") { files.stop() }
    else { files.start(); files.flush() }
  }

  /// 屏幕文字停用时不需要辅助功能权限，不显示缺权限。
  var missingAX: Bool { enabled("screen") && !AXIsProcessTrusted() }

  func updateIcon() {
    guard let statusItem else { return }
    let symbol = paused ? "pause-circle" : (missingAX ? "warning-circle" : "record")
    let image = Phosphor.image(symbol, size: 18)
    image?.accessibilityDescription = "record-anything"
    statusItem.button?.image = image
  }

  func menuNeedsUpdate(_ menu: NSMenu) {
    menu.removeAllItems()
    updateIcon()
    let f = DateFormatter(); f.dateFormat = "HH:mm"
    let state: String
    if missingAX { state = "缺少辅助功能权限" }
    else if let p = pausedUntil, paused { state = "已暂停，到 \(f.string(from: p))" }
    else { state = "正在记录" }
    menu.addItem(disabled(state))
    let pending = hub.queue.count
    if let e = hub.lastError { menu.addItem(disabled("\(e) · 待发送 \(pending)")) }
    else if pending > 0 { menu.addItem(disabled("待发送 \(pending)")) }
    if hub.queue.dropped > 0 { menu.addItem(disabled("队列溢出丢弃 \(hub.queue.dropped) 条")) }
    menu.addItem(.separator())

    if paused { menu.addItem(item("继续记录", #selector(resume))) }
    else {
      menu.addItem(item("暂停 1 小时", #selector(pauseHour)))
      menu.addItem(item("暂停到明天", #selector(pauseTomorrow)))
    }
    let open = item("打开 Record Anything", #selector(openHistory)); open.keyEquivalent = "o"
    menu.addItem(open)
    menu.addItem(.separator())

    // 数据源从注册表生成：勾选即开关，缺权限时给授权入口。
    func sourceItems(_ s: DataSourceStatus, into target: NSMenu) {
      var title = s.title
      if s.enabled {
        if s.running { title += " · 运行中" }
        else if !s.ok, !s.detail.isEmpty { title += " · " + s.detail }
        else if let last = s.lastRun { title += " · 最近 " + f.string(from: last) }
      }
      let toggle = item(title, #selector(toggleSource(_:)))
      toggle.representedObject = s.id; toggle.state = s.enabled ? .on : .off
      target.addItem(toggle)
      if s.needsPermission, let name = s.permissionName {
        let grant = item("    授权\(name)…", #selector(requestSourcePermission(_:)))
        grant.representedObject = s.id; target.addItem(grant)
      }
    }
    let statuses = sources.statuses()
    for s in statuses where s.kind == .builtin {
      sourceItems(s, into: menu)
      if s.id == "audio" {
        menu.addItem(microphoneMenu())
        if s.enabled { for line in MicrophoneChoices.statusLines(Array(audio.status().dropFirst())) { menu.addItem(disabled("    " + line)) } }
      }
    }
    let sub = NSMenu()
    if !plugins.available { sub.addItem(disabled("未配置 bun 或仓库路径")) }
    for s in statuses where s.kind == .plugin { sourceItems(s, into: sub) }
    sub.addItem(.separator())
    let runAll = item("立即运行", #selector(runPlugins)); runAll.isEnabled = plugins.available
    sub.addItem(runAll)
    let pi = NSMenuItem(title: "插件", action: nil, keyEquivalent: ""); pi.submenu = sub
    menu.addItem(pi)
    menu.addItem(.separator())
    menu.addItem(item("退出", #selector(quit)))
  }

  func microphoneMenu() -> NSMenuItem {
    let microphones = NSMenu()
    let setting = microphoneSetting
    for choice in microphoneChoices(setting: setting) {
      if choice.group != .mode, microphones.items.count == 2 { microphones.addItem(.separator()) }
      let entry = choice.selectable ? item(choice.title, #selector(selectMicrophone(_:))) : disabled(choice.title)
      entry.representedObject = choice.value
      entry.state = choice.value == setting ? .on : .off
      microphones.addItem(entry)
    }
    let microphoneMenu = NSMenuItem(title: "    麦克风", action: nil, keyEquivalent: "")
    microphoneMenu.submenu = microphones
    return microphoneMenu
  }

  var microphoneSetting: String { UserDefaults.standard.string(forKey: "micDevice") ?? "builtin" }
  /// 菜单栏子菜单和设置页选择器共用。
  func microphoneChoices(setting: String) -> [MicrophoneChoice] {
    MicrophoneChoices.list(devices: try? MicrophoneDevices.inputs().map(\.descriptor), setting: setting)
  }

  func item(_ title: String, _ sel: Selector) -> NSMenuItem {
    let i = NSMenuItem(title: title, action: sel, keyEquivalent: ""); i.target = self; return i
  }
  func disabled(_ title: String) -> NSMenuItem { let i = NSMenuItem(title: title, action: nil, keyEquivalent: ""); i.isEnabled = false; return i }

  @objc func requestAX() {
    AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
  }
  @objc func pauseHour() { pause(until: Date().addingTimeInterval(3600)) }
  @objc func pauseTomorrow() {
    let cal = Calendar.current
    pause(until: cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: Date()))!)
  }
  func pause(until: Date) { pausedUntil = until; sources.applyAll(paused: true); updateIcon() }
  @objc func resume() { pausedUntil = nil; sources.applyAll(paused: false); updateFiles(); updateIcon() }
  @objc func toggleSource(_ sender: NSMenuItem) {
    guard let id = sender.representedObject as? String else { return }
    setSource(id, !enabled(id))
  }
  func setSource(_ id: String, _ on: Bool) { sources.setEnabled(id, on, paused: paused); updateIcon() }
  @objc func requestSourcePermission(_ sender: NSMenuItem) {
    guard let id = sender.representedObject as? String else { return }
    sources.source(id)?.requestPermission()
  }
  @objc func selectMicrophone(_ sender: NSMenuItem) {
    guard let setting = sender.representedObject as? String else { return }
    audio.selectMicrophone(setting)
  }
  @objc func runPlugins() { plugins.run(plugins.plugins, since: nil) }
  @objc func openHistory() { MainActor.assumeIsolated { viewer.show() } }
  @objc func quit() { NSApp.terminate(nil) }

  // MARK: 维护

  /// 立即同步全部、重新导入最近 7 天、导入全部历史。整理启用前的历史由窗口直接向 hub 提交请求。
  func runMaintenance(_ task: MaintenanceTask) {
    guard task != .backfill, jobs[task]?.running != true else { return }
    guard plugins.available else { jobs[task] = .init(running: false, text: "未配置 bun 或仓库路径，插件无法运行"); return }
    let names = plugins.plugins.filter(enabled)
    jobs[task] = .init(running: true, text: task == .syncAll ? "同步中…" : "导入中…")
    if task == .syncAll { hub.flush(); files.flush(); calendar.poll() }
    let api = api
    plugins.run(names, since: PluginImport.since(task)) { [weak self] results in
      let accepted = results.values.reduce(0) { $0 + $1.accepted }
      let failed = results.filter { !$0.value.ok }.keys.sorted().map { DataSourceCatalog.descriptor($0)?.title ?? $0 }
      let summary = "新增 \(accepted) 条" + (failed.isEmpty ? "" : " · 失败：\(failed.joined(separator: "、"))")
      Task {
        var text = summary
        // 同步全部之后请常驻的提炼进程立即跑一轮；采集端不自己启动提炼。
        if task == .syncAll {
          do { try await api.requestDistill(kind: "round"); text += " · 已请求提炼" }
          catch { text += " · 提炼请求失败：\(error.localizedDescription)" }
        }
        let f = DateFormatter(); f.dateFormat = "HH:mm"
        let done = "\(f.string(from: Date())) 完成 · " + text
        DispatchQueue.main.async { self?.jobs[task] = .init(running: false, text: done) }
      }
    }
  }

  func writeStatus() {
    let enabledSources = Dictionary(uniqueKeysWithValues: DataSourceCatalog.all.map { ($0.id, enabled($0.id)) })
    captureQueue.async { [self] in
      var s: [String: Any] = stats
      s["queue"] = hub.queue.count; s["dropped"] = hub.queue.dropped
      s["sent"] = hub.sent; s["rejected"] = hub.rejected; s["hubError"] = hub.lastError ?? NSNull()
      s["axTrusted"] = AXIsProcessTrusted(); s["ocrEnabled"] = enabledSources["ocr"] ?? false; s["ocrGranted"] = ocr.granted
      s["sources"] = enabledSources
      s["paused"] = pausedUntil != nil; s["plugins"] = plugins.status()
      s["footprintMB"] = Int(footprintMB()); s["cpuSeconds"] = Int(cpuSeconds())
      s["time"] = LocalTime.iso(Date())
      if let d = try? JSONSerialization.data(withJSONObject: s, options: [.prettyPrinted, .sortedKeys]) {
        try? d.write(to: config.dataDir.appendingPathComponent("collector-status.json"), options: .atomic)
      }
    }
  }
}

/// 与活动监视器的"内存"一致；RSS 会把共享库和映射的模型文件算进来，偏高且可被系统回收。
func footprintMB() -> Double {
  var info = task_vm_info_data_t()
  var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
  let r = withUnsafeMutablePointer(to: &info) {
    $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
  }
  return r == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : 0
}

func cpuSeconds() -> Double {
  var usage = rusage()
  getrusage(RUSAGE_SELF, &usage)
  return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1e6
}

if CommandLine.arguments.contains("--probe-front") { runProbe(); exit(0) }
if let i = CommandLine.arguments.firstIndex(of: "--render-icon"), i + 1 < CommandLine.arguments.count {
  do { try AppIconArt.writeIconset(to: URL(fileURLWithPath: CommandLine.arguments[i + 1])); exit(0) }
  catch { FileHandle.standardError.write(Data("\(error)\n".utf8)); exit(1) }
}

// 已经有一个采集端在跑（例如 launchd 刚拉起，用户又从访达打开）：请它打开窗口，自己退出。
// launchd 拉起的那份不弹窗口：launchd 会给它的任务设 XPC_SERVICE_NAME。
let instanceLock = InstanceLock.acquire(path: Config.load().dataDir.appendingPathComponent("collector.lock").path)
if case .held = instanceLock {
  if ProcessInfo.processInfo.environment["XPC_SERVICE_NAME"]?.hasPrefix("dev.record-anything.") != true {
    DistributedNotificationCenter.default().postNotificationName(.init(AppDelegate.showWindowNotification), object: nil, deliverImmediately: true)
  }
  exit(0)
}

Phosphor.register()
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()

// MARK: 主窗口读取采集状态

extension AppDelegate: CaptureControlling {
  func captureSnapshot() -> CaptureSnapshot {
    var c = CaptureSnapshot()
    if missingAX { c.state = .noPermission } else if let p = pausedUntil, paused { c.state = .paused(p) }
    c.queue = hub.queue.count
    c.sent = hub.sent
    c.hubError = hub.lastError
    c.sources = sources.statuses()
    c.audio = enabled("audio") ? audio.status() : []
    c.microphone = microphoneSetting
    c.microphones = microphoneChoices(setting: c.microphone)
    c.pluginsAvailable = plugins.available
    c.jobs = jobs
    c.fileDirectories = FileDirectories(store: UserDefaults.standard).list
    return c
  }

  func perform(_ action: CaptureAction) {
    switch action {
    case .pauseHour: pauseHour()
    case .pauseTomorrow: pauseTomorrow()
    case .resume: resume()
    case .requestAX: requestAX()
    case .setSource(let id, let on): setSource(id, on)
    case .requestPermission(let id): sources.source(id)?.requestPermission()
    case .runSource(let id): sources.source(id)?.runNow()
    case .maintenance(let task): runMaintenance(task)
    case .selectMicrophone(let setting): audio.selectMicrophone(setting)
    case .setFileDirectories(let dirs):
      FileDirectories(store: UserDefaults.standard).save(dirs)
      // 重建监听流；停用或暂停时 start() 自己不会启动。
      files.flush(force: true); files.stop()
      if !paused && enabled("files") { files.start() }
    }
  }
}
