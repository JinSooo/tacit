import AppKit
import SwiftUI
import CollectorCore

/// 事项状态只写文字，状态正常不上色。
func threadStatus(_ status: String) -> String? {
  switch status {
  case "active": L10n.taskInProgress
  case "paused": L10n.paused
  case "done": L10n.done
  case "abandoned": L10n.dropped
  case "archived": L10n.archived
  default: nil
  }
}

struct ThreadCard: View {
  let thread: HubThread
  let project: Project?

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 8) {
        if let project { ProjectTag(name: project.name, unconfirmed: !project.confirmed.value) }
        else if thread.domain == "life" {
          HStack(spacing: 4) { PhIcon("leaf", size: 12); Text(L10n.personal) }
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
        Text(L10n.summarizing).font(.system(size: TextSize.caption)).foregroundStyle(Palette.muted)
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
  static var help: String { L10n.taskSessionHelp }
  static func text(_ t: HubThread) -> String? {
    var parts: [String] = []
    if let first = t.first { parts.append(Calendar.current.isDateInToday(first) ? L10n.startedToday : L10n.startedOn(Fmt.date(first))) }
    if let n = t.sessions, n > 1 { parts.append(L10n.sessionCount(n)) }
    return parts.isEmpty ? nil : parts.joined(separator: L10n.comma)
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
      if let s = threadStatus(thread.status), thread.status != "active" {
        Text(s).font(.system(size: TextSize.caption)).foregroundStyle(Palette.muted)
      }
      Text(ViewerFormat.relative(thread.last)).font(.system(size: TextSize.caption)).foregroundStyle(Palette.muted).frame(minWidth: 60, alignment: .trailing)
      PhIcon("caret-right", size: 12).foregroundStyle(Palette.faint)
    }
    .padding(.horizontal, 16).padding(.vertical, 12)
    .background(hovering ? Palette.fill : .clear)
    .contentShape(Rectangle())
    .hoverState($hovering)
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
    .navigationTitle(detail.value?.title ?? L10n.task)
    .toolbar { BackButton() }
    .task(id: store.revision) { await load() }
    .task(id: depth) { if depth == 2, evidence.value == nil { await loadEvidence() } }
  }

  func load() async { await detail.run { try await store.dataSource.thread(id, level: "detail") } }
  func loadEvidence() async { await evidence.run { try await store.dataSource.thread(id, level: "evidence").records ?? [] } }

  func content(_ d: EntityDetail) -> some View {
    VStack(alignment: .leading, spacing: 24) {
      VStack(alignment: .leading, spacing: 12) {
        HStack(spacing: 12) {
          if let p = store.project(d.projectId) {
            Button { store.section = .project(p.id) } label: { ProjectTag(name: p.name, unconfirmed: !p.confirmed.value) }.buttonStyle(.plain)
          }
          if let s = threadStatus(d.status ?? "") {
            Text(s).font(.system(size: TextSize.caption, weight: .medium)).foregroundStyle(Palette.muted)
          }
        }
        Text(d.title ?? "").font(.system(size: TextSize.heading, weight: .semibold)).foregroundStyle(Palette.ink).textSelection(.enabled)
          .lineSpacing(TextSize.serifLineSpacing(TextSize.heading) / 2)
          .fixedSize(horizontal: false, vertical: true)
        Picker(L10n.level, selection: $depth) {
          Text(L10n.brief).tag(0); Text(L10n.detailed).tag(1); Text(L10n.basedOn).tag(2)
        }
        .pickerStyle(.segmented).labelsHidden().frame(width: 240)
        .padding(.top, 4)
      }
      switch depth {
      case 0:
        Text(d.brief ?? L10n.noBriefYet).font(.serif(TextSize.title)).lineSpacing(TextSize.serifLineSpacing(TextSize.title)).textSelection(.enabled)
          .foregroundStyle(Palette.ink)
          .fixedSize(horizontal: false, vertical: true)
          .padding(.leading, 16)
          .overlay(alignment: .leading) { Rectangle().fill(Palette.hairline).frame(width: 2) }
      case 1:
        DetailBody(detail: d, progressLabel: L10n.progress, progress: d.detail?.progress)
        FactsView(facts: d.facts ?? [], loadEvidence: { try await store.dataSource.thread(id, level: "evidence").records ?? [] }) { Task { await load() } }
      default:
        EvidenceList(loader: evidence) { Task { await loadEvidence() } }
      }
    }
    .animation(Motion.standard, value: depth)
  }
}

struct DetailBody: View {
  let detail: EntityDetail
  let progressLabel: String
  let progress: String?

  var body: some View {
    VStack(alignment: .leading, spacing: 24) {
      paragraph(L10n.goal, detail.detail?.goal)
      paragraph(progressLabel, progress)
      if let people = detail.detail?.people, !people.isEmpty { paragraph(L10n.people, people.joined(separator: L10n.listSeparator)) }
      if let artifacts = detail.detail?.artifacts {
        let groups: [(String, String, [String])] = [(L10n.links, "link", artifacts["urls"]?.strings ?? []), (L10n.files, "file", artifacts["files"]?.strings ?? []),
                                                    (L10n.commands, "terminal-window", artifacts["commands"]?.strings ?? [])].filter { !$0.2.isEmpty }
        if !groups.isEmpty {
          VStack(alignment: .leading, spacing: 8) {
            Text(L10n.related).sectionTitle()
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
    .help(symbol == "terminal-window" ? L10n.copyCommand : L10n.openAction)
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
          FactGroup(kind: g.kind, label: L10n.factKind(g.kind, chinese: g.label), symbol: g.symbol, rows: rows, evidence: evidence, loadEvidence: loadEvidence, onChanged: onChanged) { correcting = $0 }
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
        Text(L10n.factCount(rows.count)).font(.system(size: TextSize.caption)).foregroundStyle(Palette.muted)
      }
      VStack(alignment: .leading, spacing: 0) {
        ForEach(Array(shown.enumerated()), id: \.element.id) { i, f in
          FactRow(fact: f, evidence: evidence, loadEvidence: loadEvidence, onCorrect: { onCorrect(f) }, onChanged: onChanged)
          if i < shown.count - 1 { Divider().padding(.leading, 16) }
        }
      }
      .card()
      if rows.count > limit {
        Button(expanded ? L10n.collapse : L10n.showFacts(rows.count)) { Motion.animate { expanded.toggle() } }
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
          HStack(spacing: 4) { PhIcon("user", size: 12); Text(L10n.writtenByYou) }.foregroundStyle(Palette.muted)
        }
        Button(L10n.basedOnRecordCount(fact.evidence.count)) { showEvidence = true }
          .buttonStyle(.accentLink)
          .popover(isPresented: $showEvidence, arrowEdge: .bottom) { evidencePopover }
        // 两种纠错（AGENTS.md）：文案写错用"这条不对"改写；内容根本不是这件事的用"不属于这里"。悬停时出现，右键菜单也有。
        Group {
          if canCorrect { Button(L10n.thisIsWrong, action: onCorrect) }
          if canDetach { Button(detaching ? L10n.removing : L10n.doesntBelongHere) { confirmDetach = true }.disabled(detaching) }
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
    .hoverState($hovering)
    .contextMenu {
      if canCorrect { Button(L10n.thisIsWrongAction, action: onCorrect) }
      if canDetach { Button(L10n.doesntBelongHereAction) { confirmDetach = true } }
    }
    .confirmationDialog(L10n.removeThisFromTheTask, isPresented: $confirmDetach) {
      Button(L10n.removeAction) { detach() }
      Button(L10n.cancel, role: .cancel) {}
    } message: {
      Text(L10n.detachFactPrompt(fact.evidence.count))
    }
  }

  func detach() {
    detaching = true; detachError = nil
    Task {
      defer { detaching = false }
      do { try await store.api.detachFact(fact.id); store.revision += 1; onChanged() }
      catch { detachError = UserFacingError.message(for: error, fallback: L10n.Settings.settingsRequestFailed) }
    }
  }

  var evidencePopover: some View {
    VStack(alignment: .leading, spacing: 4) {
      if let rows = evidence.value {
        let hits = rows.filter { fact.evidence.contains($0.id) }
        if hits.isEmpty { Text(L10n.missingSupportingRecords).font(.system(size: TextSize.body)).foregroundStyle(Palette.muted).padding(8) }
        ForEach(hits) { e in
          EvidenceRow(evidence: e) { showEvidence = false; store.path.append(.reviewRecord(e.id)) }
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
      Text(value.map { L10n.modelConfidence(Int($0 * 100)) } ?? L10n.confidenceUnknown).monospacedDigit().foregroundStyle(Palette.muted)
    }
    .help(L10n.modelConfidenceHelp)
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
    .hoverState($hovering)
  }
}

struct EvidenceList: View {
  let loader: Loader<[Evidence]>
  let retry: () -> Void
  @Environment(ViewerStore.self) private var store
  var body: some View {
    if let rows = loader.value {
      if rows.isEmpty { Placeholder(kind: .empty("file-magnifying-glass", L10n.noSupportingRecordsYet)).frame(height: 200) }
      else {
        VStack(alignment: .leading, spacing: 8) {
          Text(L10n.originalRecordCount(rows.count)).sectionTitle()
          // 外层圆角 10、内边距 4，行的悬停底色圆角 6，同心。
          VStack(spacing: 0) {
            ForEach(rows.sorted { ($0.start ?? .distantPast) > ($1.start ?? .distantPast) }) { e in
              EvidenceRow(evidence: e) { store.path.append(.reviewRecord(e.id)) }
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
      Text(L10n.thisIsWrong).font(.system(size: TextSize.title, weight: .semibold))
      Text(fact.text).font(.system(size: TextSize.body)).foregroundStyle(Palette.muted).lineSpacing(TextSize.lineSpacing(TextSize.body))
        .fixedSize(horizontal: false, vertical: true)
      Text(L10n.replacement).font(.system(size: TextSize.body, weight: .semibold)).padding(.top, 4)
      TextEditor(text: $text).font(.system(size: TextSize.body)).scrollContentBackground(.hidden).padding(8).card(Radius.control).frame(minHeight: 120)
      Text(L10n.factCorrectionExplanation).font(.system(size: TextSize.caption)).foregroundStyle(Palette.muted)
      if let error { Text(error).font(.system(size: TextSize.body)).foregroundStyle(Palette.attention) }
      HStack {
        Spacer()
        Button(L10n.cancel) { dismiss() }.keyboardShortcut(.cancelAction)
        Button(busy ? L10n.correcting : L10n.correct) {
          Task {
            busy = true; defer { busy = false }
            do { try await store.api.correct(fact, text: trimmed); onSaved(); dismiss() }
            catch { self.error = UserFacingError.message(for: error, fallback: L10n.Settings.settingsRequestFailed) }
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
  var shortcut: KeyboardShortcut? = KeyboardShortcut("[", modifiers: .command)
  @Environment(ViewerStore.self) private var store
  var body: some ToolbarContent {
    ToolbarItem(placement: .navigation) {
      if !store.path.isEmpty {
        Button { store.path.removeLast() } label: { PhIcon("caret-left", size: PhIcon.toolbar) }
          .help(L10n.back).accessibilityLabel(L10n.back).keyboardShortcut(shortcut)
      }
    }
  }
}
