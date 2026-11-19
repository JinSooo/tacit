import AppKit
import CryptoKit
import OSLog
import WidgetKit
import CollectorCore

@MainActor final class WidgetSnapshotPublisher {
  private let api: HubAPI
  private let file: URL
  private let icons: URL
  private let logger = Logger(subsystem: "dev.record-anything.collector", category: "widget")
  private var timer: Timer?
  private var request: Task<Void, Never>?

  init(api: HubAPI, file: URL) {
    self.api = api
    self.file = file
    self.icons = WidgetSnapshot.iconDirectory(for: file)
    // 升级后快照内容可能没变，系统会一直沿用旧版画面；每次启动主动重绘一次。
    // 升级前就在跑的扩展进程不会被系统换掉，重绘全部报版本不符，先结束它。
    let logger = logger
    DispatchQueue.global(qos: .utility).async {
      let stopped = Self.stopStaleExtension()
      if stopped > 0 { logger.notice("Stopped \(stopped, privacy: .public) stale widget extension process") }
      WidgetCenter.shared.reloadAllTimelines()
    }
  }

  nonisolated private static func stopStaleExtension() -> Int {
    guard let plugins = Bundle.main.builtInPlugInsURL else { return 0 }
    let executable = plugins.appendingPathComponent("TacitWidget.appex/Contents/MacOS/TacitWidget")
      .resolvingSymlinksInPath().path
    var info = stat()
    guard stat(executable, &info) == 0 else { return 0 }
    let installedAt = Date(timeIntervalSince1970: TimeInterval(info.st_ctimespec.tv_sec)
      + TimeInterval(info.st_ctimespec.tv_nsec) / 1_000_000_000)
    let pids = StaleExtension.pids(among: runningProcesses(), executable: executable, installedAt: installedAt)
    for pid in pids { kill(pid, SIGTERM) }
    // 等旧进程退出再请求重绘，否则系统可能仍把这次重绘交给它。
    for _ in 0..<20 where pids.contains(where: { kill($0, 0) == 0 }) { usleep(100_000) }
    return pids.count
  }

  nonisolated private static func runningProcesses() -> [StaleExtension.Process] {
    let capacity = proc_listallpids(nil, 0)
    guard capacity > 0 else { return [] }
    var pids = [pid_t](repeating: 0, count: Int(capacity) + 32)
    let count = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
    guard count > 0 else { return [] }
    var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
    return pids.prefix(Int(count)).compactMap { pid in
      guard pid > 0, proc_pidpath(pid, &path, UInt32(path.count)) > 0 else { return nil }
      var bsd = proc_bsdinfo()
      let size = Int32(MemoryLayout<proc_bsdinfo>.size)
      guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bsd, size) == size else { return nil }
      let started = Date(timeIntervalSince1970: TimeInterval(bsd.pbi_start_tvsec) + TimeInterval(bsd.pbi_start_tvusec) / 1_000_000)
      return StaleExtension.Process(pid: pid, path: String(cString: path), started: started)
    }
  }

  func refresh(invalidate: Bool = false) {
    request?.cancel()
    timer?.invalidate()
    let now = Date()
    let calendar = Calendar.current
    let day = TimelineDay.key(now, calendar: calendar)
    let nextPoll = now.addingTimeInterval(10 * 60)
    let midnight = calendar.dateInterval(of: .day, for: now)?.end ?? nextPoll
    let timer = Timer(fire: min(nextPoll, midnight), interval: 0, repeats: false) { [weak self] _ in
      MainActor.assumeIsolated { self?.refresh() }
    }
    RunLoop.main.add(timer, forMode: .common)
    self.timer = timer

    let existing = WidgetSnapshot.readToday(from: file, now: now, calendar: calendar)
    if invalidate || existing == nil { removeSnapshot() }
    request = Task {
      do {
        let diary = try await api.diary(now)
        try Task.checkCancellation()
        guard day == TimelineDay.key(.now) else { return }
        let snapshot = WidgetSnapshot(diary: diary, now: now, calendar: calendar, iconFor: publishIcon)
        if snapshot.summary == nil && snapshot.segments.isEmpty {
          removeSnapshot()
          return
        }
        if invalidate || snapshot != existing {
          try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                  attributes: [.posixPermissions: 0o700])
          try PrivateFile.write(JSONEncoder().encode(snapshot), to: file)
          WidgetCenter.shared.reloadAllTimelines()
        }
        pruneIcons(keeping: Set(snapshot.segments.compactMap(\.icon)))
      } catch is CancellationError {
        return
      } catch {
        guard !Task.isCancelled else { return }
        removeSnapshot()
        logger.error("Unable to update widget snapshot: \((error as NSError).code, privacy: .public)")
      }
    }
  }

  func stop() {
    timer?.invalidate()
    request?.cancel()
  }

  private func removeSnapshot() {
    if remove(file) { WidgetCenter.shared.reloadAllTimelines() }
    remove(icons)
  }

  private func publishIcon(for source: DayDiary.Item.App) -> String? {
    guard let bundle = SourceApplication.bundle(app: source.app, source: source.source) else { return nil }
    let name = SHA256.hash(data: Data(bundle.utf8)).map { String(format: "%02x", $0) }.joined() + ".png"
    guard let target = WidgetSnapshot.iconURL(named: name, in: icons) else { return nil }
    let fm = FileManager.default
    if fm.fileExists(atPath: target.path) { return name }
    guard let image = AppIcons.icon(bundle), let png = Self.png(image) else { return nil }
    do {
      try fm.createDirectory(at: icons, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
      try PrivateFile.write(png, to: target)
      return name
    } catch {
      logger.error("Unable to export widget icon: \((error as NSError).code, privacy: .public)")
      return nil
    }
  }

  private static func png(_ image: NSImage) -> Data? {
    // 32pt @2x, with the original app icon's transparent padding.
    let pixels = 64
    guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
      colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
      let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return nil }
    NSGraphicsContext.saveGraphicsState()
    defer { NSGraphicsContext.restoreGraphicsState() }
    NSGraphicsContext.current = context
    context.imageInterpolation = .high
    image.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels), from: .zero, operation: .copy, fraction: 1)
    return bitmap.representation(using: .png, properties: [:])
  }

  private func pruneIcons(keeping names: Set<String>) {
    do {
      for name in try FileManager.default.contentsOfDirectory(atPath: icons.path) where !names.contains(name) {
        remove(icons.appendingPathComponent(name))
      }
    } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
      return
    } catch {
      logger.error("Unable to list widget icons: \((error as NSError).code, privacy: .public)")
    }
  }

  @discardableResult private func remove(_ url: URL) -> Bool {
    do {
      try FileManager.default.removeItem(at: url)
      return true
    } catch let error as CocoaError where error.code == .fileNoSuchFile {
      return false
    } catch {
      logger.error("Unable to remove widget file: \((error as NSError).code, privacy: .public)")
      return false
    }
  }
}
