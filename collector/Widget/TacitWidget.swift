import SwiftUI
import WidgetKit

private struct DayEntry: TimelineEntry {
  let date: Date
  let snapshot: WidgetSnapshot

  init(date: Date, snapshot: WidgetSnapshot? = nil) {
    self.date = date
    self.snapshot = snapshot ?? WidgetSnapshot(day: TimelineDay.key(date))
  }
}

private struct DayProvider: TimelineProvider {
  func placeholder(in context: Context) -> DayEntry {
    let now = Date()
    let sample = WidgetSnapshot(day: TimelineDay.key(now),
      summary: "你确认了温室的补光时间，并整理了下一批种苗的移栽顺序。",
      segments: [
        .init(start: now, title: "整理种苗移栽顺序"),
        .init(start: now.addingTimeInterval(-1800), title: "核对温室补光时间"),
        .init(start: now.addingTimeInterval(-3600), title: "记录育苗盘温度"),
      ])
    return DayEntry(date: now, snapshot: sample)
  }

  func getSnapshot(in context: Context, completion: @escaping (DayEntry) -> Void) {
    completion(context.isPreview ? placeholder(in: context) : today(at: .now))
  }

  func getTimeline(in context: Context, completion: @escaping (Timeline<DayEntry>) -> Void) {
    let now = Date()
    let midnight = Calendar.current.dateInterval(of: .day, for: now)?.end ?? now.addingTimeInterval(3600)
    // The empty entry expires yesterday's text even when the host is asleep or closed.
    completion(Timeline(entries: [today(at: now), DayEntry(date: midnight)], policy: .after(midnight)))
  }

  private func today(at now: Date) -> DayEntry {
    DayEntry(date: now, snapshot: WidgetSnapshot.fileURL.flatMap { WidgetSnapshot.readToday(from: $0, now: now) })
  }
}

private struct DayWidgetView: View {
  let entry: DayEntry

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(entry.date.formatted(.dateTime.month(.wide).day().weekday(.wide).locale(Locale(identifier: "zh_CN"))))
        .font(.system(size: TextSize.title, weight: .semibold, design: .serif))
        .foregroundStyle(Palette.accent)
        .accessibilityAddTraits(.isHeader)
      if let summary = entry.snapshot.summary {
        Text(summary)
          .font(.system(size: TextSize.body))
          .foregroundStyle(Palette.readingBody)
          .lineLimit(2)
          .padding(.bottom, 4)
      }
      ForEach(Array(entry.snapshot.segments.enumerated()), id: \.offset) { _, segment in
        HStack(alignment: .firstTextBaseline, spacing: 8) {
          Text(segment.start, format: .dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).locale(Locale(identifier: "zh_CN")))
            .font(.system(size: TextSize.caption).monospacedDigit())
            .foregroundStyle(Palette.muted)
          Text(segment.title)
            .font(.system(size: TextSize.body))
            .foregroundStyle(Palette.ink)
            .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
      }
      if entry.snapshot.summary == nil && entry.snapshot.segments.isEmpty {
        Text("今天暂无时间线内容")
          .font(.system(size: TextSize.body))
          .foregroundStyle(Palette.muted)
      }
      Spacer(minLength: 0)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .containerBackground(Palette.paper, for: .widget)
    .widgetURL(entry.snapshot.timelineURL)
  }
}

@main struct TacitWidget: Widget {
  var body: some WidgetConfiguration {
    StaticConfiguration(kind: "dev.record-anything.collector.timeline", provider: DayProvider()) { entry in
      DayWidgetView(entry: entry)
    }
    .configurationDisplayName("Tacit 时间线")
    .description("查看当天概述与最近的活动。")
    .supportedFamilies([.systemMedium])
  }
}
