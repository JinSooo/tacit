import SwiftUI
import CollectorCore

struct ReviewPage: View {
  @Environment(ViewerStore.self) private var store
  @State private var picking = false
  @State private var refresh = 0

  var body: some View {
    TimelineView(.everyMinute) { clock in
      let today = Calendar.current.startOfDay(for: clock.date)
      let day = Binding(get: { store.reviewDay ?? today }, set: { store.reviewDay = $0 == today ? nil : $0 })
      ScrollView {
        ReviewDayContent(day: day.wrappedValue, isToday: day.wrappedValue == today, refresh: refresh)
          .id(store.revision)
          .modifier(ReviewWidth())
      }
      .id(day.wrappedValue)
      .background(Palette.paper)
      .navigationTitle("回顾")
      .toolbar {
        DayNavigation(day: day, picking: $picking, today: today)
        ToolbarItem(placement: .primaryAction) {
          Button { refresh += 1 } label: { PhIcon("arrow-clockwise", size: PhIcon.toolbar) }
            .help("刷新").accessibilityLabel("刷新").keyboardShortcut("r", modifiers: .command)
        }
      }
    }
  }
}

private struct ReviewWidth: ViewModifier {
  func body(content: Content) -> some View {
    content.frame(maxWidth: 680, alignment: .leading)
      .padding(.horizontal, 32).padding(.vertical, 32).frame(maxWidth: .infinity, alignment: .top)
  }
}

private struct ReviewDayContent: View {
  @Environment(ViewerStore.self) private var store
  @State private var diary = Loader<DayDiary?>()
  @State private var records = Loader<[HistoryRecord]>()
  @State private var brush: ClosedRange<Date>?
  @State private var lane: Lane?
  let day: Date
  let isToday: Bool
  let refresh: Int

  private var review: DayDiary? { diary.value ?? nil }
  private var failed: Bool { review?.failed?.value == true }
  private var items: [DayDiary.Item] { review?.detail?.items ?? [] }

  var body: some View {
    VStack(alignment: .leading, spacing: 24) {
      VStack(alignment: .leading, spacing: 8) {
        Text("\(Fmt.date(day)) \(ViewerFormat.weekday(day))")
          .font(.system(size: TextSize.caption)).foregroundStyle(Palette.muted)
        headline
      }
      let rows = ReviewActivity.visibleRecords(records.value ?? [], sources: store.capture.sources)
      let chapters = DayStrata.chapters(from: review, on: day)
      if !rows.isEmpty || !chapters.isEmpty {
        DayStrata(records: rows, chapters: chapters, day: day, selected: nil, brush: $brush, lane: $lane) { record in
          store.showRecord(record.id, at: record.start)
        }
        .zIndex(1)
      }
      if !items.isEmpty {
        VStack(spacing: 0) {
          ForEach(items) { item in
            Rectangle().fill(Palette.hairline).frame(height: 1).accessibilityHidden(true)
            Button { store.path.append(.reviewItem(day, item.id)) } label: {
              HStack(alignment: .firstTextBaseline, spacing: 16) {
                Text(ReviewTime.range(item, on: day))
                  .font(.system(size: TextSize.caption)).monospacedDigit().foregroundStyle(Palette.muted)
                  .frame(width: 84, alignment: .leading)
                VStack(alignment: .leading, spacing: 4) {
                  Text(item.title).font(.system(size: TextSize.title, weight: .semibold)).foregroundStyle(Palette.ink)
                  Text(item.description).font(.system(size: TextSize.body)).lineSpacing(TextSize.lineSpacing(TextSize.body))
                    .foregroundStyle(Palette.ink)
                  ReviewMetadata(item: item)
                }
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                PhIcon("caret-right", size: 12).foregroundStyle(Palette.muted).accessibilityHidden(true)
              }
              .padding(.vertical, 12).contentShape(Rectangle())
            }
            .buttonStyle(ReviewRowStyle())
          }
        }
      }
      if review?.detail?.items != nil, let at = review?.detail?.cutoff.flatMap(ViewerTime.parse) {
        let pending = review?.needsRegen?.value == true || rows.contains { $0.sensitivity != "private" && ($0.end ?? $0.start) > at }
        let suffix = failed ? "，最近一次整理失败" : pending ? "，有新活动待整理" : ""
        Text("内容截至 \(ReviewTime.clock(at, on: day))\(suffix)")
          .font(.system(size: TextSize.caption)).monospacedDigit().foregroundStyle(failed ? Palette.attention : Palette.muted)
      }
    }
    .task(id: refresh) {
      repeat {
        await load()
        if !isToday { break }
        try? await Task.sleep(for: .seconds(60))
      } while !Task.isCancelled
    }
    .onChange(of: store.capture.sources.filter(\.enabled).map(\.id)) { lane = nil }
  }

  @ViewBuilder private var headline: some View {
    if let summary = review?.summary {
      ReviewHeadline(text: summary, size: TextSize.display)
        .foregroundStyle(Palette.ink).lineSpacing(TextSize.serifLineSpacing(TextSize.display))
        .fixedSize(horizontal: false, vertical: true).textSelection(.enabled).accessibilityAddTraits(.isHeader)
    } else if let error = diary.error ?? records.error {
      Placeholder(kind: .error(error) { Task { await load() } })
    } else if failed && review?.detail?.items == nil {
      status("最近一次整理失败", color: Palette.attention)
    } else if diary.value == nil || records.value == nil {
      ProgressView().controlSize(.small).accessibilityLabel("正在读取回顾")
    } else if records.value?.isEmpty == true && review?.detail?.timeline?.isEmpty != false {
      status("这一天没有记录")
    } else if review?.detail?.items != nil {
      status("这一天没有形成事项")
    } else if !isToday && review?.needsRegen?.value != true {
      status("这一天的回顾待整理")
    } else {
      status("正在整理")
    }
  }

  private func status(_ text: String, color: Color = Palette.muted) -> some View {
    Text(text).font(.serif(TextSize.display)).foregroundStyle(color).accessibilityAddTraits(.isHeader)
  }

  private func load() async {
    async let review: Void = diary.run { try await store.api.diary(day) }
    async let activity: Void = records.run { try await store.api.day(day) }
    _ = await (review, activity)
  }
}

struct ReviewHeadline: View {
  let text: String
  let size: CGFloat

  var body: some View {
    let value = text.reduce(into: AttributedString()) { result, character in
      var part = AttributedString(String(character))
      part.font = character.isASCII ? .system(size: size, weight: .medium) : .serif(size)
      result.append(part)
    }
    Text(value)
  }
}

private enum ReviewTime {
  static func clock(_ date: Date, on day: Date) -> String {
    date == ViewerTime.dayBounds(day).end ? "24:00" : ViewerFormat.clock(date)
  }
  static func range(_ item: DayDiary.Item, on day: Date) -> String {
    guard let a = ViewerTime.parse(item.tStart), let b = ViewerTime.parse(item.tEnd) else { return "" }
    let start = clock(a, on: day), end = clock(b, on: day)
    return start == end ? start : "\(start)–\(end)"
  }
}

private struct ReviewMetadata: View {
  let item: DayDiary.Item
  var body: some View {
    Text(([Fmt.duration(item.activeSeconds)] + item.sources.map(SourceInfo.name)).joined(separator: "，"))
      .font(.system(size: TextSize.caption)).foregroundStyle(Palette.muted)
  }
}

private struct ReviewRowStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label.background(configuration.isPressed ? Palette.fill : Color.clear)
  }
}

struct ReviewItemPage: View {
  @Environment(ViewerStore.self) private var store
  @State private var item = Loader<DayDiary.Item?>()
  let day: Date
  let id: String

  var body: some View {
    ScrollView {
      Group {
        if let current = item.value ?? nil {
          VStack(alignment: .leading, spacing: 16) {
            Text("\(Fmt.date(day))，\(ReviewTime.range(current, on: day))")
              .font(.system(size: TextSize.caption)).monospacedDigit().foregroundStyle(Palette.muted)
            Text(current.title).font(.system(size: TextSize.title, weight: .semibold)).foregroundStyle(Palette.ink)
              .accessibilityAddTraits(.isHeader)
            Text(current.description).font(.system(size: TextSize.body)).foregroundStyle(Palette.ink).textSelection(.enabled)
            ReviewMetadata(item: current)
            Text("经过与依据").font(.system(size: TextSize.body, weight: .semibold)).foregroundStyle(Palette.ink)
              .padding(.top, 8).accessibilityAddTraits(.isHeader)
            VStack(alignment: .leading, spacing: 0) {
              ForEach(current.evidence) { ref in
                Rectangle().fill(Palette.hairline).frame(height: 1).accessibilityHidden(true)
                Button { store.path.append(.reviewRecord(ref.id)) } label: {
                  HStack(alignment: .firstTextBaseline, spacing: 12) {
                    if let at = ViewerTime.parse(ref.at) {
                      let label = Calendar.current.isDate(at, inSameDayAs: day) ? ViewerFormat.clock(at) : Fmt.stamp(ref.at) ?? ""
                      Text(label).font(.system(size: TextSize.caption)).monospacedDigit().foregroundStyle(Palette.muted)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                      Text(ref.title).font(.system(size: TextSize.body)).foregroundStyle(Palette.ink)
                      Text(SourceInfo.name(ref.source)).font(.system(size: TextSize.caption)).foregroundStyle(Palette.muted)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    PhIcon("caret-right", size: 12).foregroundStyle(Palette.muted).accessibilityHidden(true)
                  }
                  .padding(.vertical, 12).contentShape(Rectangle())
                }
                .buttonStyle(ReviewRowStyle())
              }
            }
          }
        } else if let error = item.error {
          Placeholder(kind: .error(error) { Task { await load() } })
        } else if item.value == nil {
          Placeholder(kind: .loading)
        } else {
          Placeholder(kind: .empty("clock-counter-clockwise", "这件事已更新，可返回查看当天回顾"))
        }
      }
      .modifier(ReviewWidth())
    }
    .background(Palette.paper)
    .navigationTitle("回顾")
    .toolbar { BackButton() }
    .task(id: store.revision) { await load() }
  }

  private func load() async {
    item.value = nil
    await item.run { try await store.api.diary(day)?.detail?.items?.first { $0.id == id } }
  }
}
