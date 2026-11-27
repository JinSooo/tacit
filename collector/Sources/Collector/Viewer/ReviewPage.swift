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
    // 页面每 30 秒、窗口重新露出和数据变化时都会自己刷新，不放刷新按钮；⌘R 留给想立刻重读的人。
    .background {
      Button(L10n.refresh) { refresh += 1 }.keyboardShortcut("r", modifiers: .command)
        .opacity(0).allowsHitTesting(false).accessibilityHidden(true)
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
  @State private var hoveringDateTitle = false
  @Namespace private var densityPill
  @State private var setup: (health: DistillHealth, tools: [AgentToolState], minuteModel: ModelTierConfig?)?
  @State private var backendSetup: AppSetup.ChecklistStep?
  @State private var backendChecked = false
  @State private var securityEvents = TimelineSecurityEventState()
  /// 日期栏上选中的那天；切过去后先把那天读好，再整块滑进来，期间仍显示正在看的这一天。
  @Binding var selectedDay: Date
  /// 正在显示的那一天（内容、草稿、页脚都按它）。
  @State private var day: Date
  /// 日期栏数字的滚动方向：按日期栏上前后两次选中的日子算。
  @State private var dateEdge: HorizontalEdge = .trailing
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
    let backendReady: Bool
  }

  private var localSetup: AppSetup.ChecklistStep? { store.isRemoteBackend ? nil : backendSetup }

  static func allowsDayRecords(backendSetup: AppSetup.ChecklistStep?) -> Bool { backendSetup == nil }
  private var allowsDayRecords: Bool { Self.allowsDayRecords(backendSetup: localSetup) }
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
    // 润色后编号不变；两边同时出现时以整理好的为准，列表和页脚都按去重后的算。
    let polished = Set(items.map(\.id))
    return (review?.drafts ?? []).reversed().map(\.item).filter { !polished.contains($0.id) }
  }
  private var items: [DayDiary.Item] {
    guard hasSegments else { return [] }
    return (review?.detail?.items ?? []).sorted { ($0.tStart, $0.id) > ($1.tStart, $1.id) }
  }

  var body: some View {
    Group {
      if density == .compact || !allowsDayRecords {
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
    .animation(Motion.standard, value: store.pending.isEmpty)
    .animation(Motion.standard, value: localSetup)
    .onChange(of: selectedDay) { old, new in dateEdge = new < old ? .leading : .trailing }
    .onDisappear { staleTimer?.cancel() }
    .task(id: LoadKey(day: selectedDay, refresh: refresh, revision: store.revision, density: density, backendReady: localSetup == nil)) {
      repeat {
        await load()
        if selectedDay != today || day != today {
          // 往日也会被补整理或每小时整理改写；没有刷新按钮，隔几分钟自己重读。
          await WindowVisibility.pause(.seconds(180)); continue
        }
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
    .task(id: store.isRemoteBackend) {
      guard !store.isRemoteBackend else { return }
      let dataDir = Config.load().dataDir
      while !Task.isCancelled {
        let reachable = await AppSetup.isReachable(store.api.base)
        guard !Task.isCancelled else { return }
        backendSetup = AppSetup.checklistStep(in: dataDir, reachable: reachable)
        backendChecked = true
        await WindowVisibility.pause(.seconds(backendSetup == nil ? 5 : 1))
      }
    }
  }

  private var compactList: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 14) {
        dayHeader().padding(.horizontal, TimelineReadingLayout.edge)
        // 惰性排版：展开动画时只有看得见的几段逐帧挪位置；全量 VStack 实测每帧都超出 120Hz 的预算。
        LazyVStack(spacing: 0) {
          let drafts = self.drafts
          let items = self.items
          let showsProjects = TimelineProjectLabels.showsNames(in: drafts + items)
          // 草稿和整理好的段放在同一个列表里、按开始时刻统一倒序：草稿整理好后编号不变，这一行原位换成正式的样子。
          // drafts 已去掉和整理好的段同编号的那些。
          let rows = (drafts.map { (item: $0, isDraft: true) } + items.map { (item: $0, isDraft: false) })
            .sorted { ($0.item.tStart, $0.item.id) > ($1.item.tStart, $1.item.id) }
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
        .transition(.dayChange)
        .opacity(stale ? 0.45 : 1)
        footer.padding(.horizontal, TimelineReadingLayout.edge)
          .id(day)
          .transition(.dayChange)
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
      if localSetup == nil || hasSegments {
        headline
          .id(day)
          .transition(.dayChange)
          .opacity(stale ? 0.45 : 1)
      }
      if localSetup == nil {
        if let event = securityEvents.events.first {
          TimelineSecurityEventLine(event: event) {
            Task { await securityEvents.acknowledge(event, using: store.api) }
          }
          .disabled(securityEvents.acknowledging)
          .id(event.id)
          .transition(.notice)
          if let error = securityEvents.error { SettingsMessage(text: error).transition(.notice) }
        }
        if let update = store.update.available {
          TimelineUpdateLine(notice: store.update, update: update).id(update.version).transition(.notice)
        }
        if !store.pending.isEmpty { TimelinePendingLine().transition(.notice) }
      }
      SetupChecklist(backend: localSetup, backendChecked: backendChecked || store.isRemoteBackend, health: localSetup == nil ? setup?.health : nil,
                     tools: localSetup == nil ? setup?.tools : nil, minuteModel: setup?.minuteModel)
        .transition(.notice)
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
      HStack(alignment: .firstTextBaseline, spacing: 10) {
        // 日期栏不动，只有日期数字朝翻页方向滚过去。
        Text(AppLanguage.current == .zh ? Fmt.date(selectedDay) : L10n.dayHeader(selectedDay)).font(.serif(TextSize.display)).foregroundStyle(Palette.ink)
          .contentTransition(Motion.reduced ? .opacity : .numericText(countsDown: dateEdge == .leading))
        if AppLanguage.current == .zh {
          Text(ViewerFormat.weekday(selectedDay)).font(.system(size: TextSize.body)).foregroundStyle(Palette.muted)
            .contentTransition(.opacity)
        }
        DisclosureChevron(expanded: picking, size: 11)
          .foregroundStyle(hoveringDateTitle || picking ? Palette.muted : Palette.faint)
      }
      .animation(Motion.standard, value: selectedDay)
      .padding(.horizontal, 8).padding(.vertical, 4)
      .background(hoveringDateTitle || picking ? Palette.fill : Color.clear,
                  in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
      .padding(.leading, -8)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .hoverState($hoveringDateTitle)
    .help(L10n.jumpToDate)
    .accessibilityHint(L10n.jumpToDate)
    .popover(isPresented: $picking, arrowEdge: .bottom) {
      TimelineCalendarPopover(
        selectedDay: $selectedDay,
        today: today,
        isPresented: $picking,
        dataSource: store.dataSource,
        cache: store.activeDaysCache,
        revision: store.revision
      )
    }
  }

  private var dateControls: some View {
    HStack(spacing: 16) {
      HStack(spacing: 0) {
        Button { shift(-1) } label: { PhIcon("caret-left", size: 14) }
          .help(L10n.previousDay).accessibilityLabel(L10n.previousDay).keyboardShortcut("[", modifiers: .command)
        Button(L10n.today) { selectedDay = today }.disabled(selectedDay == today).keyboardShortcut("t", modifiers: .command)
        Button { shift(1) } label: { PhIcon("caret-right", size: 14) }
          .help(L10n.nextDay).accessibilityLabel(L10n.nextDay).keyboardShortcut("]", modifiers: .command).disabled(selectedDay == today)
      }
      .buttonStyle(ReviewDateButtonStyle())
      .font(.system(size: TextSize.body)).fixedSize()
      HStack(spacing: 2) {
        densityButton(.compact, title: L10n.simple)
        densityButton(.detailed, title: L10n.detailed)
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
    if current, localSetup == nil, let error = diary.error ?? (hasContent ? nil : records.error) {
      Placeholder(kind: .error(error) { Task { await load() } })
    } else if failed && !hasSegments {
      status(L10n.lastSummaryFailed, color: Palette.attention)
    } else if diary.value == nil || (!hasContent && records.value == nil) {
      DelayedProgress(label: L10n.loadingTimeline)
    } else if !drafts.isEmpty {
      EmptyView()
    } else if records.value?.isEmpty == true && review?.detail == nil {
      status(L10n.noRecordsForThisDay)
    } else if hasSegments && !items.isEmpty {
      status(L10n.activitiesForThisDay)
    } else if hasSegments {
      status(L10n.noDaySummary)
    } else if review?.detail != nil {
      status(L10n.dayHasOriginalRecords)
    } else if !isToday && review?.needsRegen?.value != true {
      status(L10n.noDayTimeline)
    } else {
      status(L10n.summarizing)
    }
  }

  private var footer: some View {
    HStack(alignment: .firstTextBaseline, spacing: 16) {
      if hasSegments, cutoff != nil, items.isEmpty, drafts.isEmpty {
        // 一段都还没有时截止时间没有意义：新装好时显示“内容截至 00:00”像是出了错（2026-11-25 虚拟机实测）。
        if failed { Text(L10n.lastSummaryFailed).foregroundStyle(Palette.attention) }
      } else if hasSegments, let at = cutoff {
        // 有草稿时截止时间只代表润色到哪，草稿本身已经更新到最新。
        Text(L10n.timelineCutoff(ReviewTime.clock(at, on: day), hasDrafts: !drafts.isEmpty, failed: failed))
          .foregroundStyle(failed ? Palette.attention : Palette.muted)
          .rollingNumber(at)
      }
      Spacer(minLength: 0)
      if allowsDayRecords {
        Button(L10n.allRecordsForThisDay) { store.showDayRecords(day) }.buttonStyle(.accentLink)
      }
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
      let (status, installed) = try await (health, tools)
      let config = status.state == .working ? nil : try? await store.api.modelSettings().tiers["minute"]
      try Task.checkCancellation()
      setup = (status, installed, config)
    } catch is CancellationError {
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
    // 折回正在显示的那天（或同一天刷新）时，之前换天留下的压淡和计时一并撤掉。
    if switching { markStaleLater() } else { clearStale() }
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
      diaryError = UserFacingError.message(for: error, fallback: L10n.Settings.settingsRequestFailed)
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
        recordsError = UserFacingError.message(for: error, fallback: L10n.Settings.settingsRequestFailed)
      }
    }
    _ = await readiness
    guard !Task.isCancelled, target == selectedDay else { return }
    let settled = revision == store.revision
    if switching {
      // 新的一天整块淡换进来（翻页方向由日期栏数字的滚动交代）；详细档带工具栏和右侧详情栏，叠着过渡会闪，直接换。
      withAnimation(density == .compact ? Motion.page : nil) {
        day = target
        expanded = nil
        diary.value = diaryError == nil ? .some(nextDiary) : nil
        diary.error = diaryError
        records.value = nextRecords
        records.error = recordsError
        if settled { loadedRevision = revision }
      }
    } else if loadedRevision != revision, diaryError != nil || recordsError != nil {
      // 删除、修正之后重读失败：不能继续摆着删除前的内容，撤下并显示错误和重试。
      Motion.animate {
        expanded = nil
        diary.value = nil
        diary.error = diaryError ?? recordsError
        records.value = nil
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
    if AppLanguage.current == .en {
      Text(text).font(.serif(size))
    } else {
      let value = text.reduce(into: AttributedString()) { result, character in
        var part = AttributedString(String(character))
        part.font = character.isASCII ? .system(size: size, weight: .medium) : .serif(size)
        result.append(part)
      }
      Text(value)
    }
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
    AppLanguage.current == .zh && date == ViewerTime.dayBounds(day).end ? "24:00" : ViewerFormat.clock(date)
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
    Text(([Fmt.duration(item.activeSeconds)] + item.sources.map(SourceInfo.name)).joined(separator: L10n.comma))
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
            Text([Fmt.date(day), ReviewTime.range(current, on: day)].joined(separator: L10n.comma))
              .font(.system(size: TextSize.caption)).monospacedDigit().foregroundStyle(Palette.muted)
            Text(current.title).font(.system(size: TextSize.title, weight: .semibold)).foregroundStyle(Palette.ink)
              .accessibilityAddTraits(.isHeader)
            Text(current.description).font(.system(size: TextSize.body)).foregroundStyle(Palette.ink).textSelection(.enabled)
            ReviewMetadata(item: current)
            Text(L10n.taskHistoryAndEvidence).font(.system(size: TextSize.body, weight: .semibold)).foregroundStyle(Palette.ink)
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
          Placeholder(kind: .empty("clock-counter-clockwise", L10n.timelineItemUpdated))
        }
      }
      .modifier(ReviewWidth())
    }
    .background(Palette.paper)
    .navigationTitle(L10n.timeline)
    .toolbar { BackButton() }
    .task(id: store.revision) { await load() }
  }

  private func load() async {
    item.value = nil
    await item.run { try await store.dataSource.diary(day)?.detail?.items?.first { $0.id == id } }
  }
}
