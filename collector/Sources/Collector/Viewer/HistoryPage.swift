import AppKit
import SwiftUI
import CollectorCore

/// 时间线的详细视图：按事项或应用聚合活动，展开后显示原始记录。
struct HistoryPage<Header: View>: View {
  private enum Selection: Hashable { case segment(String), record(String) }
  private struct Activity {
    let segments: [HistorySegment]
    let conversations: [ConversationRef]
    let missing: [HistoryRecord]
  }
  private struct LoadKey: Equatable {
    let refresh: Int
    let revision: Int
    let missing: [String]
  }

  @Environment(ViewerStore.self) private var store
  @State private var activity = Loader<Activity>(animated: true)
  @State private var loadedKey: LoadKey?
  @State private var selection: Selection?
  @State private var expanded: Set<String> = []
  @State private var scrollTarget: String?
  @State private var brush: ClosedRange<Date>?
  @State private var lane: Lane?
  @State private var device: String?
  @State private var note = false

  let day: Date
  let diary: DayDiary?
  let dayRecords: [HistoryRecord]?
  let dayError: String?
  let refresh: Int
  @ViewBuilder let header: (HistoryDayStats?) -> Header

  private var records: [HistoryRecord] { (dayRecords ?? []) + (activity.value?.missing ?? []) }
  private var segments: [HistorySegment] { activity.value?.segments ?? [] }
  private var conversations: [ConversationRef] { activity.value?.conversations ?? [] }
  private var loadKey: LoadKey {
    LoadKey(refresh: refresh, revision: store.revision, missing: omittedIds.subtracting(dayRecords?.map(\.id) ?? []).sorted())
  }
  private var visible: [HistoryRecord] {
    records.filter { r in
      (lane == nil || Lane.of(r.source) == lane) && HistoryDeviceFilter.matches(r.device, selection: device) &&
        (brush.map { r.start <= $0.upperBound && (r.end ?? r.start) >= $0.lowerBound } ?? true)
    }
  }

  /// 全部活动段（检查器、定位记录用）；列表用按筛选裁过的 blocks。
  private var allBlocks: [SegmentBlock] { SegmentBlocks.join(segments, records: records) }
  private var blocks: [SegmentBlock] {
    lane == nil && device == nil && brush == nil ? allBlocks : SegmentBlocks.join(segments, records: records, visible: Set(visible.map(\.id)))
  }
  private var omittedIds: Set<String> { Set(diary?.detail?.omittedRecordIds ?? []) }

  private var selectedRecord: String? { if case .record(let id)? = selection { return id }; return nil }
  /// 选中项在列表里那一行的 id：合并显示的几条记录用这一行第一条的 id。
  private func selectedRowID() -> String? {
    switch selection {
    case .segment(let id)?: return id
    case .record(let id)?:
      guard let block = blocks.first(where: { $0.segment.recordIds.contains(id) }),
            expanded.contains(block.id) else { return nil }
      return RecordRuns.collapse(block.records, conversations: conversations)
        .first(where: { $0.records.contains { $0.id == id } })?.id
    case nil: return nil
    }
  }

  /// 选中一条记录：展开它所在的段并滚过去。
  private func reveal(_ id: String) {
    // 打开右侧详情和展开所在段一起过渡，再由 scrollTarget 滚过去。
    Motion.animate(Motion.page) { selection = .record(id) }
    if let block = allBlocks.first(where: { $0.segment.recordIds.contains(id) }) {
      Motion.animate {
        expanded.insert(block.id)
        // 所在的段被折进"其他 N 段"时，先展开那一组，否则这一行不在列表里、滚不过去。
        for case .minor(let group) in SegmentFold.fold(blocks) where group.contains(where: { $0.id == block.id }) {
          expanded.insert(SegmentListItem.minor(group).id)
        }
      }
      scrollTarget = selectedRowID() ?? block.id
    }
  }

  var body: some View {
    ScrollViewReader { proxy in
      ScrollView {
        dayList
      }
      .scrollContentBackground(.hidden)
      .background(Palette.paper)
      .onChange(of: scrollTarget) { _, id in
        guard let id else { return }
        withAnimation(Motion.page) { proxy.scrollTo(id, anchor: .center) }
        scrollTarget = nil
      }
    }
    .toolbar { toolbar }
    .inspector(isPresented: Binding(get: { selection != nil }, set: { if !$0 { Motion.animate(Motion.page) { selection = nil } } })) {
      inspector
        .inspectorColumnWidth(min: 300, ideal: 360, max: 520)
        // 检查器打开后要有地方关掉它（以前只能按 Esc，2026-11-10 用户报告）。放在检查器自己的工具栏里。
        .toolbar {
          ToolbarItem(placement: .primaryAction) {
            Button { Motion.animate(Motion.page) { selection = nil } } label: { PhIcon("sidebar-simple", size: PhIcon.toolbar).scaleEffect(x: -1) }
              .help("隐藏详情").accessibilityLabel("隐藏详情").keyboardShortcut("i", modifiers: [.command, .option])
          }
        }
    }
    .sheet(isPresented: $note) { NoteSheet { store.revision += 1 } }
    .task(id: dayRecords == nil ? nil : loadKey) {
      guard dayRecords != nil else { return }
      await loadActivity(loadKey)
    }
    .onChange(of: store.historyFocus, initial: true) { consumeFocus() }
    .onChange(of: dayError) { consumeFocus() }
    // 详情栏打开时列表变窄、行高变了，布局完成后再把选中的行滚回来。
    .task(id: selection == nil) {
      guard selection != nil else { return }
      do { try await Task.sleep(for: .milliseconds(300)) }
      catch { return }
      scrollTarget = selectedRowID()
    }
    .onKeyPress(.escape) {
      if selection != nil { Motion.animate(Motion.page) { selection = nil }; return .handled }
      if brush != nil { Motion.animate { brush = nil }; return .handled }
      return .ignored
    }
  }

  @ViewBuilder private var inspector: some View {
    switch selection {
    case .segment(let id)?:
      if let block = allBlocks.first(where: { $0.id == id }) {
        SegmentInspector(block: block).id(id)
      }
    case .record(let id)?:
      // 从段里点进来的记录可以回到那一段。
      let parent = allBlocks.first { $0.segment.recordIds.contains(id) }
      RecordInspector(id: id, back: parent.map { b in .init(title: SegmentText.title(b)) { selection = .segment(b.id) } }) { _ in
        Motion.animate(Motion.page) { selection = nil }
      }
      .id(id)
    case nil:
      EmptyView()
    }
  }

  private func consumeFocus() {
    guard let id = store.historyFocus, loadedKey == loadKey || dayError != nil else { return }
    // 换天时新的一天读好之前，旧的一天还在屏幕上；定位目标留给要去的那一天。
    guard Calendar.current.isDate(store.reviewDay ?? .now, inSameDayAs: day) else { return }
    store.historyFocus = nil
    lane = nil
    brush = nil
    device = nil
    // 修正记录等可能不在当天的列表里，仍可在详情里打开。
    reveal(id)
  }

  private func loadActivity(_ key: LoadKey) async {
    await activity.run {
      async let grouped = store.dataSource.segments(day)
      async let missing = store.dataSource.missingRecords(key.missing, from: [])
      let (groups, extras) = try await (grouped, missing)
      try Task.checkCancellation()
      return Activity(segments: groups.segments, conversations: groups.conversations, missing: extras)
    }
    guard !Task.isCancelled else { return }
    loadedKey = key
    if !records.contains(where: { HistoryDeviceFilter.matches($0.device, selection: device) }) { device = nil }
    consumeFocus()
  }

  // MARK: 一天

  private var dayList: some View {
    let blocks = self.blocks
    return LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
      header(loadedKey != nil && !records.isEmpty
        ? HistoryDayStats(count: allBlocks.count, activeSeconds: ActiveTime.seconds(records), start: records.map(\.start).min())
        : nil)
        // 详细档是通栏：页首与下方泳道、活动行共用左右边距，不再单独收窄居中。
        .padding(.horizontal, HistoryLayout.inset).padding(.top, 28).padding(.bottom, 12)
      Section {
        if let error = dayError ?? activity.error {
          Placeholder(kind: .error(error) { store.revision += 1 }).frame(height: 240)
        } else if loadedKey == nil || dayRecords == nil {
          Placeholder(kind: .loading).frame(height: 240)
        } else if records.isEmpty {
          Placeholder(kind: .empty("moon-stars", "这一天没有记录")).frame(height: 260)
        } else if blocks.isEmpty {
          Placeholder(kind: .empty("funnel-simple", "没有符合筛选的记录")).frame(height: 200)
        } else {
          // 修饰符加在 ForEach 上会分发给每一行，留白用独立的占位视图。
          Color.clear.frame(height: 8)
          segmentRows(blocks)
          Color.clear.frame(height: 40)
        }
      } header: {
        if !records.isEmpty { strataHeader }
      }
    }
  }

  private var strataHeader: some View {
    VStack(alignment: .leading, spacing: 8) {
      DayStrata(records: records.filter { HistoryDeviceFilter.matches($0.device, selection: device) }, chapters: DayStrata.chapters(from: diary, on: day), day: day, selected: selectedRecord,
                brush: $brush, lane: $lane,
                conversationTitles: Dictionary(conversations.flatMap { c in c.title.map { t in c.recordIds.map { ($0, t) } } ?? [] }, uniquingKeysWith: { a, _ in a })) { r in reveal(r.id) }
      if brush != nil || lane != nil {
        HStack(spacing: 8) {
          if let b = brush { chip("\(ViewerFormat.clock(b.lowerBound))–\(ViewerFormat.clock(b.upperBound))", "clock") { Motion.animate { brush = nil } } }
          if let l = lane { chip(l.name, "funnel-simple") { Motion.animate { lane = nil } } }
          Text("\(Fmt.count(visible.count)) 条记录").font(.system(size: TextSize.caption)).foregroundStyle(Palette.muted)
            .rollingNumber(visible.count)
        }
        .transition(.notice)
      }
    }
    .padding(.horizontal, HistoryLayout.inset).padding(.vertical, 12)
    .background {
      Rectangle().fill(Palette.paper)
        .overlay(alignment: .bottom) { Rectangle().fill(Palette.hairline).frame(height: 1) }
    }
    .zIndex(2)
    .animation(Motion.standard, value: brush != nil || lane != nil)
  }

  func chip(_ text: String, _ symbol: String, clear: @escaping () -> Void) -> some View {
    Button(action: clear) {
      HStack(spacing: 4) {
        PhIcon(symbol, size: 12)
        Text(text).monospacedDigit()
        PhIcon("x", size: 10)
      }
      .font(.system(size: TextSize.caption, weight: .medium))
      .padding(.horizontal, 8).padding(.vertical, 4)
      .foregroundStyle(Palette.accent)
      .background(Palette.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
    }
    .buttonStyle(.plain)
    .help("清除这个筛选")
  }

  // MARK: 行

  /// 每段一张卡片；展开后列出原始记录（相邻同标题的合成一行）。连续的零碎段折成一行"其他 N 段"。
  @ViewBuilder func segmentRows(_ blocks: [SegmentBlock]) -> some View {
    let cal = Calendar.current
    let items = SegmentFold.fold(blocks)
    let omitted = omittedIds
    ForEach(Array(items.enumerated()), id: \.element.id) { i, item in
      let hour = cal.component(.hour, from: item.start)
      if i == 0 || cal.component(.hour, from: items[i - 1].start) != hour {
        HourMark(hour: hour).padding(.top, i == 0 ? 4 : 12).padding(.horizontal, HistoryLayout.inset)
      }
      switch item {
      case .single(let block):
        segmentRow(block, omitted: omitted)
      case .minor(let group):
        let includesOmissions = group.contains { block in block.records.contains { omitted.contains($0.id) } }
        MinorSegmentsRow(blocks: group, expanded: expanded.contains(item.id), includesOmissions: includesOmissions) {
          Motion.animate { if expanded.contains(item.id) { expanded.remove(item.id) } else { expanded.insert(item.id) } }
        }
        .padding(.horizontal, HistoryLayout.inset)
        .id(item.id)
        if expanded.contains(item.id) {
          ForEach(group) { block in segmentRow(block, omitted: omitted).transition(.reveal) }
        }
      }
    }
  }

  @ViewBuilder func segmentRow(_ block: SegmentBlock, omitted: Set<String>) -> some View {
    let hasOmission = block.records.contains { omitted.contains($0.id) }
    SegmentRow(block: block, conversation: conversationNote(block), selected: selection == .segment(block.id),
               expanded: expanded.contains(block.id), includesOmissions: hasOmission) {
      Motion.animate {
        if expanded.contains(block.id) { expanded.remove(block.id) } else { expanded.insert(block.id) }
        selection = .segment(block.id)
      }
    }
    .padding(.horizontal, HistoryLayout.inset)
    .id(block.id)
    if expanded.contains(block.id) {
      ForEach(RecordRuns.collapse(block.records, conversations: conversations)) { run in
        let hasOmission = run.records.contains { omitted.contains($0.id) }
        RecordRow(record: run.newest, run: run, selected: run.records.contains { $0.id == selectedRecord },
                  expanded: false, nested: true, includesOmissions: hasOmission) {
          Motion.animate(Motion.page) { selection = .record(run.newest.id) }
        }
        .padding(.horizontal, HistoryLayout.inset)
        .id(run.id)
        .transition(.reveal)
      }
      Color.clear.frame(height: 8).transition(.identity)
    }
  }

  /// 段里第一场有总结的对话的标题。
  func conversationNote(_ block: SegmentBlock) -> String? {
    let ids = Set(block.records.filter { AudioSource.isAudio($0.source) }.map(\.id))
    guard !ids.isEmpty else { return nil }
    return conversations.first { c in c.title != nil && c.recordIds.contains(where: ids.contains) }?.title
  }

  // MARK: 工具栏

  private var toolbar: some ToolbarContent {
    ToolbarItemGroup(placement: .primaryAction) {
      Menu {
        Picker("来源", selection: $lane) {
          Text("全部来源").tag(Lane?.none)
          ForEach(Lane.allCases.filter { l in records.contains { Lane.of($0.source) == l } }, id: \.self) { Text($0.name).tag(Lane?.some($0)) }
        }
        .pickerStyle(.inline)
        let devices = Set(records.map { HistoryDeviceFilter.group($0.device) }).sorted()
        if devices.count > 1 {
          Picker("设备", selection: $device) {
            Text("全部设备").tag(String?.none)
            ForEach(devices, id: \.self) { Text($0).tag(String?.some($0)) }
          }
          .pickerStyle(.inline)
        }
      } label: {
        PhIcon("funnel-simple", fill: lane != nil || device != nil, size: PhIcon.toolbar)
      }
      .help("筛选").accessibilityLabel("筛选")
      Button { note = true } label: { PhIcon("note-pencil", size: PhIcon.toolbar) }
        .help("补写一条记录").accessibilityLabel("补写一条记录").keyboardShortcut("n", modifiers: .command)
    }
  }
}

struct HistoryDayStats: View {
  let count: Int
  let activeSeconds: TimeInterval
  let start: Date?

  var body: some View {
    let startLabel = start.map { "开始 " + ViewerFormat.clock($0) }
    let stats = ["\(Fmt.count(count)) 段活动", "活跃 \(Fmt.duration(activeSeconds))"] + (startLabel.map { [$0] } ?? [])
    Text(stats.joined(separator: "，"))
      .font(.system(size: TextSize.body)).foregroundStyle(Palette.muted)
      .rollingNumber(stats)
      .multilineTextAlignment(.trailing)
      .help("活跃时长按记录覆盖的时段算，几个来源同时在记录只算一次")
  }
}

struct HourMark: View {
  let hour: Int
  var body: some View {
    HStack(spacing: 10) {
      Text(String(format: "%02d:00", hour)).font(.system(size: TextSize.caption, weight: .medium)).monospacedDigit().foregroundStyle(Palette.muted)
        .frame(width: RecordRow.timeWidth, alignment: .trailing)
      Rectangle().fill(Palette.hairline).frame(height: 1)
    }
    .padding(.vertical, 4)
  }
}

struct RecordRow: View {
  static let timeWidth: CGFloat = 86
  let record: HistoryRecord
  let run: RecordRun?
  let selected: Bool
  let expanded: Bool
  var snippet: SearchSnippet? = nil
  var nested = false
  var titleOverride: String? = nil
  var alignsTimeLeading = false
  var includesOmissions = false
  let action: () -> Void
  @State private var hovering = false

  var body: some View {
    Button(action: action) {
      HStack(alignment: .center, spacing: 12) {
        Text(timeText)
          .font(.system(size: TextSize.caption)).monospacedDigit()
          .foregroundStyle(Palette.muted)
          .frame(width: Self.timeWidth, alignment: alignsTimeLeading ? .leading : .trailing)
          .lineLimit(1)
        Group {
          if nested { Circle().fill(Palette.faint).frame(width: 5, height: 5) }
          else { SourceGlyph(source: record.source, app: record.contextText("app"), size: 22) }
        }
        .frame(width: 26)
        VStack(alignment: .leading, spacing: 2) {
          HStack(spacing: 8) {
            Text(titleOverride ?? run?.conversation.map { ConversationText.title($0, source: record.source) } ?? RecordText.title(record, appShown: !nested))
              .font(.system(size: TextSize.body, weight: nested ? .regular : .medium))
              .foregroundStyle(nested ? Palette.muted : Palette.ink)
              .lineLimit(1)
            badges
          }
          if let snippet {
            (Text(snippet.before) + Text(snippet.match).foregroundStyle(Palette.accent).bold() + Text(snippet.after))
              .font(.system(size: TextSize.caption)).foregroundStyle(Palette.muted).lineLimit(1)
          } else if !nested, let sub = subtitle {
            Text(sub).font(.system(size: TextSize.caption)).foregroundStyle(Palette.muted).lineLimit(1)
          }
        }
        Spacer(minLength: 8)
        // 相邻、同标题的几条记录合成了一行（记录本身没合并）。
        if let run, run.records.count > 1, run.conversation == nil {
          Text("\(run.records.count) 条").font(.system(size: TextSize.caption)).monospacedDigit().foregroundStyle(Palette.muted)
            .help("连续 \(run.records.count) 条同样的记录合成一行")
        }
        if let d = durationText {
          Text(d).font(.system(size: TextSize.caption)).monospacedDigit().foregroundStyle(Palette.muted).frame(minWidth: 52, alignment: .trailing)
        }
      }
      .padding(.vertical, nested ? 4 : 8)
      .padding(.horizontal, 8)
      .background(alignment: .leading) {
        Rectangle().fill(Palette.hairline).frame(width: 1).padding(.leading, 8 + Self.timeWidth + 12 + 12.5)
      }
      .background {
        RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
          .fill(selected ? Palette.accent.opacity(0.13) : (hovering ? Palette.fill : .clear))
      }
      .animation(Motion.quick, value: selected)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .hoverState($hovering)
  }

  @ViewBuilder var badges: some View {
    if includesOmissions { TimelineOmissionLabel() }
    if record.capture?.method == "ocr" { badge("截图识字") }
    if record.sensitivity == "redacted" || (record.redactions ?? 0) > 0 { badge("已隐去密钥") }
    if record.sensitivity == "private" { PhIcon("lock", size: 12).foregroundStyle(Palette.muted).help("私密：不交给 AI 整理") }
  }
  func badge(_ text: String) -> some View {
    Text(text).font(.system(size: TextSize.caption)).foregroundStyle(Palette.muted).fixedSize()
  }

  var timeText: String {
    // 一场对话按整场的起止，和右侧详情一致（有几段可能落在别的活动段里）。
    if let c = run?.conversation {
      let a = Date(timeIntervalSince1970: c.startMs / 1000), b = Date(timeIntervalSince1970: c.endMs / 1000)
      return ViewerFormat.clock(a) == ViewerFormat.clock(b) ? ViewerFormat.clock(a) : ViewerFormat.clock(a) + "–" + ViewerFormat.clock(b)
    }
    let start = run?.start ?? record.start
    let end = run?.end ?? record.end
    if let end, ViewerFormat.clock(end) != ViewerFormat.clock(start), !nested || record.isSpan {
      return ViewerFormat.clock(start) + "–" + ViewerFormat.clock(end)
    }
    return ViewerFormat.clock(record.start)
  }

  var durationText: String? {
    if let c = run?.conversation { let s = (c.endMs - c.startMs) / 1000; return s >= 60 ? Fmt.duration(s) : nil }
    let s = run?.seconds ?? record.seconds
    return s >= 60 ? Fmt.duration(s) : nil
  }

  var subtitle: String? {
    if let url = record.contextText("url").flatMap(URL.init(string:)), ["http", "https"].contains(url.scheme ?? ""), let host = url.host() { return host }
    if let repo = record.contextText("repo") ?? record.contextText("cwd") { return (repo as NSString).abbreviatingWithTildeInPath }
    return nil
  }
}

/// 中文的月份和星期名，但一周从哪天开始仍按用户的系统设置（zh_CN 默认周日）。
enum ViewerCalendar {
  static var chinese: Calendar {
    var c = Calendar.current
    let first = c.firstWeekday
    c.locale = Locale(identifier: "zh_CN")
    c.firstWeekday = first
    return c
  }
}

/// 详细档通栏的左右边距：页首、泳道和活动行共用，留出与窗口边缘的呼吸空间。
enum HistoryLayout {
  static let inset: CGFloat = 44
}
