import AppKit
import SwiftUI
import CollectorCore

struct PendingPage: View {
  @Environment(ViewerStore.self) private var store
  @State private var resolved: Set<String> = []
  @State private var loading = false

  var items: [PendingItem] { store.pending.filter { !resolved.contains($0.id) } }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 34) {
        Text("系统先自己判断、先往下处理；这里攒着需要你拍板的事，不处理也不会卡住。")
          .font(.serif(15)).foregroundStyle(.secondary)
        if items.isEmpty, let error = store.sharedError {
          Placeholder(kind: .error(error) { Task { await store.refreshShared() } })
            .transition(.opacity)
        } else if let error = store.sharedError {
          // 刷新失败时下面是上一次读到的列表，可能已经过时。
          HStack(spacing: 8) {
            PhIcon("warning", fill: true, size: 14).foregroundStyle(.orange)
            Text("连不上中枢，下面是上次读到的内容：\(error)").lineLimit(2).textSelection(.enabled)
            Button("重试") { Task { await store.refreshShared() } }.buttonStyle(.link)
          }
          .font(.callout).foregroundStyle(.secondary)
        } else if items.isEmpty {
          VStack(spacing: 14) {
            PhIcon("check-circle", size: 50).foregroundStyle(Palette.factColors["decision"]!)
            Text("都处理完了").font(.serif(18)).foregroundStyle(.secondary)
          }
          .frame(maxWidth: .infinity).padding(.vertical, 80)
          .transition(.opacity)
        }
        ForEach(groups, id: \.kind) { g in
          VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
              PhIcon(g.symbol, size: 15).foregroundStyle(.secondary)
              Text(g.title).sectionTitle()
              Text("\(g.items.count)").font(.caption).foregroundStyle(.tertiary)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 340, maximum: 560), spacing: 14, alignment: .top)], alignment: .leading, spacing: 14) {
              ForEach(g.items) { item in
                PendingCard(item: item) { withAnimation(.smooth(duration: 0.35)) { _ = resolved.insert(item.id) }; Task { await store.refreshShared() } }
                  .transition(.asymmetric(insertion: .opacity, removal: .scale(scale: 0.92).combined(with: .opacity)))
              }
            }
          }
        }
      }
      .frame(maxWidth: 1080, alignment: .leading)
      .padding(.horizontal, 40).padding(.vertical, 32)
      .frame(maxWidth: .infinity)
    }
    .background(Palette.paper)
    .navigationTitle("待确认")
    .toolbar {
      ToolbarItem(placement: .primaryAction) {
        Button { Task { loading = true; await store.refreshShared(); resolved = []; loading = false } } label: { PhIcon("arrow-clockwise", size: PhIcon.toolbar) }
          .disabled(loading).help("刷新").accessibilityLabel("刷新")
      }
    }
    .task { await store.refreshShared() }
  }

  var groups: [(kind: String, title: String, symbol: String, items: [PendingItem])] {
    [("voice", "新声音", "waveform"), ("project", "新项目", "folder-dashed"), ("thread_done", "做完了吗", "flag-checkered"),
     ("merge", "合并建议", "git-merge")]
      .map { g in (g.0, g.1, g.2, items.filter { $0.kind == g.0 }) }
      .filter { !$0.3.isEmpty }
  }
}

struct PendingCard: View {
  let item: PendingItem
  let onResolved: () -> Void
  @Environment(ViewerStore.self) private var store
  @State private var busy = false
  @State private var error: String?
  @State private var renaming = false
  @State private var name = ""

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      content
      if let error { Text(error).font(.caption).foregroundStyle(.red) }
      Divider().opacity(0.6)
      actions
        .disabled(busy)
    }
    .padding(18)
    .frame(maxWidth: .infinity, alignment: .topLeading)
    .card(14)
    .popover(isPresented: $renaming, arrowEdge: .bottom) {
      VStack(alignment: .leading, spacing: 10) {
        Text(item.kind == "voice" ? "这是谁？" : "项目名").font(.headline)
        TextField(item.kind == "voice" ? "名字" : "项目名", text: $name).textFieldStyle(.roundedBorder).frame(width: 220)
          .onSubmit(submitName)
        HStack { Spacer(); Button("确定", action: submitName).keyboardShortcut(.defaultAction).disabled(name.trimmingCharacters(in: .whitespaces).isEmpty) }
      }
      .padding(14)
    }
  }

  func submitName() {
    let n = name.trimmingCharacters(in: .whitespaces)
    guard !n.isEmpty else { return }
    renaming = false
    resolve("rename", name: n)
  }

  @ViewBuilder var content: some View {
    let p = item.payload
    switch item.kind {
    case "voice":
      HStack(alignment: .firstTextBaseline) {
        Text(p.label ?? "新声音").font(.serif(19, .semibold))
        Spacer()
        Text("\(p.conversations ?? 0) 段对话 · \(ViewerFormat.duration(p.seconds ?? 0))").font(.caption).foregroundStyle(.secondary)
      }
      VStack(spacing: 8) {
        ForEach(Array((p.samples ?? []).enumerated()), id: \.element.id) { i, s in SamplePlayer(sample: s, index: i + 1) }
        if p.samplesPending == true || (p.samples ?? []).isEmpty {
          Label { Text("样本待取：录到它的设备上线后会送来") } icon: { PhIcon("hourglass", size: 11) }.font(.caption).foregroundStyle(.secondary)
        }
      }
    case "project":
      HStack(spacing: 8) {
        RoundedRectangle(cornerRadius: 4).fill(Palette.tag(p.name ?? "").gradient).frame(width: 16, height: 16)
        Text(p.name ?? "未命名项目").font(.serif(19, .semibold))
      }
      VStack(alignment: .leading, spacing: 5) {
        ForEach(basis, id: \.1) { symbol, text in
          Label { Text(text).lineLimit(1).truncationMode(.middle) } icon: { PhIcon(symbol, size: 15).foregroundStyle(.tertiary) }
            .font(.system(size: 12)).foregroundStyle(.secondary)
        }
      }
    case "thread_done":
      Text(p.title ?? "").font(.serif(18, .semibold)).fixedSize(horizontal: false, vertical: true)
      if let b = p.brief { Text(b).font(.system(size: 12.5)).foregroundStyle(.secondary).lineSpacing(2).fixedSize(horizontal: false, vertical: true) }
      HStack(spacing: 10) {
        if let t = p.threadId {
          Button("查看线程") { store.path.append(.thread(t)) }.buttonStyle(.link).font(.caption)
        }
        Spacer()
        if let n = PendingArchive.notice(createdAt: item.createdAt) { Text(n).font(.caption).foregroundStyle(.tertiary) }
      }
    default:
      HStack(spacing: 10) {
        projectName(p.aName)
        PhIcon("arrows-left-right", size: 17).foregroundStyle(.tertiary)
        projectName(p.bName)
      }
      if let r = p.reason { Text(r).font(.system(size: 12.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
    }
  }

  func projectName(_ n: String?) -> some View {
    HStack(spacing: 6) {
      Circle().fill(Palette.tag(n ?? "")).frame(width: 8, height: 8)
      Text(n ?? "?").font(.serif(17, .semibold))
    }
  }

  var basis: [(String, String)] {
    let p = item.payload
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    return (p.keys?.repos ?? []).prefix(4).map { ("folder", $0.replacingOccurrences(of: home, with: "~")) }
      + (p.keys?.hosts ?? []).prefix(4).map { ("globe", $0) }
      + (p.keys?.chats ?? []).prefix(3).map { ("chat-circle", $0) }
      + (p.threads ?? []).prefix(4).map { ("list-bullets", $0.title) }
  }

  @ViewBuilder var actions: some View {
    let p = item.payload
    HStack(spacing: 8) {
      switch item.kind {
      case "voice":
        Button("就是我") { resolve("me") }.buttonStyle(.borderedProminent)
        Button("填名字") { name = ""; renaming = true }
        let others = store.speakers.filter { $0.id != p.speakerId }
        if !others.isEmpty {
          Menu("同一人") { ForEach(others) { s in Button(s.display) { resolve("merge_into", target: s.id) } } }.fixedSize()
        }
        Spacer()
        Button("忽略") { resolve("ignore") }.buttonStyle(.borderless).foregroundStyle(.secondary)
      case "project":
        Button("是个项目") { resolve("confirm") }.buttonStyle(.borderedProminent)
        Button("改名") { name = p.name ?? ""; renaming = true }
        let others = store.projects.filter { $0.id != p.projectId }
        if !others.isEmpty {
          Menu("并入") { ForEach(others) { o in Button(o.name) { resolve("merge_into", target: o.id) } } }.fixedSize()
        }
        Spacer()
        Button("不是项目") { resolve("ignore") }.buttonStyle(.borderless).foregroundStyle(.secondary)
      case "thread_done":
        Button("完成了") { resolve("done") }.buttonStyle(.borderedProminent)
        Button("还在做") { resolve("continue") }
        Spacer()
        Button("不做了") { resolve("abandon") }.buttonStyle(.borderless).foregroundStyle(.secondary)
      default:
        Button("合并") { resolve("merge") }.buttonStyle(.borderedProminent)
        Spacer()
        Button("保持分开") { resolve("keep") }.buttonStyle(.borderless).foregroundStyle(.secondary)
      }
      if busy { ProgressView().controlSize(.small) }
    }
    .controlSize(.regular)
  }

  func resolve(_ action: String, name: String? = nil, target: String? = nil) {
    Task {
      busy = true; error = nil
      defer { busy = false }
      do { try await store.api.resolve(item.id, action: action, name: name, target: target); onResolved() }
      catch { self.error = error.localizedDescription }
    }
  }
}

/// 试听样本：取回 WAV，画出真实波形，播放时进度扫过波形。
struct SamplePlayer: View {
  let sample: PendingItem.Sample
  let index: Int
  @Environment(ViewerStore.self) private var store
  @State private var peaks: [Float] = []
  @State private var sound: NSSound?
  @State private var data: Data?
  @State private var playing = false
  @State private var error: String?

  var body: some View {
    HStack(spacing: 10) {
      Button { Task { await toggle() } } label: {
        PhIcon(playing ? "pause" : "play", fill: true, size: 12)
          .frame(width: 28, height: 28)
          .foregroundStyle(.white)
          .background(Palette.source("mac.audio").gradient, in: Circle())
      }
      .buttonStyle(.plain)
      TimelineView(.animation(paused: !playing)) { _ in
        let progress = sound.map { $0.duration > 0 ? $0.currentTime / $0.duration : 0 } ?? 0
        WaveformShape(peaks: peaks.isEmpty ? Array(repeating: 0.15, count: 64) : peaks)
          .fill(Color.primary.opacity(0.18))
          .overlay {
            GeometryReader { g in
              WaveformShape(peaks: peaks.isEmpty ? Array(repeating: 0.15, count: 64) : peaks)
                .fill(Palette.source("mac.audio"))
                .mask(alignment: .leading) { Rectangle().frame(width: g.size.width * progress) }
            }
          }
      }
      .frame(height: 26)
      Text(error ?? "样本 \(index)").font(.system(size: 10.5)).foregroundStyle(.secondary).frame(width: 46, alignment: .trailing)
    }
    .padding(8)
    .background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
    .task { await fetch() }
    .onDisappear { sound?.stop(); sound = nil }
  }

  func fetch() async {
    guard data == nil else { return }
    do {
      let d = try await store.api.sample(sample.id)
      data = d
      peaks = Waveform.peaks(wav: d, buckets: 64)
    } catch is CancellationError {
    } catch { self.error = "取不到" }
  }

  func toggle() async {
    if playing { sound?.pause(); playing = false; return }
    if data == nil { await fetch() }
    guard let data else { return }
    if sound == nil || sound!.currentTime >= sound!.duration - 0.05 { sound = NSSound(data: data) }
    guard let s = sound, s.resume() || s.play() else { error = "播放失败"; return }
    playing = true
    while playing, s.isPlaying { try? await Task.sleep(for: .milliseconds(150)) }
    playing = false
  }
}

struct WaveformShape: Shape {
  let peaks: [Float]
  func path(in rect: CGRect) -> Path {
    var p = Path()
    guard !peaks.isEmpty else { return p }
    let step = rect.width / CGFloat(peaks.count)
    let bar = max(1.5, step * 0.55)
    for (i, v) in peaks.enumerated() {
      let h = max(2, rect.height * CGFloat(v))
      p.addRoundedRect(in: CGRect(x: CGFloat(i) * step + (step - bar) / 2, y: rect.midY - h / 2, width: bar, height: h),
                       cornerSize: CGSize(width: bar / 2, height: bar / 2))
    }
    return p
  }
}
