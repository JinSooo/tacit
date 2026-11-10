import AppKit
import SwiftUI
import CollectorCore

/// 数据源：左边列表，右边详情（AGENTS.md 2026-11-10：不平铺）。
struct SourcesSettingsView: View {
  @Environment(ViewerStore.self) private var store
  @AppStorage("settings.source") private var selected = "screen"

  var body: some View {
    let sources = store.capture.sources
    HStack(spacing: 0) {
      List(selection: Binding(get: { selected }, set: { if let s = $0 { selected = s } })) {
        ForEach(sources) { s in
          HStack(spacing: 8) {
            Circle().fill(SourceDetail.dot(s)).frame(width: 7, height: 7)
            Text(s.title).foregroundStyle(s.enabled ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
          }
          .tag(s.id)
        }
      }
      .listStyle(.sidebar)
      .scrollContentBackground(.hidden)
      .frame(width: 190)
      Divider()
      if let s = sources.first(where: { $0.id == selected }) ?? sources.first {
        SourceDetail(source: s).id(s.id)
      } else {
        ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
      }
    }
  }
}

struct SourceDetail: View {
  @Environment(ViewerStore.self) private var store
  let source: DataSourceStatus

  static func dot(_ s: DataSourceStatus) -> Color {
    if !s.enabled { return .secondary.opacity(0.4) }
    return s.ok && !s.needsPermission ? .green : .orange
  }

  /// 每个数据源读什么、不读什么。
  static let summaries: [String: String] = [
    "screen": "前台窗口的应用、标题、网址，以及窗口里新出现的文字。只读当前在用的窗口。",
    "ocr": "屏幕文字读不到正文的应用（例如微信、Zed），在本机截图识别文字。截图只在内存里，识别完就丢。",
    "clipboard": "复制的文字。密码管理器复制的内容跳过；复制图片只记一条“复制了图片”。",
    "audio": "麦克风和系统声音。有你说话的对话在本机转写成文字；原始音频加密存在本机，到保留天数自动删除。",
    "files": "下面这些目录里新出现的文件，只记文件名、路径和下载来源，不读文件内容。",
    "calendar": "已经结束的日程：标题、地点和参会人。录音也靠它判断这段时间是否在开会。",
    "agent-sessions": "Claude Code 和 Codex 的会话，只取你的输入和最终回复。",
    "browser": "Chrome、Arc、Safari 等浏览器的访问记录。",
    "shell": "终端里执行的命令、所在目录、退出码和耗时。需要在 ~/.zshrc 里加一行钩子（见安装说明）。",
    "git": "在终端和 AI 会话里出现过的仓库，读它们的新提交。",
  ]

  var body: some View {
    let s = source
    SettingsForm {
      Section {
        Toggle(isOn: Binding(get: { s.enabled }, set: { store.perform(.setSource(s.id, $0)) })) {
          Text(s.title).font(.headline)
          if let text = Self.summaries[s.id] { Text(text) }
        }
        .toggleStyle(.switch)
      }
      if s.enabled {
        Section {
          if let name = s.permissionName {
            LabeledContent(name + "权限") {
              HStack(spacing: 8) {
                Text(permissionText(s.permission)).foregroundStyle(s.permission.satisfied ? AnyShapeStyle(.secondary) : AnyShapeStyle(.orange))
                if s.needsPermission { Button("授权…") { store.perform(.requestPermission(s.id)) } }
              }
            }
          }
          if !s.detail.isEmpty {
            LabeledContent("状态") { Text(s.detail).foregroundStyle(s.ok ? AnyShapeStyle(.secondary) : AnyShapeStyle(.orange)) }
          }
          if s.running || s.lastRun != nil || s.canRunNow {
            LabeledContent("上次运行") {
              HStack(spacing: 8) {
                Text(s.running ? "运行中…" : s.lastRun.map { ViewerFormat.clock($0) } ?? "还没运行过").foregroundStyle(.secondary)
                if s.canRunNow { Button("立即运行") { store.perform(.runSource(s.id)) }.disabled(s.running) }
              }
            }
          }
          if s.kind == .plugin && !store.capture.pluginsAvailable {
            SettingsMessage(text: "未配置 bun 或仓库路径（collector.json 的 bun、repo），这个数据源无法运行。")
          }
        }
        switch s.id {
        case "audio": AudioSourceSettings()
        case "files": FileDirectorySettings()
        default: EmptyView()
        }
      }
    }
  }

  func permissionText(_ p: SourcePermission) -> String {
    switch p {
    case .granted, .notNeeded: return "已授权"
    case .notDetermined: return "未授权"
    case .denied: return "已拒绝，需要到系统设置里打开"
    }
  }
}

/// 录音：麦克风、保留天数、清理。
private struct AudioSourceSettings: View {
  @Environment(ViewerStore.self) private var store
  @State private var days = 7
  @State private var savedDays: Int?
  @State private var error: String?
  @State private var status: String?
  @State private var confirmPurge = false

  var body: some View {
    let c = store.capture
    Section {
      Picker("麦克风", selection: Binding(get: { c.microphone }, set: { v in
        store.perform(.selectMicrophone(v))
        // 采集端在音频队列上写入设置，下一次快照才读得到；先按选中的显示。
        store.capture.microphone = v
      })) {
        ForEach(c.microphones.filter { $0.group == .mode }, id: \.self) { Text($0.title).tag($0.value) }
        Divider()
        ForEach(c.microphones.filter { $0.group != .mode }, id: \.self) { Text($0.title).tag($0.value).selectionDisabled(!$0.selectable) }
      }
      ForEach(MicrophoneChoices.statusLines(Array(c.audio.dropFirst())), id: \.self) { Text($0).foregroundStyle(.secondary) }
    }
    Section {
      LabeledContent("原始音频保留") {
        HStack(spacing: 8) {
          Text("\(days) 天").monospacedDigit()
          Stepper("原始音频保留", value: $days, in: 1...365).labelsHidden()
          if savedDays != nil, days != savedDays { Button("保存") { Task { await save() } } }
        }
      }
      LabeledContent("清理全部原始音频") {
        Button("清理…", role: .destructive) { confirmPurge = true }
      }
      if let status { SettingsMessage(text: status, warning: false) }
      if let error { SettingsMessage(text: error) }
    } footer: {
      Note("只删原始音频，转写出来的文字不受影响。")
    }
    .task { await load() }
    .confirmationDialog("清理全部音频？", isPresented: $confirmPurge) {
      Button("清理", role: .destructive) { Task { await purge() } }
      Button("取消", role: .cancel) {}
    } message: {
      Text("转写过的文字不受影响，还没转写的对话会丢失。清理在设备下次同步时执行，正在录制的对话不受影响。")
    }
  }

  func load() async {
    do { let d = try await store.api.retentionDays(); days = d; savedDays = d; error = nil }
    catch is CancellationError {}
    catch { self.error = error.localizedDescription }
  }
  func save() async {
    do { try await store.api.setRetentionDays(days); savedDays = days; status = "已保存"; error = nil }
    catch { self.error = error.localizedDescription }
  }
  func purge() async {
    do { try await store.api.purgeAudio(); status = "已请求清理，设备下次同步时执行"; error = nil }
    catch { self.error = error.localizedDescription }
  }
}

/// 文件：监听哪些目录。只接受主目录下的目录。
private struct FileDirectorySettings: View {
  @Environment(ViewerStore.self) private var store
  @State private var error: String?

  var body: some View {
    let dirs = store.capture.fileDirectories
    Section {
      ForEach(dirs, id: \.self) { d in
        LabeledContent {
          Button { set(dirs.filter { $0 != d }) } label: { PhIcon("minus-circle", size: 15) }
            .buttonStyle(.borderless).help("不再监听").accessibilityLabel("不再监听 \(d)")
        } label: {
          Text("~/" + d).font(.mono(12))
        }
      }
      if dirs.isEmpty { Text("没有监听任何目录").foregroundStyle(.secondary) }
      HStack {
        Button("添加目录…") { add(dirs) }
        if dirs != FileSourcePolicy.directories { Button("恢复默认") { set(FileSourcePolicy.directories) } }
      }
      if let error { SettingsMessage(text: error) }
    } header: {
      Text("监听的目录")
    } footer: {
      Note("子目录一起监听。隐藏目录、密码管理器的目录不记录。")
    }
  }

  func set(_ dirs: [String]) {
    error = nil
    store.perform(.setFileDirectories(dirs))
    store.capture.fileDirectories = FileDirectories.normalized(dirs)
  }

  func add(_ dirs: [String]) {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
    panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser
    panel.prompt = "监听"
    // 不用 runModal：模态循环期间采集端的定时器（屏幕、剪贴板、发送）全部停摆，选择框开多久就漏采多久。
    let handle: (NSApplication.ModalResponse) -> Void = { response in
      guard response == .OK, let url = panel.url else { return }
      guard let rel = FileSourcePolicy.relative(url.path, home: FileManager.default.homeDirectoryForCurrentUser.path) else {
        error = "只能选主目录下的目录（不含主目录本身、资源库和隐藏目录）。"; return
      }
      if let parent = FileDirectories.covering(rel, in: dirs) {
        error = parent == rel ? "~/\(rel) 已经在监听了。" : "~/\(rel) 已经包含在 ~/\(parent) 里，子目录本来就会一起监听。"; return
      }
      set(dirs + [rel])
    }
    if let window = NSApp.keyWindow { panel.beginSheetModal(for: window, completionHandler: handle) } else { panel.begin(completionHandler: handle) }
  }
}
