import SwiftUI
import CollectorCore

/// 时间线的段与来源活动共用一根时间轴；全部记录页使用原有的记录选择与来源筛选。
struct DayStrata: View {
  struct Chapter: Identifiable, Hashable {
    enum ID: Hashable { case chapter(Int), segment(String) }
    let id: ID
    let start: Date
    let end: Date
    let text: String
  }

  static func chapters(from diary: DayDiary?, on day: Date) -> [Chapter] {
    (diary?.detail?.timeline ?? []).enumerated().compactMap { i, chapter in
      guard let start = ViewerTime.clockOnDay(chapter.start, day: day),
            let end = ViewerTime.clockOnDay(chapter.end, day: day) else { return nil }
      return Chapter(id: .chapter(i), start: start, end: end <= start ? ViewerTime.dayBounds(day).end : end, text: chapter.text)
    }
  }

  let records: [HistoryRecord]
  let chapters: [Chapter]
  let day: Date
  let now: Date
  let selected: String?
  @Binding var brush: ClosedRange<Date>?
  @Binding var lane: Lane?
  /// 对话记录的总结标题（记录 id → 标题），悬停时代替"对话"二字。
  let conversationTitles: [String: String]
  let onSelect: (HistoryRecord) -> Void
  let onSegment: ((String) -> Void)?

  init(records: [HistoryRecord], chapters: [Chapter], day: Date, selected: String?,
       brush: Binding<ClosedRange<Date>?>, lane: Binding<Lane?>, conversationTitles: [String: String] = [:],
       onSelect: @escaping (HistoryRecord) -> Void) {
    self.records = records
    self.chapters = chapters
    self.day = day
    self.now = Date()
    self.selected = selected
    self._brush = brush
    self._lane = lane
    self.conversationTitles = conversationTitles
    self.onSelect = onSelect
    self.onSegment = nil
  }

  init(records: [HistoryRecord], segments: [DayDiary.Item], day: Date, now: Date? = nil, selected: String? = nil,
       brush: Binding<ClosedRange<Date>?>, onSegment: @escaping (String) -> Void) {
    self.records = records
    self.chapters = segments.compactMap { segment in
      guard let start = ViewerTime.parse(segment.tStart), let end = ViewerTime.parse(segment.tEnd), TimelinePresence.hasDuration(activeSeconds: segment.activeSeconds, start: start, end: end) else { return nil }
      return Chapter(id: .segment(segment.id), start: start, end: end, text: segment.title)
    }.sorted { $0.start < $1.start }
    self.day = day
    self.now = now ?? Date()
    self.selected = selected
    self._brush = brush
    self._lane = .constant(nil)
    self.conversationTitles = [:]
    self.onSelect = { _ in }
    self.onSegment = onSegment
  }

  @State private var hover: CGPoint?
  @State private var dragStart: CGFloat?
  @State private var zoom = StrataZoom()
  static let axisHeight: CGFloat = 18
  static let chapterHeight: CGFloat = 22

  var isTimeline: Bool { onSegment != nil }
  var labelWidth: CGFloat { isTimeline ? 6 : 60 }
  var laneHeight: CGFloat { isTimeline ? 2 : 16 }
  var laneGap: CGFloat { isTimeline ? 6 : 5 }
  var lanePitch: CGFloat { laneHeight + laneGap }

  var lanes: [Lane] { isTimeline ? [] : Lane.allCases.filter { l in records.contains { Lane.of($0.source) == l } } }
  var chapterTop: CGFloat { Self.axisHeight + (isTimeline ? 0 : 4) }
  var lanesTop: CGFloat { chapterTop + (chapters.isEmpty ? 0 : Self.chapterHeight + 8) }
  var height: CGFloat { isTimeline ? chapterTop + Self.chapterHeight + 2 : lanesTop + CGFloat(lanes.count) * lanePitch + 2 }

  /// 时间轴只覆盖有活动的小时，前后各留一点；今天会延伸到此刻。
  var fullDomain: ClosedRange<Date> {
    let bounds = ViewerTime.dayBounds(day)
    let cal = Calendar.current
    if isTimeline, let first = chapters.first?.start, let last = chapters.map(\.end).max() {
      let firstHour = cal.dateInterval(of: .hour, for: first)?.start ?? first
      let lastHour = cal.dateInterval(of: .hour, for: last)?.start ?? last
      let endOfActivityHour = last == lastHour ? last : lastHour.addingTimeInterval(3600)
      let lo = max(bounds.start, firstHour.addingTimeInterval(-3600))
      let hi = cal.isDate(day, inSameDayAs: now) ? max(last, now) : endOfActivityHour.addingTimeInterval(3600)
      return lo...max(lo.addingTimeInterval(1), min(bounds.end, hi))
    }
    var lo = records.map(\.start).min() ?? bounds.start.addingTimeInterval(8 * 3600)
    var hi = records.map { $0.end ?? $0.start }.max() ?? bounds.start.addingTimeInterval(20 * 3600)
    for c in chapters { lo = min(lo, c.start); hi = max(hi, c.end) }
    if cal.isDate(day, inSameDayAs: now) { hi = max(hi, now) }
    lo = max(bounds.start, cal.dateInterval(of: .hour, for: lo)?.start ?? lo)
    hi = min(bounds.end, (cal.dateInterval(of: .hour, for: hi)?.end ?? hi))
    if hi.timeIntervalSince(lo) < 4 * 3600 { hi = min(bounds.end, lo.addingTimeInterval(4 * 3600)); lo = min(lo, hi.addingTimeInterval(-4 * 3600)) }
    return lo...max(hi, lo.addingTimeInterval(3600))
  }

  var body: some View {
    GeometryReader { geo in
      let full = fullDomain
      let d = zoom.visible(full)
      let plot = CGRect(x: labelWidth, y: 0, width: max(10, geo.size.width - labelWidth - 6), height: height)
      let _ = { zoom.full = full; zoom.plot = plot }()
      ZStack(alignment: .topLeading) {
        Canvas { ctx, _ in draw(ctx, plot: plot, domain: d) }
          .accessibilityChildren {
            if isTimeline {
              ForEach(chapters) { chapter in
                Button(chapter.text) { openSegment(chapter) }
                  .accessibilityValue(ViewerFormat.clock(chapter.start))
              }
            }
          }
        if !isTimeline { laneLabels }
      }
      .contentShape(Rectangle())
      .onContinuousHover { phase in
        if case .active(let p) = phase { hover = p; zoom.hoverX = p.x } else { hover = nil; zoom.hoverX = nil }
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
      .overlay(alignment: .topTrailing) { zoomControls }
    }
    .frame(height: height)
    .animation(.smooth(duration: 0.25), value: lane)
    .onAppear { zoom.install() }
    .onDisappear { zoom.uninstall() }
    .onChange(of: day) { zoom.window = nil }
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
    let offset = y - lanesTop + (isTimeline ? laneGap / 2 : 0)
    let i = Int(offset / lanePitch)
    return offset >= 0 && i < lanes.count ? i : nil
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

  struct ChapterSlot {
    let chapter: Chapter
    let lo: CGFloat
    let hi: CGFloat
    let labelWidth: CGFloat?

    func distance(to x: CGFloat) -> CGFloat { max(lo - x, x - hi, 0) }
  }

  func chapterSlots(plot: CGRect, domain d: ClosedRange<Date>) -> [ChapterSlot] {
    let shown = chapters.filter { c in
      if c.start == c.end { return d.contains(c.start) }
      return c.end > d.lowerBound && c.start < d.upperBound
    }
    let spans = shown.map { c in (lo: x(max(c.start, d.lowerBound), plot, d), hi: x(min(c.end, d.upperBound), plot, d)) }
    if isTimeline {
      return zip(shown, spans).map { chapter, span in
        ChapterSlot(chapter: chapter, lo: span.lo, hi: span.hi, labelWidth: span.hi - span.lo - 12)
      }
    }
    // 旧回顾章节可能交叉，全部记录页仍按下一段的起点裁切。
    return ChapterStrip.layout(spans.map { (lo: Double($0.lo), hi: Double($0.hi)) }).map {
      ChapterSlot(chapter: shown[$0.index], lo: CGFloat($0.lo), hi: CGFloat($0.hi), labelWidth: $0.label.map { CGFloat($0) })
    }
  }

  func chapter(at p: CGPoint, plot: CGRect, domain d: ClosedRange<Date>) -> Chapter? {
    guard p.x >= plot.minX, p.x <= plot.maxX, p.y >= chapterTop, p.y <= chapterTop + Self.chapterHeight else { return nil }
    let slots = chapterSlots(plot: plot, domain: d)
    if isTimeline {
      // 让短于一个像素的段也可点击；相距很近时优先命中实际覆盖指针的段。
      return slots.filter { $0.distance(to: p.x) <= 3 }
        .min { a, b in (a.distance(to: p.x), a.hi - a.lo) < (b.distance(to: p.x), b.hi - b.lo) }?.chapter
    }
    return slots.first { $0.distance(to: p.x) == 0 }?.chapter
  }

  func openSegment(_ chapter: Chapter) {
    guard case .segment(let id) = chapter.id else { return }
    brush = nil
    onSegment?(id)
  }

  func click(_ p: CGPoint, plot: CGRect, domain d: ClosedRange<Date>) {
    if isTimeline {
      if let chapter = chapter(at: p, plot: plot, domain: d) { openSegment(chapter) }
      else { brush = nil }
    } else if p.x < plot.minX, let i = laneIndex(at: p.y) {
      lane = lane == lanes[i] ? nil : lanes[i]
    } else if let c = chapter(at: p, plot: plot, domain: d) {
      brush = brush == c.start...c.end ? nil : c.start...c.end
    } else if let r = hit(p, plot: plot, domain: d) {
      onSelect(r)
    } else if brush != nil {
      brush = nil
    }
  }

  /// 有框选时可以放大到选区；放大后可以复位。
  @ViewBuilder var zoomControls: some View {
    let canZoomToBrush = brush.map { b in
      zoom.window.map { b.upperBound.timeIntervalSince(b.lowerBound) < $0.upperBound.timeIntervalSince($0.lowerBound) * 0.9 } ?? true
    } ?? false
    if canZoomToBrush || zoom.window != nil {
      HStack(spacing: 4) {
        if canZoomToBrush, let b = brush {
          Button { withAnimation(.easeOut(duration: 0.2)) { zoom.show(b) } } label: { PhIcon("magnifying-glass-plus", size: 14).frame(width: 22, height: 20) }
            .help("放大到选区").accessibilityLabel("放大到选区")
        }
        if zoom.window != nil {
          Button { withAnimation(.easeOut(duration: 0.2)) { zoom.window = nil } } label: { PhIcon("arrows-out", size: 14).frame(width: 22, height: 20) }
            .help("看整天").accessibilityLabel("看整天")
        }
      }
      .buttonStyle(.plain)
      .foregroundStyle(Palette.muted)
      .padding(.horizontal, 4).padding(.vertical, 2)
      .background(Palette.paperRaised, in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
      .overlay(RoundedRectangle(cornerRadius: Radius.control, style: .continuous).strokeBorder(Palette.hairline))
      .offset(y: -4)
      .transition(.opacity)
    }
  }

  // MARK: 绘制

  /// 刻度：主刻度标时间，次刻度只画淡线。按可见宽度挑最细的一档。
  static let tickSteps: [TimeInterval] = [60, 120, 300, 600, 900, 1800, 3600, 7200, 10800]
  static func ticks(span: TimeInterval, width: CGFloat) -> (major: TimeInterval, minor: TimeInterval?) {
    let major = tickSteps.first { span / $0 <= Double(width) / 72 } ?? tickSteps.last!
    let minor = tickSteps.last { $0 < major && major.truncatingRemainder(dividingBy: $0) == 0 && span / $0 <= Double(width) / 12 }
    return (major, minor)
  }

  var laneLabels: some View {
    VStack(alignment: .leading, spacing: laneGap) {
      ForEach(lanes, id: \.self) { l in
        Text(l.name)
          .font(.system(size: TextSize.caption, weight: lane == l ? .semibold : .regular))
          .foregroundStyle(lane == nil || lane == l ? Palette.muted : Palette.faint)
          .lineLimit(1).fixedSize()
          .frame(width: labelWidth - 8, height: laneHeight, alignment: .leading)
      }
    }
    .padding(.top, lanesTop)
    .allowsHitTesting(false)
  }

  func draw(_ ctx: GraphicsContext, plot: CGRect, domain d: ClosedRange<Date>) {
    let cal = Calendar.current
    let span = d.upperBound.timeIntervalSince(d.lowerBound)
    let (major, minor) = Self.ticks(span: span, width: plot.width)
    let step = minor ?? major
    let bottom = height - 2
    let dayStart = cal.startOfDay(for: day)
    // 缩放后画在可见范围外的部分要裁掉，泳道标签在左边不受影响。
    let labels = ctx
    var ctx = ctx
    ctx.clip(to: Path(CGRect(x: plot.minX - 4, y: 0, width: plot.width + 8, height: height)))

    // 刻度：按当天零点对齐
    var t = dayStart.addingTimeInterval((d.lowerBound.timeIntervalSince(dayStart) / step).rounded(.up) * step)
    while t <= d.upperBound {
      let px = x(t, plot, d)
      let offset = t.timeIntervalSince(dayStart)
      let isMajor = abs(offset.remainder(dividingBy: major)) < 1
      var line = Path(); line.move(to: CGPoint(x: px, y: Self.axisHeight)); line.addLine(to: CGPoint(x: px, y: bottom))
      ctx.stroke(line, with: .color(Palette.ink.opacity(isTimeline ? (isMajor ? 0.055 : 0.025) : (isMajor ? 0.08 : 0.035))), lineWidth: 1)
      if isMajor {
        let label = major >= 3600 ? String(format: "%02d", cal.component(.hour, from: t)) : ViewerFormat.clock(t)
        let text = labels.resolve(Text(label).font(.system(size: TextSize.caption)).monospacedDigit().foregroundStyle(Palette.muted))
        let halfWidth = text.measure(in: CGSize(width: 100, height: Self.axisHeight)).width / 2
        let labelX = min(max(px, halfWidth), plot.maxX - halfWidth)
        labels.draw(text, at: CGPoint(x: labelX, y: 8), anchor: .center)
      }
      t = t.addingTimeInterval(step)
    }

    if isTimeline {
      var baseline = Path()
      baseline.move(to: CGPoint(x: plot.minX, y: chapterTop + Self.chapterHeight / 2))
      baseline.addLine(to: CGPoint(x: plot.maxX, y: chapterTop + Self.chapterHeight / 2))
      ctx.stroke(baseline, with: .color(Palette.hairline), lineWidth: 1)
    }

    for (i, slot) in chapterSlots(plot: plot, domain: d).enumerated() {
      let c = slot.chapter
      let w = max(isTimeline ? 1 : 0, slot.hi - slot.lo)
      let inset: CGFloat = w > 2 ? 0.5 : 0
      let full = CGRect(x: min(slot.lo, plot.maxX - w) + inset, y: chapterTop, width: w - 2 * inset, height: Self.chapterHeight)
      let active: Bool
      switch c.id {
      case .segment(let id): active = id == selected
      case .chapter: active = brush == c.start...c.end
      }
      let label = slot.labelWidth.flatMap { fitted(c.text, width: $0, ctx: ctx) }
      let rect = label == nil ? CGRect(x: full.minX, y: full.midY - (isTimeline ? 4 : 3), width: full.width, height: isTimeline ? 8 : 6) : full
      let outsideBrush = isTimeline && (brush.map { c.end < $0.lowerBound || c.start > $0.upperBound } ?? false)
      let alpha = outsideBrush ? 0.06 : isTimeline ? (label == nil ? 0.42 : 0.15) : label == nil ? 0.16 : (i % 2 == 0 ? 0.08 : 0.05)
      ctx.fill(Path(roundedRect: rect, cornerRadius: min(Radius.control, rect.height / 2)),
               with: .color((isTimeline || active ? Palette.accent : Palette.ink).opacity(active ? 0.3 : alpha)))
      if let label { ctx.draw(label, at: CGPoint(x: rect.minX + 6, y: rect.midY), anchor: .leading) }
    }

    // 泳道底色
    for (i, l) in lanes.enumerated() {
      let y = lanesTop + CGFloat(i) * lanePitch
      let dim = lane != nil && lane != l
      ctx.fill(Path(roundedRect: CGRect(x: plot.minX, y: y, width: plot.width, height: laneHeight), cornerRadius: min(Radius.control, laneHeight / 2)),
               with: .color(Palette.ink.opacity(dim ? 0.02 : 0.05)))
    }

    // 活动
    var selectedRect: CGRect?
    for r in records {
      guard let i = lanes.firstIndex(of: Lane.of(r.source)) else { continue }
      let y = lanesTop + CGFloat(i) * lanePitch
      let a = x(r.start, plot, d)
      let recordSelected = !isTimeline && r.id == selected
      let color = recordSelected ? Palette.accent : Palette.muted
      let dim = (lane != nil && lane != Lane.of(r.source)) || (brush.map { !overlaps(r, $0) } ?? false)
      let alpha = dim ? 0.25 : isTimeline ? 0.7 : 0.9
      if r.isSpan, let e = r.end, x(e, plot, d) - a >= 2 {
        let inset: CGFloat = isTimeline ? 0 : 2
        let rect = CGRect(x: a, y: y + inset, width: x(e, plot, d) - a, height: laneHeight - 2 * inset)
        ctx.fill(Path(roundedRect: rect, cornerRadius: min(Radius.control, rect.height / 2, rect.width / 2)), with: .color(color.opacity(alpha)))
        if recordSelected { selectedRect = rect }
      } else {
        let inset: CGFloat = isTimeline ? 0 : 3
        let rect = CGRect(x: a - 1, y: y + inset, width: 2, height: laneHeight - 2 * inset)
        ctx.fill(Path(roundedRect: rect, cornerRadius: rect.width / 2), with: .color(color.opacity(alpha)))
        if recordSelected { selectedRect = rect }
      }
    }

    // 框选
    if let b = brush {
      let a = x(max(b.lowerBound, d.lowerBound), plot, d), e = x(min(b.upperBound, d.upperBound), plot, d)
      let rect = CGRect(x: a, y: Self.axisHeight, width: max(2, e - a), height: bottom - Self.axisHeight)
      ctx.fill(Path(roundedRect: rect, cornerRadius: Radius.control), with: .color(Palette.accent.opacity(0.08)))
      ctx.stroke(Path(roundedRect: rect, cornerRadius: Radius.control), with: .color(Palette.accent.opacity(0.55)), lineWidth: 1)
    }

    // 选中
    if let s = selectedRect {
      let ring = s.insetBy(dx: -3, dy: -3)
      ctx.stroke(Path(roundedRect: ring, cornerRadius: Radius.control), with: .color(Palette.accent), lineWidth: 1.5)
    }

    // 此刻（当前位置用强调色）
    if cal.isDate(day, inSameDayAs: now) {
      let px = x(now, plot, d)
      var line = Path(); line.move(to: CGPoint(x: px, y: Self.axisHeight - 2)); line.addLine(to: CGPoint(x: px, y: bottom))
      ctx.stroke(line, with: .color(Palette.accent), lineWidth: 1.2)
      ctx.fill(Path(ellipseIn: CGRect(x: px - 3, y: Self.axisHeight - 5, width: 6, height: 6)), with: .color(Palette.accent))
    }

    // 悬停指示线
    if let h = hover, h.x >= plot.minX, h.x <= plot.maxX {
      var line = Path(); line.move(to: CGPoint(x: h.x, y: Self.axisHeight)); line.addLine(to: CGPoint(x: h.x, y: bottom))
      ctx.stroke(line, with: .color(Palette.ink.opacity(0.25)), style: StrokeStyle(lineWidth: 1, dash: [2, 2]))
    }
  }

  /// 时间线只放完整标题，全部记录页仍允许旧章节带省略号。
  func fitted(_ text: String, width: CGFloat, ctx: GraphicsContext) -> GraphicsContext.ResolvedText? {
    func resolve(_ s: String) -> GraphicsContext.ResolvedText {
      ctx.resolve(Text(s).font(.system(size: TextSize.caption)).foregroundStyle(Palette.ink))
    }
    let full = resolve(text)
    if full.measure(in: CGSize(width: 10_000, height: 20)).width <= width { return full }
    guard !isTimeline else { return nil }
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
    if let h = hover, dragStart == nil, h.x >= plot.minX, h.x <= plot.maxX {
      let r = hit(h, plot: plot, domain: d)
      let c = r == nil ? chapter(at: h, plot: plot, domain: d) : nil
      let source = isTimeline ? (r.map { SourceInfo.name($0.source) } ?? laneIndex(at: h.y).map { lanes[$0].name }) : nil
      let time = ViewerFormat.clock(self.time(h.x, plot, d))
      let titleWidth: CGFloat = (r != nil && !isTimeline) || c != nil ? 300 : 96
      VStack(alignment: .leading, spacing: 4) {
        if let source {
          Text(source).font(.system(size: TextSize.caption)).foregroundStyle(Palette.ink)
        } else if let r, !isTimeline {
          HStack(spacing: 8) {
            Text(SourceInfo.name(r.source))
            Text(range(r)).monospacedDigit()
          }
          .font(.system(size: TextSize.caption)).foregroundStyle(Palette.muted)
          Text(conversationTitles[r.id] ?? RecordText.title(r, appShown: false)).font(.system(size: TextSize.body, weight: .medium)).foregroundStyle(Palette.ink).lineLimit(2)
        } else if let c {
          let t = self.time(h.x, plot, d)
          let all = isTimeline ? [c] : [c] + chapters.filter { $0 != c && $0.start <= t && t <= $0.end }.prefix(2)
          ForEach(all) { c in
            Text("\(ViewerFormat.clock(c.start))–\(ViewerFormat.clock(c.end))").font(.system(size: TextSize.caption)).monospacedDigit()
              .foregroundStyle(Palette.muted)
              .padding(.top, c == all[0] ? 0 : 4)
            Text(c.text).font(.system(size: TextSize.body)).foregroundStyle(Palette.ink)
          }
        } else {
          Text(time).font(.system(size: TextSize.caption, weight: .medium)).monospacedDigit().foregroundStyle(Palette.ink)
        }
      }
      .fixedSize(horizontal: false, vertical: true)
      .frame(maxWidth: titleWidth == 300 ? titleWidth : nil, alignment: .leading)
      .padding(.horizontal, 12).padding(.vertical, 8)
      .background(Palette.paperRaised, in: RoundedRectangle(cornerRadius: Radius.group, style: .continuous))
      .overlay(RoundedRectangle(cornerRadius: Radius.group, style: .continuous).strokeBorder(Palette.hairline))
      .shadow(color: .black.opacity(0.12), radius: 8, y: 2)
      .offset(x: min(max(0, h.x - 24), max(0, width - titleWidth)), y: height + 6)
      .allowsHitTesting(false)
      .transition(.opacity)
    }
  }

  func range(_ r: HistoryRecord) -> String {
    guard let e = r.end, ViewerFormat.clock(e) != ViewerFormat.clock(r.start) else { return ViewerFormat.clock(r.start) }
    return "\(ViewerFormat.clock(r.start))–\(ViewerFormat.clock(e))"
  }
}
