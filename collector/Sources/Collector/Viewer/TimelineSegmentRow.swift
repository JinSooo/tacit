import SwiftUI
import CollectorCore

enum TimelineReadingLayout {
  // 与原始记录行共用时间列和轴心，展开后仍是同一条时间线。
  static let edge: CGFloat = 8
  static let timeWidth = RecordRow.timeWidth
  static let markerWidth: CGFloat = 26
  static let gap: CGFloat = 12
  static let gutter = gap + markerWidth + gap
  static let axis = edge + timeWidth + gap + (markerWidth - 1) / 2
  static let contentInset = edge + timeWidth + gutter
  static let rowPadding: CGFloat = 18
}

struct TimelineSegmentRow: View {
  let day: Date
  let item: DayDiary.Item
  var records: [HistoryRecord]? = nil
  var showsTitle = true
  var projectName: String? = nil
  let expanded: Bool
  let onToggle: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      Button(action: onToggle) {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
          Text(ReviewTime.range(item, on: day))
            .font(.system(size: TextSize.caption)).monospacedDigit().foregroundStyle(Palette.muted)
            .frame(width: TimelineReadingLayout.timeWidth, alignment: .trailing)
            .padding(.trailing, TimelineReadingLayout.gutter)
          VStack(alignment: .leading, spacing: 8) {
            if showsTitle {
              Text(item.title).font(.system(size: TextSize.title, weight: .medium)).foregroundStyle(Palette.ink)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(spacing: 12) {
              if let projectName {
                Text(projectName).font(.system(size: TextSize.caption)).foregroundStyle(Palette.muted)
                  .fixedSize(horizontal: false, vertical: true)
              }
              TimelineSourceIcons(item: item).fixedSize()
            }
            Text(item.description).font(.system(size: TextSize.body))
              .lineSpacing(TextSize.lineSpacing(TextSize.body)).foregroundStyle(Palette.ink)
          }
          .fixedSize(horizontal: false, vertical: true)
          .frame(maxWidth: .infinity, alignment: .leading)
          PhIcon(expanded ? "caret-up" : "caret-down", size: 11)
            .foregroundStyle(Palette.muted).padding(.leading, 16).accessibilityHidden(true)
        }
        .multilineTextAlignment(.leading)
        .padding(.horizontal, TimelineReadingLayout.edge)
        .padding(.vertical, TimelineReadingLayout.rowPadding)
        .contentShape(Rectangle())
      }
      .buttonStyle(TimelineRowStyle())
      .accessibilityValue(expanded ? "已展开" : "已折叠")
      .accessibilityHint(expanded ? "收起原始记录" : "展开原始记录")
      if expanded {
        TimelineSegmentRecords(day: day, item: item, dayRecords: records)
          .padding(.bottom, 16)
      }
    }
    .background(alignment: .leading) {
      Rectangle().fill(Palette.hairline).frame(width: 1)
        .offset(x: TimelineReadingLayout.axis)
        .accessibilityHidden(true).allowsHitTesting(false)
    }
    .overlay(alignment: .topLeading) {
      Circle().fill(expanded ? Palette.accent : Palette.muted)
        .frame(width: 5, height: 5)
        .offset(x: TimelineReadingLayout.axis - 2,
                y: TimelineReadingLayout.rowPadding + 7)
        .accessibilityHidden(true).allowsHitTesting(false)
    }
  }

}

struct TimelineSourceIcons: View {
  let item: DayDiary.Item

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

  var body: some View {
    HStack(spacing: 6) {
      ForEach(Array(icons.prefix(3)), id: \.self) { app in
        let label = AppIcons.name(SourceApplication.bundle(app: app.app, source: app.source)) ?? app.app ?? SourceInfo.name(app.source)
        SourceGlyph(source: app.source, app: SourceApplication.bundle(app: app.app, source: app.source), size: 16)
          .help(label).accessibilityLabel(label)
      }
    }
    .help(icons.map { AppIcons.name(SourceApplication.bundle(app: $0.app, source: $0.source)) ?? $0.app ?? SourceInfo.name($0.source) }.joined(separator: "、"))
  }
}

struct TimelineRowStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label.background(configuration.isPressed ? Palette.fill : Color.clear)
  }
}

struct TimelineSegmentRecords: View {
  let day: Date
  let item: DayDiary.Item
  let dayRecords: [HistoryRecord]?

  @Environment(ViewerStore.self) private var store
  @State private var records = Loader<[HistoryRecord]>()
  @State private var correcting = false
  @State private var confirmsDeletion = false
  @State private var deletionMembers: [String]?
  @State private var deleting = false
  @State private var deleteError: String?

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      if let rows = records.value {
        ForEach(rows) { record in
          RecordRow(record: record, run: nil, selected: false, expanded: false, nested: true, titleOverride: sourceTitle(for: record, count: rows.count)) {
            store.path.append(.reviewRecord(record.id))
          }
        }
      } else if let error = records.error {
        Text(error).foregroundStyle(Palette.attention).padding(.leading, TimelineReadingLayout.contentInset)
        Button("重试") { Task { await load() } }.buttonStyle(.accentLink).padding(.leading, TimelineReadingLayout.contentInset)
      } else {
        ProgressView().controlSize(.small).padding(.leading, TimelineReadingLayout.contentInset).accessibilityLabel("正在读取原始记录")
      }
      HStack(spacing: 16) {
        Button("这段写得不对") { correcting = true }.buttonStyle(.accentLink)
        Button("删除这段记录") {
          guard let members = item.recordIds, !members.isEmpty else { return }
          deletionMembers = members
          confirmsDeletion = true
        }
        .buttonStyle(.accentLink).disabled(deleting || item.recordIds?.isEmpty != false)
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

  private func sourceTitle(for record: HistoryRecord, count: Int) -> String? {
    guard TimelinePresence.repeatsTitle(recordCount: item.recordIds?.count ?? count,
      recordTitle: record.title, segmentTitle: item.title) else { return nil }
    let bundle = SourceApplication.bundle(app: record.contextText("app"), source: record.source)
    return AppIcons.name(bundle) ?? record.contextText("app") ?? SourceInfo.name(record.source)
  }

  private func load() async {
    await records.run {
      guard let ids = item.recordIds else { return [] }
      let idSet = Set(ids)
      let source: [HistoryRecord]
      if let dayRecords { source = dayRecords }
      else { source = try await store.api.day(day) }
      let found = source.filter { idSet.contains($0.id) }
      let missing = try await store.api.missingRecords(ids, from: found)
      return (found + missing).sorted { ($0.start, $0.id) > ($1.start, $1.id) }
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
      deleteError = error.localizedDescription
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
