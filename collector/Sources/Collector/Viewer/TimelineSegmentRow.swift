import SwiftUI
import CollectorCore

struct TimelineSegmentRow: View {
  let day: Date
  let item: DayDiary.Item
  var records: [HistoryRecord]? = nil
  let expanded: Bool
  let onToggle: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      Rectangle().fill(Palette.hairline).frame(height: 1).accessibilityHidden(true)
      Button(action: onToggle) {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
          Text(item.start.map { ViewerFormat.clock($0) } ?? "")
            .font(.system(size: TextSize.caption)).monospacedDigit().foregroundStyle(Palette.muted)
            .frame(width: 44, alignment: .leading)
          VStack(alignment: .leading, spacing: 4) {
            Text(item.title).font(.system(size: TextSize.title, weight: .semibold)).foregroundStyle(Palette.ink)
            Text(item.description).font(.system(size: TextSize.body))
              .lineSpacing(TextSize.lineSpacing(TextSize.body)).foregroundStyle(Palette.ink)
            glyphs.padding(.top, 4)
          }
          .fixedSize(horizontal: false, vertical: true)
          .frame(maxWidth: .infinity, alignment: .leading)
          PhIcon(expanded ? "caret-down" : "caret-right", size: 11)
            .foregroundStyle(Palette.muted).accessibilityHidden(true)
        }
        .multilineTextAlignment(.leading)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
      }
      .buttonStyle(TimelineRowStyle())
      .accessibilityValue(expanded ? "已展开" : "已折叠")
      if expanded {
        TimelineSegmentRecords(day: day, item: item, dayRecords: records)
          .padding(.bottom, 16)
      }
    }
  }

  private var glyphs: some View {
    let apps = (item.apps ?? []).filter { $0.app?.isEmpty == false }
    let appSources = Set(apps.map(\.source))
    return HStack(spacing: 8) {
      ForEach(apps, id: \.self) { app in
        let label = AppIcons.name(app.app) ?? SourceInfo.name(app.source)
        SourceGlyph(source: app.source, app: app.app, size: 16)
          .help(label).accessibilityLabel(label)
      }
      ForEach(item.sources.filter { !appSources.contains($0) }, id: \.self) { source in
        SourceGlyph(source: source, size: 16)
          .help(SourceInfo.name(source)).accessibilityLabel(SourceInfo.name(source))
      }
    }
  }
}

struct TimelineRowStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label.background(configuration.isPressed ? Palette.fill : Color.clear)
  }
}

private struct TimelineSegmentRecords: View {
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
      Text("时长 \(Fmt.duration(item.activeSeconds))")
        .padding(.leading, 60).monospacedDigit().foregroundStyle(Palette.muted)
      if let rows = records.value {
        ForEach(rows) { record in
          RecordRow(record: record, run: nil, selected: false, expanded: false, nested: true) {
            store.path.append(.reviewRecord(record.id))
          }
        }
      } else if let error = records.error {
        Text(error).foregroundStyle(Palette.attention).padding(.leading, 60)
        Button("重试") { Task { await load() } }.buttonStyle(.accentLink).padding(.leading, 60)
      } else {
        ProgressView().controlSize(.small).padding(.leading, 60).accessibilityLabel("正在读取原始记录")
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
      .padding(.leading, 60)
      if let deleteError {
        Text(deleteError).padding(.leading, 60).foregroundStyle(Palette.attention)
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

  private func load() async {
    await records.run {
      guard let ids = item.recordIds else { return [] }
      let idSet = Set(ids)
      let source: [HistoryRecord]
      if let dayRecords { source = dayRecords }
      else { source = try await store.api.day(day) }
      var found = source.filter { idSet.contains($0.id) }
      let available = Set(found.map(\.id))
      // 一条跨午夜记录的开始时刻可能在前一天，不在当天按时刻读取的范围内。
      for id in ids where !available.contains(id) {
        do { found.append(try await store.api.record(id).record) }
        catch let error as HubError where error.status == 404 { continue }
      }
      return found.sorted { ($0.start, $0.id) > ($1.start, $1.id) }
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
