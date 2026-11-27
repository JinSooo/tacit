import SwiftUI
import CollectorCore

struct TimelineSearchPage: View {
  @Environment(ViewerStore.self) private var store
  @FocusState private var focused: Bool
  @State private var result: Results?
  @State private var request = UUID()
  @State private var retry = 0
  @State private var expanded: String?
  @State private var loading = false
  @State private var loadError: String?
  @State private var openingRecord: String?
  @State private var openError: String?

  private struct QueryKey: Equatable {
    let text: String
    let revision: Int
    let retry: Int
  }

  private struct Results {
    let query: String
    /// 读到这批结果时的数据版本；删除、修正之后旧结果不再显示。
    let revision: Int
    let segments: [HubAPI.TimelineResult.Day]
    let labeledProjectDays: Set<String>
    let records: [HistoryRecord]
    let segmentCursor: String?
    let recordCursor: String?
    var hasMore: Bool { segmentCursor != nil || recordCursor != nil }
  }

  private var query: String { store.timelineSearch.trimmingCharacters(in: .whitespacesAndNewlines) }

  var body: some View {
    @Bindable var store = store
    let key = QueryKey(text: query, revision: store.revision, retry: retry)
    ScrollView {
      VStack(alignment: .leading, spacing: 20) {
        HStack(spacing: 10) {
          PhIcon("magnifying-glass", size: 16).foregroundStyle(Palette.muted).accessibilityHidden(true)
          TextField(L10n.searchTimelineAndRecords, text: $store.timelineSearch)
            .textFieldStyle(.plain).font(.system(size: TextSize.body)).focused($focused)
          if !store.timelineSearch.isEmpty {
            Button {
              store.timelineSearch = ""
              focused = true
            } label: {
              PhIcon("x", size: 13).foregroundStyle(Palette.muted)
            }
            .buttonStyle(.plain).help(L10n.clearSearch).accessibilityLabel(L10n.clearSearch)
            .transition(.opacity)
          }
          if loading { DelayedProgress(size: .mini, label: L10n.searching).transition(.opacity) }
        }
        .animation(Motion.quick, value: store.timelineSearch.isEmpty)
        .animation(Motion.quick, value: loading)
        .padding(10).card(Radius.control)
        if !key.text.isEmpty { content }
      }
      .modifier(ReviewWidth())
    }
    .background(Palette.paper)
    .navigationTitle("")
    .modifier(QuietPageTitle())
    .onAppear { focused = true }
    .task(id: key) { await reset(key) }
    .onDisappear { request = UUID() }
  }

  @ViewBuilder private var content: some View {
    if let openError {
      Text(openError).font(.system(size: TextSize.caption)).foregroundStyle(Palette.attention)
        .transition(.notice)
    }
    if let result, result.query == query {
      results(result)
      if result.hasMore {
        Button(L10n.loadMoreResults) { Task { await load(query, previous: result, request: request) } }
          .buttonStyle(.accentLink).font(.system(size: TextSize.caption)).disabled(loading)
      }
      if let loadError {
        Text(loadError).font(.system(size: TextSize.caption)).foregroundStyle(Palette.attention)
      }
    } else if let loadError {
      Placeholder(kind: .error(loadError) { retry += 1 })
    } else if let result {
      // 打字时先淡淡地留着上一次的结果占位，新结果到了再整体淡换，不每敲一个字就塌成空白；占位不能点。
      results(result).opacity(0.45).allowsHitTesting(false).accessibilityHidden(true)
    }
  }

  private func results(_ result: Results) -> some View {
    VStack(alignment: .leading, spacing: 20) {
      let segments = Dictionary(uniqueKeysWithValues: result.segments.map { ($0.date, $0.items) })
      let records = Dictionary(grouping: result.records) { TimelineDay.key($0.start) }
      let dates = Set(segments.keys).union(records.keys).sorted(by: >)
      if dates.isEmpty {
        Text(L10n.noMatchingActivitiesOrRecords)
          .font(.system(size: TextSize.body)).foregroundStyle(Palette.muted)
      }
      LazyVStack(alignment: .leading, spacing: 20) {
        ForEach(dates, id: \.self) { date in
          if let day = TimelineDay.date(date) {
            VStack(alignment: .leading, spacing: 0) {
              Text("\(Fmt.date(day)) \(ViewerFormat.weekday(day))")
                .font(.system(size: TextSize.caption)).foregroundStyle(Palette.muted)
                .padding(.bottom, 8).accessibilityAddTraits(.isHeader)
              ForEach(segments[date] ?? []) { item in
                let key = "\(date)/\(item.id)"
                TimelineSegmentRow(day: day, item: item,
                                   projectName: result.labeledProjectDays.contains(date) ? store.project(item.projectId)?.name : nil,
                                   expanded: expanded == key) {
                  expanded = expanded == key ? nil : key
                }
              }
              ForEach(records[date] ?? []) { record in
                RecordRow(record: record, run: nil, selected: false, expanded: false,
                          snippet: SearchSnippet.make(record.body ?? "", query: query)) {
                  Task { await showRecord(record) }
                }
                .accessibilityHint(L10n.goToTimeline)
                .disabled(openingRecord != nil)
              }
            }
          }
        }
      }
      .id(result.query)
      .transition(.opacity)
    }
  }

  private func reset(_ key: QueryKey) async {
    let id = UUID()
    request = id
    if key.text.isEmpty || result?.revision != key.revision { result = nil }
    expanded = nil
    loadError = nil
    openError = nil
    openingRecord = nil
    loading = false
    guard !key.text.isEmpty else { return }
    do { try await Task.sleep(for: .milliseconds(240)) }
    catch { return }
    await load(key.text, previous: nil, request: id)
  }

  private func load(_ text: String, previous: Results?, request id: UUID) async {
    guard id == request, query == text, !loading, previous.map({ $0.query == text && $0.revision == store.revision }) ?? true else { return }
    let revision = store.revision
    loading = true
    loadError = nil
    defer { if id == request { loading = false } }
    do {
      async let segments = segmentPage(text, more: previous != nil, cursor: previous?.segmentCursor)
      async let records = recordPage(text, more: previous != nil, cursor: previous?.recordCursor)
      let (foundSegments, foundRecords) = try await (segments, records)
      var labeledDays = previous?.labeledProjectDays ?? []
      for day in foundSegments?.days ?? [] {
        guard let date = TimelineDay.date(day.date) else { continue }
        let allItems = try await store.dataSource.diary(date)?.detail?.items ?? day.items
        if TimelineProjectLabels.showsNames(in: allItems) { labeledDays.insert(day.date) }
      }
      try Task.checkCancellation()
      guard id == request, query == text else { return }
      let priorSegments = previous?.segments ?? []
      let priorRecords = previous?.records ?? []
      let knownDays = Set(priorSegments.map(\.date)), knownRecords = Set(priorRecords.map(\.id))
      guard revision == store.revision else { return }
      let next = Results(query: text, revision: revision, segments: priorSegments + (foundSegments?.days ?? []).filter { !knownDays.contains($0.date) },
                         labeledProjectDays: labeledDays, records: priorRecords + (foundRecords?.records ?? []).filter { !knownRecords.contains($0.id) },
                         segmentCursor: foundSegments?.nextCursor,
                         recordCursor: foundRecords?.nextCursor)
      // 新的一次搜索整体淡换（列表行不挪位置）；“加载更多”接在下面淡入。
      withAnimation(previous == nil ? Motion.quick : Motion.standard) { result = next }
    } catch is CancellationError {
    } catch {
      guard id == request, query == text else { return }
      Motion.animate { loadError = UserFacingError.message(for: error, fallback: L10n.Settings.settingsRequestFailed) }
    }
  }

  private func segmentPage(_ text: String, more: Bool, cursor: String?) async throws -> HubAPI.TimelineResult? {
    if more && cursor == nil { return nil }
    return try await store.dataSource.timeline(query: text, before: cursor)
  }

  private func recordPage(_ text: String, more: Bool, cursor: String?) async throws -> RecordPage? {
    if more && cursor == nil { return nil }
    var q = HubAPI.RecordQuery()
    q.q = text
    q.limit = 50
    q.body = true
    return try await store.dataSource.records(q, cursor: cursor)
  }

  private func showRecord(_ record: HistoryRecord) async {
    guard openingRecord == nil else { return }
    let id = request
    let text = query
    openingRecord = record.id
    openError = nil
    defer { if id == request { openingRecord = nil } }
    do {
      let location = try await store.dataSource.timelineLocation(record: record.id)
      guard id == request, query == text, store.section == .search else { return }
      let day = TimelineDay.date(location.date) ?? record.start
      store.showDayRecords(day, record: record.id)
    } catch is CancellationError {
    } catch {
      guard id == request, query == text else { return }
      openError = UserFacingError.message(for: error, fallback: L10n.Settings.settingsRequestFailed)
    }
  }
}
