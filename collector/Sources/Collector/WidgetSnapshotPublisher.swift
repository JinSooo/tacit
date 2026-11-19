import Foundation
import OSLog
import WidgetKit
import CollectorCore

@MainActor final class WidgetSnapshotPublisher {
  private let api: HubAPI
  private let file: URL
  private let logger = Logger(subsystem: "dev.record-anything.collector", category: "widget")
  private var timer: Timer?
  private var request: Task<Void, Never>?

  init(api: HubAPI, file: URL) {
    self.api = api
    self.file = file
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
        let snapshot = WidgetSnapshot(diary: diary, now: now, calendar: calendar)
        guard invalidate || snapshot != existing else { return }
        if snapshot.summary == nil && snapshot.segments.isEmpty {
          removeSnapshot()
          return
        }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try PrivateFile.write(JSONEncoder().encode(snapshot), to: file)
        WidgetCenter.shared.reloadAllTimelines()
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
    do {
      try FileManager.default.removeItem(at: file)
      WidgetCenter.shared.reloadAllTimelines()
    } catch let error as CocoaError where error.code == .fileNoSuchFile {
      return
    } catch {
      logger.error("Unable to remove widget snapshot: \((error as NSError).code, privacy: .public)")
    }
  }
}
