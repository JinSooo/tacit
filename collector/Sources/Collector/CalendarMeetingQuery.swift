import EventKit
import CollectorCore

/// 只在 AudioCoordinator 的串行处理队列使用，不申请权限，也不读取日程正文。
final class CalendarMeetingQuery {
  private lazy var store = EKEventStore()

  func meetingApps(_ apps: [String], start: Date, end: Date) -> [String] {
    guard EKEventStore.authorizationStatus(for: .event) == .fullAccess, end > start else { return apps }
    let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
    // EventKit 的同步查询没有抛错接口；查询失败时返回空结果，按无日程处理。
    let events = store.events(matching: predicate).compactMap { event -> CalendarEventSnapshot? in
      guard let start = event.startDate, let end = event.endDate else { return nil }
      return CalendarEventSnapshot(externalIdentifier: "", start: start, end: end, title: "", calendar: "",
        allDay: event.isAllDay,
        declined: (event.attendees ?? []).contains { $0.isCurrentUser && $0.participantStatus == .declined },
        canceled: event.status == .canceled)
    }
    // 查询期间权限可能被撤回，不让旧结果触发例外。
    return CalendarMeetingPolicy.meetingApps(apps, events: events, start: start, end: end,
      authorized: EKEventStore.authorizationStatus(for: .event) == .fullAccess)
  }
}
