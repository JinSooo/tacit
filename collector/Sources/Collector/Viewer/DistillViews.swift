import AppKit
import SwiftUI
import CollectorCore

/// 事项状态只写文字，状态正常不上色。
let threadStatus: [String: String] = [
  "active": "进行中", "paused": "已暂停", "done": "已完成", "abandoned": "不做了", "archived": "已归档",
]

struct ThreadCard: View {
  let thread: HubThread
  let project: Project?

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 8) {
        if let project { ProjectTag(name: project.name, unconfirmed: !project.confirmed.value) }
        else if thread.domain == "life" {
          HStack(spacing: 4) { PhIcon("leaf", size: 12); Text("生活") }
            .font(.system(size: TextSize.caption, weight: .medium)).foregroundStyle(Palette.muted)
        }
        Spacer(minLength: 0)
        Text(ViewerFormat.relative(thread.last)).font(.system(size: TextSize.caption)).foregroundStyle(Palette.muted).fixedSize()
      }
      Text(thread.title).font(.system(size: TextSize.title, weight: .semibold)).foregroundStyle(Palette.ink).lineLimit(2).multilineTextAlignment(.leading)
        .lineSpacing(3)
        .fixedSize(horizontal: false, vertical: true)
      if let brief = thread.cardSummary {
        Text(brief).font(.system(size: TextSize.body)).lineSpacing(TextSize.lineSpacing(TextSize.body)).foregroundStyle(Palette.muted).lineLimit(3)
          .fixedSize(horizontal: false, vertical: true)
      } else if thread.needsRegen?.value == true {
        Text("正在整理").font(.system(size: TextSize.caption)).foregroundStyle(Palette.muted)
      }
      Spacer(minLength: 0)
      if let span = ThreadSpan.text(thread) {
        Text(span).font(.system(size: TextSize.caption)).monospacedDigit().foregroundStyle(Palette.muted)
          .help(ThreadSpan.help)
      }
    }
    .padding(16)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .card(hover: true)
    .contentShape(Rectangle())
  }
}

/// 事项卡片底部那一行：从哪天开始做、前后做了几次。
/// 不写累计时长：中枢的 active_minutes 是各片段时长直接相加，同一时间几个来源（屏幕、终端、AI 会话）
/// 各算一遍，会比实际多；片段里 10 分钟以内的空档也算在里面。
enum ThreadSpan {
  static let help = "隔 30 分钟以上再回来做，算新的一次"
  static func text(_ t: HubThread) -> String? {
    var parts: [String] = []
    if let first = t.first { parts.append(Calendar.current.isDateInToday(first) ? "今天开始" : "\(Fmt.date(first))开始") }
    if let n = t.sessions, n > 1 { parts.append("前后 \(n) 次") }
    return parts.isEmpty ? nil : parts.joined(separator: "，")
  }
}

struct ThreadLine: View {
  let thread: HubThread
  let project: Project?
  @State private var hovering = false
  var body: some View {
    HStack(spacing: 12) {
      VStack(alignment: .leading, spacing: 2) {
        Text(thread.title).font(.system(size: TextSize.body, weight: .medium)).foregroundStyle(Palette.ink).lineLimit(1)
        if let b = thread.brief { Text(b).font(.system(size: TextSize.caption)).foregroundStyle(Palette.muted).lineLimit(1) }
      }
      Spacer()
      if let s = threadStatus[thread.status], thread.status != "active" {
        Text(s).font(.system(size: TextSize.caption)).foregroundStyle(Palette.muted)
      }
      Text(ViewerFormat.relative(thread.last)).font(.system(size: TextSize.caption)).foregroundStyle(Palette.muted).frame(minWidth: 60, alignment: .trailing)
      PhIcon("caret-right", size: 12).foregroundStyle(Palette.faint)
    }
    .padding(.horizontal, 16).padding(.vertical, 12)
    .background(hovering ? Palette.fill : .clear)
    .contentShape(Rectangle())
    .onHover { hovering = $0 }
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
    .navigationTitle(detail.value?.title ?? "事项")
    .toolbar { BackButton() }
    .task(id: store.revision) { await load() }
    .task(id: depth) { if depth == 2, evidence.value == nil { await loadEvidence() } }
  }

  func load() async { await detail.run { try await store.api.thread(id, level: "detail") } }
  func loadEvidence() async { await evidence.run { try await store.api.thread(id, level: "evidence").records ?? [] } }

  func content(_ d: EntityDetail) -> some View {
    VStack(alignment: .leading, spacing: 24) {
      VStack(alignment: .leading, spacing: 12) {
        HStack(spacing: 12) {
          if let p = store.project(d.projectId) {
            Button { store.section = .project(p.id) } label: { ProjectTag(name: p.name, unconfirmed: !p.confirmed.value) }.buttonStyle(.plain)
          }
          if let s = threadStatus[d.status ?? ""] {
            Text(s).font(.system(size: TextSize.caption, weight: .medium)).foregroundStyle(Palette.muted)
          }
        }
        Text(d.title ?? "").font(.system(size: TextSize.heading, weight: .semibold)).foregroundStyle(Palette.ink).textSelection(.enabled)
          .lineSpacing(TextSize.serifLineSpacing(TextSize.heading) / 2)
          .fixedSize(horizontal: false, vertical: true)
        Picker("层级", selection: $depth) {
          Text("简略").tag(0); Text("详细").tag(1); Text("依据").tag(2)
        }
        .pickerStyle(.segmented).labelsHidden().frame(width: 240)
        .padding(.top, 4)
      }
      switch depth {
      case 0:
        Text(d.brief ?? "还没有简略版").font(.serif(TextSize.title)).lineSpacing(TextSize.serifLineSpacing(TextSize.title)).textSelection(.enabled)
          .foregroundStyle(Palette.ink)
          .fixedSize(horizontal: false, vertical: true)
          .padding(.leading, 16)
          .overlay(alignment: .leading) { Rectangle().fill(Palette.hairline).frame(width: 2) }
      case 1:
        DetailBody(detail: d, progressLabel: "进展", progress: d.detail?.progress)
        FactsView(facts: d.facts ?? [], loadEvidence: { try await store.api.thread(id, level: "evidence").records ?? [] }) { Task { await load() } }
      default:
        EvidenceList(loader: evidence) { Task { await loadEvidence() } }
      }
    }
    .animation(.easeOut(duration: 0.2), value: depth)
  }
}

struct DetailBody: View {
  let detail: EntityDetail
  let progressLabel: String
  let progress: String?

  var body: some View {
    VStack(alignment: .leading, spacing: 24) {
      paragraph("目标", detail.detail?.goal)
      paragraph(progressLabel, progress)
      if let people = detail.detail?.people, !people.isEmpty { paragraph("相关的人", people.joined(separator: "、")) }
      if let artifacts = detail.detail?.artifacts {
        let groups: [(String, String, [String])] = [("链接", "link", artifacts["urls"]?.strings ?? []), ("文件", "file", artifacts["files"]?.strings ?? []),
                                                    ("命令", "terminal-window", artifacts["commands"]?.strings ?? [])].filter { !$0.2.isEmpty }
        if !groups.isEmpty {
          VStack(alignment: .leading, spacing: 8) {
            Text("相关").sectionTitle()
            FlowLayout(spacing: 8) {
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
      VStack(alignment: .leading, spacing: 8) {
        Text(title).sectionTitle()
        Text(text).font(.system(size: TextSize.body)).lineSpacing(TextSize.lineSpacing(TextSize.body)).foregroundStyle(Palette.ink).textSelection(.enabled)
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
      HStack(spacing: 4) {
        PhIcon(symbol, size: 12).foregroundStyle(Palette.muted)
        // 等宽只给路径和命令，链接用正文字体。
        Text(text.hasPrefix("/") ? (text as NSString).abbreviatingWithTildeInPath : text)
          .font(symbol == "link" ? .system(size: TextSize.caption) : .mono(TextSize.caption))
          .foregroundStyle(Palette.ink).lineLimit(1).truncationMode(.middle)
      }
      .padding(.horizontal, 8).padding(.vertical, 4)
      .background(Palette.fill, in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
      .frame(maxWidth: 360, alignment: .leading)
    }
    .buttonStyle(.plain)
    .help(symbol == "terminal-window" ? "复制命令" : "打开")
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
    VStack(alignment: .leading, spacing: 24) {
      ForEach(SourceInfo.factLabels, id: \.kind) { g in
        let rows = live.filter { $0.kind == g.kind }
        if !rows.isEmpty {
          FactGroup(kind: g.kind, label: g.label, symbol: g.symbol, rows: rows, evidence: evidence, loadEvidence: loadEvidence, onChanged: onChanged) { correcting = $0 }
        }
      }
    }
    .sheet(item: $correcting) { f in FactCorrectionSheet(fact: f) { onChanged() } }
  }
}

/// 一组事实最新的在前（中枢按 created_at 升序返回），默认只列 5 条，其余点"展开全部"再看。
struct FactGroup: View {
  let kind: String
  let label: String
  let symbol: String
  let rows: [Fact]
  let evidence: Loader<[Evidence]>
  let loadEvidence: () async throws -> [Evidence]
  let onChanged: () -> Void
  let onCorrect: (Fact) -> Void
  @State private var expanded = false
  private let limit = 5

  var body: some View {
    let newest = Array(rows.reversed())
    let shown = expanded ? newest : Array(newest.prefix(limit))
    VStack(alignment: .leading, spacing: 8) {
      HStack(alignment: .firstTextBaseline, spacing: 8) {
        PhIcon(symbol, size: 15).foregroundStyle(Palette.muted)
        Text(label).sectionTitle()
        Text("\(rows.count) 条").font(.system(size: TextSize.caption)).foregroundStyle(Palette.muted)
      }
      VStack(alignment: .leading, spacing: 0) {
        ForEach(Array(shown.enumerated()), id: \.element.id) { i, f in
          FactRow(fact: f, evidence: evidence, loadEvidence: loadEvidence, onCorrect: { onCorrect(f) }, onChanged: onChanged)
          if i < shown.count - 1 { Divider().padding(.leading, 16) }
        }
      }
      .card()
      if rows.count > limit {
        Button(expanded ? "收起" : "展开全部 \(rows.count) 条") { withAnimation(.easeOut(duration: 0.2)) { expanded.toggle() } }
          .buttonStyle(.accentLink).font(.system(size: TextSize.caption))
      }
    }
  }
}

struct FactRow: View {
  let fact: Fact
  let evidence: Loader<[Evidence]>
  let loadEvidence: () async throws -> [Evidence]
  let onCorrect: () -> Void
  let onChanged: () -> Void
  @Environment(ViewerStore.self) private var store
  @State private var hovering = false
  @State private var showEvidence = false
  @State private var confirmDetach = false
  @State private var detaching = false
  @State private var detachError: String?

  /// 文案写错用"这条不对"改文案；内容根本不是这件事的，用"不属于这里"让证据重新归属。
  var canCorrect: Bool { fact.kind == "decision" || fact.kind == "inference" }
  var canDetach: Bool { fact.threadId != nil }

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(fact.text).font(.system(size: TextSize.body)).lineSpacing(TextSize.lineSpacing(TextSize.body)).foregroundStyle(Palette.ink)
        .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
      if let r = fact.reason, !r.isEmpty {
        Text(r).font(.system(size: TextSize.caption)).lineSpacing(3).foregroundStyle(Palette.muted).fixedSize(horizontal: false, vertical: true)
      }
      HStack(spacing: 16) {
        if fact.kind == "inference" { ConfidenceDots(value: fact.confidence) }
        if fact.origin == "user" {
          HStack(spacing: 4) { PhIcon("user", size: 12); Text("你写的") }.foregroundStyle(Palette.muted)
        }
        Button("依据 \(fact.evidence.count) 条") { showEvidence = true }
          .buttonStyle(.accentLink)
          .popover(isPresented: $showEvidence, arrowEdge: .bottom) { evidencePopover }
        // 两种纠错（AGENTS.md）：文案写错用"这条不对"改写；内容根本不是这件事的用"不属于这里"。悬停时出现，右键菜单也有。
        Group {
          if canCorrect { Button("这条不对", action: onCorrect) }
          if canDetach { Button(detaching ? "正在移出…" : "不属于这里") { confirmDetach = true }.disabled(detaching) }
        }
        .buttonStyle(.accentLink)
        .opacity(hovering || confirmDetach || detaching ? 1 : 0)
        if let detachError { Text(detachError).foregroundStyle(Palette.attention).lineLimit(2) }
      }
      .font(.system(size: TextSize.caption))
      .padding(.top, 4)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.horizontal, 16).padding(.vertical, 12)
    .contentShape(Rectangle())
    .onHover { hovering = $0 }
    .contextMenu {
      if canCorrect { Button("这条不对…", action: onCorrect) }
      if canDetach { Button("不属于这里…") { confirmDetach = true } }
    }
    .confirmationDialog("这条内容不属于这件事项？", isPresented: $confirmDetach) {
      Button("移出") { detach() }
      Button("取消", role: .cancel) {}
    } message: {
      Text("它和 \(fact.evidence.count) 条依据所在的活动会从这件事项里移走，以后也不会再分回来。下次整理时会自动归到合适的地方。")
    }
  }

  func detach() {
    detaching = true; detachError = nil
    Task {
      defer { detaching = false }
      do { try await store.api.detachFact(fact.id); store.revision += 1; onChanged() }
      catch { detachError = error.localizedDescription }
    }
  }

  var evidencePopover: some View {
    VStack(alignment: .leading, spacing: 4) {
      if let rows = evidence.value {
        let hits = rows.filter { fact.evidence.contains($0.id) }
        if hits.isEmpty { Text("找不到依据记录，可能已经删除").font(.system(size: TextSize.body)).foregroundStyle(Palette.muted).padding(8) }
        ForEach(hits) { e in
          EvidenceRow(evidence: e) { showEvidence = false; store.showRecord(e.id, at: e.start) }
        }
      } else if let e = evidence.error {
        Text(e).font(.system(size: TextSize.body)).foregroundStyle(Palette.muted).padding(8)
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
    HStack(spacing: 4) {
      ForEach(0..<5) { i in
        Circle().fill(Double(i) < (value ?? 0) * 5 - 0.001 ? Palette.muted : Palette.hairline).frame(width: 5, height: 5)
      }
      Text(value.map { "把握 \(Int($0 * 100))%" } ?? "把握未知").monospacedDigit().foregroundStyle(Palette.muted)
    }
    .help("模型对这条推测有几成把握")
  }
}

struct EvidenceRow: View {
  let evidence: Evidence
  let action: () -> Void
  @State private var hovering = false
  var body: some View {
    Button(action: action) {
      HStack(spacing: 8) {
        SourceGlyph(source: evidence.source ?? "", size: 20)
        VStack(alignment: .leading, spacing: 2) {
          Text(RecordText.title(evidence.title, source: evidence.source ?? "")).font(.system(size: TextSize.body)).foregroundStyle(Palette.ink).lineLimit(1)
          if let s = evidence.start {
            Text("\(ViewerFormat.dayTitle(s)) \(ViewerFormat.clock(s))").font(.system(size: TextSize.caption)).monospacedDigit().foregroundStyle(Palette.muted)
          }
        }
        Spacer()
        PhIcon("arrow-up-right", size: 13).foregroundStyle(Palette.muted).opacity(hovering ? 1 : 0)
      }
      .padding(.horizontal, 8).padding(.vertical, 6)
      .background(hovering ? Palette.fill : .clear, in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
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
      if rows.isEmpty { Placeholder(kind: .empty("file-magnifying-glass", "还没有依据记录")).frame(height: 200) }
      else {
        VStack(alignment: .leading, spacing: 8) {
          Text("\(Fmt.count(rows.count)) 条原始记录").sectionTitle()
          // 外层圆角 10、内边距 4，行的悬停底色圆角 6，同心。
          VStack(spacing: 0) {
            ForEach(rows.sorted { ($0.start ?? .distantPast) > ($1.start ?? .distantPast) }) { e in
              EvidenceRow(evidence: e) { store.showRecord(e.id, at: e.start) }
            }
          }
          .padding(4)
          .card()
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
  var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("这条不对").font(.system(size: TextSize.title, weight: .semibold))
      Text(fact.text).font(.system(size: TextSize.body)).foregroundStyle(Palette.muted).lineSpacing(TextSize.lineSpacing(TextSize.body))
        .fixedSize(horizontal: false, vertical: true)
      Text("改成").font(.system(size: TextSize.body, weight: .semibold)).padding(.top, 4)
      TextEditor(text: $text).font(.system(size: TextSize.body)).scrollContentBackground(.hidden).padding(8).card(Radius.control).frame(minHeight: 120)
      Text("依据和归属不变，以后显示你写的这句。").font(.system(size: TextSize.caption)).foregroundStyle(Palette.muted)
      if let error { Text(error).font(.system(size: TextSize.body)).foregroundStyle(Palette.attention) }
      HStack {
        Spacer()
        Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
        Button(busy ? "正在修正…" : "修正") {
          Task {
            busy = true; defer { busy = false }
            do { try await store.api.correct(fact, text: trimmed); onSaved(); dismiss() }
            catch { self.error = error.localizedDescription }
          }
        }
        .buttonStyle(.accent)
        .keyboardShortcut(.defaultAction)
        .disabled(busy || trimmed.isEmpty || trimmed == fact.text)
      }
    }
    .padding(24).frame(width: 500)
    .onAppear { text = fact.text }
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
      .frame(maxWidth: 860, alignment: .leading)
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
    return VStack(alignment: .leading, spacing: 32) {
      VStack(alignment: .leading, spacing: 12) {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
          PhIcon(p?.confirmed.value == false ? "folder-dashed" : "folder", size: 20).foregroundStyle(Palette.muted)
          Text(d.name ?? "").font(.system(size: TextSize.heading, weight: .semibold)).foregroundStyle(Palette.ink)
          if p?.confirmed.value == false {
            Text("未确认").font(.system(size: TextSize.caption)).foregroundStyle(Palette.muted)
          }
        }
        if let b = d.brief {
          Text(b).font(.serif(TextSize.title)).lineSpacing(TextSize.serifLineSpacing(TextSize.title)).foregroundStyle(Palette.ink)
            .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
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
      VStack(alignment: .leading, spacing: 24) {
        ForEach(order, id: \.self) { status in
          let group = rows.filter { $0.status == status }
          if !group.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
              HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(threadStatus[status] ?? status).sectionTitle()
                Text("\(group.count) 件").font(.system(size: TextSize.caption)).foregroundStyle(Palette.muted)
              }
              if status == "active" {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 280), spacing: 12)], spacing: 12) {
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
                .card()
              }
            }
          }
        }
      }
    } else if let e = threads.error {
      Text(e).font(.system(size: TextSize.body)).foregroundStyle(Palette.muted)
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
        Button { store.path.removeLast() } label: { PhIcon("caret-left", size: PhIcon.toolbar) }
          .help("返回").accessibilityLabel("返回").keyboardShortcut("[", modifiers: .command)
      }
    }
  }
}
