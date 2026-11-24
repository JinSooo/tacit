import SwiftUI
import CollectorCore

enum TimelineDensity: String {
  static let preferenceKey = "viewer.timelineDensity"
  case compact, detailed
}

enum TimelineReadingLayout {
  // 与原始记录行共用时间列和轴心，展开后仍是同一条时间线。
  static let width: CGFloat = 800
  static let edge: CGFloat = 8
  static let timeWidth = RecordRow.timeWidth
  static let markerWidth: CGFloat = 26
  static let gap: CGFloat = 12
  static let gutter = gap + markerWidth + gap
  static let axis = edge + timeWidth + gap + (markerWidth - 1) / 2
  static let contentInset = edge + timeWidth + gutter
}

struct TimelineSegmentRow: View {
  let day: Date
  let item: DayDiary.Item
  var records: [HistoryRecord]? = nil
  var showsTitle = true
  var projectName: String? = nil
  var offersThreadStory = false
  var isDraft = false
  var isOrganizing = false
  let expanded: Bool
  let onToggle: () -> Void
  @State private var hovering = false

  private var rowPadding: CGFloat { showsTitle ? 12 : 14 }
  private var time: String {
    showsTitle ? item.start.map { ReviewTime.clock($0, on: day) } ?? "" : ReviewTime.range(item, on: day)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      Button { Motion.animate { onToggle() } } label: {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
          HStack(spacing: 4) {
            Text(time).font(.system(size: TextSize.caption)).monospacedDigit().foregroundStyle(Palette.muted)
            if isOrganizing {
              ProgressView().controlSize(.mini).accessibilityLabel("正在整理").transition(.opacity)
            }
          }
          .frame(width: TimelineReadingLayout.timeWidth, alignment: showsTitle ? .leading : .trailing)
          .padding(.trailing, TimelineReadingLayout.gutter)
          VStack(alignment: .leading, spacing: 8) {
            if showsTitle {
              // 草稿整理好后原位换成正式标题：字重渐变、文字交叉淡入，看得出“这段刚整理好”。
              Text(item.title).font(.system(size: TextSize.title, weight: isDraft ? .regular : .medium)).foregroundStyle(Palette.ink)
                .contentTransition(.interpolate)
            }
            description
            HStack(spacing: showsTitle ? 6 : 8) {
              TimelineSourceIcons(item: item, size: showsTitle ? 14 : 20).fixedSize()
              projectLabel
            }
          }
          .fixedSize(horizontal: false, vertical: true)
          .frame(maxWidth: .infinity, alignment: .leading)
          DisclosureChevron(expanded: expanded)
            .opacity(showsTitle && !hovering && !expanded ? 0 : 1)
            .foregroundStyle(Palette.muted).padding(.leading, 16).accessibilityHidden(true)
        }
        .multilineTextAlignment(.leading)
        .padding(.horizontal, TimelineReadingLayout.edge)
        .padding(.vertical, rowPadding)
        .contentShape(Rectangle())
      }
      .buttonStyle(TimelineRowStyle())
      .hoverState($hovering)
      .accessibilityValue(expanded ? "已展开" : "已折叠")
      .accessibilityHint(expanded ? "收起原始记录" : "展开原始记录")
      if expanded {
        TimelineSegmentRecords(day: day, item: item, dayRecords: records, alignsTimeLeading: showsTitle,
                               offersThreadStory: offersThreadStory, isDraft: isDraft)
          .padding(.bottom, 16)
          .transition(.reveal)
      }
    }
    .background(alignment: .leading) {
      Rectangle().fill(Palette.hairline).frame(width: 1)
        .offset(x: TimelineReadingLayout.axis)
        .accessibilityHidden(true).allowsHitTesting(false)
    }
    .overlay(alignment: .topLeading) {
      // 同一个圆点：草稿是空心环，整理好后原位填实；展开时染成铜绿。
      let color = expanded ? Palette.accent : Palette.muted
      let diameter: CGFloat = isDraft ? 7 : 5
      Circle().fill(isDraft ? Palette.paper : color)
        .overlay(Circle().strokeBorder(color, lineWidth: isDraft ? 1 : 0))
        .frame(width: diameter, height: diameter)
        .offset(x: TimelineReadingLayout.axis - (diameter - 1) / 2, y: rowPadding + 9.5 - diameter / 2)
        .animation(Motion.standard, value: isDraft)
        .animation(Motion.quick, value: expanded)
        .accessibilityHidden(true).allowsHitTesting(false)
    }
  }

  @ViewBuilder private var description: some View {
    if !item.description.isEmpty {
      Text(item.description).font(.system(size: TextSize.body))
        .lineSpacing(TextSize.lineSpacing(TextSize.body) + 2)
        .foregroundStyle(Palette.readingBody)
        .contentTransition(.opacity)
    }
  }

  @ViewBuilder private var projectLabel: some View {
    if let projectName {
      Text(projectName).font(.system(size: TextSize.caption)).foregroundStyle(Palette.muted)
        .fixedSize(horizontal: false, vertical: true)
    }
  }
}

struct TimelineSourceIcons: View {
  let item: DayDiary.Item
  var size: CGFloat = 16

  private var icons: [DayDiary.Item.App] {
    let apps = (item.apps ?? []).filter { $0.app?.isEmpty == false }
    let appSources = Set(apps.map(\.source))
    let candidates = apps + item.sources.filter { !appSources.contains($0) }
      .map { DayDiary.Item.App(source: $0, app: nil) }
    var seen = Set<String>()
    return candidates.filter {
      seen.insert(SourceApplication.bundle(app: $0.app, source: $0.source)?.lowercased() ?? $0.source).inserted
    }
  }

  private func label(for app: DayDiary.Item.App) -> String {
    let bundle = SourceApplication.bundle(app: app.app, source: app.source)
    if let name = AppIcons.name(bundle) { return name }
    if let raw = app.app, !raw.isEmpty, !raw.contains(".") { return raw }
    return SourceInfo.name(app.source)
  }

  var body: some View {
    HStack(spacing: size == 20 ? 8 : 6) {
      ForEach(Array(icons.prefix(3)), id: \.self) { app in
        let text = label(for: app)
        SourceGlyph(source: app.source, app: SourceApplication.bundle(app: app.app, source: app.source), size: size, showsTile: true)
          .help(text).accessibilityLabel(text)
      }
    }
    .help(icons.map(label(for:)).joined(separator: "、"))
  }
}

struct TimelineRowStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label.background(configuration.isPressed ? Palette.fill : Color.clear)
      .pressFeedback(configuration.isPressed)
  }
}

struct TimelineSegmentRecords: View {
  let day: Date
  let item: DayDiary.Item
  let dayRecords: [HistoryRecord]?
  var alignsTimeLeading = false
  var offersThreadStory = false
  var isDraft = false

  @Environment(ViewerStore.self) private var store
  @State private var records = Loader<[HistoryRecord]>(animated: true)
  @State private var showsBackgroundRecords = false
  @State private var correcting = false
  @State private var confirmsDeletion = false
  @State private var deletionMembers: [String]?
  @State private var deleting = false
  @State private var deleteError: String?

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      if let rows = records.value {
        let groups = ReviewActivity.segmentRecords(rows)
        recordRows(groups.visible, total: rows.count)
        if !groups.collapsed.isEmpty {
          DisclosureGroup("另有 \(Fmt.count(groups.collapsed.count)) 条屏幕和网页记录", isExpanded: $showsBackgroundRecords) {
            recordRows(groups.collapsed, total: rows.count)
          }
          .disclosureGroupStyle(TimelineRecordDisclosureStyle())
        }
      } else if let error = records.error {
        Text(error).foregroundStyle(Palette.attention).padding(.leading, TimelineReadingLayout.contentInset)
        Button("重试") { Task { await load() } }.buttonStyle(.accentLink).padding(.leading, TimelineReadingLayout.contentInset)
      } else {
        DelayedProgress(label: "正在读取原始记录").padding(.leading, TimelineReadingLayout.contentInset)
      }
      HStack(spacing: 16) {
        if offersThreadStory, let threadId = item.threadId {
          Button("这件事的经过") { store.path.append(.threadStory(threadId)) }.buttonStyle(.accentLink)
        }
        if !isDraft {
          Button("这段写得不对") { correcting = true }.buttonStyle(.accentLink)
          Button("删除这段记录") {
            guard let members = item.recordIds, !members.isEmpty else { return }
            deletionMembers = members
            confirmsDeletion = true
          }
          .buttonStyle(.accentLink).disabled(deleting || item.recordIds?.isEmpty != false)
        }
      }
      .padding(.leading, TimelineReadingLayout.contentInset)
      if let deleteError {
        Text(deleteError).padding(.leading, TimelineReadingLayout.contentInset).foregroundStyle(Palette.attention)
      }
    }
    .font(.system(size: TextSize.caption))
    .task(id: item.recordIds) { await load() }
    .sheet(isPresented: $correcting) { SegmentCorrectionSheet(day: day, item: item) }
    .confirmationDialog("删除这段记录？", isPresented: $confirmsDeletion, titleVisibility: .visible, presenting: deletionMembers) { members in
      Button("删除", role: .destructive) { Task { await delete(recordIds: members) } }
      Button("取消", role: .cancel) {}
    } message: { members in
      Text("这段包含的 \(Fmt.count(members.count)) 条记录会永久删除。")
    }
  }

  private func recordRows(_ rows: [HistoryRecord], total: Int) -> some View {
    ForEach(rows) { record in
      RecordRow(record: record, run: nil, selected: false, expanded: false, nested: true,
                titleOverride: sourceTitle(for: record, count: total), alignsTimeLeading: alignsTimeLeading) {
        store.path.append(.reviewRecord(record.id))
      }
    }
  }

  private func sourceTitle(for record: HistoryRecord, count: Int) -> String? {
    guard TimelinePresence.repeatsTitle(recordCount: item.recordIds?.count ?? count,
      recordTitle: record.title, segmentTitle: item.title) else { return nil }
    let bundle = SourceApplication.bundle(app: record.contextText("app"), source: record.source)
    if let name = AppIcons.name(bundle) { return name }
    if let raw = record.contextText("app"), !raw.contains(".") { return raw }
    return SourceInfo.name(record.source)
  }

  private func load() async {
    await records.run {
      guard let ids = item.recordIds else { return [] }
      let rows: [HistoryRecord]
      if let dayRecords {
        let idSet = Set(ids)
        let found = dayRecords.filter { idSet.contains($0.id) }
        let missing = try await store.dataSource.missingRecords(ids, from: found)
        rows = found + missing
      } else {
        rows = try await store.dataSource.recordsByIDs(ids)
      }
      return rows.filter { !isDraft || $0.sensitivity != "private" }
        .sorted { ($0.start, $0.id) > ($1.start, $1.id) }
    }
  }

  private func delete(recordIds: [String]) async {
    deleteError = nil
    deleting = true
    defer { deleting = false }
    do {
      try await store.api.deleteSegment(day: day, id: item.id, recordIds: recordIds)
      store.revision += 1
    } catch {
      let message = error.localizedDescription
      Motion.animate { deleteError = message }
    }
  }
}

private struct TimelineRecordDisclosureStyle: DisclosureGroupStyle {
  func makeBody(configuration: Configuration) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      Button {
        Motion.animate { configuration.isExpanded.toggle() }
      } label: {
        HStack(spacing: 8) {
          DisclosureChevron(expanded: configuration.isExpanded, sideways: true)
          configuration.label
        }
        .foregroundStyle(Palette.muted)
        .padding(.vertical, 4)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityValue(configuration.isExpanded ? "已展开" : "已折叠")
      .padding(.leading, TimelineReadingLayout.contentInset)
      if configuration.isExpanded { configuration.content.transition(.reveal) }
    }
  }
}

private struct SegmentCorrectionSheet: View {
  let day: Date
  let item: DayDiary.Item

  @Environment(\.dismiss) private var dismiss
  @Environment(ViewerStore.self) private var store
  @State private var text = ""
  @State private var busy = false
  @State private var error: String?
  private var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("这段写得不对").font(.system(size: TextSize.title, weight: .semibold))
      TextEditor(text: $text)
        .font(.system(size: TextSize.body))
        .scrollContentBackground(.hidden).padding(8).card(Radius.control).frame(minHeight: 105)
        .accessibilityLabel("这段活动的描述")
      if let error {
        Text(error).font(.system(size: TextSize.body)).foregroundStyle(Palette.attention)
      }
      HStack {
        Spacer()
        Button("取消") { dismiss() }.keyboardShortcut(.cancelAction).disabled(busy)
        Button(busy ? "正在保存…" : "保存") { Task { await save() } }
          .buttonStyle(.accent).keyboardShortcut(.defaultAction)
          .disabled(busy || trimmed.isEmpty || trimmed == item.description)
      }
    }
    .padding(24).frame(width: 480)
    .onAppear { text = item.description }
    .interactiveDismissDisabled(busy)
  }

  private func save() async {
    busy = true
    defer { busy = false }
    do {
      try await store.api.correctSegment(day: day, id: item.id, description: trimmed)
      store.revision += 1
      dismiss()
    } catch {
      self.error = error.localizedDescription
    }
  }
}
