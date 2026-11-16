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
  let day: Date
  let isToday: Bool
  let refresh: Int

  var body: some View {
    VStack(alignment: .leading, spacing: 24) {
      HStack(alignment: .firstTextBaseline, spacing: 12) {
        Text(Fmt.date(day)).font(.serif(TextSize.heading, .semibold)).foregroundStyle(Palette.ink)
          .accessibilityAddTraits(.isHeader)
        Text(ViewerFormat.weekday(day)).font(.system(size: TextSize.body)).foregroundStyle(Palette.muted)
      }
      review.frame(maxWidth: 760, alignment: .leading)
    }
    .task(id: refresh) {
      repeat {
        await diary.run { try await store.api.diary(day) }
        if !isToday { break }
        try? await Task.sleep(for: .seconds(60))
      } while !Task.isCancelled
    }
  }

  @ViewBuilder private var review: some View {
    if let error = diary.error {
      Placeholder(kind: .error(error) { Task { await diary.run { try await store.api.diary(day) } } })
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
