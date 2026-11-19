import SwiftUI
import CollectorCore

struct ThreadStoryPage: View {
  let id: String
  @Environment(ViewerStore.self) private var store
  @State private var title = Loader<String>()
  @State private var loadedRevision: Int?

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 12) {
        if loadedRevision == store.revision, let error = title.error {
          Placeholder(kind: .error(error) { Task { await load() } })
        } else if loadedRevision == store.revision, let name = title.value {
          Text(name)
            .font(.system(size: TextSize.heading, weight: .semibold)).foregroundStyle(Palette.ink)
            .accessibilityAddTraits(.isHeader)
          StoryUpdates(threadId: id)
        } else {
          ProgressView().controlSize(.small).accessibilityLabel("正在读取这件事的经过")
        }
      }
      .modifier(ReviewWidth())
    }
    .background(Palette.paper)
    .navigationTitle("")
    .modifier(QuietPageTitle())
    .toolbar { BackButton() }
    .task(id: store.revision) { await load() }
  }

  private func load() async {
    let revision = store.revision
    await title.run {
      let thread = try await store.api.thread(id, level: "brief")
      try Task.checkCancellation()
      guard revision == store.revision else { throw CancellationError() }
      return thread.title ?? "这件事的经过"
    }
    if !Task.isCancelled, revision == store.revision { loadedRevision = revision }
  }
}

struct TimelineDayHeading: View {
  let day: Date

  var body: some View {
    Text("\(Fmt.date(day)) \(ViewerFormat.weekday(day))")
      .font(.system(size: TextSize.caption)).foregroundStyle(Palette.muted)
      .accessibilityAddTraits(.isHeader)
  }
}

/// 按时间正序读经过，同一天只标一次日期。
struct StoryUpdates: View {
  let threadId: String
  @Environment(ViewerStore.self) private var store
  @State private var story = Loader<[HubAPI.TimelineResult.Day]>()
  @State private var loadedRevision: Int?
  @State private var expandedRecord: String?

  var body: some View {
    Group {
      if loadedRevision == store.revision, let error = story.error {
        Placeholder(kind: .error(error) { Task { await load() } })
      } else if loadedRevision == store.revision, let days = story.value {
        if days.isEmpty {
          Text("这件事还没有可展示的经过。")
            .font(.system(size: TextSize.body)).foregroundStyle(Palette.muted)
        } else {
          updates(days)
        }
      } else {
        ProgressView().controlSize(.small).accessibilityLabel("正在读取这件事的经过")
      }
    }
    .task(id: store.revision) { await load() }
  }

  private func updates(_ days: [HubAPI.TimelineResult.Day]) -> some View {
    LazyVStack(alignment: .leading, spacing: 12) {
      ForEach(days.reversed()) { group in
        if let day = TimelineDay.date(group.date) {
          VStack(alignment: .leading, spacing: 6) {
            TimelineDayHeading(day: day)
            VStack(spacing: 0) {
              ForEach(group.items.reversed()) { item in
                let key = "\(group.date)/\(item.id)"
                TimelineSegmentRow(day: day, item: item,
                                   expanded: expandedRecord == key) {
                  expandedRecord = expandedRecord == key ? nil : key
                }
              }
            }
          }
        }
      }
    }
  }

  private func load() async {
    let revision = store.revision
    await story.run {
      var days: [HubAPI.TimelineResult.Day] = []
      var before: String?
      repeat {
        let page = try await store.api.timeline(threadId: threadId, before: before)
        try Task.checkCancellation()
        guard revision == store.revision else { throw CancellationError() }
        days += page.days
        before = page.nextCursor
      } while before != nil
      return days
    }
    if !Task.isCancelled, revision == store.revision { loadedRevision = revision }
  }
}
