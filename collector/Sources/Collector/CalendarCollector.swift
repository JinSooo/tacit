import AppKit
import EventKit
import CollectorCore

/// 与文件来源一样，只由采集端持有权限；音频例外由独立的只读查询器处理。
final class CalendarCollector {
  private let store = EKEventStore()
  private let device: String
  private let isPaused: () -> Bool
  private let send: ([Record]) -> Void
  private var buffer = CalendarRecordBuffer()
  private var requesting = false
  private(set) var last: Date?

  init(device: String, isPaused: @escaping () -> Bool, send: @escaping ([Record]) -> Void) {
    self.device = device; self.isPaused = isPaused; self.send = send
  }

  var authorized: Bool { EKEventStore.authorizationStatus(for: .event) == .fullAccess }

  func start() {
    if EKEventStore.authorizationStatus(for: .event) == .notDetermined { requestAccess() }
    else { poll() }
  }

  func requestAccess() {
    let status = EKEventStore.authorizationStatus(for: .event)
    guard !requesting else { return }
    if status == .notDetermined || status == .writeOnly {
      requesting = true
      store.requestFullAccessToEvents { [weak self] _, _ in
        DispatchQueue.main.async { self?.requesting = false; self?.poll() }
      }
    } else if authorized { poll() }
    else if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") {
      NSWorkspace.shared.open(url)
    }
  }

  func poll() {
    guard !isPaused(), authorized else { return }
    let now = Date()
    let predicate = store.predicateForEvents(withStart: now.addingTimeInterval(-36 * 3600), end: now, calendars: nil)
    let snapshots = store.events(matching: predicate).map { event in
      CalendarEventSnapshot(externalIdentifier: event.calendarItemExternalIdentifier ?? "",
        start: event.startDate, end: event.endDate, title: event.title ?? "（无标题）",
        calendar: event.calendar.title, organizer: event.organizer?.name, location: event.location,
        attendees: (event.attendees ?? []).compactMap(\.name), notes: event.notes, allDay: event.isAllDay,
        declined: (event.attendees ?? []).contains { $0.isCurrentUser && $0.participantStatus == .declined },
        canceled: event.status == .canceled)
    }
    // EventKit 可能同步耗时，发送前再次检查暂停。
    guard !isPaused() else { return }
    send(buffer.records(snapshots, now: now, device: device))
    last = now
  }
}
