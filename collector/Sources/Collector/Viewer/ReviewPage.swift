import SwiftUI
import CollectorCore

struct ReviewPage: View {
  @Environment(ViewerStore.self) private var store
  @State private var refresh = 0

  var body: some View {
    TimelineView(.everyMinute) { clock in
      let today = Calendar.current.startOfDay(for: clock.date)
      let day = Binding(get: { store.reviewDay ?? today }, set: {
        store.reviewDay = $0 == today ? nil : $0
        store.timelineFocus = nil
      })
      ReviewDayContent(day: day, today: today, now: clock.date, refresh: refresh)
        .id(day.wrappedValue)
    }
    .background(Palette.paper)
    .navigationTitle("")
    .modifier(QuietPageTitle())
    .toolbar {
      ToolbarItem(placement: .primaryAction) {
        Button { refresh += 1 } label: { PhIcon("arrow-clockwise", size: PhIcon.toolbar) }
          .help("刷新").accessibilityLabel("刷新").keyboardShortcut("r", modifiers: .command)
      }
    }
  }
}

struct ReviewWidth: ViewModifier {
  var maxWidth: CGFloat = 680

  func body(content: Content) -> some View {
    content.frame(maxWidth: maxWidth, alignment: .leading)
      .padding(.horizontal, 32).padding(.vertical, 28).frame(maxWidth: .infinity, alignment: .top)
  }
}

enum TimelineDay {
  static func key(_ day: Date) -> String {
    let c = Calendar.current.dateComponents([.year, .month, .day], from: day)
    return String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
  }

  static func date(_ key: String) -> Date? {
    let values = key.split(separator: "-").compactMap { Int($0) }
    guard values.count == 3 else { return nil }
    return Calendar.current.date(from: DateComponents(year: values[0], month: values[1], day: values[2]))
  }
}

private struct ReviewDayContent: View {
  @Environment(ViewerStore.self) private var store
  @AppStorage(TimelineDensity.preferenceKey) private var density = TimelineDensity.compact
  @State private var diary = Loader<DayDiary?>()
  @State private var records = Loader<[HistoryRecord]>()
  @State private var loadedRevision: Int?
  @State private var brush: ClosedRange<Date>?
  @State private var expanded: String?
  @State private var picking = false
  @State private var setup: (health: DistillHealth, tools: [AgentToolState])?
  @Binding var day: Date
  let today: Date
  let now: Date
  let refresh: Int

  private struct LoadKey: Equatable {
    let refresh: Int
    let revision: Int
  }

  private var showsSetup: Bool {
    TimelineSetup.shouldShow(
      permissionsReady: !store.capture.sources.contains { DataSourceCatalog.isVisible($0.id) && $0.needsPermission },
      modelReady: setup.map { $0.health.state == .working },
      agentReady: setup.map { $0.tools.contains(where: \.connected) })
  }
  private var current: Bool { loadedRevision == store.revision }
  private var review: DayDiary? { current ? diary.value ?? nil : nil }
  private var failed: Bool { review?.failed?.value == true }
  private var isToday: Bool { day == today }
  private var hasSegments: Bool { review?.detail?.items?.allSatisfy { $0.recordIds != nil } == true }
  private var visibleRecords: [HistoryRecord] {
    ReviewActivity.visibleRecords(records.value ?? [], sources: store.capture.sources)
  }
  private var items: [DayDiary.Item] {
    guard hasSegments else { return [] }
    return (review?.detail?.items ?? []).sorted { ($0.tStart, $0.id) > ($1.tStart, $1.id) }
  }

  var body: some View {
    ScrollViewReader { proxy in
      ScrollView {
        VStack(alignment: .leading, spacing: 14) {
          VStack(alignment: .leading, spacing: 12) {
            dateLine
            headline
          }
          .padding(.leading, TimelineReadingLayout.contentInset)
          if density == .detailed && !items.isEmpty {
            DayStrata(records: visibleRecords, segments: items, day: day, now: isToday ? now : nil, selected: expanded, brush: $brush) { id in
              open(id, in: proxy)
            }
            .padding(.leading, TimelineReadingLayout.contentInset - 6)
            .zIndex(1)
          }
          if showsSetup || !store.pending.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
              if showsSetup, let setup { SetupChecklist(health: setup.health, tools: setup.tools) }
              if !store.pending.isEmpty { TimelinePendingLine() }
            }
          }
          LazyVStack(spacing: 0) {
            let showsProjects = TimelineProjectLabels.showsNames(in: items)
            ForEach(items.filter { item in density == .compact || (brush.map { item.intersects($0) } ?? true) }) { item in
              TimelineSegmentRow(day: day, item: item, records: records.value,
                                 projectName: showsProjects ? store.project(item.projectId)?.name : nil,
                                 density: density, expanded: expanded == item.id) {
                expanded = expanded == item.id ? nil : item.id
              }
              .id(item.id)
            }
          }
          footer.padding(.leading, TimelineReadingLayout.contentInset)
        }
        .modifier(ReviewWidth(maxWidth: 680 + TimelineReadingLayout.contentInset))
      }
      .task(id: LoadKey(refresh: refresh, revision: store.revision)) {
        repeat {
          await load()
          reveal(proxy)
          if !isToday { break }
          try? await Task.sleep(for: .seconds(60))
        } while !Task.isCancelled
      }
      .onChange(of: store.timelineFocus) { reveal(proxy) }
      .onChange(of: density) { brush = nil }
    }
  }

  private var dateLine: some View {
    HStack(alignment: .firstTextBaseline, spacing: 16) {
      Button { picking = true } label: {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
          Text(Fmt.date(day)).font(.serif(TextSize.display)).foregroundStyle(Palette.ink)
          Text(ViewerFormat.weekday(day)).font(.system(size: TextSize.body)).foregroundStyle(Palette.muted)
        }
        .padding(.vertical, 4).contentShape(Rectangle())
      }
      .buttonStyle(.plain).help("跳到日期").popover(isPresented: $picking) {
        DatePicker("选择日期", selection: Binding(get: { day }, set: {
          day = Calendar.current.startOfDay(for: $0)
          picking = false
        }), in: ...now, displayedComponents: .date)
          .datePickerStyle(.graphical).labelsHidden().padding(12)
          .environment(\.locale, Locale(identifier: "zh_CN")).environment(\.calendar, ViewerCalendar.chinese)
      }
      Spacer()
      HStack(spacing: 0) {
        Button { shift(-1) } label: { PhIcon("caret-left", size: 14) }
          .help("前一天").accessibilityLabel("前一天").keyboardShortcut("[", modifiers: .command)
        Button("今天") { day = today }.disabled(isToday).keyboardShortcut("t", modifiers: .command)
        Button { shift(1) } label: { PhIcon("caret-right", size: 14) }
          .help("后一天").accessibilityLabel("后一天").keyboardShortcut("]", modifiers: .command).disabled(isToday)
      }
      .buttonStyle(ReviewDateButtonStyle())
      .font(.system(size: TextSize.body)).fixedSize()
      HStack(spacing: 2) {
        densityButton(.compact, title: "简约", icon: "list-bullets")
        densityButton(.detailed, title: "详细", icon: "clipboard-text")
      }
      .padding(2)
      .background(Palette.fill, in: RoundedRectangle(cornerRadius: Radius.control))
      .fixedSize()
    }
  }

  private func densityButton(_ mode: TimelineDensity, title: String, icon: String) -> some View {
    let selected = density == mode
    return Button { density = mode } label: {
      PhIcon(icon, size: 16)
        .frame(width: 28, height: 24)
        .foregroundStyle(selected ? Palette.accent : Palette.muted)
        .background(selected ? Palette.accent.opacity(0.13) : .clear,
                    in: RoundedRectangle(cornerRadius: Radius.control - 2))
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .help(title).accessibilityLabel(title)
    .accessibilityAddTraits(selected ? .isSelected : [])
  }

  private func shift(_ delta: Int) {
    guard let next = Calendar.current.date(byAdding: .day, value: delta, to: day), next <= today else { return }
    day = next
  }

  @ViewBuilder private var headline: some View {
    if hasSegments, let summary = review?.summary {
      ReviewHeadline(text: summary, size: TextSize.title)
        .foregroundStyle(Palette.ink).lineSpacing(TextSize.serifLineSpacing(TextSize.title))
        .fixedSize(horizontal: false, vertical: true).textSelection(.enabled).accessibilityAddTraits(.isHeader)
    } else if current, let error = diary.error ?? records.error {
      Placeholder(kind: .error(error) { Task { await load() } })
    } else if failed && !hasSegments {
      status("最近一次整理失败", color: Palette.attention)
    } else if !current || diary.value == nil || records.value == nil {
      ProgressView().controlSize(.small).accessibilityLabel("正在读取时间线")
    } else if records.value?.isEmpty == true && review?.detail == nil {
      status("这一天没有记录")
    } else if hasSegments && !items.isEmpty {
      status("这一天的活动")
    } else if hasSegments {
      status("这一天的记录还没有可展示的整理结果")
    } else if review?.detail != nil {
      status("这一天有原始记录")
    } else if !isToday && review?.needsRegen?.value != true {
      status("这一天还没有时间线")
    } else {
      status("正在整理")
    }
  }

  private var footer: some View {
    HStack(alignment: .firstTextBaseline, spacing: 16) {
      if hasSegments, let at = review?.detail?.cutoff.flatMap(ViewerTime.parse) {
        let pending = review?.needsRegen?.value == true || visibleRecords.contains {
          $0.sensitivity != "private" && ($0.end ?? $0.start) > at
        }
        let suffix = failed ? "，最近一次整理失败" : pending ? "，有新活动待整理" : ""
        Text("内容截至 \(ReviewTime.clock(at, on: day))\(suffix)")
          .monospacedDigit().foregroundStyle(failed ? Palette.attention : Palette.muted)
      }
      Spacer(minLength: 0)
      Button("这一天的全部记录") { store.showDayRecords(day) }.buttonStyle(.accentLink)
    }
    .font(.system(size: TextSize.caption))
  }

  private func status(_ text: String, color: Color = Palette.muted) -> some View {
    Text(text).font(.serif(TextSize.title)).foregroundStyle(color).accessibilityAddTraits(.isHeader)
  }

  private func reveal(_ proxy: ScrollViewProxy) {
    guard current, let target = store.timelineFocus, diary.value != nil, diary.error == nil else { return }
    store.timelineFocus = nil
    if items.contains(where: { $0.id == target.segment }) {
      open(target.segment, in: proxy)
    } else if let record = target.record {
      store.showDayRecords(day, record: record)
    }
  }

  private func open(_ id: String, in proxy: ScrollViewProxy) {
    brush = nil
    expanded = id
    Task { @MainActor in
      await Task.yield()
      proxy.scrollTo(id, anchor: .top)
    }
  }

  private func loadSetup() async {
    do {
      async let health = store.api.distillHealth()
      async let tools = store.api.agentTools()
      let value = try await (health, tools)
      try Task.checkCancellation()
      setup = value
    } catch { setup = nil }
  }

  private func load() async {
    let revision = store.revision
    if !current {
      diary.value = nil
      records.value = nil
    }
    async let review: Void = diary.run {
      let value = try await store.api.diary(day)
      try Task.checkCancellation()
      return value
    }
    async let activity: Void = records.run {
      let value = try await store.api.day(day)
      try Task.checkCancellation()
      return value
    }
    async let readiness: Void = loadSetup()
    _ = await (review, activity, readiness)
    if !Task.isCancelled, revision == store.revision { loadedRevision = revision }
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

private struct ReviewDateButtonStyle: ButtonStyle {
  @Environment(\.isEnabled) private var enabled
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .frame(minWidth: 40, minHeight: 40)
      .foregroundStyle(Palette.muted).opacity(enabled ? 1 : 0.45)
      .background(configuration.isPressed ? Palette.fill : Color.clear, in: RoundedRectangle(cornerRadius: Radius.control))
  }
}

enum ReviewTime {
  static func clock(_ date: Date, on day: Date) -> String {
    date == ViewerTime.dayBounds(day).end ? "24:00" : ViewerFormat.clock(date)
  }
  static func range(_ item: DayDiary.Item, on day: Date) -> String {
    guard let a = ViewerTime.parse(item.tStart), let b = ViewerTime.parse(item.tEnd) else { return "" }
    guard TimelinePresence.hasDuration(activeSeconds: item.activeSeconds, start: a, end: b) else { return clock(a, on: day) }
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
