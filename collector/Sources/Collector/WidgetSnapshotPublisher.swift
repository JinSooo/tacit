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
