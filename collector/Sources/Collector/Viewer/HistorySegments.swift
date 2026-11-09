import AppKit
import SwiftUI
import CollectorCore

/// 活动段的显示文字：线程名，没提炼的用应用名。
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
    for r in block.records {
      var t = r.title
      if let range = t.range(of: " · ") {
        let app = String(t[..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
        t = String(t[range.upperBound...])
        seen.insert(app)
      }
      t = t.trimmingCharacters(in: .whitespaces)
      if t.isEmpty || !seen.insert(t).inserted { continue }
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

/// 列表里的一段活动：线程名作标题，下面是在做什么和涉及的应用。
struct SegmentRow: View {
  let block: SegmentBlock
  let selected: Bool
  let expanded: Bool
  let action: () -> Void
  @State private var hovering = false

  var segment: HistorySegment { block.segment }

  var body: some View {
    Button(action: action) {
      HStack(alignment: .top, spacing: 12) {
        Text(SegmentText.time(segment))
          .font(.mono(11))
          .foregroundStyle(.secondary)
          .frame(width: RecordRow.timeWidth, alignment: .trailing)
          .lineLimit(1)
          .padding(.top, 4)
        Group {
          if let lead = segment.apps.first { SourceGlyph(source: lead.source, app: lead.app, size: 22) }
          else { SourceGlyph(source: block.records.first?.source ?? "", size: 22) }
        }
        .frame(width: 26)
        VStack(alignment: .leading, spacing: 4) {
          HStack(spacing: 8) {
            Text(SegmentText.title(block))
              .font(.system(size: 13.5, weight: .semibold))
              .lineLimit(1)
            if let p = segment.thread?.projectName { ProjectTag(name: p) }
            if segment.privateCount > 0 { Image(systemName: "lock.fill").font(.system(size: 9)).foregroundStyle(.secondary) }
          }
          if let brief = segment.thread?.brief, !brief.isEmpty {
            Text(brief).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(2).fixedSize(horizontal: false, vertical: true)
          } else if segment.thread == nil, let w = SegmentText.windows(block) {
            Text(w).font(.system(size: 11.5)).foregroundStyle(.tertiary).lineLimit(1)
          }
          if segment.thread != nil || segment.apps.count > 1 { apps }
        }
        Spacer(minLength: 8)
        HStack(spacing: 10) {
          if segment.activeSeconds >= 60 {
            Text(ViewerFormat.duration(segment.activeSeconds)).font(.system(size: 11)).monospacedDigit().foregroundStyle(.tertiary)
          }
          HStack(spacing: 3) {
            Text("\(block.records.count)").monospacedDigit()
            Image(systemName: "chevron.right").font(.system(size: 8, weight: .bold)).rotationEffect(.degrees(expanded ? 90 : 0))
          }
          .font(.system(size: 10.5, weight: .semibold))
          .foregroundStyle(.secondary)
          .padding(.horizontal, 6).padding(.vertical, 2)
          .background(.primary.opacity(0.06), in: Capsule())
          .help("\(block.records.count) 条原始记录")
        }
        .padding(.top, 3)
      }
      .padding(.vertical, 8)
      .padding(.horizontal, 8)
      .background(alignment: .leading) {
        Rectangle().fill(Palette.hairline).frame(width: 1).padding(.leading, 8 + RecordRow.timeWidth + 12 + 12.5)
      }
      .background {
        RoundedRectangle(cornerRadius: 9, style: .continuous)
          .fill(selected ? Palette.accent.opacity(0.13) : (hovering ? Color.primary.opacity(0.04) : .clear))
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .onHover { hovering = $0 }
  }

  /// 涉及的应用和各自的时长，最多列 4 个。
  var apps: some View {
    HStack(spacing: 12) {
      ForEach(segment.apps.prefix(4), id: \.self) { a in
        HStack(spacing: 4) {
          SourceGlyph(source: a.source, app: a.app, size: 12)
          Text(SegmentText.appName(a)).lineLimit(1)
          if a.seconds >= 60 { Text(ViewerFormat.compact(a.seconds)).monospacedDigit().foregroundStyle(.tertiary) }
        }
      }
      if segment.apps.count > 4 { Text("+\(segment.apps.count - 4)").foregroundStyle(.tertiary) }
    }
    .font(.system(size: 11))
    .foregroundStyle(.secondary)
  }
}

/// 右侧检查器：这段在做什么（线程的简略和详细版），原始记录折叠在下面。
struct SegmentInspector: View {
  let block: SegmentBlock
  let onOpenRecord: (String) -> Void
  @Environment(ViewerStore.self) private var store
  @State private var detail = Loader<EntityDetail>()
  @State private var showRecords: Bool

  init(block: SegmentBlock, onOpenRecord: @escaping (String) -> Void) {
    self.block = block
    self.onOpenRecord = onOpenRecord
    // 没提炼的段没有别的可看，原始记录直接展开。
    _showRecords = State(initialValue: block.segment.thread == nil)
  }

  var segment: HistorySegment { block.segment }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 22) {
        header
        if let t = segment.thread { doing(t) }
        else { Text("还没提炼").font(.callout).foregroundStyle(.tertiary) }
        if segment.apps.count > 1 { appList }
        raw
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
              Text(s.0).font(.system(size: 10.5, weight: .semibold)).foregroundStyle(s.1)
            }
          }
          Text(timeLine).font(.system(size: 11)).monospacedDigit().foregroundStyle(.secondary)
        }
      }
      Text(SegmentText.title(block)).font(.serif(19, .semibold)).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
    }
  }

  var timeLine: String {
    let c = Calendar.current.dateComponents([.month, .day], from: segment.start)
    var s = "\(c.month!) 月 \(c.day!) 日 \(SegmentText.time(segment))"
    if segment.activeSeconds >= 60 { s += " · 活跃 \(ViewerFormat.duration(segment.activeSeconds))" }
    return s
  }

  @ViewBuilder func doing(_ t: HistorySegment.ThreadRef) -> some View {
    VStack(alignment: .leading, spacing: 20) {
      if let brief = detail.value?.brief ?? t.brief, !brief.isEmpty {
        Text(brief)
          .font(.serif(15.5)).lineSpacing(5).foregroundStyle(Palette.ink.opacity(0.9))
          .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
          .padding(.leading, 12)
          .overlay(alignment: .leading) { Capsule().fill(Palette.accent.opacity(0.5)).frame(width: 2.5) }
      }
      if let d = detail.value {
        DetailBody(detail: d, progressLabel: "进展", progress: d.detail?.progress)
      } else if detail.loading {
        ProgressView().controlSize(.small)
      } else if let e = detail.error {
        Text(e).font(.caption).foregroundStyle(.secondary)
      }
      Button { store.path.append(.thread(t.id)) } label: { Label("打开线程", systemImage: "arrow.up.right") }
        .buttonStyle(.link).font(.callout)
    }
  }

  var appList: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("应用").sectionTitle()
      VStack(alignment: .leading, spacing: 7) {
        ForEach(segment.apps, id: \.self) { a in
          HStack(spacing: 8) {
            SourceGlyph(source: a.source, app: a.app, size: 16)
            Text(SegmentText.appName(a)).font(.system(size: 12))
            Spacer()
            Text(a.seconds >= 60 ? ViewerFormat.duration(a.seconds) : "\(a.records) 条")
              .font(.system(size: 11)).monospacedDigit().foregroundStyle(.secondary)
          }
        }
      }
    }
  }

  var raw: some View {
    VStack(alignment: .leading, spacing: 8) {
      Button { withAnimation(.smooth(duration: 0.2)) { showRecords.toggle() } } label: {
        HStack(spacing: 6) {
          Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold)).rotationEffect(.degrees(showRecords ? 90 : 0))
            .foregroundStyle(.secondary)
          Text("原始记录").sectionTitle()
          Text("\(block.records.count)").font(.system(size: 11)).monospacedDigit().foregroundStyle(.tertiary)
          Spacer()
        }
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      if showRecords {
        let runs = RecordRuns.collapse(block.records)
        VStack(alignment: .leading, spacing: 0) {
          ForEach(Array(runs.enumerated()), id: \.element.id) { i, run in
            Button { onOpenRecord(run.newest.id) } label: {
              HStack(spacing: 8) {
                Text(ViewerFormat.clock(run.start)).font(.mono(10.5)).foregroundStyle(.secondary)
                SourceGlyph(source: run.newest.source, app: run.newest.contextText("app"), size: 14)
                Text(run.newest.title.isEmpty ? SourceInfo.name(run.newest.source) : run.newest.title)
                  .font(.system(size: 12)).lineLimit(1)
                if run.newest.sensitivity == "private" { Image(systemName: "lock.fill").font(.system(size: 8)).foregroundStyle(.secondary) }
                Spacer(minLength: 4)
                if run.records.count > 1 { Text("×\(run.records.count)").font(.system(size: 10.5)).monospacedDigit().foregroundStyle(.tertiary) }
              }
              .padding(.horizontal, 10).padding(.vertical, 6)
              .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if i < runs.count - 1 { Divider().padding(.leading, 10) }
          }
        }
        .card(10)
        .transition(.opacity)
      }
    }
  }
}
