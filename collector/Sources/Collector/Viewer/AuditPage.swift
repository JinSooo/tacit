import SwiftUI
import CollectorCore

/// Agent 每次读了什么。
struct AuditPage: View {
  @Environment(ViewerStore.self) private var store
  @State private var tool = ""
  @State private var reads: [AuditRead] = []
  @State private var cursor: String?
  @State private var error: String?
  @State private var loading = false
  @State private var expanded: Set<String> = []
  @State private var targets: [String: (kind: String, title: String)?] = [:]

  var body: some View {
    ScrollView {
      LazyVStack(alignment: .leading, spacing: 0) {
        Text("内容链接查看的是当前记录；自动带入可查看当时保存的正文。").font(.system(size: TextSize.body)).foregroundStyle(Palette.muted)
          .padding(.bottom, 24)
        if reads.isEmpty {
          if loading { Placeholder(kind: .loading).frame(height: 240) }
          else if let error { Placeholder(kind: .error(error) { Task { await load(reset: true) } }).frame(height: 240) }
          else { Placeholder(kind: .empty("eye-slash", "AI 工具还没有读取过")).frame(height: 240) }
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
    .navigationTitle("运行记录")
    .toolbar {
      ToolbarItem(placement: .principal) {
        Picker("工具", selection: $tool) {
          Text("全部").tag(""); Text("Claude Code").tag("claude-code"); Text("Codex").tag("codex")
        }
        .pickerStyle(.segmented).labelsHidden()
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
    loading = true; defer { loading = false }
    do {
      let page = try await store.api.audit(tool: tool.isEmpty ? nil : tool, cursor: reset ? nil : cursor)
      reads = reset ? page.reads : reads + page.reads.filter { r in !reads.contains { $0.id == r.id } }
      cursor = page.next; error = nil
      // 副标题要显示读的是哪个线程或项目。
      let ids = page.reads.compactMap { $0.args["id"]?.text }
      Task { await resolve(ids) }
    } catch is CancellationError {
    } catch { self.error = error.localizedDescription; if reset { reads = [] } }
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
            SourceGlyph(source: read.tool == "codex" ? "codex.session" : "claude_code.session", size: 28)
              .help(["claude-desktop": "Claude Desktop", "claude-code": "Claude Code", "codex": "Codex"][read.tool] ?? read.tool)
          }
          VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
              Text(action).font(.system(size: TextSize.body, weight: .medium)).foregroundStyle(Palette.ink)
              if !read.ok.value { Text("失败").font(.system(size: TextSize.caption, weight: .semibold)).foregroundStyle(Palette.attention) }
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
            if count > 1 { Text("重复 \(count) 次").help("连续 \(count) 次相同的读取，点开逐次查看") }
            else if !read.resultIds.isEmpty { Text("读到 \(Fmt.count(Set(read.resultIds).count)) 项").help(read.kind == "context" ? "带入了几个项目和事项" : "读到了几个项目、事项、事实或记录") }
          }
          .font(.system(size: TextSize.caption)).monospacedDigit().foregroundStyle(Palette.muted)
          Text(read.date.map { ViewerFormat.clock($0) } ?? "").font(.system(size: TextSize.caption)).monospacedDigit().foregroundStyle(Palette.muted).frame(width: 40, alignment: .trailing)
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
          if read.resultIds.isEmpty { Text("这次没有读到内容").font(.system(size: TextSize.body)).foregroundStyle(Palette.muted).padding(.vertical, 4) }
          ForEach(Array(Set(read.resultIds)).sorted(), id: \.self) { id in target(id) }
          if read.kind == "context" {
            Button(showSnapshot ? "收起当时带入" : "查看当时带入") { Motion.animate { showSnapshot.toggle() } }.buttonStyle(.accentLink).padding(.vertical,8)
            if showSnapshot { RuntimeSnapshotView(id:read.id).transition(.reveal) }
          }
          // bytes：返回给 AI 工具的 JSON 大小。
          Text("共返回 \(ViewerFormat.bytes(read.bytes))").font(.system(size: TextSize.caption)).monospacedDigit().foregroundStyle(Palette.muted).padding(.top, 4)
        }
        .padding(.leading, 56).padding(.trailing, 16).padding(.bottom, 12)
        .transition(.reveal)
      }
    }
  }

  @ViewBuilder func target(_ id: String) -> some View {
    switch targets[id] {
    case .none:
      HStack(spacing: 8) { ProgressView().controlSize(.mini); Text("正在读取…").font(.system(size: TextSize.body)).foregroundStyle(Palette.muted) }.padding(.vertical, 4)
    case .some(.none):
      Text("这一项已经删除").font(.system(size: TextSize.body)).foregroundStyle(Palette.muted).padding(.vertical, 4).help(id)
    case .some(.some(let t)):
      let label = HStack(spacing: 8) {
        PhIcon(t.kind == "thread" ? "list-bullets" : t.kind == "project" ? "folder" : "file-text", size: 14)
          .foregroundStyle(Palette.muted).frame(width: 16)
          .help(["thread": "事项", "project": "项目", "record": "记录"][t.kind] ?? "")
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
    case "context": return read.args["event"]?.text == "compact" ? "对话压缩后重新带入" : "新会话开始时带入"
    case "now": return "查看此刻"
    case "get": return "读取\(["brief": "简介", "detail": "详情", "evidence": "依据"][read.args["level"]?.text ?? "brief"] ?? "内容")"
    case "search": return "搜索历史记录"
    case "timeline": return "查看时间线"
    case "append": return "添加到历史记录"
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
    if let n = read.args["q_length"]?.text { parts.append("搜了 \(n) 个字") }
    if let r = read.args["result"]?.text { parts.append(["created": "新添加一条", "unchanged": "已经有了，没有重复添加", "corrected": "内容变了，记成一条修正", "deleted": "以前删过，没有添加"][r] ?? r) }
    if let n = read.args["redactions"]?.text { parts.append("隐去了 \(n) 处密钥") }
    if let from = read.args["from"]?.text ?? read.args["to"]?.text { parts.append(from) }
    return parts.isEmpty ? nil : parts.joined(separator: "，")
  }
}
