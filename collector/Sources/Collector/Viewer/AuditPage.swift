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
        Text("Claude Code、Codex 每次读取你的上下文、往 History 写入内容，都会留在这里。").font(.serif(15)).foregroundStyle(.secondary)
          .padding(.bottom, 24)
        if reads.isEmpty {
          if loading { Placeholder(kind: .loading).frame(height: 240) }
          else if let error { Placeholder(kind: .error(error) { Task { await load(reset: true) } }).frame(height: 240) }
          else { Placeholder(kind: .empty("eye.slash", "还没有 Agent 读取过")).frame(height: 240) }
        }
        let days = Dictionary(grouping: reads) { Calendar.current.startOfDay(for: $0.date ?? .distantPast) }.sorted { $0.key > $1.key }
        ForEach(days, id: \.key) { day, rows in
          Text(ViewerFormat.dayTitle(day)).font(.serif(17, .semibold)).padding(.top, 18).padding(.bottom, 8)
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
                    .padding(.leading, 38).transition(.opacity)
                }
              }
              if i < groups.count - 1 { Divider().padding(.leading, 52) }
            }
          }
          .card(14)
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
    .navigationTitle("读取记录")
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
    withAnimation(.smooth(duration: 0.25)) { if expanded.remove(key) == nil { expanded.insert(key) } }
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
  /// 合并行的次数；大于 1 时右侧显示"×N"，点开逐次列出。
  var count = 1
  var nested = false
  let expanded: Bool
  let targets: [String: (kind: String, title: String)?]
  let toggle: () -> Void
  @Environment(ViewerStore.self) private var store
  @State private var hovering = false

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      Button(action: toggle) {
        HStack(spacing: 12) {
          if !nested { SourceGlyph(source: read.tool == "codex" ? "codex.session" : "claude_code.session", size: 26) }
          VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
              Text(action).font(.system(size: 13, weight: .medium))
              if !read.ok.value { Text("失败").font(.system(size: 10, weight: .semibold)).foregroundStyle(.red) }
            }
            if let s = summary { Text(s).font(.mono(10.5)).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle) }
          }
          Spacer()
          Text(count > 1 ? "×\(count)" : "\(read.resultIds.count) 项 · \(ViewerFormat.bytes(read.bytes))").font(.system(size: 11)).monospacedDigit().foregroundStyle(.secondary)
          Text(read.date.map { ViewerFormat.clock($0) } ?? "").font(.mono(11)).foregroundStyle(.tertiary).frame(width: 42, alignment: .trailing)
          Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold)).foregroundStyle(.quaternary)
            .rotationEffect(.degrees(expanded ? 90 : 0))
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(hovering ? Color.primary.opacity(0.03) : .clear)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .onHover { hovering = $0 }
      if expanded && count == 1 {
        VStack(alignment: .leading, spacing: 2) {
          if read.resultIds.isEmpty { Text("没有返回内容").font(.caption).foregroundStyle(.secondary).padding(8) }
          ForEach(Array(Set(read.resultIds)).sorted(), id: \.self) { id in target(id) }
        }
        .padding(.leading, 52).padding(.trailing, 14).padding(.bottom, 12)
        .transition(.opacity)
      }
    }
  }

  @ViewBuilder func target(_ id: String) -> some View {
    switch targets[id] {
    case .none:
      HStack(spacing: 6) { ProgressView().controlSize(.mini); Text(id).font(.mono(10.5)).foregroundStyle(.tertiary) }.padding(6)
    case .some(.none):
      Text("已删除或无法识别 · \(id)").font(.system(size: 11.5)).foregroundStyle(.tertiary).padding(6)
    case .some(.some(let t)):
      Button {
        switch t.kind {
        case "thread": store.path.append(.thread(id))
        case "project": store.section = .project(id)
        default: store.showRecord(id, at: nil)
        }
      } label: {
        HStack(spacing: 8) {
          Image(systemName: t.kind == "thread" ? "text.line.first.and.arrowtriangle.forward" : t.kind == "project" ? "folder" : "doc.text")
            .font(.system(size: 11)).foregroundStyle(.secondary).frame(width: 16)
          Text(t.title).font(.system(size: 12.5)).lineLimit(1)
          Text(["thread": "线程", "project": "项目", "record": "记录"][t.kind] ?? "").font(.system(size: 10.5)).foregroundStyle(.tertiary)
          Spacer()
        }
        .padding(.horizontal, 6).padding(.vertical, 5)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
    }
  }

  var action: String {
    switch read.kind {
    case "context": return read.args["event"]?.text == "compact" ? "压缩后重新注入" : "会话开始时注入"
    case "now": return "读取当前状态"
    case "get": return "读取\(["brief": "简略版", "detail": "详细版", "evidence": "证据"][read.args["level"]?.text ?? ""] ?? "内容")"
    case "search": return "搜索 History"
    case "timeline": return "读取时间线"
    case "append": return "写入 History"
    default: return read.kind
    }
  }

  var summary: String? {
    var parts: [String] = []
    if let cwd = read.args["cwd"]?.text { parts.append((cwd as NSString).abbreviatingWithTildeInPath) }
    if let id = read.args["id"]?.text {
      // 线程、项目显示标题；按天读取的 id 就是日期；认不出来时显示 id。
      if let t = targets[id], let title = t?.title { parts.append(title) } else { parts.append(id) }
    }
    if let n = read.args["q_length"]?.text { parts.append("查询 \(n) 字") }
    if let r = read.args["result"]?.text { parts.append(["created": "新增", "unchanged": "已存在，未重复写入", "corrected": "内容有变，已挂修正", "deleted": "已被删除过，未写入"][r] ?? r) }
    if let n = read.args["redactions"]?.text { parts.append("拦下 \(n) 处密钥") }
    if let from = read.args["from"]?.text ?? read.args["to"]?.text { parts.append(from) }
    return parts.isEmpty ? nil : parts.joined(separator: " · ")
  }
}
