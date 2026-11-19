import SwiftUI
import CollectorCore

struct ThreadStoryPage: View {
  let id: String
  @Environment(ViewerStore.self) private var store
  @State private var story = Loader<Story>()
  @State private var loadedRevision: Int?

  private struct Story {
    let title: String
    let updates: [ProjectUpdate]
  }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 12) {
        if loadedRevision == store.revision, let error = story.error {
          Placeholder(kind: .error(error) { Task { await load() } })
        } else if loadedRevision == store.revision, let value = story.value {
          Text(value.title)
            .font(.system(size: TextSize.heading, weight: .semibold)).foregroundStyle(Palette.ink)
            .accessibilityAddTraits(.isHeader)
          if value.updates.isEmpty {
            Text("这件事还没有可展示的经过。")
              .font(.system(size: TextSize.body)).foregroundStyle(Palette.muted)
          } else {
            StoryUpdates(updates: value.updates)
          }
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
    await story.run {
      async let thread = store.api.thread(id, level: "brief")
      var days: [HubAPI.TimelineResult.Day] = []
      var before: String?
      repeat {
        let page = try await store.api.timeline(threadId: id, before: before)
        try Task.checkCancellation()
        guard revision == store.revision else { throw CancellationError() }
        days += page.days
        before = page.nextCursor
      } while before != nil

      let title = try await thread.title ?? "这件事的经过"
      try Task.checkCancellation()
      guard revision == store.revision else { throw CancellationError() }
      let updates = days.reversed().flatMap { day in
        day.items.reversed().map { ProjectUpdate(day: day.date, item: $0) }
      }
      return Story(title: title, updates: updates)
    }
    if !Task.isCancelled, revision == store.revision { loadedRevision = revision }
  }
}

/// 按传入的时间正序读经过，同一天只在第一段上方标日期。
struct StoryUpdates: View {
  let updates: [ProjectUpdate]
  @State private var expandedRecord: String?

  var body: some View {
    LazyVStack(alignment: .leading, spacing: 0) {
      ForEach(Array(updates.enumerated()), id: \.element.id) { index, update in
        if let day = TimelineDay.date(update.day) {
          if index == 0 || updates[index - 1].day != update.day {
            Text("\(Fmt.date(day)) \(ViewerFormat.weekday(day))")
              .font(.system(size: TextSize.caption)).foregroundStyle(Palette.muted)
              .padding(.top, 12).padding(.bottom, 6)
              .accessibilityAddTraits(.isHeader)
          }
          TimelineSegmentRow(day: day, item: update.item, showsTitle: false,
                             expanded: expandedRecord == update.id) {
            expandedRecord = expandedRecord == update.id ? nil : update.id
          }
        }
      }
    }
  }
}
