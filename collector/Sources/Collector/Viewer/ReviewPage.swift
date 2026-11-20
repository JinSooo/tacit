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
        store.historyFocus = nil
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

private struct ReviewDayContent: View {
  @Environment(ViewerStore.self) private var store
  @State private var diary = Loader<DayDiary?>()
  @State private var records = Loader<[HistoryRecord]>()
  @State private var loadedRevision: Int?
  @State private var expanded: String?
  @State private var picking = false
  @State private var setup: (health: DistillHealth, tools: [AgentToolState])?
  @State private var startupMessage: String?
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
  private var density: TimelineDensity { store.timelineDensity }
  private var current: Bool { loadedRevision == store.revision }
  private var review: DayDiary? { current ? diary.value ?? nil : nil }
  private var failed: Bool { review?.failed?.value == true }
  private var isToday: Bool { day == today }
  private var hasSegments: Bool { review?.detail?.items?.allSatisfy { $0.recordIds != nil } == true }
  private var visibleRecords: [HistoryRecord] {
    ReviewActivity.visibleRecords(records.value ?? [], sources: store.capture.sources)
  }
  private var cutoff: Date? { review?.detail?.cutoff.flatMap(ViewerTime.parse) }
  /// 今天最近一次整理之后才到的记录；以往日期整理到 24:00，没有这一截。
  private var unsorted: [HistoryRecord] {
    guard isToday, current, records.value != nil else { return [] }
    return ReviewActivity.unsorted(visibleRecords, after: cutoff)
  }
  private var showsUnsorted: Bool { hasSegments && cutoff != nil && ReviewActivity.hasSubstance(unsorted) }
  private static let unsortedID = "unsorted"
  private var items: [DayDiary.Item] {
    guard hasSegments else { return [] }
    return (review?.detail?.items ?? []).sorted { ($0.tStart, $0.id) > ($1.tStart, $1.id) }
  }

  var body: some View {
    Group {
      if density == .compact {
        compactList
      } else {
        HistoryPage(day: day, diary: review, dayRecords: current ? records.value : nil,
                    dayError: current ? records.error : nil, refresh: refresh) { stats in
          dayHeader(stats: stats)
        }
      }
    }
    .task(id: LoadKey(refresh: refresh, revision: store.revision)) {
      repeat {
        await load()
        if !isToday { break }
        if await catchUp() { continue }
        await WindowVisibility.pause(.seconds(TimelineCatchUp.isRunning(store.catchUpRequest) ? 10 : 60))
      } while !Task.isCancelled
    }
    .task(id: refresh) {
      let dataDir = Config.load().dataDir
      while !Task.isCancelled {
        let message = DiagnosticSummary.startupMessage(in: dataDir)
        let reachable = message == nil ? true : await store.api.isReachable()
        guard !Task.isCancelled else { return }
        startupMessage = reachable ? nil : message
        await WindowVisibility.pause(.seconds(5))
      }
    }
  }

  private var compactList: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 14) {
        dayHeader().padding(.horizontal, TimelineReadingLayout.edge)
        LazyVStack(spacing: 0) {
          if showsUnsorted, let cutoff {
            TimelineUnsortedRow(day: day, since: cutoff, records: unsorted,
                                running: TimelineCatchUp.isRunning(store.catchUpRequest),
                                expanded: expanded == Self.unsortedID) {
              expanded = expanded == Self.unsortedID ? nil : Self.unsortedID
            }
          }
          let showsProjects = TimelineProjectLabels.showsNames(in: items)
          ForEach(items) { item in
            TimelineSegmentRow(day: day, item: item, records: records.value,
                               projectName: showsProjects ? store.project(item.projectId)?.name : nil,
                               offersThreadStory: true,
                               expanded: expanded == item.id) {
              expanded = expanded == item.id ? nil : item.id
            }
          }
        }
        footer.padding(.horizontal, TimelineReadingLayout.edge)
      }
      .modifier(ReviewWidth(maxWidth: TimelineReadingLayout.width))
    }
  }

  private func dayHeader(stats: HistoryDayStats? = nil) -> some View {
    VStack(alignment: .leading, spacing: 12) {
      dateLine
      if let stats {
        stats.frame(maxWidth: .infinity, alignment: .trailing)
      }
      if startupMessage == nil || hasSegments { headline }
      if let startupMessage {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
          Text(startupMessage).foregroundStyle(Palette.attention)
            .fixedSize(horizontal: false, vertical: true)
          Spacer(minLength: 0)
          OpenLogsButton().buttonStyle(.accentLink).fixedSize()
        }
        .font(.system(size: TextSize.body))
      } else {
        if showsSetup, let setup { SetupChecklist(health: setup.health, tools: setup.tools) }
        if !store.pending.isEmpty { TimelinePendingLine() }
      }
    }
  }

  private var dateLine: some View {
    ViewThatFits(in: .horizontal) {
      HStack(alignment: .firstTextBaseline, spacing: 16) {
        dateTitle.fixedSize()
        Spacer(minLength: 0)
        dateControls
      }
      VStack(alignment: .leading, spacing: 4) {
        dateTitle
        dateControls.frame(maxWidth: .infinity, alignment: .trailing)
      }
    }
  }

  private var dateTitle: some View {
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
  }

  private var dateControls: some View {
    HStack(spacing: 16) {
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
        densityButton(.compact, title: "简约")
        densityButton(.detailed, title: "详细")
      }
      .padding(2)
      .background(Palette.fill, in: RoundedRectangle(cornerRadius: Radius.control))
      .fixedSize()
    }
  }

  /// 两个图标都表达不准“简约 / 详细”，直接用字。
  private func densityButton(_ mode: TimelineDensity, title: String) -> some View {
    let selected = density == mode
    return Button {
      guard density != mode else { return }
      store.historyFocus = nil
      store.timelineDensity = mode
    } label: {
      Text(title).font(.system(size: TextSize.caption))
        .padding(.horizontal, 8).frame(height: 24)
        .foregroundStyle(selected ? Palette.accent : Palette.muted)
        .background(selected ? Palette.accent.opacity(0.13) : .clear,
                    in: RoundedRectangle(cornerRadius: Radius.control - 2))
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
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
    } else if density == .compact {
      compactStatus
    }
  }

  @ViewBuilder private var compactStatus: some View {
    if current, let error = diary.error ?? records.error {
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
      if hasSegments, let at = cutoff {
        // 还没整理的部分在列表最上面单独一行，这里只说截至时间和失败。
        Text("内容截至 \(ReviewTime.clock(at, on: day))\(failed ? "，最近一次整理失败" : "")")
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

  private func loadSetup() async {
    do {
      async let health = store.api.distillHealth()
      async let tools = store.api.agentTools()
      let value = try await (health, tools)
      try Task.checkCancellation()
      setup = value
    } catch { setup = nil }
  }

  /// 打开今天的时间线时按需补整理（规则见 TimelineCatchUp）。返回 true 表示补整理刚结束，需要马上重新读取。
  private func catchUp() async -> Bool {
    guard current, diary.error == nil, records.value != nil else { return false }
    if let request = store.catchUpRequest {
      guard let list = try? await store.api.distillRequests() else { return false }
      let latest = list.first { $0.id == request.id }
      store.catchUpRequest = latest
      if TimelineCatchUp.isRunning(latest) { return false }
      store.catchUpRequest = nil
      return true
    }
    let now = Date()
    guard TimelineCatchUp.shouldRequest(unsorted: unsorted, cutoff: cutoff,
                                        lastRequest: store.catchUpRequestedAt, now: now) else { return false }
    store.catchUpRequestedAt = now
    let date = TimelineDay.key(day)
    if let info = try? await store.api.requestDistill(kind: "regen_days", range: DistillDateRange(from: date, to: date)),
       TimelineCatchUp.isRunning(info) {
      store.catchUpRequest = info
    }
    return false
  }

  private func load() async {
    let revision = store.revision
    if !current {
      diary.value = nil
      diary.error = nil
      records.value = nil
      records.error = nil
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
