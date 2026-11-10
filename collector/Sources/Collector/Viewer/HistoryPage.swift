import AppKit
import SwiftUI
import CollectorCore

/// 一天的 History：列表按活动段聚合（线程或应用），展开才是原始记录；搜索时按记录显示命中。
struct HistoryPage: View {
  enum Selection: Hashable { case segment(String), record(String) }

  @Environment(ViewerStore.self) private var store
  @State private var records: [HistoryRecord] = []
  @State private var segments: [HistorySegment] = []
  @State private var diary: DayDiary?
  @State private var loading = false
  @State private var error: String?
  @State private var selection: Selection?
  @State private var expanded: Set<String> = []
  @State private var scrollTarget: String?
  @State private var brush: ClosedRange<Date>?
  @State private var lane: Lane?
  @State private var device: String?
  @AppStorage("historyDiaryExpanded") private var showDiary = false
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
        withAnimation(.smooth) { proxy.scrollTo(id, anchor: .center) }
        scrollTarget = nil
      }
    }
    .navigationTitle(isSearch ? "搜索" : ViewerFormat.dayTitle(day))
    .navigationSubtitle(isSearch ? "" : ViewerFormat.weekday(day))
    .searchable(text: $store.historySearch, placement: .toolbar, prompt: "搜索 History")
    .toolbar { toolbar }
    .inspector(isPresented: Binding(get: { selection != nil }, set: { if !$0 { selection = nil } })) {
      inspector
        .inspectorColumnWidth(min: 300, ideal: 360, max: 520)
    }
    .sheet(isPresented: $note) { NoteSheet { store.revision += 1 } }
    .task(id: LoadKey(day: day, revision: store.revision)) { await loadDay() }
    .task(id: store.historySearch) { await search(reset: true) }
    .onChange(of: day) { brush = nil; lane = nil; selection = nil; expanded = [] }
    .onAppear { consumeFocus() }
    .onChange(of: store.historyFocus) { consumeFocus() }
    .onChange(of: records) { consumeFocus() }
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
    guard let id = store.historyFocus else { return }
    if records.contains(where: { $0.id == id }) {
      lane = nil; brush = nil
      reveal(id)
      store.historyFocus = nil
    } else if !loading, !records.isEmpty {
      // 不在当天列表里（例如修正记录），直接在检查器里打开。
      selection = .record(id); store.historyFocus = nil
    }
  }

  // MARK: 读取

  func loadDay() async {
    loading = true; error = nil
    defer { loading = false }
    do {
      async let r = store.api.day(day)
      async let s = store.api.segments(day)
      async let d = store.api.diary(day)
      let (rows, segs, diary) = try await (r, s, d)
      segments = segs
      records = rows.sorted { ($0.start, $0.id) > ($1.start, $1.id) }
      self.diary = diary
    } catch is CancellationError {
    } catch { self.error = error.localizedDescription; records = []; segments = []; diary = nil }
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
        .padding(.horizontal, 32).padding(.top, 26).padding(.bottom, 18)
      Section {
        if loading && records.isEmpty {
          Placeholder(kind: .loading).frame(height: 240)
        } else if let error, records.isEmpty {
          Placeholder(kind: .error(error) { store.revision += 1 }).frame(height: 240)
        } else if records.isEmpty {
          Placeholder(kind: .empty("moon-stars", "这一天没有记录")).frame(height: 260)
        } else if blocks.isEmpty {
          Placeholder(kind: .empty("funnel-simple", "筛选后没有记录")).frame(height: 200)
        } else {
          // 修饰符加在 ForEach 上会分发给每一行，留白用独立的占位视图。
          Color.clear.frame(height: 6)
          segmentRows(blocks)
          Color.clear.frame(height: 40)
        }
      } header: {
        if !records.isEmpty { strataHeader }
      }
    }
  }

  var dayHeader: some View {
    VStack(alignment: .leading, spacing: 14) {
      ViewThatFits(in: .horizontal) {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
          dateTitle
          Spacer(minLength: 16)
          if !records.isEmpty { stats }
        }
        VStack(alignment: .leading, spacing: 10) {
          dateTitle
          if !records.isEmpty { stats }
        }
      }
      if let summary = diary?.detail?.summary ?? diary?.brief, !summary.isEmpty {
        VStack(alignment: .leading, spacing: 8) {
          Text(summary)
            .font(.serif(15.5))
            .lineSpacing(5)
            .foregroundStyle(Palette.ink.opacity(0.88))
            .lineLimit(showDiary ? nil : 2)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
          Button(showDiary ? "收起日记" : "展开日记") { withAnimation(.smooth) { showDiary.toggle() } }
            .buttonStyle(.link).font(.caption)
        }
        .frame(maxWidth: 760, alignment: .leading)
        .padding(.leading, 14)
        .overlay(alignment: .leading) { Capsule().fill(Palette.accent.opacity(0.5)).frame(width: 2.5) }
      }
    }
  }

  var dateTitle: some View {
    HStack(alignment: .firstTextBaseline, spacing: 12) {
      Text(longDate).font(.serif(30, .semibold)).foregroundStyle(Palette.ink)
      Text(ViewerFormat.weekday(day)).font(.serif(17)).foregroundStyle(.secondary)
    }
    .lineLimit(1)
    .fixedSize()
  }

  var longDate: String {
    let c = Calendar.current.dateComponents([.year, .month, .day], from: day)
    let year = c.year != Calendar.current.component(.year, from: Date()) ? "\(c.year!) 年 " : ""
    return "\(year)\(c.month!) 月 \(c.day!) 日"
  }

  var stats: some View {
    let active = activeSeconds(records)
    return HStack(spacing: 18) {
      stat(String(allBlocks.count), "段活动")
      stat(ViewerFormat.compact(active), "活跃")
      if let first = records.map(\.start).min() { stat(ViewerFormat.clock(first), "开始") }
    }
  }
  func stat(_ value: String, _ label: String) -> some View {
    VStack(alignment: .trailing, spacing: 1) {
      Text(value).font(.system(size: 17, weight: .semibold, design: .rounded)).monospacedDigit()
      Text(label).font(.system(size: 10.5)).foregroundStyle(.secondary)
    }
    .lineLimit(1)
    .fixedSize()
  }

  /// 并集时长：重叠的时段只算一次。
  func activeSeconds(_ rows: [HistoryRecord]) -> TimeInterval {
    let spans = rows.compactMap { r in r.end.map { (r.start, $0) } }.filter { $0.1 > $0.0 }.sorted { $0.0 < $1.0 }
    var total: TimeInterval = 0, cur: (Date, Date)?
    for s in spans {
      if let c = cur, s.0 <= c.1 { cur = (c.0, max(c.1, s.1)) }
      else { if let c = cur { total += c.1.timeIntervalSince(c.0) }; cur = s }
    }
    if let c = cur { total += c.1.timeIntervalSince(c.0) }
    return total
  }

  var strataHeader: some View {
    VStack(alignment: .leading, spacing: 8) {
      DayStrata(records: records.filter { device == nil || $0.device == device }, chapters: chapters, day: day, selected: selectedRecord,
                brush: $brush, lane: $lane) { r in reveal(r.id) }
      if brush != nil || lane != nil {
        HStack(spacing: 8) {
          if let b = brush { chip("\(ViewerFormat.clock(b.lowerBound))–\(ViewerFormat.clock(b.upperBound))", "clock") { brush = nil } }
          if let l = lane { chip(l.title, "funnel-simple") { lane = nil } }
          Text("\(visible.count) 条").font(.caption).foregroundStyle(.secondary)
        }
        .transition(.opacity.combined(with: .move(edge: .top)))
      }
    }
    .padding(.horizontal, 20).padding(.top, 12).padding(.bottom, 12)
    .background {
      Rectangle().fill(.bar)
        .overlay(alignment: .bottom) { Rectangle().fill(Palette.hairline).frame(height: 1) }
    }
    .zIndex(2)
    .animation(.smooth(duration: 0.2), value: brush != nil || lane != nil)
  }

  func chip(_ text: String, _ symbol: String, clear: @escaping () -> Void) -> some View {
    Button(action: clear) {
      HStack(spacing: 5) {
        PhIcon(symbol, size: 13.5)
        Text(text).monospacedDigit()
        PhIcon("x", size: 10).opacity(0.6)
      }
      .font(.system(size: 11, weight: .medium))
      .padding(.horizontal, 9).padding(.vertical, 4)
      .foregroundStyle(Palette.accent)
      .background(Palette.accent.opacity(0.12), in: Capsule())
    }
    .buttonStyle(.plain)
  }

  // MARK: 行

  /// 每段一张卡片；展开后列出原始记录（相邻同标题的合成一行）。连续的零碎段折成一行"其他 N 段"。
  @ViewBuilder func segmentRows(_ blocks: [SegmentBlock]) -> some View {
    let cal = Calendar.current
    let items = SegmentFold.fold(blocks)
    ForEach(Array(items.enumerated()), id: \.element.id) { i, item in
      let hour = cal.component(.hour, from: item.start)
      if i == 0 || cal.component(.hour, from: items[i - 1].start) != hour {
        HourMark(hour: hour).padding(.top, i == 0 ? 4 : 14).padding(.horizontal, 20)
      }
      switch item {
      case .single(let block):
        segmentRow(block)
      case .minor(let group):
        MinorSegmentsRow(blocks: group, expanded: expanded.contains(item.id)) {
          withAnimation(.smooth(duration: 0.25)) { if expanded.contains(item.id) { expanded.remove(item.id) } else { expanded.insert(item.id) } }
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
    SegmentRow(block: block, selected: selection == .segment(block.id), expanded: expanded.contains(block.id)) {
      withAnimation(.smooth(duration: 0.25)) { if expanded.contains(block.id) { expanded.remove(block.id) } else { expanded.insert(block.id) } }
      selection = .segment(block.id)
    }
    .padding(.horizontal, 20)
    .id(block.id)
    if expanded.contains(block.id) {
      ForEach(RecordRuns.collapse(block.records)) { run in
        RecordRow(record: run.newest, run: run, selected: run.records.contains { $0.id == selectedRecord }, expanded: false, nested: true) {
          selection = .record(run.newest.id)
        }
        .padding(.horizontal, 20)
        .id(run.id)
        .transition(.opacity)
      }
      Color.clear.frame(height: 6)
    }
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
            Text(ViewerFormat.dayTitle(day)).font(.serif(19, .semibold))
            Text(ViewerFormat.weekday(day)).font(.serif(13)).foregroundStyle(.secondary)
            Spacer()
            Button("看这一天") { store.historySearch = ""; store.historyDay = day }.buttonStyle(.link).font(.caption)
          }
          .padding(.horizontal, 32).padding(.top, 24).padding(.bottom, 6)
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
    ToolbarItemGroup(placement: .navigation) {
      if !isSearch {
        ControlGroup {
          Button { shift(-1) } label: { PhIcon("caret-left", size: PhIcon.toolbar) }.help("前一天").accessibilityLabel("前一天").keyboardShortcut("[", modifiers: .command)
          Button("今天") { store.historyDay = Calendar.current.startOfDay(for: Date()) }
            .disabled(Calendar.current.isDateInToday(day)).keyboardShortcut("t", modifiers: .command)
          Button { shift(1) } label: { PhIcon("caret-right", size: PhIcon.toolbar) }.help("后一天").accessibilityLabel("后一天").keyboardShortcut("]", modifiers: .command)
            .disabled(Calendar.current.isDateInToday(day))
        }
        Button { picking = true } label: { PhIcon("calendar-blank", size: PhIcon.toolbar) }
          .help("跳到日期").accessibilityLabel("跳到日期")
          .popover(isPresented: $picking, arrowEdge: .bottom) {
            DatePicker("", selection: Binding(get: { day }, set: { store.historyDay = Calendar.current.startOfDay(for: $0); picking = false }),
                       in: ...Date(), displayedComponents: .date)
              .datePickerStyle(.graphical).labelsHidden().padding(12)
              // 应用没声明中文本地化（会让中文标点变宽），日历的月份、星期在这里单独指定中文。
              .environment(\.locale, Locale(identifier: "zh_CN")).environment(\.calendar, ViewerCalendar.chinese)
          }
      }
    }
    ToolbarItemGroup(placement: .primaryAction) {
      if !isSearch {
        Menu {
          Picker("来源", selection: $lane) {
            Text("全部来源").tag(Lane?.none)
            ForEach(Lane.allCases.filter { l in records.contains { Lane.of($0.source) == l } }, id: \.self) { Text($0.title).tag(Lane?.some($0)) }
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
        .help("补写 History").accessibilityLabel("补写 History").keyboardShortcut("n", modifiers: .command)
    }
  }

  func shift(_ days: Int) {
    guard let d = Calendar.current.date(byAdding: .day, value: days, to: day), d <= Date() else { return }
    store.historyDay = Calendar.current.startOfDay(for: d)
  }
}

struct HourMark: View {
  let hour: Int
  var body: some View {
    HStack(spacing: 10) {
      Text(String(format: "%02d:00", hour)).font(.mono(10.5, .medium)).foregroundStyle(.tertiary)
        .frame(width: RecordRow.timeWidth, alignment: .trailing)
      Rectangle().fill(Palette.hairline).frame(height: 1)
    }
    .padding(.vertical, 6)
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
          .font(.mono(11))
          .foregroundStyle(.secondary)
          .frame(width: Self.timeWidth, alignment: .trailing)
          .lineLimit(1)
        Group {
          if nested { Circle().fill(Palette.source(record.source)).frame(width: 5, height: 5) }
          else { SourceGlyph(source: record.source, app: record.contextText("app"), size: 22) }
        }
        .frame(width: 26)
        VStack(alignment: .leading, spacing: 2) {
          HStack(spacing: 6) {
            Text(record.title.isEmpty ? SourceInfo.name(record.source) : record.title)
              .font(.system(size: nested ? 12 : 13, weight: nested ? .regular : .medium))
              .foregroundStyle(nested ? .secondary : .primary)
              .lineLimit(1)
            badges
          }
          if let snippet {
            (Text(snippet.before) + Text(snippet.match).foregroundStyle(Palette.accent).bold() + Text(snippet.after))
              .font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1)
          } else if !nested, let sub = subtitle {
            Text(sub).font(.system(size: 11)).foregroundStyle(.tertiary).lineLimit(1)
          }
        }
        Spacer(minLength: 8)
        if let run, run.records.count > 1 {
          HStack(spacing: 3) {
            Text("×\(run.records.count)").monospacedDigit()
            if !nested {
              PhIcon("caret-right", size: 10.5).rotationEffect(.degrees(expanded ? 90 : 0))
            }
          }
          .font(.system(size: 10.5, weight: .semibold))
          .foregroundStyle(.secondary)
          .padding(.horizontal, 6).padding(.vertical, 2)
          .background(.primary.opacity(0.06), in: Capsule())
        }
        if let d = durationText {
          Text(d).font(.system(size: 11)).monospacedDigit().foregroundStyle(.tertiary).frame(minWidth: 44, alignment: .trailing)
        }
      }
      .padding(.vertical, nested ? 3 : 6)
      .padding(.horizontal, 8)
      .background(alignment: .leading) {
        Rectangle().fill(Palette.hairline).frame(width: 1).padding(.leading, 8 + Self.timeWidth + 12 + 12.5)
      }
      .background {
        RoundedRectangle(cornerRadius: 9, style: .continuous)
          .fill(selected ? Palette.accent.opacity(0.13) : (hovering ? Color.primary.opacity(0.04) : .clear))
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .onHover { hovering = $0 }
  }

  @ViewBuilder var badges: some View {
    if record.capture?.method == "ocr" { badge("OCR") }
    if record.sensitivity == "redacted" || (record.redactions ?? 0) > 0 { badge("已脱敏", tint: .orange) }
    if record.sensitivity == "private" { PhIcon("lock", fill: true, size: 10).foregroundStyle(.secondary) }
  }
  func badge(_ text: String, tint: Color = .secondary) -> some View {
    Text(text).font(.system(size: 9, weight: .semibold)).foregroundStyle(tint)
      .padding(.horizontal, 4).padding(.vertical, 1)
      .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(tint.opacity(0.4), lineWidth: 0.5))
  }

  var timeText: String {
    let start = run?.start ?? record.start
    let end = run?.end ?? record.end
    if let end, ViewerFormat.clock(end) != ViewerFormat.clock(start), !nested || record.isSpan {
      return ViewerFormat.clock(start) + "–" + ViewerFormat.clock(end)
    }
    return ViewerFormat.clock(record.start)
  }

  var durationText: String? {
    let s = run?.seconds ?? record.seconds
    return s >= 1 ? ViewerFormat.compact(s) : nil
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
