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
      let d = try await store.dataSource.record(id)
      // 读不到整场对话时退回显示这条记录的原文，不报错。
      conversation = AudioSource.isAudio(d.record.source) ? try? await store.dataSource.conversation(id) : nil
      withAnimation(detail == nil ? Motion.standard : nil) { detail = d; error = nil }
    }
    catch is CancellationError {}
    catch { let message = UserFacingError.message(for: error, fallback: L10n.Settings.settingsRequestFailed); Motion.animate { self.error = message } }
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
            Text(L10n.correctedAt(cur.start))
            Spacer()
            Button(showOriginal ? L10n.hideOriginal : L10n.showOriginal) { Motion.animate { showOriginal.toggle() } }.buttonStyle(.accentLink)
          }
          .font(.system(size: TextSize.body))
          .foregroundStyle(Palette.muted)
        }
        if let c = conversation { ConversationBody(conversation: c) }
        else { RecordBodyText(text: cur.body ?? "", source: r.source) }
        if showOriginal, cur.id != r.id {
          VStack(alignment: .leading, spacing: 8) {
            Text(L10n.original).sectionTitle()
            RecordBodyText(text: r.body ?? "", source: r.source)
          }
          .transition(.reveal)
        }
        contextGrid(r)
      }
      .modifier(ReviewWidth())
    }
    .background(Palette.paper)
  }

  func header(_ d: RecordDetail) -> some View {
    let r = d.record
    let time = conversation.flatMap(conversationTime) ?? metadataTime(r.start, r.isSpan ? r.end : nil)
    return VStack(alignment: .leading, spacing: 8) {
      Text(conversation.map { $0.title ?? SourceInfo.name(r.source) } ?? RecordText.title(r, appShown: false)).font(.serif(TextSize.title, .semibold)).foregroundStyle(Palette.ink)
        .fixedSize(horizontal: false, vertical: true).textSelection(.enabled).accessibilityAddTraits(.isHeader)
      HStack(spacing: 8) {
        SourceGlyph(source: r.source, app: r.contextText("app"), size: 20).accessibilityHidden(true)
        Text("\(SourceInfo.name(r.source)) · \(time)")
          .font(.system(size: TextSize.caption)).monospacedDigit().foregroundStyle(Palette.muted)
      }
      actions(d)
    }
  }

  func metadataTime(_ start: Date, _ end: Date?) -> String {
    let sameDay = end.map { Calendar.current.isDate(start, inSameDayAs: $0) } ?? true
    var time = "\(Fmt.date(start)) \(Fmt.range(start, sameDay ? end : nil))"
    if let end {
      if !sameDay { time += "–\(Fmt.date(end)) \(ViewerFormat.clock(end))" }
      let seconds = end.timeIntervalSince(start)
      if seconds >= 1 { time += " · \(Fmt.duration(seconds))" }
    }
    return time
  }

  func conversationTime(_ c: ConversationDetail) -> String? {
    guard let start = ViewerTime.parse(c.start), let end = ViewerTime.parse(c.end) else { return nil }
    return metadataTime(start, end)
  }

  @ViewBuilder func contextGrid(_ r: HistoryRecord) -> some View {
    let rows = contextRows(r)
    if !rows.isEmpty {
      VStack(alignment: .leading, spacing: 8) {
        Text(L10n.recordingContext).sectionTitle()
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 8) {
          ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
            let (key, label, value) = row
            GridRow {
              Text(label).font(.system(size: TextSize.caption)).foregroundStyle(Palette.muted)
                .fixedSize().gridColumnAlignment(.leading)
              if key == "url", let url = URL(string: value), ["http", "https"].contains(url.scheme ?? "") {
                Link(destination: url) {
                  Text(value).multilineTextAlignment(.leading).foregroundStyle(Palette.accent)
                }.lineLimit(3)
              } else if ["repo", "cwd", "dir", "path"].contains(key) {
                Button { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: (value as NSString).expandingTildeInPath) } label: {
                  Text(value).font(.mono(TextSize.body)).foregroundStyle(Palette.readingBody).multilineTextAlignment(.leading)
                }
                .buttonStyle(.plain).help(L10n.showInFinder)
              } else {
                Text(value).foregroundStyle(Palette.readingBody).textSelection(.enabled).lineLimit(4)
              }
            }
          }
        }
        .font(.system(size: TextSize.body))
      }
    }
  }

  func contextRows(_ r: HistoryRecord) -> [(key: String, label: String, value: String)] {
    var rows: [(key: String, label: String, value: String)] = []
    let app = r.contextText("app")
    if let name = AppIcons.name(app) { rows.append(("app", L10n.app, name)) }
    for (key, label) in [("window", L10n.window), ("url", L10n.url), ("repo", L10n.repository), ("cwd", L10n.folder), ("chat", L10n.conversation), ("place", L10n.location)] {
      if let v = r.contextText(key) {
        let shown = key == "repo" || key == "cwd" ? (v as NSString).abbreviatingWithTildeInPath : v
        if key == "cwd", rows.contains(where: { $0.value == shown }) { continue }
        rows.append((key, label, shown))
      }
    }
    if case .object(let extra)? = r.context?["extra"] {
      let names = ["hash": L10n.commit, "files": L10n.fileCount, "added": L10n.linesAdded, "deleted": L10n.linesDeleted, "author": L10n.author, "from_url": L10n.downloadSource,
                   "size": L10n.size, "dir": L10n.folder, "profile": L10n.browserProfile, "exit": L10n.exitCode, "duration_ms": L10n.duration, "location": L10n.location,
                   "attendees": L10n.attendees, "calendar": L10n.calendar]
      for (k, v) in extra.sorted(by: { $0.key < $1.key }) {
        guard let label = names[k], var text = v.text else { continue }
        if k == "hash" { text = String(text.prefix(10)) }
        if k == "size", let n = Int(text) { if n == 0 { continue }; text = ViewerFormat.bytes(n) }
        if k == "duration_ms", let n = Double(text) { text = Fmt.duration(n / 1000) }
        rows.append((k, label, text))
      }
    }
    var capture = r.capture?.method ?? ""
    capture = ["ax": L10n.windowText, "ocr": L10n.screenText, "db": L10n.databaseRead, "api": L10n.systemAPI, "file": L10n.fileRead, "hook": L10n.terminalHook, "asr": L10n.speechToText, "manual": L10n.note][capture] ?? capture
    // confidence 是采集端给的识别置信度（OCR、转写），0–1。
    if let c = r.capture?.confidence { capture += L10n.comma + L10n.captureConfidence(Int((c * 100).rounded())) }
    if !capture.isEmpty { rows.append(("capture", L10n.captureMethod, capture)) }
    rows.append(("device", L10n.device, r.device))
    if let n = r.redactions, n > 0 { rows.append(("redactions", L10n.redactedSecrets, L10n.redactionCount(n))) }
    return rows
  }

  func actions(_ d: RecordDetail) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 16) {
        Button { correcting = true } label: { Label { Text(L10n.correct) } icon: { PhIcon("pencil-simple", size: TextSize.body) } }
        Button {
          NSPasteboard.general.clearContents()
          let original = conversation.flatMap(ConversationBody.originalTranscript) ?? d.current.body ?? d.record.title
          NSPasteboard.general.setString(original, forType: .string)
          withAnimation(Motion.quick) { copied = true }
          copyReset?.cancel()
          copyReset = Task {
            try? await Task.sleep(for: .seconds(1.5))
            if !Task.isCancelled { withAnimation(Motion.quick) { copied = false } }
          }
        } label: {
          Label { Text(copied ? L10n.copied : L10n.copy) } icon: {
            PhIcon(copied ? "check" : "copy", size: TextSize.body).id(copied).transition(.opacity)
          }
        }
        Spacer()
        Button(L10n.delete) { confirmDelete = true }
          .buttonStyle(RecordActionStyle(attention: true))
          .disabled(busy)
      }
      .buttonStyle(RecordActionStyle())
      if let deleteError {
        Text(deleteError).font(.system(size: TextSize.caption)).foregroundStyle(Palette.attention).textSelection(.enabled)
          .transition(.notice)
      }
    }
    .animation(Motion.standard, value: deleteError)
    .controlSize(.small)
    .confirmationDialog(L10n.deleteThisRecord, isPresented: $confirmDelete) {
      Button(L10n.delete, role: .destructive) { Task { await delete(d) } }
      Button(L10n.cancel, role: .cancel) {}
    } message: {
      Text(L10n.recordDeletionExplanation)
    }
  }

  func delete(_ d: RecordDetail) async {
    busy = true; deleteError = nil; defer { busy = false }
    do {
      try await store.api.deleteRecord(d.record.id)
      onDelete([d.record.id] + d.corrections.map(\.id))
      store.revision += 1
    } catch { deleteError = UserFacingError.message(for: error, fallback: L10n.Settings.settingsRequestFailed) }
  }
}

private struct RecordActionStyle: ButtonStyle {
  var attention = false
  @Environment(\.isEnabled) private var enabled
  @State private var hovering = false

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(.system(size: TextSize.body))
      .foregroundStyle(attention ? Palette.attention : hovering ? Palette.ink : Palette.muted)
      .opacity(!enabled ? 0.5 : configuration.isPressed ? 0.7 : 1)
      .pressFeedback(configuration.isPressed)
      .frame(minHeight: 24)
      .contentShape(Rectangle())
      .hoverState($hovering)
  }
}

private struct RecordBodyText: View {
  let text: String
  let source: String
  @State private var showAll = false

  var body: some View {
    if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      Text(L10n.thisRecordHasNoText).font(.system(size: TextSize.body)).foregroundStyle(Palette.muted)
    } else {
      let transcript = AudioSource.isAudio(source) || AgentTools.session(source: source) != nil
      let lines = RecordReadingLines.display(transcript ? L10n.transcript(text) : text, source: source)
      let previewLimit = 40
      VStack(alignment: .leading, spacing: 8) {
        Text(showAll ? lines.joined(separator: "\n") : lines.prefix(previewLimit).joined(separator: "\n"))
          .recordReadingStyle()
        if lines.count > previewLimit {
          Button(showAll ? L10n.collapse : L10n.showAll) { showAll.toggle() }
            .buttonStyle(.accentLink).font(.system(size: TextSize.body))
        }
      }
    }
  }
}

private extension SwiftUI.Text {
  func recordReadingStyle() -> some View {
    font(.system(size: TextSize.body))
      .foregroundStyle(Palette.readingBody)
      .lineSpacing(TextSize.lineSpacing(TextSize.body))
      .textSelection(.enabled)
      .fixedSize(horizontal: false, vertical: true)
      .frame(maxWidth: .infinity, alignment: .leading)
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
      Text(L10n.correctThisRecord).font(.system(size: TextSize.title, weight: .semibold))
      Text(L10n.recordCorrectionExplanation).font(.system(size: TextSize.body)).foregroundStyle(Palette.muted)
      TextEditor(text: $text)
        .font(.system(size: TextSize.body))
        .scrollContentBackground(.hidden)
        .padding(8)
        .card(Radius.control)
        .frame(minHeight: 260)
      if let error { Text(error).font(.system(size: TextSize.body)).foregroundStyle(Palette.attention) }
      HStack {
        Spacer()
        Button(L10n.cancel) { dismiss() }.keyboardShortcut(.cancelAction)
        Button(busy ? L10n.correcting : L10n.correct) { Task { await save() } }
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
    catch { self.error = UserFacingError.message(for: error, fallback: L10n.Settings.settingsRequestFailed) }
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
      Text(L10n.addANote).font(.system(size: TextSize.title, weight: .semibold))
      Form {
        DatePicker(L10n.start, selection: $start, in: ...Date())
        Toggle(L10n.setAnEndTime, isOn: $hasEnd.animation(Motion.standard))
        if hasEnd { DatePicker(L10n.end, selection: $end, in: start...) }
        TextField(L10n.title, text: $title, prompt: Text(L10n.whatDidYouDo))
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
            Text(L10n.addMoreDetailHere).font(.system(size: TextSize.body)).foregroundStyle(Palette.muted)
              .padding(.horizontal, 13).padding(.vertical, 8).allowsHitTesting(false)
          }
        }
      if let error { Text(error).font(.system(size: TextSize.body)).foregroundStyle(Palette.attention) }
      HStack {
        Spacer()
        Button(L10n.cancel) { dismiss() }.keyboardShortcut(.cancelAction)
        Button(busy ? L10n.saving : L10n.save) { Task { await save() } }
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
    catch { self.error = UserFacingError.message(for: error, fallback: L10n.Settings.settingsRequestFailed) }
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
        Text(L10n.noReadableTranscript).font(.system(size: TextSize.body)).foregroundStyle(Palette.muted)
      } else {
        VStack(alignment: .leading, spacing: 12) {
          Text(L10n.conversationContent).sectionTitle()
          let shown = showAll ? c.turns : Array(c.turns.prefix(80))
          ForEach(Array(shown.enumerated()), id: \.offset) { _, t in turn(t) }
          if c.turns.count > 80 {
            Button(showAll ? L10n.collapse : L10n.showTurns(c.turns.count)) { showAll.toggle() }.buttonStyle(.accentLink).font(.system(size: TextSize.body))
          }
        }
      }
      if let original = Self.originalTranscript(c) {
        VStack(alignment: .leading, spacing: 8) {
          Button(showRaw ? L10n.hideOriginalTranscript : L10n.showOriginalTranscript) { Motion.animate { showRaw.toggle() } }
            .buttonStyle(.accentLink).font(.system(size: TextSize.body))
          if showRaw {
            Text(L10n.transcript(original)).recordReadingStyle().transition(.reveal)
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
          Text(s).recordReadingStyle()
        }
        ForEach(c.points, id: \.self) { p in
          HStack(alignment: .firstTextBaseline, spacing: 8) {
            Circle().fill(Palette.faint).frame(width: 4, height: 4).alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
            Text(p).recordReadingStyle()
          }
        }
      }
    case "waiting": Text(L10n.theSummaryWillAppearLater).font(.system(size: TextSize.body)).foregroundStyle(Palette.muted)
    case "private": Text(L10n.privateConversation).font(.system(size: TextSize.body)).foregroundStyle(Palette.muted)
    default: EmptyView()
    }
  }

  static func originalTranscript(_ conversation: ConversationDetail) -> String? {
    guard let records = conversation.records, !records.isEmpty else { return nil }
    return records.map(\.body).joined(separator: "\n")
  }

  func turn(_ t: ConversationDetail.Turn) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      HStack(alignment: .firstTextBaseline, spacing: 8) {
        Text(L10n.speaker(t.speaker)).font(.system(size: TextSize.body, weight: .semibold)).foregroundStyle(Palette.ink)
        if let d = ViewerTime.parse(t.at) { Text(ViewerFormat.clock(d)).font(.system(size: TextSize.caption)).monospacedDigit().foregroundStyle(Palette.muted) }
      }
      Text(t.text).recordReadingStyle()
    }
  }

}
