import SwiftUI
import WidgetKit

struct DayWidgetView: View {
  let family: WidgetFamily
  let date: Date
  let snapshot: WidgetSnapshot
  let iconDirectory: URL?

  private var large: Bool { family == .systemLarge }

  var body: some View {
    // 大号放不下时先少一段，不压缩间距。
    ViewThatFits(in: .vertical) {
      contents(recentCount: large ? 4 : 3)
      contents(recentCount: large ? 3 : 2)
      contents(recentCount: large ? 2 : 1)
    }
    .padding(.horizontal, large ? 18 : 16)
    .padding(.vertical, large ? 18 : 12)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .containerBackground(Palette.paper, for: .widget)
    .widgetURL(snapshot.timelineURL)
  }

  /// 大号分三块：日期和概述、活动条、最近几段，块间留白比块内大，读起来不挤。
  private func contents(recentCount: Int) -> some View {
    VStack(alignment: .leading, spacing: large ? 16 : 4) {
      VStack(alignment: .leading, spacing: large ? 6 : 4) {
        Text(date.formatted(.dateTime.month(.wide).day().weekday(.wide).locale(Locale(identifier: "zh_CN"))))
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
        VStack(alignment: .leading, spacing: large ? 12 : 4) {
          ForEach(Array(snapshot.segments.prefix(recentCount).enumerated()), id: \.offset) { _, segment in
            recentRow(segment)
          }
        }
      } else if snapshot.summary == nil {
        Text("今天暂无时间线内容")
          .font(.system(size: TextSize.body))
          .foregroundStyle(Palette.muted)
          .lineLimit(1)
      }
    }
    .fixedSize(horizontal: false, vertical: true)
  }

  private func activityStrip(_ range: ClosedRange<Date>) -> some View {
    let start = clock(range.lowerBound)
    let end = Calendar.current.isDate(date, inSameDayAs: range.upperBound) ? clock(range.upperBound) : "24:00"
    return VStack(spacing: 4) {
      Canvas { context, size in
        let span = range.upperBound.timeIntervalSince(range.lowerBound)
        guard span > 0 else { return }
        for segment in snapshot.segments where segment.end > segment.start {
          let x = segment.start.timeIntervalSince(range.lowerBound) / span * size.width
          let width = segment.end.timeIntervalSince(segment.start) / span * size.width
          context.fill(Path(CGRect(x: x, y: 0, width: width, height: size.height)), with: .color(Palette.accent))
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
    .accessibilityLabel("当天活动时段")
    .accessibilityValue("\(start) 至 \(end)")
  }

  private func recentRow(_ segment: WidgetSnapshot.Segment) -> some View {
    HStack(alignment: .top, spacing: 10) {
      sourceIcon(segment)
        .accessibilityHidden(true)

      VStack(alignment: .leading, spacing: 2) {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
          Text(segment.title)
            .font(.system(size: TextSize.body, weight: .medium))
            .foregroundStyle(Palette.ink)
            .lineLimit(1)
          Spacer(minLength: 0)
          Text(clock(segment.start))
            .font(.system(size: TextSize.caption).monospacedDigit())
            .foregroundStyle(Palette.muted)
            .fixedSize()
        }
        if large && !segment.description.isEmpty {
          Text(segment.description)
            .font(.system(size: TextSize.caption))
            .foregroundStyle(Palette.muted)
            .lineLimit(1)
        }
      }
    }
    .accessibilityElement(children: .combine)
  }

  @ViewBuilder private func sourceIcon(_ segment: WidgetSnapshot.Segment) -> some View {
    ZStack {
      if let iconDirectory, let name = segment.icon,
         let file = WidgetSnapshot.iconURL(named: name, in: iconDirectory),
         let image = NSImage(contentsOf: file) {
        Image(nsImage: image).resizable().interpolation(.high).scaledToFit()
      } else {
        RoundedRectangle(cornerRadius: 4).fill(Palette.fill)
        Image(systemName: symbol(for: segment.source))
          .font(.system(size: TextSize.caption))
          .foregroundStyle(Palette.muted)
      }
    }
    .frame(width: 16, height: 16)
  }

  private func clock(_ date: Date) -> String {
    date.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).locale(Locale(identifier: "zh_CN")))
  }

  private func symbol(for source: String?) -> String {
    switch source {
    case "mac.screen", "mac.app": "macwindow"
    case "mac.browser": "globe"
    case "claude_code.session": "asterisk"
    case "codex.session": "chevron.left.forwardslash.chevron.right"
    case "mac.shell": "terminal"
    case "mac.git": "point.topleft.down.to.point.bottomright.curvepath"
    case "mac.clipboard": "clipboard"
    case "mac.file": "doc"
    case "mac.calendar": "calendar"
    case "mac.wechat": "bubble.left"
    case "mac.audio": "waveform"
    case "android.audio": "mic"
    case "android.notification": "phone.bubble"
    case "android.usage": "apps.iphone"
    case "manual.note", "manual.agent", "manual.correction": "pencil"
    default: "circle.dashed"
    }
  }
}
