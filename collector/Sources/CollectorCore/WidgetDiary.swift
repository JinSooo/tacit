import Foundation

extension WidgetSnapshot {
  /// The diary endpoint projects the day review, whose input excludes private originals and corrections.
  public init(diary: DayDiary?, now: Date, calendar: Calendar = .current) {
    let day = TimelineDay.key(now, calendar: calendar)
    guard let diary, diary.date == day,
          let items = diary.detail?.items, items.allSatisfy({ $0.recordIds != nil }) else {
      self.init(day: day)
      return
    }
    let segments = items.compactMap { item -> (start: Date, id: String, title: String)? in
      let title = item.title.trimmingCharacters(in: .whitespacesAndNewlines)
      guard let start = item.start, TimelineDay.key(start, calendar: calendar) == day, !title.isEmpty else { return nil }
      return (start, item.id, title)
    }.sorted { ($0.start, $0.id) > ($1.start, $1.id) }
    self.init(day: day, summary: diary.summary, segments: segments.prefix(3).map { Segment(start: $0.start, title: $0.title) })
  }
}
