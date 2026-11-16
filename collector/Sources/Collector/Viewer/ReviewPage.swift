import SwiftUI
import CollectorCore

struct ReviewPage: View {
  @Environment(ViewerStore.self) private var store
  @State private var picking = false
  @State private var refresh = 0

  var body: some View {
    TimelineView(.everyMinute) { clock in
      let calendar = Calendar.current
      let today = calendar.startOfDay(for: clock.date)
      let day = Binding(get: { store.reviewDay ?? today }, set: { store.reviewDay = $0 == today ? nil : $0 })
      ScrollView {
        ReviewDayContent(day: day.wrappedValue, isToday: day.wrappedValue == today, refresh: refresh)
          .id(day.wrappedValue).id(store.revision)
          .frame(maxWidth: 1080, alignment: .leading)
          .padding(.horizontal, 40).padding(.vertical, 32)
          .frame(maxWidth: .infinity)
      }
      .background(Palette.paper)
      .navigationTitle("回顾")
      .toolbar {
        DayNavigation(day: day, picking: $picking, today: today)
        ToolbarItem(placement: .primaryAction) {
          Button { refresh += 1 } label: { PhIcon("arrow-clockwise", size: PhIcon.toolbar) }
            .help("刷新").accessibilityLabel("刷新").keyboardShortcut("r", modifiers: .command)
        }
      }
    }
  }
}

private struct ReviewDayContent: View {
  @Environment(ViewerStore.self) private var store
  @State private var diary = Loader<DayDiary?>()
  @State private var now = Loader<NowState?>()
  @State private var records = Loader<[HistoryRecord]>()
  @State private var active = Loader<[HubThread]>()
  @State private var paused = Loader<[HubThread]>()
  @State private var brush: ClosedRange<Date>?
  @State private var lane: Lane?
  let day: Date
  let isToday: Bool
  let refresh: Int

  var body: some View {
    VStack(alignment: .leading, spacing: 24) {
      if isToday { SetupChecklist() }
      HStack(alignment: .firstTextBaseline, spacing: 12) {
        Text(Fmt.date(day)).font(.serif(TextSize.heading, .semibold)).foregroundStyle(Palette.ink)
          .accessibilityAddTraits(.isHeader)
        Text(ViewerFormat.weekday(day)).font(.system(size: TextSize.body)).foregroundStyle(Palette.muted)
      }
      if isToday {
        currentSummary
        activity
      }
      review.frame(maxWidth: 760, alignment: .leading)
      if isToday {
        ongoing
        if let paused = paused.value {
          let recent = paused.filter { ($0.last ?? .distantPast) > Date().addingTimeInterval(-3 * 86_400) }
          if !recent.isEmpty { recentlyPaused(recent) }
        }
      }
    }
    .task(id: refresh) {
      repeat {
        await load()
        if !isToday { break }
        try? await Task.sleep(for: .seconds(60))
      } while !Task.isCancelled
    }
  }

  private func load() async {
    async let review: Void = loadReview()
    if isToday {
      async let summary: Void = now.run { try await store.api.now() }
      async let activity: Void = records.run { try await store.api.day(day) }
      async let current: Void = active.run { try await store.api.threads(status: "active").sorted { ($0.lastMs ?? 0) > ($1.lastMs ?? 0) } }
      async let recent: Void = paused.run { try await store.api.threads(status: "paused").sorted { ($0.lastMs ?? 0) > ($1.lastMs ?? 0) } }
      _ = await (summary, activity, current, recent)
    }
    await review
  }

  private func loadReview() async { await diary.run { try await store.api.diary(day) } }

  @ViewBuilder private var currentSummary: some View {
    if let error = now.error {
      Placeholder(kind: .error(error) { Task { await load() } })
    } else if case .some(let state) = now.value {
      let brief = state?.brief?.trimmingCharacters(in: .whitespacesAndNewlines)
      VStack(alignment: .leading, spacing: 8) {
        if let brief, !brief.isEmpty {
          Text(brief == "最近 24 小时没有活跃的线程。" ? "最近 24 小时没有活跃的事项。" : brief)
            .font(.serif(TextSize.display)).lineSpacing(TextSize.serifLineSpacing(TextSize.display))
            .foregroundStyle(Palette.ink).textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
        } else {
          Text("还没有此刻的摘要").font(.system(size: TextSize.body)).foregroundStyle(Palette.muted)
        }
        if let updated = state?.updatedAt.flatMap(ViewerTime.parse) {
          TimelineView(.everyMinute) { _ in
            Text(Fmt.updated(updated)).font(.system(size: TextSize.caption)).foregroundStyle(Palette.muted)
          }
        }
        if let feedback = state?.feedback {
          Text(feedback).font(.system(size: TextSize.caption)).foregroundStyle(Palette.muted)
        }
      }
      .frame(maxWidth: 860, alignment: .leading)
    } else {
      ProgressView().controlSize(.small)
    }
  }

  private var activity: some View {
    let visible = records.value.map { ReviewActivity.visibleRecords($0, sources: store.capture.sources) }
    return VStack(alignment: .leading, spacing: 12) {
      HStack(alignment: .firstTextBaseline, spacing: 8) {
        Text("活动").sectionTitle()
        if let rows = visible, !rows.isEmpty {
          Text("\(Fmt.count(rows.count)) 条记录").font(.system(size: TextSize.caption)).monospacedDigit().foregroundStyle(Palette.muted)
        }
        Spacer()
        Button {
          store.historyDay = day
          store.historySearch = ""
          store.historyFocus = nil
          store.section = .history
        } label: {
          HStack(spacing: 4) { Text("打开历史记录"); PhIcon("arrow-right", size: 12) }
        }
        .buttonStyle(.accentLink).font(.system(size: TextSize.body))
      }
      if let error = records.error {
        Text(error).font(.system(size: TextSize.body)).foregroundStyle(Palette.attention)
      } else if let rows = visible {
        if rows.isEmpty {
          Text(records.value?.isEmpty == false ? "已启用的数据源今天还没有记录" : "今天还没有记录")
            .font(.system(size: TextSize.body)).foregroundStyle(Palette.muted)
        } else {
          DayStrata(records: rows, chapters: DayStrata.chapters(from: diary.value ?? nil, on: day), day: day,
                    selected: nil, brush: $brush, lane: $lane) { r in
            store.showRecord(r.id, at: r.start)
          }
        }
      } else {
        ProgressView().controlSize(.small).frame(maxWidth: .infinity, minHeight: 64)
      }
    }
    .padding(16)
    .card()
    .zIndex(1)
    .onChange(of: store.capture.sources.filter(\.enabled).map(\.id)) {
      lane = nil
    }
  }

  private var ongoing: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(alignment: .firstTextBaseline, spacing: 8) {
        Text("进行中").font(.system(size: TextSize.title, weight: .semibold)).foregroundStyle(Palette.ink)
          .accessibilityAddTraits(.isHeader)
        if let n = active.value?.count, n > 0 {
          Text("\(n) 件").font(.system(size: TextSize.caption)).foregroundStyle(Palette.muted)
        }
      }
      if let error = active.error {
        Placeholder(kind: .error(error) { Task { await load() } })
      } else if let rows = active.value {
        if rows.isEmpty {
          Text("现在没有进行中的事项").font(.system(size: TextSize.body)).foregroundStyle(Palette.muted)
        } else {
          LazyVGrid(columns: [GridItem(.adaptive(minimum: 290, maximum: 520), spacing: 12)], spacing: 12) {
            ForEach(rows) { t in
              Button { store.path.append(.thread(t.id)) } label: {
                ThreadCard(thread: t, project: store.project(t.projectId))
              }
              .buttonStyle(.plain)
            }
          }
        }
      } else {
        ProgressView().controlSize(.small).frame(maxWidth: .infinity, minHeight: 64)
      }
    }
  }

  private func recentlyPaused(_ rows: [HubThread]) -> some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("最近暂停").sectionTitle().accessibilityAddTraits(.isHeader)
      VStack(spacing: 0) {
        ForEach(rows) { t in
          Button { store.path.append(.thread(t.id)) } label: { ThreadLine(thread: t, project: store.project(t.projectId)) }
            .buttonStyle(.plain)
          if t.id != rows.last?.id { Divider().padding(.leading, 16) }
        }
      }
      .card()
    }
  }

  @ViewBuilder private var review: some View {
    if let error = diary.error {
      Placeholder(kind: .error(error) { Task { await loadReview() } })
    } else if case .some(let result) = diary.value {
      VStack(alignment: .leading, spacing: 20) {
        if result?.needsRegen?.value == true {
          let updated = result?.updatedAt.flatMap(ViewerTime.parse)
          let status = updated.map { "回顾待更新，上次更新于 \(ViewerFormat.clock($0))" } ?? "回顾待生成"
          Text(status).font(.system(size: TextSize.caption)).foregroundStyle(Palette.muted)
        }
        if let cutoff = result?.detail?.cutoff.flatMap(ViewerTime.parse) {
          Text("内容截至 \(ViewerFormat.clock(cutoff))").font(.system(size: TextSize.caption)).monospacedDigit()
            .foregroundStyle(Palette.muted)
        }
        if let sections = result?.detail?.sections,
           [sections.progress, sections.blockers, sections.authored, sections.suggestions].contains(where: { !$0.isEmpty }) {
          reviewSection("进展与决定", sections.progress)
          reviewSection("未完成与阻塞", sections.blockers)
          reviewSection("自己留下了什么", sections.authored)
          reviewSection("明日建议", sections.suggestions)
        } else if let summary = result?.summary {
          Text(summary).font(.system(size: TextSize.body)).lineSpacing(TextSize.lineSpacing(TextSize.body))
            .foregroundStyle(Palette.ink).textSelection(.enabled)
        } else if result?.needsRegen?.value != true {
          Text(isToday ? "今天的回顾还未生成" : "这一天没有回顾").font(.system(size: TextSize.body)).foregroundStyle(Palette.muted)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    } else {
      HStack(spacing: 8) {
        ProgressView().controlSize(.small)
        Text("正在读取回顾…").font(.system(size: TextSize.body)).foregroundStyle(Palette.muted)
      }
    }
  }

  @ViewBuilder private func reviewSection(_ title: String, _ entries: [DayDiary.Entry]) -> some View {
    if !entries.isEmpty {
      VStack(alignment: .leading, spacing: 12) {
        Text(title).font(.system(size: TextSize.title, weight: .semibold)).foregroundStyle(Palette.ink)
          .accessibilityAddTraits(.isHeader)
        ForEach(entries.indices, id: \.self) { index in
          let entry = entries[index]
          VStack(alignment: .leading, spacing: 4) {
            Text(entry.text).font(.system(size: TextSize.body)).lineSpacing(TextSize.lineSpacing(TextSize.body))
              .foregroundStyle(Palette.ink).textSelection(.enabled)
            if !entry.evidence.isEmpty {
              HStack(spacing: 12) {
                ForEach(entry.evidence.indices, id: \.self) { index in
                  let reference = entry.evidence[index]
                  Button(entry.evidence.count == 1 ? "查看依据" : "查看依据 \(index + 1)") {
                    store.showRecord(reference.id, at: ViewerTime.parse(reference.at))
                  }
                  .buttonStyle(.accentLink).font(.system(size: TextSize.caption))
                }
              }
            }
          }
        }
      }
    }
  }
}
