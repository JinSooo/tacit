import AppKit
import SwiftUI
import CollectorCore

/// 右侧检查器：一条记录的全部内容、上下文、修正和删除。
struct RecordInspector: View {
  let id: String
  let onDelete: ([String]) -> Void
  @Environment(ViewerStore.self) private var store
  @State private var detail: RecordDetail?
  @State private var error: String?
  @State private var showAll = false
  @State private var showOriginal = false
  @State private var correcting = false
  @State private var confirmDelete = false
  @State private var busy = false

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
    do { detail = try await store.api.record(id); error = nil }
    catch is CancellationError {}
    catch { self.error = error.localizedDescription }
  }

  func content(_ d: RecordDetail) -> some View {
    let r = d.record, cur = d.current
    return ScrollView {
      VStack(alignment: .leading, spacing: 20) {
        header(r)
        if cur.id != r.id {
          HStack(spacing: 6) {
            Image(systemName: "pencil.and.outline")
            Text("已修正 · \(ViewerFormat.relative(cur.start))")
            Spacer()
            Button(showOriginal ? "收起原文" : "查看原文") { withAnimation(.smooth) { showOriginal.toggle() } }.buttonStyle(.link)
          }
          .font(.caption)
          .foregroundStyle(Palette.source("manual.correction"))
          .padding(10)
          .background(Palette.source("manual.correction").opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
        }
        if r.source == "mac.audio", let people = r.people, !people.isEmpty {
          HStack(spacing: 6) {
            Image(systemName: "person.2.wave.2")
            Text(store.speakerNames(people).joined(separator: "、"))
          }
          .font(.callout).foregroundStyle(.secondary)
        }
        bodyText(cur.body ?? "")
        if showOriginal, cur.id != r.id {
          VStack(alignment: .leading, spacing: 6) {
            Text("原文").sectionTitle()
            bodyText(r.body ?? "").opacity(0.7)
          }
        }
        contextGrid(r)
        actions(d)
      }
      .padding(20)
    }
    .background(Palette.paper)
  }

  func header(_ r: HistoryRecord) -> some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(spacing: 10) {
        SourceGlyph(source: r.source, app: r.contextText("app"), size: 34)
        VStack(alignment: .leading, spacing: 2) {
          Text(SourceInfo.name(r.source)).font(.system(size: 11, weight: .semibold)).foregroundStyle(Palette.source(r.source))
          Text(timeLine(r)).font(.system(size: 11)).monospacedDigit().foregroundStyle(.secondary)
        }
      }
      Text(r.title).font(.serif(19, .semibold)).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
    }
  }

  func timeLine(_ r: HistoryRecord) -> String {
    let c = Calendar.current.dateComponents([.month, .day], from: r.start)
    var s = "\(c.month!) 月 \(c.day!) 日 \(ViewerFormat.clock(r.start))"
    if let e = r.end, r.isSpan {
      if ViewerFormat.clock(e) != ViewerFormat.clock(r.start) { s += "–\(ViewerFormat.clock(e))" }
      if r.seconds >= 1 { s += " · \(ViewerFormat.duration(r.seconds))" }
    }
    return s
  }

  @ViewBuilder func bodyText(_ text: String) -> some View {
    let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
    if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      Text("没有正文").font(.callout).foregroundStyle(.tertiary)
    } else {
      VStack(alignment: .leading, spacing: 8) {
        Text(showAll || lines.count <= 60 ? text : lines.prefix(60).joined(separator: "\n"))
          .font(.system(size: 12.5))
          .lineSpacing(3.5)
          .textSelection(.enabled)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(14)
          .card(10)
        if lines.count > 60 {
          Button(showAll ? "收起" : "展开全部 \(lines.count) 行") { showAll.toggle() }.buttonStyle(.link).font(.caption)
        }
      }
    }
  }

  @ViewBuilder func contextGrid(_ r: HistoryRecord) -> some View {
    let rows = contextRows(r)
    if !rows.isEmpty {
      VStack(alignment: .leading, spacing: 8) {
        Text("上下文").sectionTitle()
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 7) {
          ForEach(rows, id: \.0) { label, value in
            GridRow {
              Text(label).font(.system(size: 11.5)).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
              if label == "URL", let url = URL(string: value), ["http", "https"].contains(url.scheme ?? "") {
                Link(value, destination: url).font(.system(size: 11.5)).lineLimit(3)
              } else if ["仓库", "目录", "路径"].contains(label) {
                Button { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: (value as NSString).expandingTildeInPath) } label: {
                  Text(value).font(.mono(11)).multilineTextAlignment(.leading)
                }
                .buttonStyle(.plain).help("在 Finder 中显示")
              } else {
                Text(value).font(.system(size: 11.5)).textSelection(.enabled).lineLimit(4)
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
    for (key, label) in [("window", "窗口"), ("url", "URL"), ("repo", "仓库"), ("cwd", "目录"), ("chat", "会话"), ("place", "地点")] {
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
        if k == "duration_ms", let n = Double(text) { text = ViewerFormat.duration(n / 1000) }
        rows.append((label, text))
      }
    }
    var capture = r.capture?.method ?? ""
    capture = ["ax": "辅助功能", "ocr": "OCR", "db": "数据库", "api": "系统接口", "file": "文件", "hook": "Shell 钩子", "asr": "语音转写", "manual": "手动"][capture] ?? capture
    if let c = r.capture?.confidence { capture += " · 置信度 \(Int(c * 100))%" }
    if !capture.isEmpty { rows.append(("采集", capture)) }
    rows.append(("设备", r.device))
    if (r.redactions ?? 0) > 0 { rows.append(("脱敏", "\(r.redactions!) 处")) }
    return rows
  }

  func actions(_ d: RecordDetail) -> some View {
    HStack(spacing: 10) {
      Button { correcting = true } label: { Label("修正", systemImage: "pencil") }
      Button {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(d.current.body ?? d.record.title, forType: .string)
      } label: { Label("复制", systemImage: "doc.on.doc") }
      Spacer()
      Button(role: .destructive) { confirmDelete = true } label: { Label("删除", systemImage: "trash") }
        .disabled(busy)
    }
    .controlSize(.regular)
    .padding(.top, 6)
    .confirmationDialog("删除这条记录？", isPresented: $confirmDelete) {
      Button("删除", role: .destructive) { Task { await delete(d) } }
    } message: {
      Text("删除后不能恢复，已经发给云端模型的内容收不回来。")
    }
  }

  func delete(_ d: RecordDetail) async {
    busy = true; defer { busy = false }
    do {
      try await store.api.deleteRecord(d.record.id)
      onDelete([d.record.id] + d.corrections.map(\.id))
      store.revision += 1
    } catch { self.error = error.localizedDescription; detail = nil }
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
    VStack(alignment: .leading, spacing: 14) {
      Text("修正正文").font(.serif(20, .semibold))
      Text("原文保留，显示和提炼以修正为准。").font(.callout).foregroundStyle(.secondary)
      TextEditor(text: $text)
        .font(.system(size: 13))
        .scrollContentBackground(.hidden)
        .padding(8)
        .card(8)
        .frame(minHeight: 260)
      if let error { Text(error).font(.callout).foregroundStyle(.red) }
      HStack {
        Spacer()
        Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
        Button(busy ? "提交中…" : "提交修正") { Task { await save() } }
          .keyboardShortcut(.defaultAction).disabled(busy || text.count > 200_000)
      }
    }
    .padding(22)
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
      Text("补写 History").font(.serif(22, .semibold))
      Form {
        DatePicker("开始", selection: $start, in: ...Date())
        Toggle("是一段时间", isOn: $hasEnd.animation())
        if hasEnd { DatePicker("结束", selection: $end, in: start...) }
        TextField("标题", text: $title, prompt: Text("这段时间做了什么"))
      }
      .formStyle(.columns)
      TextEditor(text: $text)
        .font(.system(size: 13))
        .scrollContentBackground(.hidden)
        .padding(8)
        .card(8)
        .frame(minHeight: 180)
        .overlay(alignment: .topLeading) {
          if text.isEmpty { Text("详细内容（可空）").foregroundStyle(.tertiary).padding(.horizontal, 14).padding(.vertical, 9).allowsHitTesting(false) }
        }
      if let error { Text(error).font(.callout).foregroundStyle(.red) }
      HStack {
        Spacer()
        Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
        Button(busy ? "提交中…" : "补写") { Task { await save() } }
          .keyboardShortcut(.defaultAction)
          .disabled(busy || trimmed.isEmpty || trimmed.count > 200 || (hasEnd && end < start))
      }
    }
    .padding(22)
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
