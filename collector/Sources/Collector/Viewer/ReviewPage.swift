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
      ReviewDayContent(selectedDay: day, today: today, now: clock.date, refresh: refresh)
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
  @State private var diary = Loader<DayDiary?>(animated: true)
  @State private var records = Loader<[HistoryRecord]>(animated: true)
  @State private var loadedRevision: Int?
  @State private var expanded: String?
  @State private var picking = false
  @Namespace private var densityPill
  @State private var setup: (health: DistillHealth, tools: [AgentToolState])?
  @State private var startupMessage: String?
  @State private var securityEvents = TimelineSecurityEventState()
  /// 日期栏上选中的那天；切过去后先把那天读好，再整块滑进来，期间仍显示正在看的这一天。
  @Binding var selectedDay: Date
  /// 正在显示的那一天（内容、草稿、页脚都按它）。
  @State private var day: Date
  /// 新的一天从哪边进来：往前翻从左，往后翻从右。
  @State private var dayEdge: HorizontalEdge = .trailing
  /// 换天读得慢时把旧的一天压淡，表示正在换。
  @State private var stale = false
  @State private var staleTimer: Task<Void, Never>?
  let today: Date
  let now: Date
  let refresh: Int

  init(selectedDay: Binding<Date>, today: Date, now: Date, refresh: Int) {
    _selectedDay = selectedDay
    _day = State(initialValue: selectedDay.wrappedValue)
    self.today = today
    self.now = now
    self.refresh = refresh
  }

  private struct LoadKey: Equatable {
    let day: Date
    let refresh: Int
    let revision: Int
    let density: TimelineDensity
  }

  private var showsSetup: Bool {
    TimelineSetup.shouldShow(
      permissionsReady: !store.capture.sources.contains { DataSourceCatalog.isVisible($0.id) && $0.needsPermission },
      modelReady: setup.map { $0.health.state == .working },
      agentReady: setup.map { $0.tools.contains(where: \.connected) })
  }
  private var density: TimelineDensity { store.timelineDensity }
  private var current: Bool { loadedRevision == store.revision }
  /// 重新读取时继续显示上一版，新内容到了再原位换上，不先清空闪一下。
  private var review: DayDiary? { diary.value ?? nil }
  private var failed: Bool { review?.failed?.value == true }
  private var isToday: Bool { day == today }
  private var hasSegments: Bool { review?.detail?.items?.allSatisfy { $0.recordIds != nil } == true }
  private var cutoff: Date? { review?.detail?.cutoff.flatMap(ViewerTime.parse) }
  private var drafts: [DayDiary.Item] {
    guard isToday else { return [] }
    return (review?.drafts ?? []).reversed().map(\.item)
  }
  private var items: [DayDiary.Item] {
    guard hasSegments else { return [] }
    return (review?.detail?.items ?? []).sorted { ($0.tStart, $0.id) > ($1.tStart, $1.id) }
  }

  var body: some View {
    Group {
      if density == .compact {
        compactList
      } else {
        HistoryPage(day: day, diary: current ? review : nil, dayRecords: current ? records.value : nil,
                    dayError: current ? records.error : nil, refresh: refresh) { stats in
          dayHeader(stats: stats)
        }
        .id(day)
      }
    }
    // 页首的提示行进出时，下面的时间线一起顺滑让位，不整块跳（挂在整页上，下面的列表也在同一次动画里）。
    .animation(Motion.standard, value: securityEvents.events.first?.id)
    .animation(Motion.standard, value: securityEvents.error)
    .animation(Motion.standard, value: showsSetup && setup != nil)
    .animation(Motion.standard, value: store.pending.isEmpty)
    .animation(Motion.standard, value: startupMessage)
    .onChange(of: selectedDay) { old, new in dayEdge = new < old ? .leading : .trailing }
    .task(id: LoadKey(day: selectedDay, refresh: refresh, revision: store.revision, density: density)) {
      repeat {
        await load()
        if selectedDay != today || day != today { break }
        if await catchUp() { continue }
        await WindowVisibility.pause(.seconds(TimelineCatchUp.isRunning(store.catchUpRequest) ? 10 : 30))
      } while !Task.isCancelled
    }
    .task(id: refresh) {
      while !Task.isCancelled {
        await securityEvents.refresh(using: store.api)
        await WindowVisibility.pause(.seconds(15))
      }
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
        // 一天最多 30 段加今天的草稿，普通 VStack 就够；惰性列表在展开时会先估高再修正，下面的段会跳两下。
        VStack(spacing: 0) {
          let drafts = self.drafts
          let items = self.items
          let showsProjects = TimelineProjectLabels.showsNames(in: drafts + items)
          // 草稿和整理好的段放在同一个列表里：草稿整理好后编号不变，这一行原位换成正式的样子，而不是删掉重来。
          let polished = Set(items.map(\.id))
          let rows = drafts.filter { !polished.contains($0.id) }.map { (item: $0, isDraft: true) } + items.map { (item: $0, isDraft: false) }
          ForEach(rows, id: \.item.id) { row in
            let item = row.item
            TimelineSegmentRow(day: day, item: item, records: records.value,
                               projectName: showsProjects ? store.project(item.projectId)?.name : nil,
                               offersThreadStory: true, isDraft: row.isDraft,
                               isOrganizing: row.isDraft && item.id == drafts.first?.id && TimelineCatchUp.isRunning(store.catchUpRequest),
                               expanded: expanded == item.id) {
              expanded = expanded == item.id ? nil : item.id
            }
            .transition(.opacity)
          }
        }
        .id(day)
        .transition(.slide(from: dayEdge))
        .opacity(stale ? 0.45 : 1)
        footer.padding(.horizontal, TimelineReadingLayout.edge)
          .id(day)
          .transition(.slide(from: dayEdge))
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
      if startupMessage == nil || hasSegments {
        headline
          .id(day)
          .transition(.slide(from: dayEdge))
          .opacity(stale ? 0.45 : 1)
      }
      if let startupMessage {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
          Text(startupMessage).foregroundStyle(Palette.attention)
            .fixedSize(horizontal: false, vertical: true)
          Spacer(minLength: 0)
          OpenLogsButton().buttonStyle(.accentLink).fixedSize()
        }
        .font(.system(size: TextSize.body))
      } else {
        if let event = securityEvents.events.first {
          TimelineSecurityEventLine(event: event) {
            Task { await securityEvents.acknowledge(event, using: store.api) }
          }
          .disabled(securityEvents.acknowledging)
          .id(event.id)
          .transition(.notice)
          if let error = securityEvents.error { SettingsMessage(text: error).transition(.notice) }
        }
        if showsSetup, let setup { SetupChecklist(health: setup.health, tools: setup.tools).transition(.notice) }
        if !store.pending.isEmpty { TimelinePendingLine().transition(.notice) }
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
        // 日期栏不动，只有日期数字朝翻页方向滚过去。
        Text(Fmt.date(selectedDay)).font(.serif(TextSize.display)).foregroundStyle(Palette.ink)
          .contentTransition(Motion.reduced ? .opacity : .numericText(countsDown: dayEdge == .leading))
        Text(ViewerFormat.weekday(selectedDay)).font(.system(size: TextSize.body)).foregroundStyle(Palette.muted)
          .contentTransition(.opacity)
      }
      .animation(Motion.standard, value: selectedDay)
      .padding(.vertical, 4).contentShape(Rectangle())
    }
    .buttonStyle(.plain).help("跳到日期").popover(isPresented: $picking) {
      DatePicker("选择日期", selection: Binding(get: { selectedDay }, set: {
        selectedDay = Calendar.current.startOfDay(for: $0)
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
        Button("今天") { selectedDay = today }.disabled(selectedDay == today).keyboardShortcut("t", modifiers: .command)
        Button { shift(1) } label: { PhIcon("caret-right", size: 14) }
          .help("后一天").accessibilityLabel("后一天").keyboardShortcut("]", modifiers: .command).disabled(selectedDay == today)
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
      Motion.animate { store.timelineDensity = mode }
    } label: {
      Text(title).font(.system(size: TextSize.caption))
        .padding(.horizontal, 8).frame(height: 24)
        .foregroundStyle(selected ? Palette.accent : Palette.muted)
        .background {
          // 选中底块在两档之间滑过去，而不是这边消失那边出现。
          if selected {
            RoundedRectangle(cornerRadius: Radius.control - 2).fill(Palette.accent.opacity(0.13))
              .matchedGeometryEffect(id: "density", in: densityPill)
          }
        }
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityAddTraits(selected ? .isSelected : [])
  }

  private func shift(_ delta: Int) {
    guard let next = Calendar.current.date(byAdding: .day, value: delta, to: selectedDay), next <= today else { return }
    selectedDay = next
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
    let hasContent = hasSegments || !drafts.isEmpty
    if current, let error = diary.error ?? (hasContent ? nil : records.error) {
      Placeholder(kind: .error(error) { Task { await load() } })
    } else if failed && !hasSegments {
      status("最近一次整理失败", color: Palette.attention)
    } else if diary.value == nil || (!hasContent && records.value == nil) {
      DelayedProgress(label: "正在读取时间线")
    } else if !drafts.isEmpty {
      EmptyView()
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
        // 有草稿时截止时间只代表润色到哪，草稿本身已经更新到最新。
        Text("\(drafts.isEmpty ? "内容截至" : "已整理到") \(ReviewTime.clock(at, on: day))\(failed ? "，最近一次整理失败" : "")")
          .foregroundStyle(failed ? Palette.attention : Palette.muted)
          .rollingNumber(at)
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
    guard current, diary.error == nil else { return false }
    if let request = store.catchUpRequest {
      guard let list = try? await store.api.distillRequests() else { return false }
      let latest = list.first { $0.id == request.id }
      store.catchUpRequest = latest
      if TimelineCatchUp.isRunning(latest) { return false }
      store.catchUpRequest = nil
      return true
    }
    let now = Date()
    guard TimelineCatchUp.shouldRequest(hasDrafts: !(review?.drafts ?? []).isEmpty, cutoff: cutoff,
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
    let target = selectedDay
    let revision = store.revision
    let switching = target != day
    if switching { markStaleLater() }
    // 被下一次换天取消时不收尾，压淡交给接手的那次读取处理。
    defer { if switching, !Task.isCancelled { clearStale() } }
    async let readiness: Void = loadSetup()
    var nextDiary: DayDiary?
    var diaryError: String?
    do {
      nextDiary = try await store.dataSource.diary(target)
      try Task.checkCancellation()
    } catch is CancellationError {
      _ = await readiness
      return
    } catch {
      diaryError = error.localizedDescription
    }
    let hasDiaryItems = nextDiary?.detail?.items?.allSatisfy { $0.recordIds != nil } == true
    let hasDiaryDrafts = target == today && !(nextDiary?.drafts ?? []).isEmpty
    // 简约档已有整理段或草稿时不拉整天原文，展开单段再按需读取；详细档或空天再拉当天原始记录。
    let needsRecords = density == .detailed || (!hasDiaryItems && !hasDiaryDrafts)
    var nextRecords: [HistoryRecord]?
    var recordsError: String?
    if needsRecords {
      do {
        nextRecords = try await store.dataSource.day(target)
        try Task.checkCancellation()
      } catch is CancellationError {
        _ = await readiness
        return
      } catch {
        recordsError = error.localizedDescription
      }
    }
    _ = await readiness
    guard !Task.isCancelled, target == selectedDay else { return }
    let settled = revision == store.revision
    if switching {
      // 新的一天整块从翻页方向滑进来；详细档带工具栏和右侧详情栏，叠着过渡会闪，直接换。
      withAnimation(density == .compact ? Motion.page : nil) {
        day = target
        expanded = nil
        diary.value = diaryError == nil ? .some(nextDiary) : nil
        diary.error = diaryError
        records.value = nextRecords
        records.error = recordsError
        if settled { loadedRevision = revision }
      }
    } else {
      diary.apply {
        if diaryError == nil, diary.value != .some(nextDiary) { diary.value = .some(nextDiary) }
        if diary.error != diaryError { diary.error = diaryError }
      }
      if needsRecords {
        records.apply {
          if recordsError == nil, records.value != nextRecords { records.value = nextRecords }
          if records.error != recordsError { records.error = recordsError }
        }
      }
      if settled { loadedRevision = revision }
    }
  }

  private func markStaleLater() {
    staleTimer?.cancel()
    staleTimer = Task {
      try? await Task.sleep(for: Motion.loadingDelay)
      guard !Task.isCancelled else { return }
      withAnimation(Motion.quick) { stale = true }
    }
  }

  private func clearStale() {
    staleTimer?.cancel()
    staleTimer = nil
    if stale { withAnimation(Motion.quick) { stale = false } }
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
      .pressFeedback(configuration.isPressed)
      .animation(Motion.quick, value: enabled)
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
      .pressFeedback(configuration.isPressed)
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
    await item.run { try await store.dataSource.diary(day)?.detail?.items?.first { $0.id == id } }
  }
}
