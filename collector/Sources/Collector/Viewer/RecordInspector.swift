import AppKit
import SwiftUI
import CollectorCore

/// 右侧检查器：一条记录的全部内容、上下文、修正和删除。
struct RecordInspector: View {
  /// 记录所在的活动段，点了回到那一段。
  struct Back { let title: String; let action: () -> Void }
  let id: String
  var back: Back? = nil
  let onDelete: ([String]) -> Void
  @Environment(ViewerStore.self) private var store
  @State private var detail: RecordDetail?
  /// 对话记录所在的整场对话：整理过的原文和总结。
  @State private var conversation: ConversationDetail?
  @State private var error: String?
  @State private var showAll = false
  @State private var showOriginal = false
  @State private var correcting = false
  @State private var confirmDelete = false
  @State private var busy = false
  @State private var copied = false
  @State private var copyReset: Task<Void, Never>?
  @State private var deleteError: String?

  var body: some View {
    Group {
      if let detail { content(detail) }
      else if let error { Placeholder(kind: .error(error) { Task { await load() } }) }
      else { Placeholder(kind: .loading) }
    }
    .task { await load() }
    .sheet(isPresented: $correcting) {
      if let detail { CorrectionSheet(original: detail.current, originalID: detail.record.id) { Task { await load(); store.revision += 1 } } }
    }
  }

  func load() async {
    do {
      let d = try await store.api.record(id)
      // 读不到整场对话时退回显示这条记录的原文，不报错。
      conversation = d.record.source == "mac.audio" ? try? await store.api.conversation(id) : nil
      detail = d; error = nil
    }
    catch is CancellationError {}
    catch { self.error = error.localizedDescription }
  }

  func content(_ d: RecordDetail) -> some View {
    let r = d.record, cur = d.current
    return ScrollView {
      VStack(alignment: .leading, spacing: 20) {
        if let back {
          Button(action: back.action) {
            HStack(spacing: 4) {
              PhIcon("caret-left", size: 12)
              Text(back.title).lineLimit(1)
            }
          }
          .buttonStyle(.accentLink).font(.system(size: TextSize.body))
          .padding(.bottom, -8)
        }
        header(d)
        if cur.id != r.id {
          // cur.start 是修正记录写入的时间。
          HStack(spacing: 8) {
            PhIcon("note-pencil", size: 14)
            Text(ViewerFormat.relative(cur.start) == "刚刚" ? "刚刚修正过" : "\(ViewerFormat.relative(cur.start))修正过")
            Spacer()
            Button(showOriginal ? "收起原文" : "查看原文") { withAnimation(.easeOut(duration: 0.2)) { showOriginal.toggle() } }.buttonStyle(.accentLink)
          }
          .font(.system(size: TextSize.body))
          .foregroundStyle(Palette.muted)
        }
        if let c = conversation { ConversationBody(conversation: c) }
        else { bodyText(cur.body ?? "") }
        if showOriginal, cur.id != r.id {
          VStack(alignment: .leading, spacing: 8) {
            Text("原文").sectionTitle()
            bodyText(r.body ?? "")
          }
        }
        contextGrid(r)
      }
      .padding(20)
    }
    .background(Palette.paper)
  }

  func header(_ d: RecordDetail) -> some View {
    let r = d.record
    return VStack(alignment: .leading, spacing: 12) {
      HStack(spacing: 12) {
        SourceGlyph(source: r.source, app: r.contextText("app"), size: 32)
        VStack(alignment: .leading, spacing: 2) {
          Text(SourceInfo.name(r.source)).font(.system(size: TextSize.caption, weight: .semibold)).foregroundStyle(Palette.muted)
          Text(conversation.map(conversationTime) ?? timeLine(r)).font(.system(size: TextSize.caption)).monospacedDigit().foregroundStyle(Palette.muted)
        }
      }
      Text(conversation.map { $0.title ?? "对话" } ?? RecordText.title(r, appShown: false)).font(.serif(TextSize.title, .semibold)).foregroundStyle(Palette.ink)
        .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
      actions(d)
    }
  }

  func timeLine(_ r: HistoryRecord) -> String {
    var s = "\(Fmt.date(r.start)) \(ViewerFormat.clock(r.start))"
    if let e = r.end, r.isSpan {
      if ViewerFormat.clock(e) != ViewerFormat.clock(r.start) { s += "–\(ViewerFormat.clock(e))" }
      if r.seconds >= 1 { s += "，共 \(Fmt.duration(r.seconds))" }
    }
    return s
  }

  /// 整场对话的起止，"11 月 11 日 16:03–16:45，共 42 分钟"。
  func conversationTime(_ c: ConversationDetail) -> String {
    guard let a = ViewerTime.parse(c.start), let b = ViewerTime.parse(c.end) else { return "" }
    var s = "\(Fmt.date(a)) \(Fmt.range(a, b))"
    if b.timeIntervalSince(a) >= 60 { s += "，共 \(Fmt.duration(b.timeIntervalSince(a)))" }
    return s
  }

  @ViewBuilder func bodyText(_ text: String) -> some View {
    let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
    if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      Text("这条没有正文").font(.system(size: TextSize.body)).foregroundStyle(Palette.muted)
    } else {
      VStack(alignment: .leading, spacing: 8) {
        Text(showAll || lines.count <= 60 ? text : lines.prefix(60).joined(separator: "\n"))
          .font(.system(size: TextSize.body))
          .foregroundStyle(Palette.ink)
          .lineSpacing(TextSize.lineSpacing(TextSize.body))
          .textSelection(.enabled)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(16)
          .card()
        if lines.count > 60 {
          Button(showAll ? "收起" : "展开全部 \(Fmt.count(lines.count)) 行") { showAll.toggle() }.buttonStyle(.accentLink).font(.system(size: TextSize.body))
        }
      }
    }
  }

  @ViewBuilder func contextGrid(_ r: HistoryRecord) -> some View {
    let rows = contextRows(r)
    if !rows.isEmpty {
      VStack(alignment: .leading, spacing: 8) {
        Text("记录时的情况").sectionTitle()
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 8) {
          ForEach(rows, id: \.0) { label, value in
            GridRow {
              Text(label).font(.system(size: TextSize.caption)).foregroundStyle(Palette.muted).gridColumnAlignment(.trailing)
              if label == "网址", let url = URL(string: value), ["http", "https"].contains(url.scheme ?? "") {
                Link(value, destination: url).font(.system(size: TextSize.caption)).lineLimit(3)
              } else if ["仓库", "目录", "路径"].contains(label) {
                Button { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: (value as NSString).expandingTildeInPath) } label: {
                  Text(value).font(.mono(TextSize.caption)).foregroundStyle(Palette.ink).multilineTextAlignment(.leading)
                }
                .buttonStyle(.plain).help("在访达中显示")
              } else {
                Text(value).font(.system(size: TextSize.caption)).foregroundStyle(Palette.ink).textSelection(.enabled).lineLimit(4)
              }
            }
          }
        }
      }
    }
  }

  func contextRows(_ r: HistoryRecord) -> [(String, String)] {
    var rows: [(String, String)] = []
    let app = r.contextText("app")
    if let name = AppIcons.name(app) { rows.append(("应用", name)) }
    for (key, label) in [("window", "窗口"), ("url", "网址"), ("repo", "仓库"), ("cwd", "目录"), ("chat", "会话"), ("place", "地点")] {
      if let v = r.contextText(key) {
        let shown = key == "repo" || key == "cwd" ? (v as NSString).abbreviatingWithTildeInPath : v
        if key == "cwd", rows.contains(where: { $0.1 == shown }) { continue }
        rows.append((label, shown))
      }
    }
    if case .object(let extra)? = r.context?["extra"] {
      let names = ["hash": "提交", "files": "文件数", "added": "新增行", "deleted": "删除行", "author": "作者", "from_url": "下载来源",
                   "size": "大小", "dir": "目录", "profile": "浏览器配置", "exit": "退出码", "duration_ms": "耗时", "location": "地点",
                   "attendees": "参会人", "calendar": "日历"]
      for (k, v) in extra.sorted(by: { $0.key < $1.key }) {
        guard let label = names[k], var text = v.text else { continue }
        if k == "hash" { text = String(text.prefix(10)) }
        if k == "size", let n = Int(text) { if n == 0 { continue }; text = ViewerFormat.bytes(n) }
        if k == "duration_ms", let n = Double(text) { text = Fmt.duration(n / 1000) }
        rows.append((label, text))
      }
    }
    var capture = r.capture?.method ?? ""
    capture = ["ax": "读取窗口文字", "ocr": "截图识字", "db": "读取数据库", "api": "系统接口", "file": "读取文件", "hook": "终端钩子", "asr": "语音转文字", "manual": "手动补写"][capture] ?? capture
    // confidence 是采集端给的识别置信度（OCR、转写），0–1。
    if let c = r.capture?.confidence { capture += "，识别把握 \(Int((c * 100).rounded()))%" }
    if !capture.isEmpty { rows.append(("怎么记的", capture)) }
    rows.append(("设备", r.device))
    if (r.redactions ?? 0) > 0 { rows.append(("隐去的密钥", "\(r.redactions!) 处")) }
    return rows
  }

  func actions(_ d: RecordDetail) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 8) {
        Button { correcting = true } label: { Label { Text("修正") } icon: { PhIcon("pencil-simple", size: 14) } }
        Button {
          NSPasteboard.general.clearContents()
          NSPasteboard.general.setString(conversation.map(ConversationBody.plain) ?? d.current.body ?? d.record.title, forType: .string)
          copied = true
          copyReset?.cancel()
          copyReset = Task {
            try? await Task.sleep(for: .seconds(1.5))
            if !Task.isCancelled { copied = false }
          }
        } label: { Label { Text(copied ? "已复制" : "复制") } icon: { PhIcon(copied ? "check" : "copy", size: 14) } }
        Spacer()
        Button { confirmDelete = true } label: { Label { Text("删除") } icon: { PhIcon("trash", size: 14) } }
          .buttonStyle(.borderless).foregroundStyle(Palette.attention)
          .disabled(busy)
      }
      if let deleteError { Text(deleteError).font(.system(size: TextSize.caption)).foregroundStyle(Palette.attention).textSelection(.enabled) }
    }
    .controlSize(.small)
    .confirmationDialog("删除这条记录？", isPresented: $confirmDelete) {
      Button("删除", role: .destructive) { Task { await delete(d) } }
      Button("取消", role: .cancel) {}
    } message: {
      Text("删除后不能恢复。已经交给云端 AI 的内容收不回来。")
    }
  }

  func delete(_ d: RecordDetail) async {
    busy = true; deleteError = nil; defer { busy = false }
    do {
      try await store.api.deleteRecord(d.record.id)
      onDelete([d.record.id] + d.corrections.map(\.id))
      store.revision += 1
    } catch { deleteError = error.localizedDescription }
  }
}

// MARK: 修正与补写

struct CorrectionSheet: View {
  let original: HistoryRecord
  let originalID: String
  let onSaved: () -> Void
  @Environment(ViewerStore.self) private var store
  @Environment(\.dismiss) private var dismiss
  @State private var text = ""
  @State private var busy = false
  @State private var error: String?

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("修正这条记录").font(.system(size: TextSize.title, weight: .semibold))
      Text("原文会保留，以后显示和整理都用你改的版本。").font(.system(size: TextSize.body)).foregroundStyle(Palette.muted)
      TextEditor(text: $text)
        .font(.system(size: TextSize.body))
        .scrollContentBackground(.hidden)
        .padding(8)
        .card(Radius.control)
        .frame(minHeight: 260)
      if let error { Text(error).font(.system(size: TextSize.body)).foregroundStyle(Palette.attention) }
      HStack {
        Spacer()
        Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
        Button(busy ? "正在修正…" : "修正") { Task { await save() } }
          .buttonStyle(.accent)
          .keyboardShortcut(.defaultAction).disabled(busy || text.count > 200_000 || text == (original.body ?? ""))
      }
    }
    .padding(24)
    .frame(width: 560)
    .onAppear { text = original.body ?? "" }
  }

  func save() async {
    busy = true; defer { busy = false }
    // 不继承原记录的来源键、媒体或采集信息；保留隐私等级。
    let record: [String: Any] = [
      "id": ULID.make(), "schema": 1, "device": store.device, "source": "manual.correction", "kind": "event",
      "t_start": LocalTime.iso(Date()), "title": original.title, "body": text, "corrects": originalID,
      "capture": ["method": "manual"], "sensitivity": original.sensitivity ?? "normal",
    ]
    do { try await store.api.saveManual(record); onSaved(); dismiss() }
    catch { self.error = error.localizedDescription }
  }
}

struct NoteSheet: View {
  let onSaved: () -> Void
  @Environment(ViewerStore.self) private var store
  @Environment(\.dismiss) private var dismiss
  @State private var start = Date()
  @State private var hasEnd = false
  @State private var end = Date()
  @State private var title = ""
  @State private var text = ""
  @State private var busy = false
  @State private var error: String?

  var trimmed: String { title.split(whereSeparator: \.isWhitespace).joined(separator: " ") }

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text("补写一条记录").font(.system(size: TextSize.title, weight: .semibold))
      Form {
        DatePicker("开始", selection: $start, in: ...Date())
        Toggle("持续了一段时间", isOn: $hasEnd.animation(.easeOut(duration: 0.2)))
        if hasEnd { DatePicker("结束", selection: $end, in: start...) }
        TextField("标题", text: $title, prompt: Text("做了什么"))
      }
      .formStyle(.columns)
      TextEditor(text: $text)
        .font(.system(size: TextSize.body))
        .scrollContentBackground(.hidden)
        .padding(8)
        .card(Radius.control)
        .frame(minHeight: 180)
        .overlay(alignment: .topLeading) {
          if text.isEmpty {
            Text("想多写点可以写在这里").font(.system(size: TextSize.body)).foregroundStyle(Palette.muted)
              .padding(.horizontal, 13).padding(.vertical, 8).allowsHitTesting(false)
          }
        }
      if let error { Text(error).font(.system(size: TextSize.body)).foregroundStyle(Palette.attention) }
      HStack {
        Spacer()
        Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
        Button(busy ? "正在保存…" : "保存") { Task { await save() } }
          .buttonStyle(.accent)
          .keyboardShortcut(.defaultAction)
          .disabled(busy || trimmed.isEmpty || trimmed.count > 200 || (hasEnd && end < start))
      }
    }
    .padding(24)
    .frame(width: 520)
  }

  func save() async {
    busy = true; defer { busy = false }
    var record: [String: Any] = [
      "id": ULID.make(), "schema": 1, "device": store.device, "source": "manual.note", "kind": hasEnd ? "span" : "event",
      "t_start": LocalTime.iso(start), "title": trimmed, "body": text, "capture": ["method": "manual"], "sensitivity": "normal",
    ]
    if hasEnd { record["t_end"] = LocalTime.iso(end) }
    do { try await store.api.saveManual(record); onSaved(); dismiss() }
    catch { self.error = error.localizedDescription }
  }
}

// MARK: 对话

/// 一场对话：先是总结，再是整理过的原文（同一个人接着说的合在一起，去掉了语气词和识别噪声），最后可以看转写原文。
struct ConversationBody: View {
  let conversation: ConversationDetail
  @State private var showRaw = false
  @State private var showAll = false

  var body: some View {
    let c = conversation
    VStack(alignment: .leading, spacing: 20) {
      summary(c)
      if c.turns.isEmpty {
        Text("没有转出能读的内容").font(.system(size: TextSize.body)).foregroundStyle(Palette.muted)
      } else {
        VStack(alignment: .leading, spacing: 12) {
          Text("对话内容").sectionTitle()
          let shown = showAll ? c.turns : Array(c.turns.prefix(80))
          ForEach(Array(shown.enumerated()), id: \.offset) { _, t in turn(t) }
          if c.turns.count > 80 {
            Button(showAll ? "收起" : "展开全部 \(Fmt.count(c.turns.count)) 段") { showAll.toggle() }.buttonStyle(.accentLink).font(.system(size: TextSize.body))
          }
        }
      }
      if let raw = c.records, !raw.isEmpty {
        VStack(alignment: .leading, spacing: 8) {
          Button(showRaw ? "收起转写原文" : "查看转写原文") { withAnimation(.easeOut(duration: 0.2)) { showRaw.toggle() } }
            .buttonStyle(.accentLink).font(.system(size: TextSize.body))
          if showRaw {
            Text(raw.map(\.body).joined(separator: "\n"))
              .font(.system(size: TextSize.caption)).foregroundStyle(Palette.muted)
              .lineSpacing(TextSize.lineSpacing(TextSize.caption)).textSelection(.enabled)
              .frame(maxWidth: .infinity, alignment: .leading)
          }
        }
      }
    }
  }

  @ViewBuilder func summary(_ c: ConversationDetail) -> some View {
    switch c.state {
    case "ready":
      VStack(alignment: .leading, spacing: 8) {
        if let s = c.summary {
          Text(s).font(.system(size: TextSize.body)).foregroundStyle(Palette.ink)
            .lineSpacing(TextSize.lineSpacing(TextSize.body)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        }
        ForEach(c.points, id: \.self) { p in
          HStack(alignment: .firstTextBaseline, spacing: 8) {
            Circle().fill(Palette.faint).frame(width: 4, height: 4).alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
            Text(p).font(.system(size: TextSize.body)).foregroundStyle(Palette.ink).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
          }
        }
      }
    case "waiting": Text("总结稍后生成").font(.system(size: TextSize.body)).foregroundStyle(Palette.muted)
    case "private": Text("私密内容不生成总结").font(.system(size: TextSize.body)).foregroundStyle(Palette.muted)
    default: EmptyView()
    }
  }

  func turn(_ t: ConversationDetail.Turn) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      HStack(alignment: .firstTextBaseline, spacing: 8) {
        Text(t.speaker).font(.system(size: TextSize.body, weight: .semibold)).foregroundStyle(Palette.ink)
        if let d = ViewerTime.parse(t.at) { Text(ViewerFormat.clock(d)).font(.system(size: TextSize.caption)).monospacedDigit().foregroundStyle(Palette.muted) }
      }
      Text(t.text).font(.system(size: TextSize.body)).foregroundStyle(Palette.ink)
        .lineSpacing(TextSize.lineSpacing(TextSize.body)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
    }
  }

  /// 复制时给整理过的原文，"16:03 我：……"一行一段。
  static func plain(_ c: ConversationDetail) -> String {
    c.turns.map { t in "\(ViewerTime.parse(t.at).map { ViewerFormat.clock($0) } ?? "") \(t.speaker)：\(t.text)" }.joined(separator: "\n")
  }
}
