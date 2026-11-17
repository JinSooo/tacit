import SwiftUI
import CollectorCore

struct ProjectPage: View {
  let id: String
  @Environment(ViewerStore.self) private var store
  @State private var detail = Loader<EntityDetail>()
  @State private var timeline = Loader<HubAPI.TimelineResult>()
  @State private var expanded: String?
  @State private var loadingMore = false
  @State private var moreError: String?
  @State private var loadedRevision: Int?

  private var current: Bool { loadedRevision == store.revision }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 24) {
        header
        results
      }
      .modifier(ReviewWidth())
    }
    .background(Palette.paper)
    .navigationTitle(detail.value?.name ?? store.project(id)?.name ?? "项目")
    .toolbar { BackButton() }
    .task(id: store.revision) { await load() }
  }

  private var header: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(alignment: .firstTextBaseline, spacing: 16) {
        Text(detail.value?.name ?? store.project(id)?.name ?? "项目")
          .font(.system(size: TextSize.heading, weight: .semibold)).foregroundStyle(Palette.ink)
          .accessibilityAddTraits(.isHeader)
        Spacer(minLength: 0)
        Button("新会话会带入的内容") { store.path.append(.projectContext(id)) }
          .buttonStyle(.accentLink).font(.system(size: TextSize.caption)).fixedSize()
      }
      if current, let goal = detail.value?.detail?.goal?.split(whereSeparator: { "。！？!?\n".contains($0) }).first,
         !goal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        let line = goal.trimmingCharacters(in: .whitespacesAndNewlines)
        Text(line.count > 40 ? String(line.prefix(39)) + "…" : line)
          .font(.system(size: TextSize.body)).foregroundStyle(Palette.muted)
      }
    }
  }

  @ViewBuilder private var results: some View {
    if current, let error = timeline.error ?? detail.error {
      Placeholder(kind: .error(error) { Task { await load() } })
    } else if current, let page = timeline.value {
      if page.days.isEmpty {
        Text("这个项目还没有整理成时间线的日期。")
          .font(.system(size: TextSize.body)).foregroundStyle(Palette.muted)
      } else {
        LazyVStack(alignment: .leading, spacing: 20) {
          ForEach(page.days) { group in
            if let day = TimelineDay.date(group.date) {
              VStack(alignment: .leading, spacing: 0) {
                Text("\(Fmt.date(day)) \(ViewerFormat.weekday(day))")
                  .font(.system(size: TextSize.caption)).foregroundStyle(Palette.muted)
                  .padding(.bottom, 8).accessibilityAddTraits(.isHeader)
                ForEach(group.items) { item in
                  let key = "\(group.date)/\(item.id)"
                  TimelineSegmentRow(day: day, item: item, expanded: expanded == key) {
                    expanded = expanded == key ? nil : key
                  }
                }
              }
            }
          }
        }
        Text("这里只显示已经整理成时间线的日期。")
          .font(.system(size: TextSize.caption)).foregroundStyle(Palette.muted)
        if let next = page.nextCursor {
          Button("加载更早的日期") { Task { await loadMore(before: next) } }.buttonStyle(.accentLink)
            .font(.system(size: TextSize.caption)).disabled(loadingMore)
        }
        if let moreError {
          Text(moreError).font(.system(size: TextSize.caption)).foregroundStyle(Palette.attention)
        }
      }
    } else {
      ProgressView().controlSize(.small).accessibilityLabel("正在读取项目时间线")
    }
  }

  private func load() async {
    moreError = nil
    let revision = store.revision
    if !current {
      timeline.value = nil
      detail.value = nil
    }
    async let a: Void = detail.run {
      let value = try await store.api.project(id, level: "detail")
      try Task.checkCancellation()
      return value
    }
    await timeline.run {
      let page = try await store.api.timeline(projectId: id)
      try Task.checkCancellation()
      guard revision == store.revision else { throw CancellationError() }
      return page
    }
    await a
    if !Task.isCancelled, revision == store.revision { loadedRevision = revision }
  }

  private func loadMore(before: String) async {
    guard !loadingMore, let previous = timeline.value else { return }
    loadingMore = true
    moreError = nil
    defer { loadingMore = false }
    let revision = store.revision
    do {
      let page = try await store.api.timeline(projectId: id, before: before)
      guard !Task.isCancelled, revision == store.revision, timeline.value?.nextCursor == before else { return }
      timeline.value = HubAPI.TimelineResult(days: previous.days + page.days, nextCursor: page.nextCursor)
    } catch is CancellationError {
    } catch {
      guard revision == store.revision else { return }
      moreError = error.localizedDescription
    }
  }
}

struct ProjectContextPage: View {
  let id: String
  @Environment(ViewerStore.self) private var store
  @State private var threads = Loader<[HubThread]>()

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 0) {
        if let error = threads.error {
          Placeholder(kind: .error(error) { Task { await load() } })
        } else if let list = threads.value {
          if list.isEmpty {
            Text("当前没有可带入的内容。")
              .font(.system(size: TextSize.body)).foregroundStyle(Palette.muted)
          }
          ForEach(list) { thread in
            Rectangle().fill(Palette.hairline).frame(height: 1).accessibilityHidden(true)
            Button { store.path.append(.thread(thread.id)) } label: {
              HStack(alignment: .firstTextBaseline, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                  Text(thread.title).font(.system(size: TextSize.title, weight: .semibold)).foregroundStyle(Palette.ink)
                  if let brief = thread.cardSummary {
                    Text(brief).font(.system(size: TextSize.body)).foregroundStyle(Palette.muted)
                  }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                PhIcon("caret-right", size: 11).foregroundStyle(Palette.muted).accessibilityHidden(true)
              }
              .multilineTextAlignment(.leading).padding(.vertical, 12).contentShape(Rectangle())
            }
            .buttonStyle(TimelineRowStyle())
          }
        } else {
          ProgressView().controlSize(.small).accessibilityLabel("正在读取带入内容")
        }
      }
      .modifier(ReviewWidth())
    }
    .background(Palette.paper)
    .navigationTitle("新会话会带入的内容")
    .toolbar { BackButton() }
    .task(id: store.revision) { await load() }
  }

  private func load() async {
    await threads.run { try await store.api.projectContext(id) }
  }
}
