import AppKit
import SwiftUI
import CollectorCore

let threadStatus: [String: (String, Color)] = [
  "active": ("进行中", Palette.dynamic(0x2B9460, 0x52CC8C)), "paused": ("暂停", Palette.dynamic(0xDE8A0A, 0xFFB24A)),
  "done": ("已完成", Palette.dynamic(0x3478C0, 0x70ADEB)), "abandoned": ("已放弃", .secondary), "archived": ("已归档", .secondary),
]

// MARK: 此刻

struct NowPage: View {
  @Environment(ViewerStore.self) private var store
  @State private var now = Loader<NowState?>()
  @State private var active = Loader<[HubThread]>()
  @State private var paused = Loader<[HubThread]>()
  @State private var today = Loader<([HistoryRecord], DayDiary?)>()
  @State private var brush: ClosedRange<Date>?
  @State private var lane: Lane?

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 40) {
        hero
        todayCard
        threadsSection
        if let rows = recentPaused, !rows.isEmpty { pausedSection(rows) }
        if !store.projects.isEmpty { projectsSection }
      }
      .frame(maxWidth: 1080, alignment: .leading)
      .padding(.horizontal, 40).padding(.vertical, 36)
      .frame(maxWidth: .infinity)
    }
    .background(Palette.paper)
    .navigationTitle("此刻")
    .toolbar {
      ToolbarItem(placement: .primaryAction) {
        Button { Task { await load() } } label: { Image(systemName: "arrow.clockwise") }.help("刷新").keyboardShortcut("r", modifiers: .command)
      }
    }
    .task(id: store.revision) { await load() }
  }

  func load() async {
    async let a: Void = now.run { try await store.api.now() }
    async let b: Void = active.run { try await store.api.threads(status: "active").sorted { ($0.lastMs ?? 0) > ($1.lastMs ?? 0) } }
    async let c: Void = paused.run { try await store.api.threads(status: "paused") }
    async let d: Void = today.run {
      let day = Calendar.current.startOfDay(for: Date())
      async let r = store.api.day(day)
      async let y = store.api.diary(day)
      return try await (r, y)
    }
    async let e: Void = store.refreshShared()
    _ = await (a, b, c, d, e)
  }

  var recentPaused: [HubThread]? {
    paused.value?.filter { ($0.last ?? .distantPast) > Date().addingTimeInterval(-3 * 86400) }.sorted { ($0.lastMs ?? 0) > ($1.lastMs ?? 0) }
  }

  // MARK: 头部

  var hero: some View {
    VStack(alignment: .leading, spacing: 16) {
      TimelineView(.everyMinute) { ctx in
        HStack(spacing: 8) {
          Text(dateLine(ctx.date))
          Text("·").foregroundStyle(.quaternary)
          Text(ViewerFormat.clock(ctx.date)).monospacedDigit()
        }
        .font(.system(size: 12, weight: .semibold))
        .tracking(1.2)
        .foregroundStyle(.secondary)
      }
      Group {
        if let state = now.value {
          Text(state?.brief?.isEmpty == false ? state!.brief! : "还没有当前摘要。提炼跑过一轮后，这里会写你此刻在做什么。")
            .font(.serif(29, .regular))
            .lineSpacing(7)
            .foregroundStyle(Palette.ink)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: 860, alignment: .leading)
          if let at = state?.updatedAt.flatMap(ViewerTime.parse) {
            Text("提炼于 \(ViewerFormat.relative(at))").font(.caption).foregroundStyle(.tertiary)
          }
        } else if let e = now.error {
          Placeholder(kind: .error(e) { Task { await load() } }).frame(height: 120)
        } else {
          RoundedRectangle(cornerRadius: 6).fill(.primary.opacity(0.05)).frame(width: 560, height: 70).redacted(reason: .placeholder)
        }
      }
      .transition(.opacity)
    }
    .animation(.smooth, value: now.value == nil)
  }

  func dateLine(_ d: Date) -> String {
    let c = Calendar.current.dateComponents([.month, .day], from: d)
    return "\(c.month!) 月 \(c.day!) 日  \(ViewerFormat.weekday(d))"
  }

  // MARK: 今天

  var todayCard: some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack(alignment: .firstTextBaseline) {
        Text("今天").sectionTitle()
        if let rows = today.value?.0, !rows.isEmpty {
          Text("\(rows.count) 条记录").font(.caption).foregroundStyle(.tertiary)
        }
        Spacer()
        Button { store.historyDay = Calendar.current.startOfDay(for: Date()); store.historySearch = ""; store.section = .history } label: {
          HStack(spacing: 3) { Text("打开 History"); Image(systemName: "arrow.right") }
        }
        .buttonStyle(.link).font(.caption)
      }
      if let (rows, diary) = today.value {
        if rows.isEmpty {
          Text("今天还没有记录").font(.serif(14)).foregroundStyle(.secondary).frame(height: 60)
        } else {
          DayStrata(records: rows, chapters: chapters(diary), day: Date(), selected: nil, brush: $brush, lane: $lane) { r in
            store.showRecord(r.id, at: r.start)
          }
        }
      } else if let e = today.error {
        Text(e).font(.callout).foregroundStyle(.secondary)
      } else {
        ProgressView().controlSize(.small).frame(maxWidth: .infinity, minHeight: 80)
      }
    }
    .padding(20)
    .card(16)
    .zIndex(1)
  }

  func chapters(_ diary: DayDiary?) -> [DayStrata.Chapter] {
    (diary?.detail?.timeline ?? []).enumerated().compactMap { i, c in
      guard let s = ViewerTime.clockOnDay(c.start, day: Date()), var e = ViewerTime.clockOnDay(c.end, day: Date()) else { return nil }
      if e <= s { e = ViewerTime.dayBounds(Date()).end }
      return .init(id: i, start: s, end: e, text: c.text)
    }
  }

  // MARK: 线程

  var threadsSection: some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack(alignment: .firstTextBaseline) {
        Text("进行中").sectionTitle()
        if let n = active.value?.count, n > 0 { Text("\(n)").font(.caption).foregroundStyle(.tertiary) }
      }
      if let rows = active.value {
        if rows.isEmpty {
          Text("没有进行中的线程").font(.serif(14)).foregroundStyle(.secondary).padding(.vertical, 20)
        } else {
          LazyVGrid(columns: [GridItem(.adaptive(minimum: 290, maximum: 520), spacing: 14)], spacing: 14) {
            ForEach(rows) { t in
              Button { store.path.append(.thread(t.id)) } label: { ThreadCard(thread: t, project: store.project(t.projectId)) }
                .buttonStyle(.plain)
            }
          }
        }
      } else if let e = active.error {
        Placeholder(kind: .error(e) { Task { await load() } }).frame(height: 140)
      } else {
        ProgressView().controlSize(.small).frame(maxWidth: .infinity, minHeight: 120)
      }
    }
  }

  func pausedSection(_ rows: [HubThread]) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("最近暂停").sectionTitle()
      VStack(spacing: 0) {
        ForEach(Array(rows.enumerated()), id: \.element.id) { i, t in
          Button { store.path.append(.thread(t.id)) } label: { ThreadLine(thread: t, project: store.project(t.projectId)) }
            .buttonStyle(.plain)
          if i < rows.count - 1 { Divider().padding(.leading, 16) }
        }
      }
      .card(14)
    }
  }

  var projectsSection: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text("项目").sectionTitle()
      LazyVGrid(columns: [GridItem(.adaptive(minimum: 230, maximum: 360), spacing: 14)], spacing: 14) {
        ForEach(store.projects.sorted { ($0.lastMs ?? 0) > ($1.lastMs ?? 0) }) { p in
          Button { store.section = .project(p.id) } label: { ProjectCard(project: p) }.buttonStyle(.plain)
        }
      }
    }
  }
}

struct ThreadCard: View {
  let thread: HubThread
  let project: Project?

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(spacing: 8) {
        if let project { ProjectTag(name: project.name, unconfirmed: !project.confirmed.value) }
        else { Label(thread.domain == "life" ? "生活" : "未归属", systemImage: thread.domain == "life" ? "leaf" : "circle.dashed").font(.system(size: 11, weight: .medium)).foregroundStyle(.tertiary) }
        Spacer()
        Text(ViewerFormat.relative(thread.last)).font(.system(size: 11)).foregroundStyle(.tertiary)
      }
      Text(thread.title).font(.serif(17, .semibold)).foregroundStyle(Palette.ink).lineLimit(2).multilineTextAlignment(.leading)
        .fixedSize(horizontal: false, vertical: true)
      if let brief = thread.brief {
        Text(brief).font(.system(size: 12.5)).lineSpacing(2.5).foregroundStyle(.secondary).lineLimit(3)
          .fixedSize(horizontal: false, vertical: true)
      }
      Spacer(minLength: 0)
      HStack(spacing: 10) {
        WarmthBar(value: Warmth.of(thread.last), tint: project.map { Palette.tag($0.name) } ?? Palette.accent)
        if let m = thread.activeMinutes {
          Text("\(ViewerFormat.minutes(m))\(thread.sessions.map { " · \($0) 次" } ?? "")")
            .font(.system(size: 10.5)).monospacedDigit().foregroundStyle(.tertiary).fixedSize()
        }
      }
    }
    .padding(16)
    .frame(maxWidth: .infinity, minHeight: 172, alignment: .topLeading)
    .card(14, hover: true)
    .contentShape(Rectangle())
  }
}

struct ThreadLine: View {
  let thread: HubThread
  let project: Project?
  @State private var hovering = false
  var body: some View {
    HStack(spacing: 12) {
      Circle().fill(project.map { Palette.tag($0.name) } ?? Color.secondary.opacity(0.4)).frame(width: 7, height: 7)
      VStack(alignment: .leading, spacing: 2) {
        Text(thread.title).font(.system(size: 13, weight: .medium)).lineLimit(1)
        if let b = thread.brief { Text(b).font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1) }
      }
      Spacer()
      if let s = threadStatus[thread.status], thread.status != "active" {
        Text(s.0).font(.system(size: 10.5, weight: .medium)).foregroundStyle(s.1)
      }
      Text(ViewerFormat.relative(thread.last)).font(.system(size: 11)).foregroundStyle(.tertiary).frame(minWidth: 60, alignment: .trailing)
      Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(.quaternary)
    }
    .padding(.horizontal, 16).padding(.vertical, 11)
    .background(hovering ? Color.primary.opacity(0.03) : .clear)
    .contentShape(Rectangle())
    .onHover { hovering = $0 }
  }
}

struct ProjectCard: View {
  let project: Project
  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 8) {
        RoundedRectangle(cornerRadius: 3).fill(Palette.tag(project.name).gradient).frame(width: 14, height: 14)
        Text(project.name).font(.system(size: 14, weight: .semibold)).lineLimit(1)
        if !project.confirmed.value { Text("未确认").font(.system(size: 10)).foregroundStyle(.tertiary) }
        Spacer()
      }
      if let b = project.brief { Text(b).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(2).fixedSize(horizontal: false, vertical: true) }
      Spacer(minLength: 0)
      HStack {
        Text("\(project.threadCount ?? 0) 个线程")
        Spacer()
        Text(ViewerFormat.relative(project.last))
      }
      .font(.system(size: 10.5)).foregroundStyle(.tertiary)
    }
    .padding(14)
    .frame(maxWidth: .infinity, minHeight: 112, alignment: .topLeading)
    .card(12, hover: true)
    .contentShape(Rectangle())
  }
}

struct WarmthBar: View {
  let value: Double
  let tint: Color
  var body: some View {
    GeometryReader { g in
      ZStack(alignment: .leading) {
        Capsule().fill(.primary.opacity(0.07))
        Capsule().fill(LinearGradient(colors: [tint.opacity(0.35), tint], startPoint: .leading, endPoint: .trailing))
          .frame(width: max(4, g.size.width * value))
      }
    }
    .frame(height: 4)
    .accessibilityHidden(true)
  }
}

// MARK: 线程详情

struct ThreadPage: View {
  let id: String
  @Environment(ViewerStore.self) private var store
  @State private var detail = Loader<EntityDetail>()
  @State private var evidence = Loader<[Evidence]>()
  @State private var depth = 1

  var body: some View {
    ScrollView {
      Group {
        if let d = detail.value { content(d) }
        else if let e = detail.error { Placeholder(kind: .error(e) { Task { await load() } }).frame(height: 400) }
        else { Placeholder(kind: .loading).frame(height: 400) }
      }
      .frame(maxWidth: 860, alignment: .leading)
      .padding(.horizontal, 40).padding(.vertical, 32)
      .frame(maxWidth: .infinity)
    }
    .background(Palette.paper)
    .navigationTitle(detail.value?.title ?? "线程")
    .toolbar { BackButton() }
    .task(id: store.revision) { await load() }
    .task(id: depth) { if depth == 2, evidence.value == nil { await loadEvidence() } }
  }

  func load() async { await detail.run { try await store.api.thread(id, level: "detail") } }
  func loadEvidence() async { await evidence.run { try await store.api.thread(id, level: "evidence").records ?? [] } }

  func content(_ d: EntityDetail) -> some View {
    VStack(alignment: .leading, spacing: 26) {
      VStack(alignment: .leading, spacing: 12) {
        HStack(spacing: 10) {
          if let p = store.project(d.projectId) {
            Button { store.section = .project(p.id) } label: { ProjectTag(name: p.name, unconfirmed: !p.confirmed.value) }.buttonStyle(.plain)
          }
          if let s = threadStatus[d.status ?? ""] {
            Text(s.0).font(.system(size: 10.5, weight: .semibold)).foregroundStyle(s.1)
              .padding(.horizontal, 7).padding(.vertical, 2).background(s.1.opacity(0.12), in: Capsule())
          }
        }
        Text(d.title ?? "").font(.serif(30, .semibold)).foregroundStyle(Palette.ink).textSelection(.enabled)
          .fixedSize(horizontal: false, vertical: true)
        Picker("层级", selection: $depth) {
          Text("简略").tag(0); Text("详细").tag(1); Text("证据").tag(2)
        }
        .pickerStyle(.segmented).labelsHidden().frame(width: 240)
        .padding(.top, 4)
      }
      switch depth {
      case 0:
        Text(d.brief ?? "暂无简略版").font(.serif(21)).lineSpacing(6).textSelection(.enabled)
          .fixedSize(horizontal: false, vertical: true)
          .padding(.leading, 16)
          .overlay(alignment: .leading) { Capsule().fill(Palette.accent.opacity(0.5)).frame(width: 3) }
      case 1:
        DetailBody(detail: d, progressLabel: "进展", progress: d.detail?.progress)
        FactsView(facts: d.facts ?? [], loadEvidence: { try await store.api.thread(id, level: "evidence").records ?? [] }) { Task { await load() } }
      default:
        EvidenceList(loader: evidence) { Task { await loadEvidence() } }
      }
    }
    .animation(.smooth(duration: 0.25), value: depth)
  }
}

struct DetailBody: View {
  let detail: EntityDetail
  let progressLabel: String
  let progress: String?

  var body: some View {
    VStack(alignment: .leading, spacing: 22) {
      paragraph("目标", detail.detail?.goal)
      paragraph(progressLabel, progress)
      if let people = detail.detail?.people, !people.isEmpty { paragraph("相关的人", people.joined(separator: "、")) }
      if let artifacts = detail.detail?.artifacts {
        let groups: [(String, String, [String])] = [("链接", "link", artifacts["urls"]?.strings ?? []), ("文件", "doc", artifacts["files"]?.strings ?? []),
                                                    ("命令", "terminal", artifacts["commands"]?.strings ?? [])].filter { !$0.2.isEmpty }
        if !groups.isEmpty {
          VStack(alignment: .leading, spacing: 8) {
            Text("相关").sectionTitle()
            FlowLayout(spacing: 6) {
              ForEach(groups, id: \.0) { _, symbol, items in
                ForEach(items, id: \.self) { item in ArtifactChip(symbol: symbol, text: item) }
              }
            }
          }
        }
      }
    }
  }

  @ViewBuilder func paragraph(_ title: String, _ text: String?) -> some View {
    if let text, !text.isEmpty {
      VStack(alignment: .leading, spacing: 6) {
        Text(title).sectionTitle()
        Text(text).font(.serif(15.5)).lineSpacing(5).foregroundStyle(Palette.ink.opacity(0.9)).textSelection(.enabled)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
  }
}

struct ArtifactChip: View {
  let symbol: String
  let text: String
  var body: some View {
    Button {
      if let url = URL(string: text), ["http", "https"].contains(url.scheme ?? "") { NSWorkspace.shared.open(url) }
      else if text.hasPrefix("/") || text.hasPrefix("~") {
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: (text as NSString).expandingTildeInPath)
      } else {
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string)
      }
    } label: {
      HStack(spacing: 5) {
        Image(systemName: symbol).font(.system(size: 9.5)).foregroundStyle(.secondary)
        Text(text.hasPrefix("/") ? (text as NSString).abbreviatingWithTildeInPath : text).font(.mono(11)).lineLimit(1).truncationMode(.middle)
      }
      .padding(.horizontal, 8).padding(.vertical, 4)
      .background(.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
      .frame(maxWidth: 360, alignment: .leading)
    }
    .buttonStyle(.plain)
    .help(symbol == "terminal" ? "复制命令" : "打开")
  }
}

/// 下一步 / 未决 / 已定 / 推测 / 否决，各自一组；失效的不显示。
struct FactsView: View {
  let facts: [Fact]
  let loadEvidence: () async throws -> [Evidence]
  let onChanged: () -> Void
  @State private var correcting: Fact?
  @State private var evidence = Loader<[Evidence]>()

  var body: some View {
    let live = facts.filter { $0.invalidAt == nil && $0.supersededBy == nil }
    VStack(alignment: .leading, spacing: 22) {
      ForEach(SourceInfo.factLabels, id: \.kind) { g in
        let rows = live.filter { $0.kind == g.kind }
        if !rows.isEmpty {
          FactGroup(kind: g.kind, label: g.label, symbol: g.symbol, rows: rows, evidence: evidence, loadEvidence: loadEvidence) { correcting = $0 }
        }
      }
    }
    .sheet(item: $correcting) { f in FactCorrectionSheet(fact: f) { onChanged() } }
  }
}

/// 一组事实默认只列前 5 条（接口顺序），其余点"展开全部"再看。
struct FactGroup: View {
  let kind: String
  let label: String
  let symbol: String
  let rows: [Fact]
  let evidence: Loader<[Evidence]>
  let loadEvidence: () async throws -> [Evidence]
  let onCorrect: (Fact) -> Void
  @State private var expanded = false
  private let limit = 5

  var body: some View {
    let shown = expanded ? rows : Array(rows.prefix(limit))
    VStack(alignment: .leading, spacing: 10) {
      HStack(spacing: 6) {
        Image(systemName: symbol).foregroundStyle(Palette.factColors[kind] ?? .secondary)
        Text(label).font(.system(size: 12, weight: .semibold))
        Text("\(rows.count)").font(.system(size: 11)).foregroundStyle(.tertiary)
      }
      VStack(alignment: .leading, spacing: 0) {
        ForEach(Array(shown.enumerated()), id: \.element.id) { i, f in
          FactRow(fact: f, evidence: evidence, loadEvidence: loadEvidence) { onCorrect(f) }
          if i < shown.count - 1 { Divider().padding(.leading, 14) }
        }
      }
      .card(12)
      if rows.count > limit {
        Button(expanded ? "收起" : "展开全部 \(rows.count) 条") { withAnimation(.smooth) { expanded.toggle() } }
          .buttonStyle(.link).font(.caption)
      }
    }
  }
}

struct FactRow: View {
  let fact: Fact
  let evidence: Loader<[Evidence]>
  let loadEvidence: () async throws -> [Evidence]
  let onCorrect: () -> Void
  @Environment(ViewerStore.self) private var store
  @State private var hovering = false
  @State private var showEvidence = false

  var body: some View {
    HStack(alignment: .top, spacing: 12) {
      Capsule().fill(Palette.factColors[fact.kind] ?? .secondary).frame(width: 3).padding(.vertical, 3)
      VStack(alignment: .leading, spacing: 5) {
        Text(fact.text).font(.system(size: 13.5)).lineSpacing(2.5).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        if let r = fact.reason, !r.isEmpty {
          Text(r).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        HStack(spacing: 14) {
          if fact.kind == "inference" { ConfidenceDots(value: fact.confidence) }
          if fact.origin == "user" { Label("你写的", systemImage: "person.fill").font(.system(size: 10.5)).foregroundStyle(.secondary) }
          Button("证据 \(fact.evidence.count)") { showEvidence = true }
            .buttonStyle(.link).font(.system(size: 11))
            .popover(isPresented: $showEvidence, arrowEdge: .bottom) { evidencePopover }
          if fact.kind == "decision" || fact.kind == "inference" {
            Button("这条不对", action: onCorrect).buttonStyle(.link).font(.system(size: 11))
              .opacity(hovering ? 1 : 0)
          }
        }
        .padding(.top, 2)
      }
      Spacer(minLength: 0)
    }
    .padding(.horizontal, 14).padding(.vertical, 12)
    .onHover { hovering = $0 }
  }

  var evidencePopover: some View {
    VStack(alignment: .leading, spacing: 4) {
      if let rows = evidence.value {
        let hits = rows.filter { fact.evidence.contains($0.id) }
        if hits.isEmpty { Text("暂无可用证据").foregroundStyle(.secondary).padding(8) }
        ForEach(hits) { e in
          EvidenceRow(evidence: e) { showEvidence = false; store.showRecord(e.id, at: e.start) }
        }
      } else if let e = evidence.error {
        Text(e).foregroundStyle(.secondary).padding(8)
      } else {
        ProgressView().controlSize(.small).padding(16)
      }
    }
    .padding(8)
    .frame(width: 400)
    .task { if evidence.value == nil { await evidence.run(loadEvidence) } }
  }
}

struct ConfidenceDots: View {
  let value: Double?
  var body: some View {
    HStack(spacing: 3) {
      ForEach(0..<5) { i in
        Circle().fill(Double(i) < (value ?? 0) * 5 - 0.001 ? Palette.factColors["inference"]! : Color.primary.opacity(0.12)).frame(width: 5, height: 5)
      }
      Text(value.map { "\(Int($0 * 100))%" } ?? "置信度未知").font(.system(size: 10.5)).monospacedDigit().foregroundStyle(.secondary)
    }
  }
}

struct EvidenceRow: View {
  let evidence: Evidence
  let action: () -> Void
  @State private var hovering = false
  var body: some View {
    Button(action: action) {
      HStack(spacing: 10) {
        SourceGlyph(source: evidence.source ?? "", size: 20)
        VStack(alignment: .leading, spacing: 1) {
          Text(evidence.title).font(.system(size: 12.5)).lineLimit(1)
          if let s = evidence.start {
            Text("\(ViewerFormat.dayTitle(s)) \(ViewerFormat.clock(s))").font(.system(size: 10.5)).monospacedDigit().foregroundStyle(.tertiary)
          }
        }
        Spacer()
        Image(systemName: "arrow.up.right").font(.system(size: 10)).foregroundStyle(.tertiary).opacity(hovering ? 1 : 0)
      }
      .padding(.horizontal, 8).padding(.vertical, 6)
      .background(hovering ? Color.primary.opacity(0.05) : .clear, in: RoundedRectangle(cornerRadius: 7))
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .onHover { hovering = $0 }
  }
}

struct EvidenceList: View {
  let loader: Loader<[Evidence]>
  let retry: () -> Void
  @Environment(ViewerStore.self) private var store
  var body: some View {
    if let rows = loader.value {
      if rows.isEmpty { Placeholder(kind: .empty("doc.text.magnifyingglass", "暂无证据")).frame(height: 200) }
      else {
        VStack(alignment: .leading, spacing: 10) {
          Text("\(rows.count) 条原始记录").sectionTitle()
          VStack(spacing: 2) {
            ForEach(rows.sorted { ($0.start ?? .distantPast) > ($1.start ?? .distantPast) }) { e in
              EvidenceRow(evidence: e) { store.showRecord(e.id, at: e.start) }
            }
          }
          .padding(6)
          .card(12)
        }
      }
    } else if let e = loader.error {
      Placeholder(kind: .error(e, retry)).frame(height: 200)
    } else {
      Placeholder(kind: .loading).frame(height: 200)
    }
  }
}

struct FactCorrectionSheet: View {
  let fact: Fact
  let onSaved: () -> Void
  @Environment(ViewerStore.self) private var store
  @Environment(\.dismiss) private var dismiss
  @State private var text = ""
  @State private var busy = false
  @State private var error: String?

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text("修正这条内容").font(.serif(20, .semibold))
      Text(fact.text).font(.callout).foregroundStyle(.secondary).padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
      Text("正确的内容").font(.caption).foregroundStyle(.secondary)
      TextEditor(text: $text).font(.system(size: 13)).scrollContentBackground(.hidden).padding(8).card(8).frame(minHeight: 120)
      if let error { Text(error).font(.callout).foregroundStyle(.red) }
      HStack {
        Spacer()
        Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
        Button(busy ? "提交中…" : "提交修正") {
          Task {
            busy = true; defer { busy = false }
            do { try await store.api.correct(fact, text: text.trimmingCharacters(in: .whitespacesAndNewlines)); onSaved(); dismiss() }
            catch { self.error = error.localizedDescription }
          }
        }
        .keyboardShortcut(.defaultAction)
        .disabled(busy || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      }
    }
    .padding(22).frame(width: 500)
  }
}

// MARK: 项目

struct ProjectPage: View {
  let id: String
  @Environment(ViewerStore.self) private var store
  @State private var detail = Loader<EntityDetail>()
  @State private var threads = Loader<[HubThread]>()

  var body: some View {
    ScrollView {
      Group {
        if let d = detail.value { content(d) }
        else if let e = detail.error { Placeholder(kind: .error(e) { Task { await load() } }).frame(height: 400) }
        else { Placeholder(kind: .loading).frame(height: 400) }
      }
      .frame(maxWidth: 960, alignment: .leading)
      .padding(.horizontal, 40).padding(.vertical, 32)
      .frame(maxWidth: .infinity)
    }
    .background(Palette.paper)
    .navigationTitle(detail.value?.name ?? "项目")
    .toolbar { BackButton() }
    .task(id: store.revision) { await load() }
  }

  func load() async {
    async let a: Void = detail.run { try await store.api.project(id, level: "detail") }
    async let b: Void = threads.run { try await store.api.threads(project: id) }
    _ = await (a, b)
  }

  func content(_ d: EntityDetail) -> some View {
    let p = store.project(id)
    return VStack(alignment: .leading, spacing: 28) {
      VStack(alignment: .leading, spacing: 10) {
        HStack(spacing: 12) {
          RoundedRectangle(cornerRadius: 6).fill(Palette.tag(d.name ?? "").gradient).frame(width: 24, height: 24)
          Text(d.name ?? "").font(.serif(32, .semibold)).foregroundStyle(Palette.ink)
          if p?.confirmed.value == false {
            Text("未确认").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
              .padding(.horizontal, 7).padding(.vertical, 2).overlay(Capsule().strokeBorder(.secondary.opacity(0.4)))
          }
        }
        if let b = d.brief {
          Text(b).font(.serif(17)).lineSpacing(4).foregroundStyle(.secondary).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        }
      }
      DetailBody(detail: d, progressLabel: "状态", progress: d.detail?.status)
      threadList
      FactsView(facts: d.facts ?? [], loadEvidence: { try await store.api.project(id, level: "evidence").records ?? [] }) { Task { await load() } }
    }
  }

  @ViewBuilder var threadList: some View {
    if let rows = threads.value, !rows.isEmpty {
      let order = ["active", "paused", "done", "abandoned", "archived"]
      VStack(alignment: .leading, spacing: 20) {
        ForEach(order, id: \.self) { status in
          let group = rows.filter { $0.status == status }
          if !group.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
              HStack(spacing: 6) {
                Text(threadStatus[status]?.0 ?? status).sectionTitle()
                Text("\(group.count)").font(.caption).foregroundStyle(.tertiary)
              }
              if status == "active" {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 280), spacing: 14)], spacing: 14) {
                  ForEach(group) { t in
                    Button { store.path.append(.thread(t.id)) } label: { ThreadCard(thread: t, project: store.project(id)) }.buttonStyle(.plain)
                  }
                }
              } else {
                VStack(spacing: 0) {
                  ForEach(Array(group.enumerated()), id: \.element.id) { i, t in
                    Button { store.path.append(.thread(t.id)) } label: { ThreadLine(thread: t, project: store.project(id)) }.buttonStyle(.plain)
                    if i < group.count - 1 { Divider().padding(.leading, 16) }
                  }
                }
                .card(14)
              }
            }
          }
        }
      }
    } else if let e = threads.error {
      Text(e).foregroundStyle(.secondary)
    }
  }
}

/// 简单的流式布局：放不下就换行。
struct FlowLayout: Layout {
  var spacing: CGFloat = 6
  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    let width = proposal.width ?? 600
    var x: CGFloat = 0, y: CGFloat = 0, line: CGFloat = 0, maxX: CGFloat = 0
    for s in subviews {
      let size = s.sizeThatFits(.unspecified)
      let w = min(size.width, width)
      if x > 0, x + w > width { x = 0; y += line + spacing; line = 0 }
      x += w + spacing; line = max(line, size.height); maxX = max(maxX, x)
    }
    return CGSize(width: min(width, maxX), height: y + line)
  }
  func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
    var x = bounds.minX, y = bounds.minY, line: CGFloat = 0
    for s in subviews {
      let size = s.sizeThatFits(.unspecified)
      let w = min(size.width, bounds.width)
      if x > bounds.minX, x + w > bounds.maxX { x = bounds.minX; y += line + spacing; line = 0 }
      s.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(width: w, height: size.height))
      x += w + spacing; line = max(line, size.height)
    }
  }
}

/// 推入的线程/项目页不一定带系统返回按钮（分栏 + 导航栈桥接到 NSToolbar 时会丢），自己放一个。
struct BackButton: ToolbarContent {
  @Environment(ViewerStore.self) private var store
  var body: some ToolbarContent {
    ToolbarItem(placement: .navigation) {
      if !store.path.isEmpty {
        Button { store.path.removeLast() } label: { Image(systemName: "chevron.left") }
          .help("返回").keyboardShortcut("[", modifiers: .command)
      }
    }
  }
}
