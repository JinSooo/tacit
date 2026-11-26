import SwiftUI
import CollectorCore

struct ProjectPage: View {
  let id: String
  @Environment(ViewerStore.self) private var store
  @AppStorage("viewer.sidebarVisible") private var sidebarVisible = true
  @State private var overview: (revision: Int, brief: String)?
  @State private var context = Loader<[HubThread]>(animated: true)
  @State private var timeline = Loader<HubAPI.TimelineResult>(animated: true)
  @State private var expandedThread: String?
  @State private var loadedMore = false
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
          sectionTitle(L10n.inProgress)
          ongoingWork
        }
        .padding(.horizontal, TimelineReadingLayout.edge)
        // “正在推进”就是新会话会带入的事项，随整理变化，和下面两块一样自己重读。
        .task(id: store.revision) {
          while !Task.isCancelled { await loadContext(); await WindowVisibility.pause(.seconds(180)) }
        }
        VStack(alignment: .leading, spacing: 12) {
          sectionTitle(L10n.recentProgress).padding(.horizontal, TimelineReadingLayout.edge)
          results
        }
      }
      .modifier(ReviewWidth())
    }
    .background(Palette.paper)
    .navigationTitle("")
    .modifier(QuietPageTitle())
    .toolbar {
      BackButton()
      if let project = store.project(id) {
        ToolbarItem(placement: .primaryAction) {
          Menu {
            Button(L10n.removeProject, role: .destructive) { store.projectToRemove = project }.disabled(store.removingProject)
          } label: { PhIcon("dots-three", size: PhIcon.toolbar) }
            .menuIndicator(.hidden).help(L10n.more).accessibilityLabel(L10n.more)
        }
      }
    }
    // 项目概况和进展随整理更新，页面自己隔几分钟重读。
    .task(id: store.revision) {
      while !Task.isCancelled { await loadOverview(); await WindowVisibility.pause(.seconds(180)) }
    }
    .task(id: store.revision) {
      // 数据变化时列表回到第一页，定时重读也随之恢复。
      loadedMore = false
      await load()
      // 加载过更早的日期就不再定时重读，免得把已展开的旧日期收回去。
      while !Task.isCancelled {
        await WindowVisibility.pause(.seconds(180))
        if !loadedMore { await load() }
      }
    }
  }

  @ViewBuilder private var projectOverview: some View {
    // 侧栏里选中的项目已经写着名字；侧栏收起时页面自己写出来。
    let showsName = store.section != .project(id) || !sidebarVisible
    let brief = overview?.revision == store.revision ? overview?.brief : nil
    if showsName || brief != nil {
      VStack(alignment: .leading, spacing: 8) {
        if showsName {
          Text(store.project(id)?.name ?? L10n.project)
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
        Text(L10n.noTasksInProgress)
          .font(.system(size: TextSize.caption)).foregroundStyle(Palette.muted)
      } else {
        VStack(alignment: .leading, spacing: 0) {
          ForEach(list) { thread in
            ProjectContextRow(thread: thread, expanded: expandedThread == thread.id) {
              expandedThread = expandedThread == thread.id ? nil : thread.id
            }
          }
        }
        Text(L10n.newSessionsGetContextForTheseTasks)
          .font(.system(size: TextSize.caption)).foregroundStyle(Palette.muted)
      }
    } else {
      DelayedProgress(label: L10n.loadingTasksInProgress)
    }
  }

  @ViewBuilder private var results: some View {
    if current, let error = timeline.error {
      Placeholder(kind: .error(error) { Task { await load() } })
    } else if current, let page = timeline.value {
      if page.days.isEmpty {
        Text(L10n.noSummaryToShowForThisProject)
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
              .transition(.opacity)
            }
          }
        }
        if let next = page.nextCursor {
          Button(L10n.loadEarlierDays) { Task { await loadMore(before: next) } }.buttonStyle(.accentLink)
            .font(.system(size: TextSize.caption)).disabled(loadingMore)
            .padding(.horizontal, TimelineReadingLayout.edge)
        }
        if let moreError {
          Text(moreError).font(.system(size: TextSize.caption)).foregroundStyle(Palette.attention)
            .padding(.horizontal, TimelineReadingLayout.edge)
            .transition(.notice)
        }
      }
    } else {
      DelayedProgress(label: L10n.loadingProjectProgress)
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
    if !Task.isCancelled, revision == store.revision, contextRevision != revision {
      Motion.animate { contextRevision = revision }
    }
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
    if !Task.isCancelled, revision == store.revision, loadedRevision != revision {
      Motion.animate { loadedRevision = revision }
    }
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
      // 更早的日期接在下面淡入，已读到的部分不动。
      Motion.animate { timeline.value = HubAPI.TimelineResult(days: previous.days + page.days, nextCursor: page.nextCursor) }
      loadedMore = true
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
  @State private var hovering = false

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      Rectangle().fill(Palette.hairline).frame(height: 1).accessibilityHidden(true)
      Button { Motion.animate { onToggle() } } label: {
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
          DisclosureChevron(expanded: expanded).foregroundStyle(Palette.muted)
        }
        .multilineTextAlignment(.leading).padding(.vertical, 12)
        .background(Palette.fill.opacity(hovering ? 1 : 0))
        .contentShape(Rectangle())
      }
      .buttonStyle(TimelineRowStyle())
      .hoverState($hovering)
      .accessibilityValue(expanded ? L10n.expanded : L10n.collapsed)
      .accessibilityHint(expanded ? L10n.collapseTaskHistory : L10n.expandTaskHistory)
      if expanded {
        VStack(alignment: .leading, spacing: 8) {
          StoryUpdates(threadId: thread.id)
          Button(L10n.whatAIRemembers) { store.path.append(.thread(thread.id)) }
            .buttonStyle(.accentLink).font(.system(size: TextSize.caption))
        }
        .padding(.leading, 16).padding(.bottom, 16)
        .transition(.reveal)
      }
    }
  }
}
