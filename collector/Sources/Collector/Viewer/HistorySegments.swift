import AppKit
import SwiftUI
import CollectorCore

/// 活动段的显示文字：事项名，还没整理的用应用名。
@MainActor enum SegmentText {
  static func appName(_ a: HistorySegment.App) -> String {
    if let name = AppIcons.name(a.app) { return name }
    if let app = a.app, !app.contains(".") { return app }
    return SourceInfo.name(a.source)
  }

  static func title(_ block: SegmentBlock) -> String {
    if let t = block.segment.thread, !t.title.isEmpty { return t.title }
    return block.segment.apps.first.map(appName) ?? block.records.first.map { SourceInfo.name($0.source) } ?? ""
  }

  /// 没提炼的段没有摘要，用记录标题里窗口那一截（去掉"应用名 · "前缀）说明在看什么。
  static func windows(_ block: SegmentBlock, limit: Int = 3) -> String? {
    // "无标题"和与应用名相同的窗口名（如"Claude · Claude"）不提供信息，不显示。
    var seen: Set<String> = ["无标题", "（无标题）", title(block)], out: [String] = []
    for r in block.records where r.source != "mac.audio" {
      guard let t = RecordTitles.display(r.title, source: r.source, appShown: true), seen.insert(t).inserted else { continue }
      out.append(t)
      if out.count == limit { break }
    }
    return out.isEmpty ? nil : out.joined(separator: "、")
  }

  static func time(_ s: HistorySegment) -> String {
    let a = ViewerFormat.clock(s.start), b = ViewerFormat.clock(s.end)
    return a == b ? a : "\(a)–\(b)"
  }
}

/// 列表里的一段活动：事项名作标题，下面是在做什么和涉及的应用。
struct SegmentRow: View {
  let block: SegmentBlock
  /// 段里对话的总结标题，没提炼的段用它说明在聊什么。
  var conversation: String? = nil
  let selected: Bool
  let expanded: Bool
  let action: () -> Void
  @State private var hovering = false

  var segment: HistorySegment { block.segment }

  var body: some View {
    Button(action: action) {
      HStack(alignment: .top, spacing: 12) {
        Text(SegmentText.time(segment))
          .font(.system(size: TextSize.caption)).monospacedDigit()
          .foregroundStyle(Palette.muted)
          .frame(width: RecordRow.timeWidth, alignment: .trailing)
          .lineLimit(1)
          .padding(.top, 2)
        Group {
          if let lead = segment.apps.first { SourceGlyph(source: lead.source, app: lead.app, size: 22) }
          else { SourceGlyph(source: block.records.first?.source ?? "", size: 22) }
        }
        .frame(width: 26)
        VStack(alignment: .leading, spacing: 4) {
          HStack(spacing: 8) {
            Text(SegmentText.title(block))
              .font(.system(size: TextSize.body, weight: .semibold))
              .foregroundStyle(Palette.ink)
              .lineLimit(segment.thread == nil ? 1 : 2)
              .fixedSize(horizontal: false, vertical: true)
              .layoutPriority(1)
            if let p = segment.thread?.projectName { ProjectTag(name: p) }
            if segment.privateCount > 0 { PhIcon("lock", size: 12).foregroundStyle(Palette.muted).help("含私密记录") }
          }
          if let brief = segment.thread?.brief, !brief.isEmpty {
            Text(brief).font(.system(size: TextSize.body)).lineSpacing(3).foregroundStyle(Palette.muted).lineLimit(2).fixedSize(horizontal: false, vertical: true)
          } else if segment.thread == nil, let w = conversation ?? SegmentText.windows(block) {
            Text(w).font(.system(size: TextSize.body)).foregroundStyle(Palette.muted).lineLimit(1)
          }
          if segment.thread != nil || segment.apps.count > 1 { apps }
        }
        Spacer(minLength: 8)
        // 右边：这段活跃了多久（记录时段的并集），有几条原始记录（点开就是这些）。
        HStack(spacing: 12) {
          if segment.activeSeconds >= 60 {
            Text(Fmt.duration(segment.activeSeconds)).monospacedDigit()
          }
          HStack(spacing: 4) {
            Text("\(Fmt.count(block.records.count)) 条").monospacedDigit()
            PhIcon("caret-right", size: 10).rotationEffect(.degrees(expanded ? 90 : 0))
          }
          .help(expanded ? "收起原始记录" : "展开 \(block.records.count) 条原始记录")
        }
        .font(.system(size: TextSize.caption))
        .foregroundStyle(Palette.muted)
        .fixedSize()
        .padding(.top, 2)
      }
      .padding(.vertical, 8)
      .padding(.horizontal, 8)
      .background(alignment: .leading) {
        Rectangle().fill(Palette.hairline).frame(width: 1).padding(.leading, 8 + RecordRow.timeWidth + 12 + 12.5)
      }
      .background {
        RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
          .fill(selected ? Palette.accent.opacity(0.13) : (hovering ? Palette.fill : .clear))
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .onHover { hovering = $0 }
  }

  /// 涉及的应用和各自的时长，最多列 4 个。
  /// 列表窄的时候少列几个，不截断应用名、不把时长折到第二行（侧栏打开时出现过"Tence…""14 / 分钟"）。
  var apps: some View {
    ViewThatFits(in: .horizontal) {
      ForEach(Array(stride(from: min(4, segment.apps.count), through: 1, by: -1)), id: \.self) { n in chips(n) }
    }
    .font(.system(size: TextSize.caption))
    .foregroundStyle(Palette.muted)
  }

  func chips(_ n: Int) -> some View {
    HStack(spacing: 12) {
      ForEach(segment.apps.prefix(n), id: \.self) { a in
        HStack(spacing: 4) {
          SourceGlyph(source: a.source, app: a.app, size: 12)
          Text(SegmentText.appName(a))
          if a.seconds >= 60 { Text(Fmt.duration(a.seconds)).monospacedDigit() }
        }
        .fixedSize()
      }
      if segment.apps.count > n { Text("等 \(segment.apps.count) 个应用").fixedSize() }
    }
  }
}

/// 右侧检查器：这段的概要（时间、应用、在做什么）。原始记录只在左侧列表里展开看，这里不再列一遍。
struct SegmentInspector: View {
  let block: SegmentBlock
  @Environment(ViewerStore.self) private var store
  @State private var detail = Loader<EntityDetail>()

  var segment: HistorySegment { block.segment }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 24) {
        header
        if let t = segment.thread { doing(t) }
        else { undistilled }
        if !segment.apps.isEmpty { appList }
      }
      .padding(20)
    }
    .background(Palette.paper)
    .task(id: LoadKey(thread: segment.thread?.id, revision: store.revision)) {
      if let id = segment.thread?.id { await detail.run { try await store.api.thread(id, level: "detail") } }
    }
  }

  struct LoadKey: Equatable { let thread: String?; let revision: Int }

  var header: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(spacing: 10) {
        HStack(spacing: -8) {
          ForEach(Array(segment.apps.prefix(3).enumerated()), id: \.offset) { i, a in
            SourceGlyph(source: a.source, app: a.app, size: 30).zIndex(Double(3 - i))
          }
        }
        VStack(alignment: .leading, spacing: 2) {
          HStack(spacing: 8) {
            if let p = segment.thread?.projectName {
              if let id = segment.thread?.projectId {
                Button { store.section = .project(id) } label: { ProjectTag(name: p) }.buttonStyle(.plain)
              } else { ProjectTag(name: p) }
            }
            if let s = threadStatus[segment.thread?.status ?? ""], segment.thread?.status != "active" {
              Text(s).font(.system(size: TextSize.caption)).foregroundStyle(Palette.muted)
            }
          }
          Text(timeLine).font(.system(size: TextSize.caption)).monospacedDigit().foregroundStyle(Palette.muted)
        }
      }
      Text(SegmentText.title(block)).font(.serif(TextSize.title, .semibold)).foregroundStyle(Palette.ink)
        .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
    }
  }

  var timeLine: String {
    let c = Calendar.current.dateComponents([.month, .day], from: segment.start)
    var s = "\(c.month!) 月 \(c.day!) 日 \(SegmentText.time(segment))"
    if segment.activeSeconds >= 60 { s += "，活跃 \(Fmt.duration(segment.activeSeconds))" }
    return s
  }

  @ViewBuilder func doing(_ t: HistorySegment.ThreadRef) -> some View {
    VStack(alignment: .leading, spacing: 24) {
      if let brief = detail.value?.brief ?? t.brief, !brief.isEmpty {
        Text(brief)
          .font(.system(size: TextSize.body)).lineSpacing(TextSize.lineSpacing(TextSize.body)).foregroundStyle(Palette.ink)
          .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
      }
      if let d = detail.value {
        DetailBody(detail: d, progressLabel: "进展", progress: d.detail?.progress)
      } else if detail.loading {
        ProgressView().controlSize(.small)
      } else if let e = detail.error {
        Text(e).font(.system(size: TextSize.caption)).foregroundStyle(Palette.muted)
      }
      Button { store.path.append(.thread(t.id)) } label: {
        HStack(spacing: 4) { Text("打开这件事项"); PhIcon("arrow-right", size: 12) }
      }
        .buttonStyle(.accentLink).font(.system(size: TextSize.body))
    }
  }

  /// 没提炼的段没有摘要，用窗口标题说明在看什么。
  var undistilled: some View {
    VStack(alignment: .leading, spacing: 8) {
      if let w = SegmentText.windows(block, limit: 6) {
        Text(w).font(.system(size: TextSize.body)).lineSpacing(TextSize.lineSpacing(TextSize.body)).foregroundStyle(Palette.ink)
          .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
      }
      Text("这段还没整理，整理后会写出在做什么。").font(.system(size: TextSize.caption)).foregroundStyle(Palette.muted)
    }
  }

  var appList: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("应用").sectionTitle()
      VStack(alignment: .leading, spacing: 8) {
        ForEach(segment.apps, id: \.self) { a in
          HStack(spacing: 8) {
            SourceGlyph(source: a.source, app: a.app, size: 16)
            Text(SegmentText.appName(a)).font(.system(size: TextSize.body)).foregroundStyle(Palette.ink)
            Spacer()
            Text(a.seconds >= 60 ? Fmt.duration(a.seconds) : "\(a.records) 条记录")
              .font(.system(size: TextSize.caption)).monospacedDigit().foregroundStyle(Palette.muted)
          }
        }
      }
    }
  }
}

/// 连续几段零碎活动折成的一行：列出涉及的应用，点开再逐段显示。
struct MinorSegmentsRow: View {
  let blocks: [SegmentBlock]
  let expanded: Bool
  let action: () -> Void
  @State private var hovering = false

  /// 按出现次数排的应用，同一应用只算一次。
  var apps: [HistorySegment.App] {
    var seen = Set<String>(), out: [HistorySegment.App] = []
    for b in blocks { for a in b.segment.apps where seen.insert(a.app ?? a.source).inserted { out.append(a) } }
    return out
  }

  var span: String {
    guard let first = blocks.last?.segment, let last = blocks.first?.segment else { return "" }
    let a = ViewerFormat.clock(first.start), b = ViewerFormat.clock(last.end)
    return a == b ? a : "\(a)–\(b)"
  }

  var body: some View {
    Button(action: action) {
      HStack(alignment: .center, spacing: 12) {
        Text(span)
          .font(.system(size: TextSize.caption)).monospacedDigit()
          .foregroundStyle(Palette.muted)
          .frame(width: RecordRow.timeWidth, alignment: .trailing)
          .lineLimit(1)
        // 最多叠 3 个 14pt 图标，总宽正好 26pt，和其他行的图标列对齐。
        HStack(spacing: -8) {
          ForEach(Array(apps.prefix(3).enumerated()), id: \.offset) { _, a in
            SourceGlyph(source: a.source, app: a.app, size: 14)
          }
        }
        .frame(width: 26, alignment: .leading)
        Text(apps.prefix(4).map(SegmentText.appName).joined(separator: "、") + (apps.count > 4 ? " 等" : ""))
          .font(.system(size: TextSize.body))
          .foregroundStyle(Palette.muted)
          .lineLimit(1)
        Spacer(minLength: 8)
        HStack(spacing: 4) {
          Text("\(blocks.count) 段零碎活动").monospacedDigit()
          PhIcon("caret-right", size: 10).rotationEffect(.degrees(expanded ? 90 : 0))
        }
        .font(.system(size: TextSize.caption))
        .foregroundStyle(Palette.muted)
        .fixedSize()
      }
      .padding(.vertical, 8)
      .padding(.horizontal, 8)
      .background {
        RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
          .fill(hovering ? Palette.fill : .clear)
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .onHover { hovering = $0 }
    .help("每段不到 2 分钟、还没整理的活动，折在一起")
  }
}
