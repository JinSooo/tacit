import SwiftUI
import WidgetKit

struct DayWidgetView: View {
  let family: WidgetFamily
  let date: Date
  let snapshot: WidgetSnapshot

  private var large: Bool { family == .systemLarge }
  private var language: AppLanguage { snapshot.resolvedLanguage }
  private var timeWidth: CGFloat { language == .zh ? 34 : 61 }
  private let columnSpacing: CGFloat = 8

  var body: some View {
    content
      .containerBackground(Palette.paper, for: .widget)
      .widgetURL(snapshot.timelineURL)
  }

  // 文档示意图也用这段布局，圆角与挂件背景由各自的容器负责。
  var content: some View {
    // 大号放不下时先少一段，不压缩间距。
    ViewThatFits(in: .vertical) {
      contents(recentCount: large ? 4 : 3)
      contents(recentCount: large ? 3 : 2)
      contents(recentCount: large ? 2 : 1)
    }
    .padding(.horizontal, large ? 18 : 16)
    .padding(.vertical, large ? 18 : 12)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
  }

  /// 大号分三块：日期和概述、活动条、最近几段，块间留白比块内大，读起来不挤。
  private func contents(recentCount: Int) -> some View {
    VStack(alignment: .leading, spacing: large ? 16 : 4) {
      VStack(alignment: .leading, spacing: large ? 6 : 4) {
        Text(L10n.dayHeader(date, lang: language))
          .font(.system(size: TextSize.title, weight: .semibold, design: .serif))
          .foregroundStyle(Palette.ink)
          .lineLimit(1)
          .accessibilityAddTraits(.isHeader)

        if let summary = snapshot.summary {
          Text(summary)
            .font(.system(size: TextSize.body))
            .foregroundStyle(Palette.readingBody)
            .lineSpacing(large ? TextSize.lineSpacing(TextSize.body) : 0)
            .lineLimit(large ? 3 : 2)
            .fixedSize(horizontal: false, vertical: true)
        }
      }

      if let range = snapshot.activityRange(at: date) {
        activityStrip(range)
        let segments = snapshot.segments.prefix(recentCount)
        VStack(alignment: .leading, spacing: 0) {
          ForEach(Array(segments.enumerated()), id: \.offset) { index, segment in
            recentRow(segment, index: index, last: index == segments.count - 1)
          }
        }
      } else if snapshot.summary == nil {
        Text(L10n.text(zh: "今天暂无时间线内容", en: "No timeline activity today", lang: language))
          .font(.system(size: TextSize.body))
          .foregroundStyle(Palette.muted)
          .lineLimit(1)
      }
    }
    .fixedSize(horizontal: false, vertical: true)
  }

  private func activityStrip(_ range: ClosedRange<Date>) -> some View {
    let start = clock(range.lowerBound)
    let crossesMidnight = !Calendar.current.isDate(date, inSameDayAs: range.upperBound)
    let end = crossesMidnight && language == .zh ? "24:00" : clock(range.upperBound)
    return VStack(spacing: 4) {
      Canvas { context, size in
        let span = range.upperBound.timeIntervalSince(range.lowerBound)
        guard span > 0 else { return }
        for segment in snapshot.segments where segment.end > segment.start {
          let x = segment.start.timeIntervalSince(range.lowerBound) / span * size.width
          let width = segment.end.timeIntervalSince(segment.start) / span * size.width
          // 两端各让出一点，首尾相接的活动也看得出分界。
          let inset = min(1, width / 4)
          let rect = CGRect(x: x + inset, y: 0, width: width - 2 * inset, height: size.height)
          context.fill(Capsule().path(in: rect), with: .color(Palette.accent))
        }
      }
      .frame(height: 6)
      .background(Palette.fill)
      .clipShape(Capsule())
      .accessibilityHidden(true)

      HStack {
        Text(start)
        Spacer()
        Text(end)
      }
      .font(.system(size: TextSize.caption).monospacedDigit())
      .foregroundStyle(Palette.muted)
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(L10n.text(zh: "当天活动时段", en: "Activity today", lang: language))
    .accessibilityValue(L10n.text(zh: "\(start) 至 \(end)", en: "\(start) to \(end)", lang: language))
  }

  private func recentRow(_ segment: WidgetSnapshot.Segment, index: Int, last: Bool) -> some View {
    let verticalInset: CGFloat = large ? 5 : 2
    return HStack(alignment: .top, spacing: columnSpacing) {
      Text(clock(segment.start))
        .font(.system(size: TextSize.caption).monospacedDigit())
        .foregroundStyle(Palette.muted)
        .frame(width: timeWidth, alignment: .leading)
        .padding(.top, 2)
      Color.clear.frame(width: 10, height: 0).accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 2) {
        Text(segment.title)
          .font(.system(size: TextSize.body, weight: .medium))
          .foregroundStyle(Palette.ink)
          .lineLimit(1)
        if large && !segment.description.isEmpty {
          Text(segment.description)
            .font(.system(size: TextSize.caption))
            .foregroundStyle(Palette.muted)
            .lineLimit(1)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .padding(.vertical, verticalInset)
    .background {
      Canvas { context, size in
        let x = timeWidth + columnSpacing + 5
        let y = verticalInset + 8
        let top = index == 0 ? y + 4 : 0
        let bottom = last ? y : size.height
        if bottom > top {
          let rail = CGRect(x: x - 0.5, y: top, width: 1, height: bottom - top)
          context.fill(Path(rail), with: .color(Palette.muted.opacity(0.32)))
        }
        if index == 0 {
          let ring = CGRect(x: x - 3.5, y: y - 3.5, width: 7, height: 7)
          context.stroke(Path(ellipseIn: ring), with: .color(Palette.accent), lineWidth: 1.5)
          let core = CGRect(x: x - 1, y: y - 1, width: 2, height: 2)
          context.fill(Path(ellipseIn: core), with: .color(Palette.dynamic(0xB8B0A5, 0xF2EFEA)))
        } else {
          let dot = CGRect(x: x - 2, y: y - 2, width: 4, height: 4)
          let tone = Palette.dynamic(0x6E6860, 0xF2EFEA).opacity(0.86 - Double(index - 1) * 0.16)
          context.fill(Path(ellipseIn: dot), with: .color(tone))
        }
      }
      .accessibilityHidden(true)
    }
    .accessibilityElement(children: .combine)
  }

  private func clock(_ date: Date) -> String {
    L10n.clock(date, lang: language)
  }
}
