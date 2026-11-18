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
    .navigationTitle("")
    .modifier(QuietPageTitle())
    .toolbar { BackButton() }
    .task(id: store.revision) { await load() }
  }

  private var header: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(alignment: .firstTextBaseline, spacing: 16) {
        if store.section != .project(id) {
          Text(detail.value?.name ?? store.project(id)?.name ?? "项目")
            .font(.system(size: TextSize.heading, weight: .semibold)).foregroundStyle(Palette.ink)
            .accessibilityAddTraits(.isHeader)
        }
        Spacer(minLength: 0)
        Button("新会话会带入的内容") { store.path.append(.projectContext(id)) }
          .buttonStyle(.accentLink).font(.system(size: TextSize.caption)).fixedSize()
      }
      if current, let goal = detail.value?.detail?.goal?.split(whereSeparator: { "。！？!?\n".contains($0) }).first,
         !goal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        Text(goal.trimmingCharacters(in: .whitespacesAndNewlines))
          .font(.system(size: TextSize.body)).foregroundStyle(Palette.muted)
      }
    }
  }

  @ViewBuilder private var results: some View {
    if current, let error = timeline.error ?? detail.error {
      Placeholder(kind: .error(error) { Task { await load() } })
    } else if current, let page = timeline.value {
      if page.days.isEmpty {
        Text("这个项目还没有可展示的整理结果。")
          .font(.system(size: TextSize.body)).foregroundStyle(Palette.muted)
      } else {
        let updates = page.days.flatMap { day in day.items.map { ProjectUpdate(day: day.date, item: $0) } }
        LazyVStack(alignment: .leading, spacing: 0) {
          ForEach(ProjectReading.stories(updates)) { story in
            ProjectStoryRow(story: story, expanded: expanded == story.id) {
              expanded = expanded == story.id ? nil : story.id
            }
          }
        }
        if let next = page.nextCursor {
          Button("加载更早的日期") { Task { await loadMore(before: next) } }.buttonStyle(.accentLink)
            .font(.system(size: TextSize.caption)).disabled(loadingMore)
        }
        if let moreError {
          Text(moreError).font(.system(size: TextSize.caption)).foregroundStyle(Palette.attention)
        }
      }
    } else {
      ProgressView().controlSize(.small).accessibilityLabel("正在读取项目进展")
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

private struct ProjectStoryRow: View {
  let story: ProjectStory
  let expanded: Bool
  let onToggle: () -> Void
  @State private var expandedRecord: String?

  private var latest: ProjectUpdate { story.latest }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      Rectangle().fill(Palette.hairline).frame(height: 1).accessibilityHidden(true)
      Button(action: onToggle) {
        VStack(alignment: .leading, spacing: 10) {
          HStack(alignment: .firstTextBaseline, spacing: 16) {
            Text(latest.item.title).font(.system(size: TextSize.title, weight: .medium)).foregroundStyle(Palette.ink)
              .frame(maxWidth: .infinity, alignment: .leading)
            if let day = TimelineDay.date(latest.day) {
              Text(Fmt.date(day)).font(.system(size: TextSize.caption)).foregroundStyle(Palette.muted).fixedSize()
            }
            PhIcon(expanded ? "caret-up" : "caret-down", size: 11).foregroundStyle(Palette.muted)
              .accessibilityHidden(true)
          }
          if !expanded || story.updates.count == 1 {
            Text(latest.item.description).font(.system(size: TextSize.body))
              .lineSpacing(TextSize.lineSpacing(TextSize.body) + 2).foregroundStyle(Palette.readingBody)
            TimelineSourceIcons(item: latest.item, size: 20)
          }
        }
        .multilineTextAlignment(.leading).padding(.vertical, 20).contentShape(Rectangle())
      }
      .buttonStyle(TimelineRowStyle())
      .accessibilityValue(expanded ? "已展开" : "已折叠")
      .accessibilityHint(story.updates.count > 1 ? "展开这件事的经过" : "展开原始记录")
      if expanded {
        if story.updates.count == 1, let day = TimelineDay.date(latest.day) {
          TimelineSegmentRecords(day: day, item: latest.item, dayRecords: nil).padding(.bottom, 20)
        } else {
          let updates = Array(story.updates.reversed())
          ForEach(updates.indices, id: \.self) { index in
            let update = updates[index]
            if let day = TimelineDay.date(update.day) {
              if index == 0 || updates[index - 1].day != update.day {
                Text("\(Fmt.date(day)) \(ViewerFormat.weekday(day))")
                  .font(.system(size: TextSize.caption)).foregroundStyle(Palette.muted)
                  .padding(.top, 12).padding(.bottom, 6)
              }
              TimelineSegmentRow(day: day, item: update.item, showsTitle: false,
                                 density: .detailed, expanded: expandedRecord == update.id) {
                expandedRecord = expandedRecord == update.id ? nil : update.id
              }
            }
          }
        }
      }
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
