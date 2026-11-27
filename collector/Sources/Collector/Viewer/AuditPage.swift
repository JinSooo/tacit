import SwiftUI
import CollectorCore

/// Agent 每次读了什么。
struct AuditPage: View {
  @Environment(ViewerStore.self) private var store
  @State private var tool = ""
  @State private var observedTools: Set<String> = []
  @State private var reads: [AuditRead] = []
  @State private var cursor: String?
  @State private var error: String?
  @State private var loading = false
  @State private var expanded: Set<String> = []
  @State private var targets: [String: (kind: String, title: String)?] = [:]

  var body: some View {
    ScrollView {
      LazyVStack(alignment: .leading, spacing: 0) {
        Text(L10n.auditExplanation).font(.system(size: TextSize.body)).foregroundStyle(Palette.muted)
          .padding(.bottom, 24)
        if reads.isEmpty {
          if loading { Placeholder(kind: .loading).frame(height: 240) }
          else if let error { Placeholder(kind: .error(error) { Task { await load(reset: true) } }).frame(height: 240) }
          else { Placeholder(kind: .empty("eye-slash", L10n.aiToolsHaventReadAnythingYet)).frame(height: 240) }
        }
        let days = Dictionary(grouping: reads) { Calendar.current.startOfDay(for: $0.date ?? .distantPast) }.sorted { $0.key > $1.key }
        ForEach(days, id: \.key) { day, rows in
          Text(ViewerFormat.dayTitle(day)).font(.serif(TextSize.title, .semibold)).foregroundStyle(Palette.ink).padding(.top, 16).padding(.bottom, 8)
          let groups = AuditGrouping.group(rows)
          VStack(spacing: 0) {
            ForEach(Array(groups.enumerated()), id: \.element.id) { i, g in
              if g.reads.count == 1 {
                row(g.latest)
              } else {
                // 相邻、完全相同的读取合成一行，展开后逐次列出。
                let key = "group:" + g.id
                AuditRow(read: g.latest, count: g.reads.count, expanded: expanded.contains(key), targets: targets) { toggle(key) }
                if expanded.contains(key) {
                  VStack(spacing: 0) { ForEach(g.reads) { r in row(r, nested: true) } }
                    .padding(.leading, 40).transition(.opacity)
                }
              }
              if i < groups.count - 1 { Divider().padding(.leading, 52) }
            }
          }
          .card()
        }
        if cursor != nil {
          ProgressView().controlSize(.small).frame(maxWidth: .infinity).padding(24)
            .onAppear { Task { await load(reset: false) } }
        }
      }
      .frame(maxWidth: 1080, alignment: .leading)
      .padding(.horizontal, 40).padding(.vertical, 32)
      .frame(maxWidth: .infinity)
    }
    .background(Palette.paper)
    .navigationTitle(L10n.runLog)
    .toolbar {
      if observedTools.count > 1 {
        ToolbarItem(placement: .principal) {
          Picker(L10n.tool, selection: $tool) {
            Text(L10n.all).tag("")
            ForEach(observedTools.map(AgentTools.auditTool).sorted { $0.label < $1.label }, id: \.id) { entry in
              Text(entry.label).tag(entry.id)
            }
          }
          .pickerStyle(.menu).labelsHidden()
        }
      }
    }
    .task(id: tool) { await load(reset: true) }
  }

  func row(_ r: AuditRead, nested: Bool = false) -> some View {
    AuditRow(read: r, nested: nested, expanded: expanded.contains(r.id), targets: targets) {
      toggle(r.id)
      if expanded.contains(r.id) { Task { await resolve(r.resultIds) } }
    }
  }

  func toggle(_ key: String) {
    Motion.animate { if expanded.remove(key) == nil { expanded.insert(key) } }
  }

  func load(reset: Bool) async {
    if loading && !reset { return }
    let requestedTool = tool
    loading = true; defer { if tool == requestedTool { loading = false } }
    do {
      let page = try await store.api.audit(tool: requestedTool.isEmpty ? nil : requestedTool, cursor: reset ? nil : cursor)
      guard !Task.isCancelled, tool == requestedTool else { return }
      if requestedTool.isEmpty {
        if reset { observedTools = [] }
        observedTools.formUnion(page.reads.map(\.tool))
      }
      reads = reset ? page.reads : reads + page.reads.filter { r in !reads.contains { $0.id == r.id } }
      cursor = page.next; error = nil
      // 副标题要显示读的是哪个线程或项目。
      let ids = page.reads.compactMap { $0.args["id"]?.text }
      Task { await resolve(ids) }
    } catch is CancellationError {
    } catch {
      guard !Task.isCancelled, tool == requestedTool else { return }
      self.error = error.localizedDescription
      if reset { reads = [] }
    }
  }

  func resolve(_ ids: [String]) async {
    for id in Set(ids) where targets[id] == nil {
      if let t = try? await store.api.resolveTarget(id) { targets[id] = .some(t) } else { targets[id] = .some(nil) }
    }
  }
}

struct AuditRow: View {
  let read: AuditRead
  /// 合并行的次数；大于 1 时右侧显示"N 次"，点开逐次列出。
  var count = 1
  var nested = false
  let expanded: Bool
  let targets: [String: (kind: String, title: String)?]
  let toggle: () -> Void
  @Environment(ViewerStore.self) private var store
  @State private var hovering = false
  @State private var showSnapshot = false

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      Button(action: toggle) {
        HStack(spacing: 12) {
          if !nested {
            let entry = AgentTools.auditTool(id: read.tool)
            SourceGlyph(source: entry.source ?? "", app: entry.bundle, size: 28, symbol: entry.symbol)
              .help(entry.label)
          }
          VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
              Text(action).font(.system(size: TextSize.body, weight: .medium)).foregroundStyle(Palette.ink)
              if !read.ok.value { Text(L10n.failed).font(.system(size: TextSize.caption, weight: .semibold)).foregroundStyle(Palette.attention) }
            }
            if path != nil || summary != nil {
              HStack(spacing: 8) {
                if let path { Text(path).font(.mono(TextSize.caption)).lineLimit(1).truncationMode(.middle) }
                if let summary { Text(summary).font(.system(size: TextSize.caption)).lineLimit(1).truncationMode(.tail) }
              }
              .foregroundStyle(Palette.muted)
            }
          }
          Spacer(minLength: 16)
          // count：连续几次一模一样的读取被合成这一行；resultIds：这次读到 / 带入的项目、事项、事实和记录的条数。
          Group {
            if count > 1 { Text(L10n.repeatedReads(count)).help(L10n.groupedReads(count)) }
            else if !read.resultIds.isEmpty { Text(L10n.itemsRead(Set(read.resultIds).count)).help(read.kind == "context" ? L10n.contextResultCountHelp : L10n.readResultCountHelp) }
          }
          .font(.system(size: TextSize.caption)).monospacedDigit().foregroundStyle(Palette.muted)
          Text(read.date.map { ViewerFormat.clock($0) } ?? "").font(.system(size: TextSize.caption)).monospacedDigit().foregroundStyle(Palette.muted).frame(width: AppLanguage.current == .zh ? 40 : 66, alignment: .trailing)
          DisclosureChevron(expanded: expanded, size: 12, sideways: true).foregroundStyle(Palette.faint)
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .background(hovering ? Palette.fill : .clear)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .hoverState($hovering)
      if expanded && count == 1 {
        VStack(alignment: .leading, spacing: 4) {
          if read.resultIds.isEmpty { Text(L10n.nothingWasReturned).font(.system(size: TextSize.body)).foregroundStyle(Palette.muted).padding(.vertical, 4) }
          ForEach(Array(Set(read.resultIds)).sorted(), id: \.self) { id in target(id) }
          if read.kind == "context" {
            Button(showSnapshot ? L10n.hideSavedSessionContext : L10n.showSavedSessionContext) { Motion.animate { showSnapshot.toggle() } }.buttonStyle(.accentLink).padding(.vertical,8)
            if showSnapshot { RuntimeSnapshotView(id:read.id).transition(.reveal) }
          }
          // bytes：返回给 AI 工具的 JSON 大小。
          Text(L10n.bytesReturned(ViewerFormat.bytes(read.bytes))).font(.system(size: TextSize.caption)).monospacedDigit().foregroundStyle(Palette.muted).padding(.top, 4)
        }
        .padding(.leading, 56).padding(.trailing, 16).padding(.bottom, 12)
        .transition(.reveal)
      }
    }
  }

  @ViewBuilder func target(_ id: String) -> some View {
    switch targets[id] {
    case .none:
      HStack(spacing: 8) { ProgressView().controlSize(.mini); Text(L10n.loading).font(.system(size: TextSize.body)).foregroundStyle(Palette.muted) }.padding(.vertical, 4)
    case .some(.none):
      Text(L10n.thisItemWasDeleted).font(.system(size: TextSize.body)).foregroundStyle(Palette.muted).padding(.vertical, 4).help(id)
    case .some(.some(let t)):
      let label = HStack(spacing: 8) {
        PhIcon(t.kind == "thread" ? "list-bullets" : t.kind == "project" ? "folder" : "file-text", size: 14)
          .foregroundStyle(Palette.muted).frame(width: 16)
          .help(["thread": L10n.task, "project": L10n.project, "record": L10n.record][t.kind] ?? "")
        Text(t.title).font(.system(size: TextSize.body)).foregroundStyle(Palette.ink).lineLimit(1)
        Spacer()
      }
      .padding(.vertical, 4)
      .contentShape(Rectangle())
      Button {
        if t.kind == "thread" { store.path.append(.threadStory(id)) }
        else if t.kind == "project" { store.section = .project(id) }
        else { store.path.append(.reviewRecord(id)) }
      } label: { label }
      .buttonStyle(.plain)
    }
  }

  var action: String {
    switch read.kind {
    case "context": return read.args["event"]?.text == "compact" ? L10n.contextAfterCompaction : L10n.contextAtSessionStart
    case "now": return L10n.viewNow
    case "get": return L10n.readAction(read.args["level"]?.text ?? "brief")
    case "search": return L10n.searchRecords
    case "timeline": return L10n.viewTimeline
    case "append": return L10n.addToRecords
    default: return read.kind
    }
  }

  /// 会话所在目录，等宽显示。
  var path: String? { read.args["cwd"]?.text.map { ($0 as NSString).abbreviatingWithTildeInPath } }

  var summary: String? {
    var parts: [String] = []
    if let id = read.args["id"]?.text {
      // 线程、项目显示标题；按天读取的 id 就是日期；认不出来时显示 id。
      if let t = targets[id], let title = t?.title { parts.append(title) } else { parts.append(id) }
    }
    if let n = read.args["q_length"]?.text { parts.append(L10n.searchCharacters(n)) }
    if let r = read.args["result"]?.text { parts.append(["created": L10n.addedARecord, "unchanged": L10n.alreadySaved, "corrected": L10n.appendedCorrection, "deleted": L10n.previouslyDeleted][r] ?? r) }
    if let n = read.args["redactions"]?.text { parts.append(L10n.hiddenSecrets(n)) }
    if let from = read.args["from"]?.text ?? read.args["to"]?.text { parts.append(from) }
    return parts.isEmpty ? nil : parts.joined(separator: L10n.comma)
  }
}
