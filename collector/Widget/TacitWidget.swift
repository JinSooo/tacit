import SwiftUI
import WidgetKit

private var widgetLanguage: AppLanguage {
  WidgetSnapshot.fileURL.flatMap(WidgetSnapshot.readLanguage(for:)) ?? .system()
}

private struct DayEntry: TimelineEntry {
  let date: Date
  let snapshot: WidgetSnapshot

  init(date: Date, snapshot: WidgetSnapshot? = nil) {
    self.date = date
    self.snapshot = snapshot ?? WidgetSnapshot(day: TimelineDay.key(date), language: widgetLanguage)
  }
}

private struct DayProvider: TimelineProvider {
  func placeholder(in context: Context) -> DayEntry {
    let now = Calendar.current.date(bySettingHour: 16, minute: 45, second: 0, of: .now) ?? .now
    let language = widgetLanguage
    func text(_ zh: String, _ en: String) -> String { L10n.text(zh: zh, en: en, lang: language) }
    let sample = WidgetSnapshot(day: TimelineDay.key(now),
      summary: text("你确认了温室的补光时间，并整理了下一批种苗的移栽顺序。靠窗的育苗盘将先移到东侧种植区。", "You checked the greenhouse lighting schedule and planned the next round of transplanting. The trays by the window will move to the east bed first."),
      segments: [
        .init(start: now.addingTimeInterval(-900), end: now, title: text("整理种苗移栽顺序", "Planned the seedling transplant order"),
              description: text("靠窗的两盘番茄苗安排在周五移栽。", "The two tomato trays by the window are scheduled for Friday."), source: "manual.note"),
        .init(start: now.addingTimeInterval(-4200), end: now.addingTimeInterval(-2400), title: text("核对温室补光时间", "Checked the greenhouse lighting schedule"),
              description: text("确认东侧种植区每天补光四小时。", "The east bed gets four hours of supplemental light a day."), source: "mac.wechat"),
        .init(start: now.addingTimeInterval(-10800), end: now.addingTimeInterval(-9000), title: text("记录育苗盘温度", "Recorded seedling tray temperatures"),
              description: text("进风口附近的育苗盘温度下降了两度。", "The trays near the air inlet were two degrees cooler."), source: "mac.audio"),
        .init(start: now.addingTimeInterval(-14400), end: now.addingTimeInterval(-12600), title: text("对比种植灯的规格", "Compared grow lights"),
              description: text("选定可手动调整照射角度的型号。", "You picked a model with an adjustable angle."), source: "mac.browser"),
        .init(start: now.addingTimeInterval(-25200), end: now.addingTimeInterval(-21600), title: text("安排分区浇水", "Planned watering by zone"),
              description: text("把叶菜和香草分成两组浇水。", "Leafy greens and herbs will be watered separately."), source: "mac.calendar"),
      ], language: language)
    return DayEntry(date: now, snapshot: sample)
  }

  func getSnapshot(in context: Context, completion: @escaping (DayEntry) -> Void) {
    completion(context.isPreview ? placeholder(in: context) : today(at: .now))
  }

  func getTimeline(in context: Context, completion: @escaping (Timeline<DayEntry>) -> Void) {
    let now = Date()
    let midnight = Calendar.current.dateInterval(of: .day, for: now)?.end ?? now.addingTimeInterval(3600)
    let entry = today(at: now)
    var entries = [entry]
    // Advance the right edge even if the host has no new segments to publish.
    if let range = entry.snapshot.activityRange(at: now) {
      let step: TimeInterval = 30 * 60
      var next = range.upperBound.addingTimeInterval(step)
      while next < midnight {
        entries.append(DayEntry(date: next, snapshot: entry.snapshot))
        next = next.addingTimeInterval(step)
      }
    }
    // The empty entry expires yesterday's text even when the host is asleep or closed.
    entries.append(DayEntry(date: midnight))
    completion(Timeline(entries: entries, policy: .after(midnight)))
  }

  private func today(at now: Date) -> DayEntry {
    DayEntry(date: now, snapshot: WidgetSnapshot.fileURL.flatMap { WidgetSnapshot.readToday(from: $0, now: now) })
  }
}

private struct DayWidgetEntryView: View {
  @Environment(\.widgetFamily) private var family
  let entry: DayEntry

  var body: some View {
    DayWidgetView(family: family, date: entry.date, snapshot: entry.snapshot)
  }
}

@main struct TacitWidget: Widget {
  var body: some WidgetConfiguration {
    StaticConfiguration(kind: "dev.record-anything.collector.timeline", provider: DayProvider()) { entry in
      DayWidgetEntryView(entry: entry)
    }
    .configurationDisplayName(L10n.text(zh: "Tacit 时间线", en: "Tacit timeline", lang: widgetLanguage))
    .description(L10n.text(zh: "查看当天概述与最近的活动。", en: "See the day overview and recent activities.", lang: widgetLanguage))
    .supportedFamilies([.systemMedium, .systemLarge])
    .contentMarginsDisabled()
  }
}
