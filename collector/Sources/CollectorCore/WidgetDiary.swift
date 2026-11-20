import Foundation

extension WidgetSnapshot {
  /// Both the day review and its live drafts exclude private originals and corrections at the hub.
  public init(diary: DayDiary?, now: Date, calendar: Calendar = .current,
              iconFor: (DayDiary.Item.App) -> String? = { _ in nil }) {
    let day = TimelineDay.key(now, calendar: calendar)
    guard let diary, diary.date == day,
          let midnight = calendar.dateInterval(of: .day, for: now)?.end else {
      self.init(day: day)
      return
    }
    let stored = diary.detail?.items
    let reviewed = stored?.allSatisfy { $0.recordIds != nil } == true ? stored : nil
    let items = (reviewed ?? []) + (diary.drafts ?? []).map(\.item)
    let segments = items.compactMap { item -> (id: String, segment: Segment)? in
      let title = item.title.trimmingCharacters(in: .whitespacesAndNewlines)
      guard let start = item.start, TimelineDay.key(start, calendar: calendar) == day, !title.isEmpty else { return nil }
      let end = min(item.end ?? start, midnight)
      let first = item.apps?.first ?? item.sources.first.map { DayDiary.Item.App(source: $0, app: nil) }
      return (item.id, Segment(
        start: start, end: TimelinePresence.hasDuration(activeSeconds: item.activeSeconds, start: start, end: end) ? end : start,
        title: title, description: item.description, source: first?.source, icon: first.flatMap(iconFor)
      ))
    }.sorted { ($0.segment.start, $0.id) > ($1.segment.start, $1.id) }
    self.init(day: day, summary: reviewed == nil ? nil : diary.summary, segments: segments.map(\.segment))
  }
}
