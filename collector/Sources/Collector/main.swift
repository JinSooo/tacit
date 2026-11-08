import AppKit
import ApplicationServices
import Carbon.HIToolbox
import CollectorCore

/// 菜单栏采集端。所有读取都在这里做，hub 只接收数据。
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
  let config = Config.load()
  lazy var hub = HubClient(config: config)
  lazy var plugins = PluginScheduler(config: config)
  lazy var segmenter = Segmenter(device: config.device)
  let ax = AXReader()
  let ocr = OCRReader()
  let captureQueue = DispatchQueue(label: "record-anything.capture", qos: .utility)

  var statusItem: NSStatusItem!
  var timers: [Timer] = []
  var pausedUntil: Date?
  var ocrEnabled: Bool {
    get { UserDefaults.standard.bool(forKey: "ocrEnabled") }
    set { UserDefaults.standard.set(newValue, forKey: "ocrEnabled") }
  }
  var lastOCR: [String: Date] = [:]
  var clipboardCount = NSPasteboard.general.changeCount

  // 只计数，不含任何内容；写到 collector-status.json 便于排查和验收。
  var stats: [String: Int] = ["ticks": 0, "scanMsTotal": 0, "scanMsMax": 0, "truncated": 0,
                              "ocrRuns": 0, "ocrMsTotal": 0, "ocrLines": 0, "screenRecords": 0,
                              "clipboardRecords": 0, "skippedPolicy": 0, "skippedSecureInput": 0]

  func applicationDidFinishLaunching(_ n: Notification) {
    statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    let menu = NSMenu(); menu.delegate = self
    statusItem.menu = menu
    updateIcon()
    if !AXIsProcessTrusted() {
      AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
    }

    timers = [
      Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in self?.tick() },
      Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.pollClipboard() },
      Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in self?.hub.flush() },
      Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in self?.writeStatus() },
      Timer.scheduledTimer(withTimeInterval: config.pluginInterval, repeats: true) { [weak self] _ in self?.plugins.runAll() },
    ]
    DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in self?.plugins.runAll() }

    let ws = NSWorkspace.shared.notificationCenter
    ws.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in self?.tick() }
    for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
      ws.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.closeSegment() }
    }
    DistributedNotificationCenter.default().addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
      self?.closeSegment()
    }
  }

  func applicationWillTerminate(_ n: Notification) {
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
    guard !paused, AXIsProcessTrusted() else { closeSegment(); updateIcon(); return }
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
      if ocrEnabled, (snap?.chars ?? 0) < 80, now.timeIntervalSince(lastOCR[key] ?? .distantPast) > 15, ocr.granted {
        lastOCR[key] = now
        if lastOCR.count > 500 { lastOCR = lastOCR.filter { now.timeIntervalSince($0.value) < 600 } }
        ocr.recognize(pid: pid, frame: snap?.frame) { [self] lines, ms in
          captureQueue.async { [self] in
            stats["ocrRuns", default: 0] += 1
            stats["ocrMsTotal", default: 0] += ms
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

  func pollClipboard() {
    let pb = NSPasteboard.general
    guard pb.changeCount != clipboardCount else { return }
    clipboardCount = pb.changeCount
    guard !paused else { return }
    let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
    if let front, CapturePolicy.shouldSkip(bundleID: front, window: "") { return }
    let types = pb.types?.map(\.rawValue) ?? []
    if let r = ClipboardPolicy.record(text: pb.string(forType: .string), types: types, app: front,
                                       time: Date(), device: config.device) {
      captureQueue.async { [self] in stats["clipboardRecords", default: 0] += 1 }
      hub.enqueue([r])
    }
  }

  // MARK: 菜单

  func updateIcon() {
    let symbol = paused ? "pause.circle" : (AXIsProcessTrusted() ? "record.circle" : "exclamationmark.circle")
    statusItem.button?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "record-anything")
    statusItem.button?.image?.isTemplate = true
  }

  func menuNeedsUpdate(_ menu: NSMenu) {
    menu.removeAllItems()
    updateIcon()
    let f = DateFormatter(); f.dateFormat = "HH:mm"
    let state: String
    if !AXIsProcessTrusted() { state = "缺少辅助功能权限" }
    else if let p = pausedUntil, paused { state = "已暂停，到 \(f.string(from: p))" }
    else { state = "正在记录" }
    menu.addItem(disabled(state))
    let pending = hub.queue.count
    if let e = hub.lastError { menu.addItem(disabled("\(e) · 待发送 \(pending)")) }
    else if pending > 0 { menu.addItem(disabled("待发送 \(pending)")) }
    if hub.queue.dropped > 0 { menu.addItem(disabled("队列溢出丢弃 \(hub.queue.dropped) 条")) }
    menu.addItem(.separator())

    if !AXIsProcessTrusted() { menu.addItem(item("授权辅助功能…", #selector(requestAX))) }
    if paused { menu.addItem(item("继续记录", #selector(resume))) }
    else {
      menu.addItem(item("暂停 1 小时", #selector(pauseHour)))
      menu.addItem(item("暂停到明天", #selector(pauseTomorrow)))
    }
    menu.addItem(item("打开 History", #selector(openHistory)))
    menu.addItem(.separator())

    let o = item("读不到文字时用 OCR", #selector(toggleOCR))
    o.state = ocrEnabled ? .on : .off
    menu.addItem(o)
    if ocrEnabled && !ocr.granted { menu.addItem(disabled("OCR 需要录屏权限")) }
    if plugins.available {
      let sub = NSMenu()
      for p in plugins.plugins { sub.addItem(disabled("\(p) · \(plugins.status()[p] ?? "等待首次运行")")) }
      sub.addItem(.separator())
      sub.addItem(item("立即运行", #selector(runPlugins)))
      let pi = NSMenuItem(title: "数据源", action: nil, keyEquivalent: ""); pi.submenu = sub
      menu.addItem(pi)
    }
    menu.addItem(.separator())
    menu.addItem(item("退出", #selector(quit)))
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
  func pause(until: Date) { pausedUntil = until; closeSegment(); updateIcon() }
  @objc func resume() { pausedUntil = nil; updateIcon() }
  @objc func toggleOCR() {
    ocrEnabled.toggle()
    if ocrEnabled && !ocr.granted { ocr.requestAccess() }
  }
  @objc func runPlugins() { plugins.runAll() }
  @objc func openHistory() {
    guard let token = config.token else { return }
    var c = URLComponents(url: config.hubURL, resolvingAgainstBaseURL: false)!
    c.path = "/"; c.fragment = "token=\(token)"
    if let u = c.url { NSWorkspace.shared.open(u) }
  }
  @objc func quit() { NSApp.terminate(nil) }

  func writeStatus() {
    captureQueue.async { [self] in
      var s: [String: Any] = stats
      s["queue"] = hub.queue.count; s["dropped"] = hub.queue.dropped
      s["sent"] = hub.sent; s["rejected"] = hub.rejected; s["hubError"] = hub.lastError ?? NSNull()
      s["axTrusted"] = AXIsProcessTrusted(); s["ocrEnabled"] = ocrEnabled; s["ocrGranted"] = ocr.granted
      s["paused"] = pausedUntil != nil; s["plugins"] = plugins.status()
      s["rssMB"] = Int(residentMB()); s["cpuSeconds"] = Int(cpuSeconds())
      s["time"] = LocalTime.iso(Date())
      if let d = try? JSONSerialization.data(withJSONObject: s, options: [.prettyPrinted, .sortedKeys]) {
        try? d.write(to: config.dataDir.appendingPathComponent("collector-status.json"), options: .atomic)
      }
    }
  }
}

func residentMB() -> Double {
  var info = mach_task_basic_info()
  var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
  let r = withUnsafeMutablePointer(to: &info) {
    $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count) }
  }
  return r == KERN_SUCCESS ? Double(info.resident_size) / 1_048_576 : 0
}

func cpuSeconds() -> Double {
  var usage = rusage()
  getrusage(RUSAGE_SELF, &usage)
  return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1e6
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
