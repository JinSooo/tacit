import SwiftUI
import CollectorCore

/// 一天的条带图：上面一条是日记的章节，下面按来源分泳道画出每一段活动。
/// 悬停看标题，点一下选中记录，拖动框选一个时间段来筛选列表。
struct DayStrata: View {
  struct Chapter: Identifiable, Hashable { let id: Int; let start: Date; let end: Date; let text: String }

  let records: [HistoryRecord]
  let chapters: [Chapter]
  let day: Date
  let selected: String?
  @Binding var brush: ClosedRange<Date>?
  @Binding var lane: Lane?
  let onSelect: (HistoryRecord) -> Void

  @State private var hover: CGPoint?
  @State private var dragStart: CGFloat?
  @Environment(\.colorScheme) private var scheme

  static let labelWidth: CGFloat = 48
  static let axisHeight: CGFloat = 18
  static let chapterHeight: CGFloat = 22
  static let laneHeight: CGFloat = 16
  static let laneGap: CGFloat = 5

  var lanes: [Lane] { Lane.allCases.filter { l in records.contains { Lane.of($0.source) == l } } }
  var chapterTop: CGFloat { Self.axisHeight + 4 }
  var lanesTop: CGFloat { chapterTop + (chapters.isEmpty ? 0 : Self.chapterHeight + 8) }
  var height: CGFloat { lanesTop + CGFloat(lanes.count) * (Self.laneHeight + Self.laneGap) + 2 }

  /// 时间轴只覆盖有活动的小时，前后各留一点；今天会延伸到此刻。
  var domain: ClosedRange<Date> {
    let bounds = ViewerTime.dayBounds(day)
    let cal = Calendar.current
    var lo = records.map(\.start).min() ?? bounds.start.addingTimeInterval(8 * 3600)
    var hi = records.map { $0.end ?? $0.start }.max() ?? bounds.start.addingTimeInterval(20 * 3600)
    for c in chapters { lo = min(lo, c.start); hi = max(hi, c.end) }
    if cal.isDateInToday(day) { hi = max(hi, Date()) }
    lo = max(bounds.start, cal.dateInterval(of: .hour, for: lo)?.start ?? lo)
    hi = min(bounds.end, (cal.dateInterval(of: .hour, for: hi)?.end ?? hi))
    if hi.timeIntervalSince(lo) < 4 * 3600 { hi = min(bounds.end, lo.addingTimeInterval(4 * 3600)); lo = min(lo, hi.addingTimeInterval(-4 * 3600)) }
    return lo...max(hi, lo.addingTimeInterval(3600))
  }

  var body: some View {
    GeometryReader { geo in
      let d = domain
      let plot = CGRect(x: Self.labelWidth, y: 0, width: max(10, geo.size.width - Self.labelWidth - 6), height: height)
      ZStack(alignment: .topLeading) {
        Canvas { ctx, _ in draw(ctx, plot: plot, domain: d) }
        laneLabels
      }
      .contentShape(Rectangle())
      .onContinuousHover { phase in
        if case .active(let p) = phase { hover = p } else { hover = nil }
      }
      .gesture(
        DragGesture(minimumDistance: 0)
          .onChanged { g in
            hover = g.location
            if dragStart == nil { dragStart = g.startLocation.x }
            if abs(g.translation.width) > 4, let s = dragStart, s >= plot.minX {
              let a = time(s, plot, d), b = time(g.location.x, plot, d)
              brush = min(a, b)...max(a, b)
            }
          }
          .onEnded { g in
            defer { dragStart = nil }
            guard abs(g.translation.width) <= 4 else { return }
            click(g.location, plot: plot, domain: d)
          }
      )
      .overlay(alignment: .topLeading) { tooltip(plot: plot, domain: d, width: geo.size.width) }
    }
    .frame(height: height)
    .animation(.smooth(duration: 0.25), value: lane)
  }

  // MARK: 交互

  func x(_ t: Date, _ plot: CGRect, _ d: ClosedRange<Date>) -> CGFloat {
    plot.minX + CGFloat(t.timeIntervalSince(d.lowerBound) / d.upperBound.timeIntervalSince(d.lowerBound)) * plot.width
  }
  func time(_ x: CGFloat, _ plot: CGRect, _ d: ClosedRange<Date>) -> Date {
    let f = min(1, max(0, (x - plot.minX) / plot.width))
    return d.lowerBound.addingTimeInterval(Double(f) * d.upperBound.timeIntervalSince(d.lowerBound))
  }

  func laneIndex(at y: CGFloat) -> Int? {
    let i = Int((y - lanesTop) / (Self.laneHeight + Self.laneGap))
    return y >= lanesTop && i < lanes.count ? i : nil
  }

  func hit(_ p: CGPoint, plot: CGRect, domain d: ClosedRange<Date>) -> HistoryRecord? {
    guard let i = laneIndex(at: p.y), p.x >= plot.minX else { return nil }
    let l = lanes[i]
    var best: (HistoryRecord, CGFloat)?
    for r in records where Lane.of(r.source) == l {
      let a = x(r.start, plot, d), b = max(a + 2, x(r.end ?? r.start, plot, d))
      let dist: CGFloat = p.x < a ? a - p.x : (p.x > b ? p.x - b : 0)
      if dist <= 4, best == nil || dist < best!.1 || (dist == best!.1 && b - a < 6) { best = (r, dist) }
    }
    return best?.0
  }

  func chapter(at p: CGPoint, plot: CGRect, domain d: ClosedRange<Date>) -> Chapter? {
    guard !chapters.isEmpty, p.y >= chapterTop, p.y <= chapterTop + Self.chapterHeight else { return nil }
    let t = time(p.x, plot, d)
    return chapters.first { $0.start <= t && t <= $0.end }
  }

  func click(_ p: CGPoint, plot: CGRect, domain d: ClosedRange<Date>) {
    if p.x < plot.minX, let i = laneIndex(at: p.y) {
      lane = lane == lanes[i] ? nil : lanes[i]
    } else if let c = chapter(at: p, plot: plot, domain: d) {
      brush = brush == c.start...c.end ? nil : c.start...c.end
    } else if let r = hit(p, plot: plot, domain: d) {
      onSelect(r)
    } else if brush != nil {
      brush = nil
    }
  }

  // MARK: 绘制

  var laneLabels: some View {
    VStack(alignment: .leading, spacing: Self.laneGap) {
      ForEach(lanes, id: \.self) { l in
        Text(l.title)
          .font(.system(size: 10, weight: lane == l ? .bold : .medium))
          .foregroundStyle(lane == nil || lane == l ? AnyShapeStyle(.secondary) : AnyShapeStyle(.quaternary))
          .frame(width: Self.labelWidth - 8, height: Self.laneHeight, alignment: .leading)
      }
    }
    .padding(.top, lanesTop)
    .allowsHitTesting(false)
  }

  func draw(_ ctx: GraphicsContext, plot: CGRect, domain d: ClosedRange<Date>) {
    let cal = Calendar.current
    let span = d.upperBound.timeIntervalSince(d.lowerBound)
    let step: TimeInterval = span > 14 * 3600 ? 3 * 3600 : span > 7 * 3600 ? 2 * 3600 : 3600
    let bottom = height - 2

    // 小时刻度
    var t = cal.dateInterval(of: .hour, for: d.lowerBound)?.start ?? d.lowerBound
    if t < d.lowerBound { t = t.addingTimeInterval(3600) }
    while t <= d.upperBound {
      let px = x(t, plot, d)
      let h = cal.component(.hour, from: t)
      var line = Path(); line.move(to: CGPoint(x: px, y: Self.axisHeight)); line.addLine(to: CGPoint(x: px, y: bottom))
      ctx.stroke(line, with: .color(.primary.opacity(h % Int(step / 3600) == 0 ? 0.08 : 0.035)), lineWidth: 1)
      if h % Int(step / 3600) == 0 {
        ctx.draw(Text(String(format: "%02d", h)).font(.mono(9.5, .medium)).foregroundStyle(.tertiary), at: CGPoint(x: px, y: 8), anchor: .center)
      }
      t = t.addingTimeInterval(3600)
    }

    // 日记章节
    for (i, c) in chapters.enumerated() {
      let a = x(max(c.start, d.lowerBound), plot, d), b = x(min(c.end, d.upperBound), plot, d)
      guard b - a > 1 else { continue }
      let full = CGRect(x: a + 0.5, y: chapterTop, width: b - a - 1, height: Self.chapterHeight)
      let active = brush == c.start...c.end
      let label = full.width > 40 ? fitted(c.text, width: full.width - 12, ctx: ctx) : nil
      let rect = label == nil ? CGRect(x: full.minX, y: full.midY - 3, width: full.width, height: 6) : full
      ctx.fill(Path(roundedRect: rect, cornerRadius: min(6, rect.height / 2)),
               with: .color(Palette.accent.opacity(active ? 0.45 : (label == nil ? 0.3 : (i % 2 == 0 ? 0.13 : 0.08)))))
      if let label { ctx.draw(label, at: CGPoint(x: rect.minX + 6, y: rect.midY), anchor: .leading) }
    }

    // 泳道底色
    for (i, l) in lanes.enumerated() {
      let y = lanesTop + CGFloat(i) * (Self.laneHeight + Self.laneGap)
      let dim = lane != nil && lane != l
      ctx.fill(Path(roundedRect: CGRect(x: plot.minX, y: y, width: plot.width, height: Self.laneHeight), cornerRadius: 4),
               with: .color(.primary.opacity(dim ? 0.015 : 0.035)))
    }

    // 活动
    var selectedRect: CGRect?
    for r in records {
      guard let i = lanes.firstIndex(of: Lane.of(r.source)) else { continue }
      let y = lanesTop + CGFloat(i) * (Self.laneHeight + Self.laneGap)
      let a = x(r.start, plot, d)
      let color = Palette.source(r.source)
      let dim = (lane != nil && lane != Lane.of(r.source)) || (brush.map { !overlaps(r, $0) } ?? false)
      let alpha = dim ? 0.18 : 0.9
      if r.isSpan, let e = r.end, x(e, plot, d) - a >= 2 {
        let rect = CGRect(x: a, y: y + 2, width: x(e, plot, d) - a, height: Self.laneHeight - 4)
        ctx.fill(Path(roundedRect: rect, cornerRadius: min(3, rect.height / 2)), with: .color(color.opacity(alpha)))
        if r.id == selected { selectedRect = rect }
      } else {
        let rect = CGRect(x: a - 1, y: y + 3, width: 2, height: Self.laneHeight - 6)
        ctx.fill(Path(roundedRect: rect, cornerRadius: 1), with: .color(color.opacity(alpha)))
        if r.id == selected { selectedRect = rect }
      }
    }

    // 框选
    if let b = brush {
      let a = x(max(b.lowerBound, d.lowerBound), plot, d), e = x(min(b.upperBound, d.upperBound), plot, d)
      let rect = CGRect(x: a, y: Self.axisHeight, width: max(2, e - a), height: bottom - Self.axisHeight)
      ctx.fill(Path(roundedRect: rect, cornerRadius: 5), with: .color(Palette.accent.opacity(0.08)))
      ctx.stroke(Path(roundedRect: rect, cornerRadius: 5), with: .color(Palette.accent.opacity(0.55)), lineWidth: 1)
    }

    // 选中
    if let s = selectedRect {
      let ring = s.insetBy(dx: -3, dy: -3)
      ctx.stroke(Path(roundedRect: ring, cornerRadius: 5), with: .color(.primary.opacity(0.85)), lineWidth: 1.5)
    }

    // 此刻
    if cal.isDateInToday(day) {
      let px = x(Date(), plot, d)
      var line = Path(); line.move(to: CGPoint(x: px, y: Self.axisHeight - 2)); line.addLine(to: CGPoint(x: px, y: bottom))
      ctx.stroke(line, with: .color(Palette.recording.opacity(0.8)), lineWidth: 1.2)
      ctx.fill(Path(ellipseIn: CGRect(x: px - 3, y: Self.axisHeight - 5, width: 6, height: 6)), with: .color(Palette.recording))
    }

    // 悬停指示线
    if let h = hover, h.x >= plot.minX, h.x <= plot.maxX {
      var line = Path(); line.move(to: CGPoint(x: h.x, y: Self.axisHeight)); line.addLine(to: CGPoint(x: h.x, y: bottom))
      ctx.stroke(line, with: .color(.primary.opacity(0.25)), style: StrokeStyle(lineWidth: 1, dash: [2, 2]))
    }
  }

  /// 章节标题按宽度截断，末尾加省略号；连两个字都放不下就不画。
  func fitted(_ text: String, width: CGFloat, ctx: GraphicsContext) -> GraphicsContext.ResolvedText? {
    func resolve(_ s: String) -> GraphicsContext.ResolvedText {
      ctx.resolve(Text(s).font(.system(size: 10, weight: .medium)).foregroundStyle(Palette.accent))
    }
    let full = resolve(text)
    if full.measure(in: CGSize(width: 10_000, height: 20)).width <= width { return full }
    var chars = Array(text)
    while chars.count > 2 {
      chars.removeLast(max(1, chars.count / 8))
      let r = resolve(String(chars) + "…")
      if r.measure(in: CGSize(width: 10_000, height: 20)).width <= width { return r }
    }
    return nil
  }

  func overlaps(_ r: HistoryRecord, _ b: ClosedRange<Date>) -> Bool {
    r.start <= b.upperBound && (r.end ?? r.start) >= b.lowerBound
  }

  @ViewBuilder func tooltip(plot: CGRect, domain d: ClosedRange<Date>, width: CGFloat) -> some View {
    if let h = hover, dragStart == nil, h.x >= plot.minX {
      let r = hit(h, plot: plot, domain: d)
      let c = r == nil ? chapter(at: h, plot: plot, domain: d) : nil
      let time = ViewerFormat.clock(self.time(h.x, plot, d))
      VStack(alignment: .leading, spacing: 3) {
        if let r {
          HStack(spacing: 6) {
            Circle().fill(Palette.source(r.source)).frame(width: 6, height: 6)
            Text(SourceInfo.name(r.source)).foregroundStyle(.secondary)
            Text(range(r)).font(.mono(10)).foregroundStyle(.tertiary)
          }
          .font(.system(size: 10.5, weight: .medium))
          Text(r.title).font(.system(size: 12, weight: .medium)).lineLimit(2)
        } else if let c {
          Text("\(ViewerFormat.clock(c.start))–\(ViewerFormat.clock(c.end))").font(.mono(10)).foregroundStyle(.secondary)
          Text(c.text).font(.serif(12.5)).lineLimit(4)
        } else {
          Text(time).font(.mono(10.5, .medium))
        }
      }
      .fixedSize(horizontal: false, vertical: true)
      .frame(maxWidth: r == nil && c == nil ? nil : 300, alignment: .leading)
      .padding(.horizontal, 10).padding(.vertical, 7)
      .glassPanel(10)
      .offset(x: min(max(0, h.x - 24), width - (r == nil && c == nil ? 60 : 300)), y: height + 6)
      .allowsHitTesting(false)
      .transition(.opacity)
    }
  }

  func range(_ r: HistoryRecord) -> String {
    guard let e = r.end, ViewerFormat.clock(e) != ViewerFormat.clock(r.start) else { return ViewerFormat.clock(r.start) }
    return "\(ViewerFormat.clock(r.start))–\(ViewerFormat.clock(e))"
  }
}
