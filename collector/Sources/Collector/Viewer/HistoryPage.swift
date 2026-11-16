import AppKit
import SwiftUI
import CollectorCore

/// 一天的历史记录：列表按活动段聚合（事项或应用），展开才是原始记录；搜索时按记录显示命中。
struct HistoryPage: View {
  enum Selection: Hashable { case segment(String), record(String) }

  @Environment(ViewerStore.self) private var store
  @State private var records: [HistoryRecord] = []
  @State private var segments: [HistorySegment] = []
  @State private var conversations: [ConversationRef] = []
  @State private var diary: DayDiary?
  @State private var loadedDay: Date?
  @State private var loading = false
  @State private var error: String?
  @State private var selection: Selection?
  @State private var expanded: Set<String> = []
  @State private var scrollTarget: String?
  @State private var brush: ClosedRange<Date>?
  @State private var lane: Lane?
  @State private var device: String?
  @State private var note = false
  @State private var picking = false
  // 搜索
  @State private var results: [HistoryRecord] = []
  @State private var cursor: String?
  @State private var searching = false

  var day: Date { store.historyDay }
  var isSearch: Bool { !store.historySearch.trimmingCharacters(in: .whitespaces).isEmpty }

  var visible: [HistoryRecord] {
    records.filter { r in
      (lane == nil || Lane.of(r.source) == lane) && (device == nil || r.device == device) &&
        (brush.map { r.start <= $0.upperBound && (r.end ?? r.start) >= $0.lowerBound } ?? true)
    }
  }

  /// 全部活动段（检查器、定位记录用）；列表用按筛选裁过的 blocks。
  var allBlocks: [SegmentBlock] { SegmentBlocks.join(segments, records: records) }
  var blocks: [SegmentBlock] {
    lane == nil && device == nil && brush == nil ? allBlocks : SegmentBlocks.join(segments, records: records, visible: Set(visible.map(\.id)))
  }
  var selectedRecord: String? { if case .record(let id)? = selection { return id }; return nil }
  /// 选中项在列表里那一行的 id：合并显示的几条记录用这一行第一条的 id。
  func rowID(for s: Selection?) -> String? {
    switch s {
    case .segment(let id)?: return id
    case .record(let id)?:
      for block in blocks where expanded.contains(block.id) {
        if let run = RecordRuns.collapse(block.records, conversations: conversations).first(where: { $0.records.contains { $0.id == id } }) { return run.id }
      }
      return id
    case nil: return nil
    }
  }

  /// 选中一条记录：展开它所在的段并滚过去。
  func reveal(_ id: String) {
    selection = .record(id)
    if let block = allBlocks.first(where: { $0.segment.recordIds.contains(id) }) {
      expanded.insert(block.id)
      // 所在的段被折进"其他 N 段"时，先展开那一组，否则这一行不在列表里、滚不过去。
      for case .minor(let group) in SegmentFold.fold(blocks) where group.contains(where: { $0.id == block.id }) {
        expanded.insert(SegmentListItem.minor(group).id)
      }
      scrollTarget = block.id
    }
  }

  var chapters: [DayStrata.Chapter] {
    (diary?.detail?.timeline ?? []).enumerated().compactMap { i, c in
      guard let s = ViewerTime.clockOnDay(c.start, day: day), var e = ViewerTime.clockOnDay(c.end, day: day) else { return nil }
      if e <= s { e = ViewerTime.dayBounds(day).end }
      return .init(id: i, start: s, end: e, text: c.text)
    }
  }

  var body: some View {
    @Bindable var store = store
    ScrollViewReader { proxy in
      ScrollView {
        if isSearch { searchList } else { dayList }
      }
      .scrollContentBackground(.hidden)
      .background(Palette.paper)
      .onChange(of: scrollTarget) { _, id in
        guard let id else { return }
        withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(id, anchor: .center) }
        scrollTarget = nil
      }
    }
    .navigationTitle(isSearch ? "搜索" : ViewerFormat.dayTitle(day))
    .navigationSubtitle(isSearch ? "" : ViewerFormat.weekday(day))
    .searchable(text: $store.historySearch, placement: .toolbar, prompt: "搜索历史记录")
    .toolbar { toolbar }
    .inspector(isPresented: Binding(get: { selection != nil }, set: { if !$0 { selection = nil } })) {
      inspector
        .inspectorColumnWidth(min: 300, ideal: 360, max: 520)
        // 检查器打开后要有地方关掉它（以前只能按 Esc，2026-11-10 用户报告）。放在检查器自己的工具栏里。
        .toolbar {
          ToolbarItem(placement: .primaryAction) {
            Button { selection = nil } label: { PhIcon("sidebar-simple", size: PhIcon.toolbar).scaleEffect(x: -1) }
              .help("隐藏详情").accessibilityLabel("隐藏详情").keyboardShortcut("i", modifiers: [.command, .option])
          }
        }
    }
    .sheet(isPresented: $note) { NoteSheet { store.revision += 1 } }
    .task(id: LoadKey(day: day, revision: store.revision)) { await loadDay() }
    .task(id: store.historySearch) { await search(reset: true) }
    .onChange(of: day) { brush = nil; lane = nil; selection = nil; expanded = [] }
    .onAppear { consumeFocus() }
    .onChange(of: store.historyFocus) { consumeFocus() }
    .onChange(of: records) { consumeFocus() }
    // 详情栏打开时列表变窄、行高变了，滚动位置会跳到别处（用户点了 13:37 那段，列表跳到 10:41）。打开后把点的那一行滚回来。
    .onChange(of: selection == nil) { closed, isClosed in
      guard closed, !isClosed, let target = rowID(for: selection) else { return }
      Task { try? await Task.sleep(for: .milliseconds(300)); scrollTarget = target }
    }
    .onKeyPress(.escape) { if selection != nil { selection = nil; return .handled }; if brush != nil { brush = nil; return .handled }; return .ignored }
  }

  @ViewBuilder var inspector: some View {
    switch selection {
    case .segment(let id)?:
      if let block = allBlocks.first(where: { $0.id == id }) {
        SegmentInspector(block: block).id(id)
      }
    case .record(let id)?:
      // 从段里点进来的记录可以回到那一段。
      let parent = isSearch ? nil : allBlocks.first { $0.segment.recordIds.contains(id) }
      RecordInspector(id: id, back: parent.map { b in .init(title: SegmentText.title(b)) { selection = .segment(b.id) } }) { deleted in
        records.removeAll { deleted.contains($0.id) }
        results.removeAll { deleted.contains($0.id) }
        selection = nil
      }
      .id(id)
    case nil:
      EmptyView()
    }
  }

  struct LoadKey: Equatable { let day: Date; let revision: Int }

  func consumeFocus() {
    guard let id = store.historyFocus, loadedDay == day, !loading else { return }
    if records.contains(where: { $0.id == id }) {
      lane = nil; brush = nil
      reveal(id)
      store.historyFocus = nil
    } else {
      // 不在当天列表里（例如修正记录），直接在检查器里打开。
      selection = .record(id); store.historyFocus = nil
    }
  }

  // MARK: 读取

  func loadDay() async {
    let requestedDay = day
    loading = true; error = nil
    defer {
      if !Task.isCancelled, day == requestedDay {
        loadedDay = requestedDay
        loading = false
        consumeFocus()
      }
    }
    do {
      async let r = store.api.day(requestedDay)
      async let s = store.api.segments(requestedDay)
      async let d = store.api.diary(requestedDay)
      let (rows, segs, diary) = try await (r, s, d)
      guard !Task.isCancelled, day == requestedDay else { return }
      segments = segs.segments; conversations = segs.conversations
      records = rows.sorted { ($0.start, $0.id) > ($1.start, $1.id) }
      self.diary = diary
    } catch is CancellationError {
    } catch {
      guard !Task.isCancelled, day == requestedDay else { return }
      self.error = error.localizedDescription; records = []; segments = []; conversations = []; diary = nil
    }
  }

  func search(reset: Bool) async {
    guard isSearch else { results = []; cursor = nil; return }
    if reset { try? await Task.sleep(for: .milliseconds(280)); if Task.isCancelled { return } }
    searching = true; defer { searching = false }
    do {
      var q = HubAPI.RecordQuery(); q.q = store.historySearch.trimmingCharacters(in: .whitespaces); q.limit = 50; q.body = true
      let page = try await store.api.records(q, cursor: reset ? nil : cursor)
      results = reset ? page.records : results + page.records.filter { r in !results.contains { $0.id == r.id } }
      cursor = page.nextCursor
      error = nil
    } catch is CancellationError {
    } catch { self.error = error.localizedDescription }
  }

  // MARK: 一天

  @ViewBuilder var dayList: some View {
    let blocks = self.blocks
    LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
      dayHeader
        .padding(.horizontal, 32).padding(.top, 24).padding(.bottom, 16)
      Section {
        if loading && records.isEmpty {
          Placeholder(kind: .loading).frame(height: 240)
        } else if let error, records.isEmpty {
          Placeholder(kind: .error(error) { store.revision += 1 }).frame(height: 240)
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

  var dayHeader: some View {
    VStack(alignment: .leading, spacing: 12) {
      ViewThatFits(in: .horizontal) {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
          dateTitle
          Spacer(minLength: 16)
          if !records.isEmpty { stats }
        }
        VStack(alignment: .leading, spacing: 8) {
          dateTitle
          if !records.isEmpty { stats }
        }
      }
      if loadedDay == day, let summary = diary?.summary {
        Text(summary)
          .font(.serif(TextSize.title))
          .lineSpacing(TextSize.serifLineSpacing(TextSize.title))
          .foregroundStyle(Palette.ink)
          .lineLimit(2)
          .textSelection(.enabled)
          .fixedSize(horizontal: false, vertical: true)
          .frame(maxWidth: 760, alignment: .leading)
      }
      Button("查看当天回顾") { store.showReview(day) }.buttonStyle(.accentLink).font(.system(size: TextSize.body))
    }
  }

  var dateTitle: some View {
    HStack(alignment: .firstTextBaseline, spacing: 12) {
      Text(longDate).font(.serif(TextSize.heading, .semibold)).foregroundStyle(Palette.ink)
      Text(ViewerFormat.weekday(day)).font(.serif(TextSize.heading)).foregroundStyle(Palette.muted)
    }
    .lineLimit(1)
    .fixedSize()
  }

  var longDate: String {
    let c = Calendar.current.dateComponents([.year, .month, .day], from: day)
    let year = c.year != Calendar.current.component(.year, from: Date()) ? "\(c.year!) 年 " : ""
    return "\(year)\(c.month!) 月 \(c.day!) 日"
  }

  /// 段数是列表里的活动段（包括折起来的零碎段）；活跃时长是当天所有记录时段的并集，重叠只算一次。
  var stats: some View {
    let active = ActiveTime.seconds(records)
    return Text("\(Fmt.count(allBlocks.count)) 段活动，活跃 \(Fmt.duration(active))")
      .font(.system(size: TextSize.body)).monospacedDigit().foregroundStyle(Palette.muted)
      .lineLimit(1).fixedSize()
      .help("活跃时长按记录覆盖的时段算，几个来源同时在记录只算一次")
  }

  var strataHeader: some View {
    VStack(alignment: .leading, spacing: 8) {
      DayStrata(records: records.filter { device == nil || $0.device == device }, chapters: chapters, day: day, selected: selectedRecord,
                brush: $brush, lane: $lane,
                conversationTitles: Dictionary(conversations.flatMap { c in c.title.map { t in c.recordIds.map { ($0, t) } } ?? [] }, uniquingKeysWith: { a, _ in a })) { r in reveal(r.id) }
      if brush != nil || lane != nil {
        HStack(spacing: 8) {
          if let b = brush { chip("\(ViewerFormat.clock(b.lowerBound))–\(ViewerFormat.clock(b.upperBound))", "clock") { brush = nil } }
          if let l = lane { chip(l.name, "funnel-simple") { lane = nil } }
          Text("\(Fmt.count(visible.count)) 条记录").font(.system(size: TextSize.caption)).monospacedDigit().foregroundStyle(Palette.muted)
        }
        .transition(.opacity)
      }
    }
    .padding(.horizontal, 20).padding(.vertical, 12)
    .background {
      Rectangle().fill(Palette.paper)
        .overlay(alignment: .bottom) { Rectangle().fill(Palette.hairline).frame(height: 1) }
    }
    .zIndex(2)
    .animation(.easeOut(duration: 0.2), value: brush != nil || lane != nil)
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
    ForEach(Array(items.enumerated()), id: \.element.id) { i, item in
      let hour = cal.component(.hour, from: item.start)
      if i == 0 || cal.component(.hour, from: items[i - 1].start) != hour {
        HourMark(hour: hour).padding(.top, i == 0 ? 4 : 12).padding(.horizontal, 20)
      }
      switch item {
      case .single(let block):
        segmentRow(block)
      case .minor(let group):
        MinorSegmentsRow(blocks: group, expanded: expanded.contains(item.id)) {
          withAnimation(.easeOut(duration: 0.2)) { if expanded.contains(item.id) { expanded.remove(item.id) } else { expanded.insert(item.id) } }
        }
        .padding(.horizontal, 20)
        .id(item.id)
        if expanded.contains(item.id) {
          ForEach(group) { block in segmentRow(block) }
        }
      }
    }
  }

  @ViewBuilder func segmentRow(_ block: SegmentBlock) -> some View {
    SegmentRow(block: block, conversation: conversationNote(block), selected: selection == .segment(block.id), expanded: expanded.contains(block.id)) {
      withAnimation(.easeOut(duration: 0.2)) { if expanded.contains(block.id) { expanded.remove(block.id) } else { expanded.insert(block.id) } }
      selection = .segment(block.id)
    }
    .padding(.horizontal, 20)
    .id(block.id)
    if expanded.contains(block.id) {
      ForEach(RecordRuns.collapse(block.records, conversations: conversations)) { run in
        RecordRow(record: run.newest, run: run, selected: run.records.contains { $0.id == selectedRecord }, expanded: false, nested: true) {
          selection = .record(run.newest.id)
        }
        .padding(.horizontal, 20)
        .id(run.id)
        .transition(.opacity)
      }
      Color.clear.frame(height: 8)
    }
  }

  /// 段里第一场有总结的对话的标题。
  func conversationNote(_ block: SegmentBlock) -> String? {
    let ids = Set(block.records.filter { $0.source == "mac.audio" }.map(\.id))
    guard !ids.isEmpty else { return nil }
    return conversations.first { c in c.title != nil && c.recordIds.contains(where: ids.contains) }?.title
  }

  func searchRows(_ rows: [HistoryRecord]) -> some View {
    ForEach(rows) { r in
      RecordRow(record: r, run: nil, selected: selectedRecord == r.id, expanded: false,
                snippet: SearchSnippet.make(r.body ?? "", query: store.historySearch)) { selection = .record(r.id) }
        .padding(.horizontal, 20)
        .id(r.id)
    }
  }

  // MARK: 搜索

  @ViewBuilder var searchList: some View {
    LazyVStack(alignment: .leading, spacing: 0) {
      if results.isEmpty {
        if searching { Placeholder(kind: .loading).frame(height: 300) }
        else if let error { Placeholder(kind: .error(error) { Task { await search(reset: true) } }).frame(height: 300) }
        else { Placeholder(kind: .empty("magnifying-glass", "没有找到「\(store.historySearch)」")).frame(height: 300) }
      } else {
        let groups = Dictionary(grouping: results) { Calendar.current.startOfDay(for: $0.start) }.sorted { $0.key > $1.key }
        ForEach(groups, id: \.key) { day, rows in
          HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(ViewerFormat.dayTitle(day)).font(.serif(TextSize.title, .semibold)).foregroundStyle(Palette.ink)
            Text(ViewerFormat.weekday(day)).font(.serif(TextSize.title)).foregroundStyle(Palette.muted)
            Spacer()
            Button("打开这一天") { store.historySearch = ""; store.historyDay = day }.buttonStyle(.accentLink).font(.system(size: TextSize.body))
          }
          .padding(.horizontal, 32).padding(.top, 24).padding(.bottom, 8)
          searchRows(rows.sorted { $0.start > $1.start })
        }
        if cursor != nil {
          ProgressView().controlSize(.small).frame(maxWidth: .infinity).padding(24)
            .onAppear { Task { await search(reset: false) } }
        }
      }
    }
    .padding(.bottom, 40)
  }

  // MARK: 工具栏

  @ToolbarContentBuilder var toolbar: some ToolbarContent {
    if !isSearch {
      DayNavigation(day: Binding(get: { day }, set: { store.historyDay = $0 }), picking: $picking)
    }
    ToolbarItemGroup(placement: .primaryAction) {
      if !isSearch {
        Menu {
          Picker("来源", selection: $lane) {
            Text("全部来源").tag(Lane?.none)
            ForEach(Lane.allCases.filter { l in records.contains { Lane.of($0.source) == l } }, id: \.self) { Text($0.name).tag(Lane?.some($0)) }
          }
          .pickerStyle(.inline)
          let devices = Set(records.map(\.device)).sorted()
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
      }
      Button { note = true } label: { PhIcon("note-pencil", size: PhIcon.toolbar) }
        .help("补写一条记录").accessibilityLabel("补写一条记录").keyboardShortcut("n", modifiers: .command)
    }
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
  let action: () -> Void
  @State private var hovering = false

  var body: some View {
    Button(action: action) {
      HStack(alignment: .center, spacing: 12) {
        Text(timeText)
          .font(.system(size: TextSize.caption)).monospacedDigit()
          .foregroundStyle(Palette.muted)
          .frame(width: Self.timeWidth, alignment: .trailing)
          .lineLimit(1)
        Group {
          if nested { Circle().fill(Palette.faint).frame(width: 5, height: 5) }
          else { SourceGlyph(source: record.source, app: record.contextText("app"), size: 22) }
        }
        .frame(width: 26)
        VStack(alignment: .leading, spacing: 2) {
          HStack(spacing: 8) {
            Text(run?.conversation.map(ConversationText.title) ?? RecordText.title(record, appShown: !nested))
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
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .onHover { hovering = $0 }
  }

  @ViewBuilder var badges: some View {
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
