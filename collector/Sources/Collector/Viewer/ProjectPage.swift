import SwiftUI
import CollectorCore

struct ProjectPage: View {
  let id: String
  @Environment(ViewerStore.self) private var store
  @State private var overview: (revision: Int, brief: String)?
  @State private var context = Loader<[HubThread]>()
  @State private var timeline = Loader<HubAPI.TimelineResult>()
  @State private var expandedThread: String?
  @State private var expandedSegment: String?
  @State private var loadingMore = false
  @State private var moreError: String?
  @State private var loadedRevision: Int?
  @State private var contextRevision: Int?

  private var current: Bool { loadedRevision == store.revision }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 32) {
        projectOverview
        VStack(alignment: .leading, spacing: 12) {
          sectionTitle("正在推进")
          ongoingWork
        }
        .padding(.horizontal, TimelineReadingLayout.edge)
        .task(id: store.revision) { await loadContext() }
        VStack(alignment: .leading, spacing: 12) {
          sectionTitle("最近的进展").padding(.horizontal, TimelineReadingLayout.edge)
          results
        }
      }
      .modifier(ReviewWidth())
    }
    .background(Palette.paper)
    .navigationTitle("")
    .modifier(QuietPageTitle())
    .toolbar { BackButton() }
    .task(id: store.revision) { await loadOverview() }
    .task(id: store.revision) { await load() }
  }

  @ViewBuilder private var projectOverview: some View {
    let showsName = store.section != .project(id)
    let brief = overview?.revision == store.revision ? overview?.brief : nil
    if showsName || brief != nil {
      VStack(alignment: .leading, spacing: 8) {
        if showsName {
          Text(store.project(id)?.name ?? "项目")
            .font(.system(size: TextSize.heading, weight: .semibold)).foregroundStyle(Palette.ink)
            .accessibilityAddTraits(.isHeader)
        }
        if let brief {
          // 与时间线当天概述同一样式：页首一句话是这一页的视觉锚点。
          ReviewHeadline(text: brief, size: TextSize.title)
            .foregroundStyle(Palette.ink).lineSpacing(TextSize.serifLineSpacing(TextSize.title))
            .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
        }
      }
      .padding(.horizontal, TimelineReadingLayout.edge)
    }
  }

  private func sectionTitle(_ title: String) -> some View {
    Text(title).font(.system(size: TextSize.title, weight: .medium)).foregroundStyle(Palette.readingBody)
      .accessibilityAddTraits(.isHeader)
  }

  @ViewBuilder private var ongoingWork: some View {
    if contextRevision == store.revision, let error = context.error {
      Placeholder(kind: .error(error) { Task { await loadContext() } })
    } else if contextRevision == store.revision, let list = context.value {
      if list.isEmpty {
        Text("现在没有正在推进的事。")
          .font(.system(size: TextSize.caption)).foregroundStyle(Palette.muted)
      } else {
        LazyVStack(alignment: .leading, spacing: 0) {
          ForEach(list) { thread in
            ProjectContextRow(thread: thread, expanded: expandedThread == thread.id) {
              expandedThread = expandedThread == thread.id ? nil : thread.id
            }
          }
        }
        Text("新会话会带入这几件事。")
          .font(.system(size: TextSize.caption)).foregroundStyle(Palette.muted)
      }
    } else {
      ProgressView().controlSize(.small).accessibilityLabel("正在读取正在推进的事")
    }
  }

  @ViewBuilder private var results: some View {
    if current, let error = timeline.error {
      Placeholder(kind: .error(error) { Task { await load() } })
    } else if current, let page = timeline.value {
      if page.days.isEmpty {
        Text("这个项目还没有可展示的整理结果。")
          .font(.system(size: TextSize.body)).foregroundStyle(Palette.muted)
          .padding(.horizontal, TimelineReadingLayout.edge)
      } else {
        LazyVStack(alignment: .leading, spacing: 16) {
          ForEach(page.days) { group in
            if let day = TimelineDay.date(group.date) {
              VStack(alignment: .leading, spacing: 6) {
                TimelineDayHeading(day: day).padding(.horizontal, TimelineReadingLayout.edge)
                VStack(spacing: 0) {
                  ForEach(group.items) { item in
                    let key = "\(group.date)/\(item.id)"
                    TimelineSegmentRow(day: day, item: item, offersThreadStory: true,
                                       expanded: expandedSegment == key) {
                      expandedSegment = expandedSegment == key ? nil : key
                    }
                  }
                }
              }
            }
          }
        }
        if let next = page.nextCursor {
          Button("加载更早的日期") { Task { await loadMore(before: next) } }.buttonStyle(.accentLink)
            .font(.system(size: TextSize.caption)).disabled(loadingMore)
            .padding(.horizontal, TimelineReadingLayout.edge)
        }
        if let moreError {
          Text(moreError).font(.system(size: TextSize.caption)).foregroundStyle(Palette.attention)
            .padding(.horizontal, TimelineReadingLayout.edge)
        }
      }
    } else {
      ProgressView().controlSize(.small).accessibilityLabel("正在读取项目进展")
    }
  }

  private func loadOverview() async {
    let revision = store.revision
    let project = try? await store.dataSource.project(id, level: "detail")
    guard !Task.isCancelled, revision == store.revision else { return }
    let brief = project?.brief?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    overview = brief.isEmpty ? nil : (revision, brief)
  }

  private func loadContext() async {
    let revision = store.revision
    await context.run {
      let threads = try await store.dataSource.projectContext(id)
      try Task.checkCancellation()
      guard revision == store.revision else { throw CancellationError() }
      return threads
    }
    if !Task.isCancelled, revision == store.revision { contextRevision = revision }
  }

  private func load() async {
    moreError = nil
    let revision = store.revision
    if !current { timeline.value = nil }
    await timeline.run {
      let page = try await store.dataSource.timeline(projectId: id)
      try Task.checkCancellation()
      guard revision == store.revision else { throw CancellationError() }
      return page
    }
    if !Task.isCancelled, revision == store.revision { loadedRevision = revision }
  }

  private func loadMore(before: String) async {
    guard !loadingMore, let previous = timeline.value else { return }
    loadingMore = true
    moreError = nil
    defer { loadingMore = false }
    let revision = store.revision
    do {
      let page = try await store.dataSource.timeline(projectId: id, before: before)
      guard !Task.isCancelled, revision == store.revision, timeline.value?.nextCursor == before else { return }
      timeline.value = HubAPI.TimelineResult(days: previous.days + page.days, nextCursor: page.nextCursor)
    } catch is CancellationError {
    } catch {
      guard revision == store.revision else { return }
      moreError = error.localizedDescription
    }
  }
}

private struct ProjectContextRow: View {
  let thread: HubThread
  let expanded: Bool
  let onToggle: () -> Void
  @Environment(ViewerStore.self) private var store

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      Rectangle().fill(Palette.hairline).frame(height: 1).accessibilityHidden(true)
      Button(action: onToggle) {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
          VStack(alignment: .leading, spacing: 4) {
            Text(thread.title).font(.system(size: TextSize.title, weight: .semibold)).foregroundStyle(Palette.ink)
            if let brief = thread.cardSummary {
              Text(brief).font(.system(size: TextSize.body)).foregroundStyle(Palette.readingBody)
                .lineSpacing(TextSize.lineSpacing(TextSize.body))
            }
            ForEach(Array((thread.open ?? []).prefix(2).enumerated()), id: \.offset) { _, fact in
              HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("•").accessibilityHidden(true)
                Text(fact)
              }
              .font(.system(size: TextSize.caption)).foregroundStyle(Palette.muted)
            }
          }
          .fixedSize(horizontal: false, vertical: true)
          .frame(maxWidth: .infinity, alignment: .leading)
          PhIcon(expanded ? "caret-up" : "caret-down", size: 11).foregroundStyle(Palette.muted)
            .accessibilityHidden(true)
        }
        .multilineTextAlignment(.leading).padding(.vertical, 12).contentShape(Rectangle())
      }
      .buttonStyle(TimelineRowStyle())
      .accessibilityValue(expanded ? "已展开" : "已折叠")
      .accessibilityHint(expanded ? "收起这件事的经过" : "展开这件事的经过")
      if expanded {
        VStack(alignment: .leading, spacing: 8) {
          StoryUpdates(threadId: thread.id)
          Button("AI 记住的要点") { store.path.append(.thread(thread.id)) }
            .buttonStyle(.accentLink).font(.system(size: TextSize.caption))
        }
        .padding(.leading, 16).padding(.bottom, 16)
      }
    }
  }
}
