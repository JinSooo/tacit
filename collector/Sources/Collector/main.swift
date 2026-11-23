import AppKit
import ApplicationServices
import Carbon.HIToolbox
import SwiftUI
import CollectorCore

/// 菜单栏采集端。所有读取都在这里做，hub 只接收数据。
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
  /// 第二个实例启动时发这个通知，请已在运行的采集端打开窗口。
  static let showWindowNotification = "dev.record-anything.collector.show-window"
  let config: Config

  init(config: Config) { self.config = config }
  let toggles = SourceToggles(store: UserDefaults.standard)
  lazy var sources = DataSourceRegistry(toggles: toggles)
  lazy var deviceSession = HostDeviceSession(
    origin: { [config] in config.hubURL },
    files: LocalDeviceLink.Files(directory: config.dataDir),
    keys: .keychain
  )
  lazy var hub = HubClient(config: config, deviceSession: deviceSession, onHealthEvent: { [weak self] in
    nonisolated(unsafe) let delegate = self
    DispatchQueue.main.async { delegate?.writeStatus() }
  }) { [weak self] _ in
    nonisolated(unsafe) let delegate = self
    delegate?.viewerDataSource.activateIfLinked()
    DispatchQueue.main.async { delegate?.writeStatus(forceReport: true) }
  }
  lazy var api = HubAPI(base: { [config] in config.hubURL }, token: { [config] in config.token })
  lazy var viewerDataSource: AdaptiveViewerDataSource = {
    let widgetURL = WidgetSnapshot.fileURL.flatMap { file in
      file.deletingLastPathComponent().deletingLastPathComponent().path == config.dataDir.standardizedFileURL.path ? file : nil
    }
    return AdaptiveViewerDataSource(
      http: HTTPViewerDataSource(api: api),
      dataDir: config.dataDir,
      originProvider: { [config] in config.hubURL },
      widgetSnapshotURL: widgetURL,
      onUpdate: { [weak self] result in
        let delegate = self
        await MainActor.run {
          guard let delegate, !delegate.terminating else { return }
          delegate.widgetPublisher?.refresh()
          let needsReload = result.deletedCount > 0 || !result.goneRecordIDs.isEmpty || result.didReset
          delegate.viewer.store.applyRemoteSync(reloadViews: needsReload)
        }
      },
      onWipe: { [weak self] _ in
        let delegate = self
        await MainActor.run {
          guard let delegate, !delegate.terminating else { return }
          delegate.widgetPublisher?.clearSnapshot()
        }
      }
    )
  }()
  @MainActor private lazy var deviceDiscovery = DeviceDiscovery(advertiser: BonjourDeviceAdvertiser())
  lazy var audio = AudioCoordinator(config: config, deviceSession: deviceSession)
  lazy var plugins = PluginScheduler(config: config, deviceSession: deviceSession)
  lazy var viewer: ViewerWindow = MainActor.assumeIsolated {
    let store = ViewerStore(api: api, dataSource: viewerDataSource, device: config.device, controls: self)
    store.onRevision = { [weak self] in
      self?.viewerDataSource.notifyLocalWrite()
      self?.widgetPublisher?.refresh(invalidate: true)
    }
    store.onDeviceSettingsUpdate = { [weak self] settings, invitationHubId in
      guard let self, !self.terminating else { return }
      self.deviceDiscovery.update(settings, invitationHubId: invitationHubId)
    }
    let window = ViewerWindow(store: store)
    window.onClose = { [weak self] in
      self?.viewerDataSource.clearMemory()
      self?.updateSyncForeground()
    }
    return window
  }
  private var widgetPublisher: WidgetSnapshotPublisher?
  private var readyForTimelineURL = false
  private var pendingTimelineDay: Date?
  lazy var segmenter = Segmenter(device: config.device)
  lazy var wechat = WeChatCollector(device: config.device, ocr: ocr, send: { [weak self] in self?.hub.enqueue($0) })
  let ax = AXReader()
  let ocr = OCRReader()
  let captureQueue = DispatchQueue(label: "record-anything.capture", qos: .utility)

  var statusItem: NSStatusItem!
  let statusMenu = NSMenu()
  lazy var panel: StatusPanel = MainActor.assumeIsolated {
    let p = StatusPanel(store: viewer.store) { [weak self] page in self?.viewer.show(page) }
    p.onVisibilityChange = { [weak self] visible in
      guard let self else { return }
      if !visible && !WindowVisibility.visible { self.viewerDataSource.clearMemory() }
      self.updateSyncForeground()
    }
    return p
  }

  @MainActor private func updateSyncForeground() {
    viewerDataSource.setForeground(WindowVisibility.visible || panel.isShown)
  }
  var timers: [Timer] = []
  var terminationSignal: TerminationSignal?
  var terminating = false
  var pausedUntil: Date?
  var ocrSchedule = OCRSchedule()
  // 以下只在主线程读写，给"上次运行"用。
  var lastScreen: Date?
  var lastOCRRun: Date?
  /// 维护任务（同步、导入）的进行状态，只在主线程读写。
  var jobs: [MaintenanceTask: CaptureSnapshot.Job] = [:]
  var managingPlugins = Set<String>()

  // 只计数，不含任何内容；写到 collector-status.json 便于排查和验收。
  var stats: [String: Int] = ["ticks": 0, "scanMsTotal": 0, "scanMsMax": 0, "truncated": 0,
                              "ocrRuns": 0, "ocrMsTotal": 0, "ocrLines": 0, "screenRecords": 0,
                              "skippedPolicy": 0, "skippedSecureInput": 0]

  func enabled(_ id: String) -> Bool { toggles.isEnabled(id) }

  func applicationDidFinishLaunching(_ n: Notification) {
    terminationSignal = TerminationSignal { NSApp.terminate(nil) }
    let startup = LoginStartup(home: FileManager.default.homeDirectoryForCurrentUser, dataDir: config.dataDir)
    guard AppSetup.start(config: config, startup: startup) else { return }
    MainActor.assumeIsolated {
      WindowVisibility.onChange = { [weak self] _ in self?.updateSyncForeground() }
    }
    viewerDataSource.activateIfLinked()
    hub.flush()
    statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    // 左键弹面板，右键（或按住 control 点）弹菜单。菜单不常驻在 statusItem 上，否则左键也会弹菜单。
    statusMenu.delegate = self
    statusItem.button?.target = self
    statusItem.button?.action = #selector(statusClicked(_:))
    statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
    registerSources()
    // 上次开启录音时崩溃：先关掉录音开关，再启动各数据源。
    if audio.initiallyBlocked { toggles.setEnabled("audio", false) }
    sources.launch(paused: paused)
    updateIcon()
    MainActor.assumeIsolated { deviceDiscovery.refreshIfDue(api: api) }

    timers = [
      Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in self?.tick() },
      Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.updateAudio() },
      Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in self?.hub.flush() },
      Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in self?.writeStatus() },
      Timer.scheduledTimer(withTimeInterval: config.pluginInterval, repeats: true) { [weak self] _ in self?.plugins.runAll() },
    ]
    DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in self?.plugins.runAll() }

    let ws = NSWorkspace.shared.notificationCenter
    if let file = WidgetSnapshot.fileURL,
       file.deletingLastPathComponent().deletingLastPathComponent().path == config.dataDir.standardizedFileURL.path,
       let plugins = Bundle.main.builtInPlugInsURL,
       FileManager.default.fileExists(atPath: plugins.appendingPathComponent("TacitWidget.appex").path) {
      MainActor.assumeIsolated {
        widgetPublisher = WidgetSnapshotPublisher(dataSource: viewerDataSource, file: file)
        widgetPublisher?.refresh()
      }
      ws.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
        MainActor.assumeIsolated { self?.widgetPublisher?.refresh() }
      }
      NotificationCenter.default.addObserver(forName: .NSCalendarDayChanged, object: nil, queue: .main) { [weak self] _ in
        MainActor.assumeIsolated { self?.widgetPublisher?.refresh() }
      }
    }
    readyForTimelineURL = true
    if let day = pendingTimelineDay {
      pendingTimelineDay = nil
      MainActor.assumeIsolated { viewer.show(.timelineDay(day)) }
    }
    ws.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { [weak self] _ in self?.updateAudio() }
    ws.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in self?.tick() }
    for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
      ws.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
        self?.closeSegment()
        self?.viewerDataSource.clearMemory()
      }
    }
    DistributedNotificationCenter.default().addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
      self?.closeSegment()
      self?.viewerDataSource.clearMemory()
    }
    DistributedNotificationCenter.default().addObserver(forName: .init(Self.showWindowNotification), object: nil, queue: .main) { [weak self] _ in
      self?.openHistory()
    }
  }

  /// 把各采集器接到统一的数据源接口上。顺序以 DataSourceCatalog 为准。
  func registerSources() {
    let ocr = ocr
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
      s.describe = { [weak self] in self?.enabled("screen") == false ? ("要先打开“屏幕文字”", false) : ("", true) }
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
    let wechat = wechat
    sources.register(BlockSource("wechat") { s in
      s.permissionName = "录屏"
      s.permissionCheck = { ocr.granted ? .granted : .denied }
      s.request = { ocr.requestAccess(); if !ocr.granted { SystemPermissions.openPrivacyPane("Privacy_ScreenCapture") } }
      s.onEnable = { _ in if !ocr.granted { ocr.requestAccess() } }
      s.last = { wechat.last }
      s.describe = { (wechat.lastSummary, true) }
    })
    plugins.isEnabled = { [toggles] in toggles.isEnabled($0) }
    for name in DataSourceCatalog.plugins.map(\.id) { sources.register(PluginSource(name, scheduler: plugins)) }
    reloadExtensions()
  }

  /// 从 Finder、Spotlight 或 Dock 再次打开 App 时弹出主窗口。
  func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
    MainActor.assumeIsolated { viewer.show() }; return true
  }

  func application(_ application: NSApplication, open urls: [URL]) {
    guard let day = urls.lazy.compactMap({ WidgetSnapshot.timelineDate(from: $0) }).first,
          day <= Date() else { return }
    if readyForTimelineURL { MainActor.assumeIsolated { viewer.show(.timelineDay(day)) } }
    else { pendingTimelineDay = day }
  }

  func applicationWillTerminate(_ n: Notification) {
    guard !terminating else { return }
    terminating = true
    MainActor.assumeIsolated {
      widgetPublisher?.stop()
      deviceDiscovery.update(nil)
    }
    viewerDataSource.stop()
    timers.forEach { $0.invalidate() }
    audio.shutdown()
    captureQueue.sync { emit(segmenter.flush()) }
    let deadline = Date().addingTimeInterval(3)
    hub.flush()
    while hub.pendingCount > 0 && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.1)) }
  }

  // MARK: 屏幕

  var paused: Bool {
    if let p = pausedUntil, p > Date() { return true }
    if pausedUntil != nil { pausedUntil = nil; sources.applyAll(paused: false) }
    return false
  }

  func tick() {
    guard !terminating else { return }
    // 微信对话不依赖屏幕文字和辅助功能：只要开着、微信在前台就截图拆消息。
    if !paused, enabled("wechat"), !IsSecureEventInputEnabled(),
       let front = NSWorkspace.shared.frontmostApplication, front.bundleIdentifier == WeChatCollector.bundleID,
       !CapturePolicy.shouldSkip(bundleID: WeChatCollector.bundleID, window: "") {
      wechat.poll(pid: front.processIdentifier, frame: nil)
    }
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
    let keepText = ScreenTextPolicy.keepsText(bundleID: bundle)

    captureQueue.async { [self] in
      if CapturePolicy.shouldSkip(bundleID: bundle, window: "") {
        stats["skippedPolicy", default: 0] += 1
        emit(segmenter.flush()); return
      }
      let snap = ax.snapshot(pid: pid, includeText: keepText)
      let window = snap?.window ?? ""
      if CapturePolicy.shouldSkip(bundleID: bundle, window: window) {
        stats["skippedPolicy", default: 0] += 1
        emit(segmenter.flush()); return
      }
      let o = Observation(time: now, bundleID: bundle, appName: name, window: window, url: snap?.url,
                          lines: snap?.lines ?? [], editable: snap?.editable ?? [:],
                          method: snap == nil ? "none" : "ax")
      stats["ticks", default: 0] += 1
      if let s = snap {
        stats["scanMsTotal", default: 0] += s.ms
        stats["scanMsMax"] = max(stats["scanMsMax"] ?? 0, s.ms)
        if s.truncated { stats["truncated", default: 0] += 1 }
      }
      emit(segmenter.observe(o))

      // 辅助功能几乎读不到正文时用 OCR 兜底，节奏见 OCRSchedule：画面文字没变就逐步放慢。
      let key = o.key
      if ocrOn, keepText, (snap?.chars ?? 0) < 80, ocrSchedule.due(key, now: now), ocr.granted {
        ocrSchedule.started(key, now: now)
        ocr.recognizeLines(pid: pid, frame: snap?.frame) { [self] found, size, ms in
          let lines = found.filter { line in
            !ScreenTextPolicy.isEditableOCRPoint(CGPoint(x: line.midX, y: line.y + line.height / 2),
                                                 window: size, frame: snap?.frame, editableFrames: snap?.editableFrames ?? [])
          }.map(\.text)
          DispatchQueue.main.async { [self] in lastOCRRun = Date() }
          captureQueue.async { [self] in
            stats["ocrRuns", default: 0] += 1
            stats["ocrMsTotal", default: 0] += ms
            stats["ocrMsMax"] = max(stats["ocrMsMax"] ?? 0, ms)
            stats["ocrLines", default: 0] += lines.count
            ocrSchedule.finished(key, lines: lines)
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

  // MARK: 录音

  func updateAudio() {
    guard !terminating else { return }
    audio.update(enabled: enabled("audio") && !paused)
  }

  // MARK: 菜单

  /// 屏幕文字停用时不需要辅助功能权限，不显示缺权限。
  var missingAX: Bool { enabled("screen") && !AXIsProcessTrusted() }

  func updateIcon() {
    guard let statusItem else { return }
    let image = StatusIconArt.image(paused ? .paused : (missingAX ? .warning : .recording))
    image.accessibilityDescription = "Tacit"
    statusItem.button?.image = image
  }

  @objc func statusClicked(_ sender: NSStatusBarButton) {
    let event = NSApp.currentEvent
    MainActor.assumeIsolated {
      if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
        panel.close()
        statusItem.menu = statusMenu
        sender.performClick(nil)
        statusItem.menu = nil
      } else {
        panel.toggle(from: sender)
      }
    }
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
    let pending = hub.pendingCount
    if let e = hub.lastError { menu.addItem(disabled("\(e)，\(pending) 条等着发送")) }
    else if pending > 0 { menu.addItem(disabled("\(pending) 条等着发送")) }
    let dropped = hub.queue.dropped + hub.outboxStatus.dropped
    if dropped > 0 { menu.addItem(disabled("等太久丢掉了 \(dropped) 条")) }
    menu.addItem(.separator())

    if paused { menu.addItem(item("继续记录", #selector(resume))) }
    else {
      menu.addItem(item("暂停 1 小时", #selector(pauseHour)))
      menu.addItem(item("暂停到明天", #selector(pauseTomorrow)))
    }
    let open = item("打开 Tacit", #selector(openHistory)); open.keyEquivalent = "o"
    menu.addItem(open)
    menu.addItem(.separator())

    // 数据源从注册表生成：勾选即开关，缺权限时给授权入口。
    func sourceItems(_ s: DataSourceStatus, into target: NSMenu) {
      var title = s.title
      if s.enabled {
        if s.running { title += "（正在运行）" }
        else if !s.ok, !s.detail.isEmpty { title += "：" + s.detail }
        else if let last = s.lastRun { title += "（\(f.string(from: last)) 运行过）" }
      }
      let toggle = item(title, #selector(toggleSource(_:)))
      toggle.representedObject = s.id; toggle.state = s.enabled ? .on : .off
      target.addItem(toggle)
      if s.needsPermission, let name = s.permissionName {
        let grant = item("    授权\(name)…", #selector(requestSourcePermission(_:)))
        grant.representedObject = s.id; target.addItem(grant)
      }
    }
    let statuses = sources.statuses().filter { DataSourceCatalog.isVisible($0.id) }
    for s in statuses where s.kind == .builtin {
      sourceItems(s, into: menu)
      if s.id == "audio" {
        menu.addItem(microphoneMenu())
        if s.enabled { for line in MicrophoneChoices.statusLines(Array(audio.status().dropFirst())) { menu.addItem(disabled("    " + line)) } }
      }
    }
    let sub = NSMenu()
    if !plugins.available { sub.addItem(disabled("找不到 bun 或安装目录")) }
    for s in statuses where s.kind == .plugin { sourceItems(s, into: sub) }
    sub.addItem(.separator())
    let runAll = item("全部运行一次", #selector(runPlugins)); runAll.isEnabled = plugins.available
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
  @objc func resume() { pausedUntil = nil; sources.applyAll(paused: false); updateIcon() }
  @objc func toggleSource(_ sender: NSMenuItem) {
    guard let id = sender.representedObject as? String else { return }
    setSource(id, !enabled(id))
  }
  func setSource(_ id: String, _ on: Bool) {
    if on && managingPlugins.contains(id) { return }
    sources.setEnabled(id, on, paused: paused); updateIcon()
  }
  @objc func requestSourcePermission(_ sender: NSMenuItem) {
    guard let id = sender.representedObject as? String else { return }
    sources.source(id)?.requestPermission()
  }
  @objc func selectMicrophone(_ sender: NSMenuItem) {
    guard let setting = sender.representedObject as? String else { return }
    audio.selectMicrophone(setting)
  }
  @objc func runPlugins() { plugins.run(plugins.plugins.filter(DataSourceCatalog.isVisible), since: nil) }
  @objc func openHistory() { MainActor.assumeIsolated { viewer.show() } }
  @objc func quit() { NSApp.terminate(nil) }

  // MARK: 维护

  /// 立即同步全部、重新导入最近 7 天、导入全部历史。整理启用前的历史由窗口直接向 hub 提交请求。
  func runMaintenance(_ task: MaintenanceTask) {
    guard task != .backfill, jobs[task]?.running != true else { return }
    guard plugins.available else { jobs[task] = .init(running: false, text: "找不到 bun 或安装目录，插件不能运行"); return }
    let names = plugins.plugins.filter(enabled)
    jobs[task] = .init(running: true, text: task == .syncAll ? "正在同步…" : "正在导入…")
    if task == .syncAll { hub.flush() }
    let api = api
    plugins.run(names, since: PluginImport.since(task)) { [weak self] results in
      let accepted = results.values.reduce(0) { $0 + $1.accepted }
      let failed = results.filter { !$0.value.ok }.keys.sorted().map { DataSourceCatalog.descriptor($0)?.title ?? $0 }
      let summary = "新增 \(accepted.formatted()) 条" + (failed.isEmpty ? "" : "，\(failed.joined(separator: "、"))没有成功")
      Task { @MainActor in
        var text = summary
        // 同步全部之后请常驻的提炼进程立即跑一轮；采集端不自己启动提炼。
        if task == .syncAll {
          do { try await api.requestDistill(kind: "round"); text += "，正在整理" }
          catch { text += "，整理没能开始：\(error.localizedDescription)" }
        }
        let f = DateFormatter(); f.dateFormat = "HH:mm"
        let done = "\(f.string(from: Date())) 完成，" + text
        self?.jobs[task] = .init(running: false, text: done)
      }
    }
  }

  private var statusThrottle = CollectorStatusThrottle()
  private var statusReporting = false

  func writeStatus(forceReport: Bool = false) {
    MainActor.assumeIsolated { deviceDiscovery.refreshIfDue(api: api) }
    let enabledSources = Dictionary(uniqueKeysWithValues: DataSourceCatalog.all.map { ($0.id, enabled($0.id)) })
    captureQueue.async { [self] in
      let nowDate = Date()
      let timeText = LocalTime.iso(nowDate)
      let outbox = hub.outboxStatus
      let hubBusy = hub.hubBusy
      let queuePeak = hub.queuePeak
      let hubError = hub.lastError
      let transcription = enabledSources["audio"] == true ? audio.transcriptionStatus() : nil
      var s: [String: Any] = stats
      s["queue"] = hub.pendingCount; s["dropped"] = hub.queue.dropped
      s["hubBusy"] = hubBusy; s["queuePeak"] = queuePeak
      s["sent"] = hub.sent; s["rejected"] = hub.rejected; s["hubError"] = hubError ?? NSNull()
      s["axTrusted"] = AXIsProcessTrusted(); s["ocrEnabled"] = enabledSources["ocr"] ?? false; s["ocrGranted"] = ocr.granted
      s["sources"] = enabledSources
      s["paused"] = pausedUntil != nil; s["plugins"] = plugins.status()
      s["footprintMB"] = Int(footprintMB()); s["cpuSeconds"] = Int(cpuSeconds())
      s["time"] = timeText
      if enabledSources["audio"] == true { s["micQuietLevels"] = audio.microphoneQuietLevels().json }
      CollectorStatus.write(s, transcription: transcription,
                            outbox: outbox, to: config.dataDir.appendingPathComponent("collector-status.json"))

      let report = CollectorStatusReport(
        time: timeText,
        transcription: transcription,
        outbox: outbox,
        hubBusy: hubBusy,
        queuePeak: queuePeak
      )
      let uptime = ProcessInfo.processInfo.systemUptime
      let hasError = hubError != nil
      guard !statusReporting, statusThrottle.shouldSend(report, hasError: hasError, force: forceReport, now: uptime) else { return }
      statusReporting = true
      let deviceSession = self.deviceSession
      nonisolated(unsafe) weak var weakSelf = self
      Task {
        let sent = (try? await deviceSession.send(op: "collector.status", body: report)) != nil
        weakSelf?.captureQueue.async {
          guard let self = weakSelf else { return }
          self.statusReporting = false
          if sent { self.statusThrottle.recordSent(report, hasError: hasError, at: ProcessInfo.processInfo.systemUptime) }
        }
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

let config = Config.load()
let logFile = config.dataDir.appendingPathComponent("logs/collector.log")
let launchedByAgent = ProcessInfo.processInfo.environment["XPC_SERVICE_NAME"]?.hasPrefix("dev.record-anything.") == true
let launchSource: DiagnosticLog.LaunchSource = launchedByAgent || DiagnosticLog.isFile(logFile, on: STDERR_FILENO)
  ? .launchd : Bundle.main.bundleURL.pathExtension == "app" ? .finder : .unknown
do { try DiagnosticLog.redirectIfNeeded(to: logFile) }
catch { DiagnosticLog.shared.record(.collectorLogOpenFailed) }
DiagnosticLog.installUncaughtExceptionHandler()

// 已经有一个采集端在跑时，请它打开窗口，自己退出。launchd 拉起的实例不弹窗。
let instanceLock = InstanceLock.acquire(path: config.dataDir.appendingPathComponent("collector.lock").path)
if case .held = instanceLock {
  if !launchedByAgent {
    DistributedNotificationCenter.default().postNotificationName(.init(AppDelegate.showWindowNotification), object: nil, deliverImmediately: true)
  }
  exit(0)
}
DiagnosticLog.shared.record(.started(DiagnosticBuild(), launchSource))

Phosphor.register()
let app = NSApplication.shared
let delegate = AppDelegate(config: config)
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()

// MARK: 主窗口读取采集状态

extension AppDelegate: CaptureControlling {
  func reloadExtensions() {
    let installed = plugins.installedExtensions()
    for source in sources.sources where source.descriptor.id.hasPrefix("ext-") {
      if !installed.contains(where: { $0.id == source.descriptor.id && $0.manifest.name == source.descriptor.title }) {
        sources.unregister(source.descriptor.id)
      }
    }
    for plugin in installed where sources.source(plugin.id) == nil {
      let source = PluginSource(plugin, scheduler: plugins)
      sources.register(source)
      source.apply(active: !paused && enabled(plugin.id))
    }
  }
  @MainActor func pluginCommand(_ request: PluginRequest) async throws -> PluginResponse {
    // 管理和采集共用串行队列：先停用，再等待已运行的进程退出，避免更新/删除时还在写记录。
    let managed = ["install", "uninstall"].contains(request.action) ? request.id : nil
    if let id = managed { managingPlugins.insert(id); setSource(id, false) }
    defer { if let id = managed { managingPlugins.remove(id) } }
    let result = try await plugins.manage(request)
    if result.error == nil && ["install", "uninstall"].contains(request.action) {
      if let id = result.plugin?.id { toggles.setEnabled(id, false) }
      reloadExtensions()
    }
    return result
  }

  func captureSnapshot() -> CaptureSnapshot {
    var c = CaptureSnapshot()
    if missingAX { c.state = .noPermission } else if let p = pausedUntil, paused { c.state = .paused(p) }
    c.queue = hub.pendingCount
    c.sent = hub.sent
    c.hubError = hub.lastError
    c.sources = sources.statuses()
    c.audio = enabled("audio") ? audio.status() : []
    c.microphone = microphoneSetting
    c.microphones = microphoneChoices(setting: c.microphone)
    c.pluginsAvailable = plugins.available
    c.jobs = jobs
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
    }
  }
}
