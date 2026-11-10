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
      VStack(alignment: .leading, spacing: 32) {
        if !items.isEmpty {
          Text("这些是需要你确认的事。不处理也没关系，记录和整理照常进行。")
            .font(.system(size: TextSize.body)).foregroundStyle(Palette.muted)
        }
        if items.isEmpty, let error = store.sharedError {
          Placeholder(kind: .error(error) { Task { await store.refreshShared() } })
            .transition(.opacity)
        } else if let error = store.sharedError {
          // 刷新失败时下面是上一次读到的列表，可能已经过时。
          HStack(spacing: 8) {
            PhIcon("warning", size: 14).foregroundStyle(Palette.attention)
            Text("连不上后台服务，下面是上次读到的内容。").help(error)
            Button("重试") { Task { await store.refreshShared() } }.buttonStyle(.link)
          }
          .font(.system(size: TextSize.body)).foregroundStyle(Palette.muted)
        } else if items.isEmpty {
          VStack(spacing: 12) {
            PhIcon("check-circle", size: 32).foregroundStyle(Palette.faint)
            Text("没有要确认的事").font(.system(size: TextSize.body)).foregroundStyle(Palette.muted)
          }
          .frame(maxWidth: .infinity).padding(.vertical, 80)
          .transition(.opacity)
        }
        ForEach(groups, id: \.kind) { g in
          VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
              PhIcon(g.symbol, size: 14).foregroundStyle(Palette.muted)
              Text(g.title).sectionTitle()
              Text("\(g.items.count)").font(.system(size: TextSize.caption)).monospacedDigit().foregroundStyle(Palette.muted)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 340, maximum: 560), spacing: 16, alignment: .top)], alignment: .leading, spacing: 16) {
              ForEach(g.items) { item in
                PendingCard(item: item) { withAnimation(.easeOut(duration: 0.2)) { _ = resolved.insert(item.id) }; Task { await store.refreshShared() } }
                  .transition(.opacity)
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
    [("voice", "这是谁的声音", "waveform"), ("project", "新项目", "folder-dashed"), ("thread_done", "这件事做完了吗", "flag-checkered"),
     ("merge", "是同一个项目吗", "git-merge")]
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
      if let error { Text(error).font(.system(size: TextSize.caption)).foregroundStyle(Palette.attention) }
      Spacer(minLength: 0)
      actions
        .disabled(busy)
        .padding(.top, 4)
    }
    .padding(16)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .card()
    .popover(isPresented: $renaming, arrowEdge: .bottom) {
      VStack(alignment: .leading, spacing: 12) {
        Text(item.kind == "voice" ? "这是谁？" : "项目叫什么？").font(.system(size: TextSize.body, weight: .semibold))
        TextField(item.kind == "voice" ? "名字" : "项目名", text: $name).textFieldStyle(.roundedBorder).frame(width: 220)
          .onSubmit(submitName)
        HStack { Spacer(); Button("好", action: submitName).buttonStyle(.accent).keyboardShortcut(.defaultAction).disabled(name.trimmingCharacters(in: .whitespaces).isEmpty) }
      }
      .padding(16)
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
      // conversations：这个声音出现过的对话数；seconds：它在这些对话里一共说了多久。
      HStack(alignment: .firstTextBaseline) {
        Text(p.label ?? "新的声音").font(.serif(TextSize.title, .semibold)).foregroundStyle(Palette.ink)
        Spacer()
        Text("\(p.conversations ?? 0) 段对话里说了 \(Fmt.duration(p.seconds ?? 0))")
          .font(.system(size: TextSize.caption)).monospacedDigit().foregroundStyle(Palette.muted)
      }
      VStack(spacing: 4) {
        ForEach(p.samples ?? [], id: \.id) { s in SamplePlayer(sample: s) }
        if p.samplesPending == true || (p.samples ?? []).isEmpty {
          Text("试听片段还在路上，录到它的设备连上后就能听。").font(.system(size: TextSize.caption)).foregroundStyle(Palette.muted)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
      }
    case "project":
      HStack(spacing: 8) {
        PhIcon("folder-dashed", size: 16).foregroundStyle(Palette.muted)
        Text(p.name ?? "未命名项目").font(.serif(TextSize.title, .semibold)).foregroundStyle(Palette.ink)
      }
      VStack(alignment: .leading, spacing: 4) {
        ForEach(basis, id: \.1) { symbol, text in
          Label { Text(text).lineLimit(1).truncationMode(.middle) } icon: { PhIcon(symbol, size: 14).foregroundStyle(Palette.muted) }
            .font(.system(size: TextSize.body)).foregroundStyle(Palette.muted)
        }
      }
    case "thread_done":
      if let t = p.threadId {
        Button { store.path.append(.thread(t)) } label: {
          Text(p.title ?? "").font(.serif(TextSize.title, .semibold)).foregroundStyle(Palette.ink)
            .multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
        }
        .buttonStyle(.plain).help("打开这件事项")
      } else {
        Text(p.title ?? "").font(.serif(TextSize.title, .semibold)).foregroundStyle(Palette.ink).fixedSize(horizontal: false, vertical: true)
      }
      if let b = p.brief {
        Text(b).font(.system(size: TextSize.body)).foregroundStyle(Palette.muted).lineSpacing(TextSize.lineSpacing(TextSize.body))
          .fixedSize(horizontal: false, vertical: true)
      }
    default:
      HStack(spacing: 10) {
        projectName(p.aName)
        PhIcon("arrows-left-right", size: 17).foregroundStyle(.tertiary)
        projectName(p.bName)
      }
      if let r = p.reason { Text(r).font(.system(size: TextSize.body)).foregroundStyle(Palette.muted).fixedSize(horizontal: false, vertical: true) }
    }
  }

  func projectName(_ n: String?) -> some View {
    HStack(spacing: 8) {
      PhIcon("folder", size: 16).foregroundStyle(Palette.muted)
      Text(n ?? "?").font(.serif(TextSize.title, .semibold)).foregroundStyle(Palette.ink)
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
        Button("是我") { resolve("me") }.buttonStyle(.accent)
        Button("填名字…") { name = ""; renaming = true }.help("这是别人，填上他的名字")
        let others = store.speakers.filter { $0.id != p.speakerId }
        let known = others.filter { $0.confirmed.value }
        let unknown = others.filter { !$0.confirmed.value }
        if !others.isEmpty {
          // 把这个声音并到一个已有的人身上（hub merge_into）。
          Menu("其实是…") {
            ForEach(known) { s in Button(s.display) { resolve("merge_into", target: s.id) } }
            if !unknown.isEmpty {
              Section("还没确认的声音") { ForEach(unknown) { s in Button(s.display) { resolve("merge_into", target: s.id) } } }
            }
          }
          .fixedSize()
          .help("这个声音和已有的某个人是同一个人")
        }
        Spacer()
        Button("忽略") { resolve("ignore") }.buttonStyle(.borderless).foregroundStyle(Palette.muted).help("以后不再问这个声音")
      case "project":
        Button("是个项目") { resolve("confirm") }.buttonStyle(.accent)
        Button("改名…") { name = p.name ?? ""; renaming = true }
        let others = store.projects.filter { $0.id != p.projectId }
        if !others.isEmpty {
          Menu("并入已有项目") { ForEach(others) { o in Button(o.name) { resolve("merge_into", target: o.id) } } }.fixedSize()
        }
        Spacer()
        Button("不是项目") { resolve("ignore") }.buttonStyle(.borderless).foregroundStyle(Palette.muted)
      case "thread_done":
        Button("做完了") { resolve("done") }.buttonStyle(.accent)
        Button("还在做") { resolve("continue") }
        Spacer()
        if let n = PendingArchive.notice(createdAt: item.createdAt) {
          Text(n).font(.system(size: TextSize.caption)).foregroundStyle(Palette.muted)
            .help("一直不回答，这件事项会自动归档：不再问你，也不再带给 AI 工具，但仍能找到")
        }
        Button("不做了") { resolve("abandon") }.buttonStyle(.borderless).foregroundStyle(Palette.muted)
      default:
        Button("合并") { resolve("merge") }.buttonStyle(.accent)
        Spacer()
        Button("保持分开") { resolve("keep") }.buttonStyle(.borderless).foregroundStyle(Palette.muted)
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

/// 试听样本：取回 WAV，画出真实波形，播放时进度扫过波形。卡片里不再套底色框。
struct SamplePlayer: View {
  let sample: PendingItem.Sample
  @Environment(ViewerStore.self) private var store
  @State private var peaks: [Float] = []
  @State private var sound: NSSound?
  @State private var data: Data?
  @State private var playing = false
  @State private var error: String?

  var body: some View {
    HStack(spacing: 12) {
      Button { Task { await toggle() } } label: {
        PhIcon(playing ? "pause" : "play", fill: true, size: 12)
          .frame(width: 28, height: 28)
          .foregroundStyle(Palette.onAccent)
          .background(Palette.accent, in: Circle())
      }
      .buttonStyle(.plain)
      .help(playing ? "暂停" : "试听")
      .accessibilityLabel(playing ? "暂停" : "试听")
      TimelineView(.animation(paused: !playing)) { _ in
        let progress = sound.map { $0.duration > 0 ? $0.currentTime / $0.duration : 0 } ?? 0
        WaveformShape(peaks: peaks.isEmpty ? Array(repeating: 0.15, count: 64) : peaks)
          .fill(Palette.faint)
          .overlay {
            GeometryReader { g in
              WaveformShape(peaks: peaks.isEmpty ? Array(repeating: 0.15, count: 64) : peaks)
                .fill(Palette.accent)
                .mask(alignment: .leading) { Rectangle().frame(width: g.size.width * progress) }
            }
          }
      }
      .frame(height: 24)
      if let error { Text(error).font(.system(size: TextSize.caption)).foregroundStyle(Palette.attention).fixedSize() }
    }
    .padding(.vertical, 4)
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
    } catch { self.error = "取不到片段" }
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
